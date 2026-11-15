use std::{io::SeekFrom, os::unix::fs::MetadataExt};

use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncSeekExt},
};

use crate::protocol::{
    HostResult, IMAGE_CHUNK_BYTES, ImageMediaType, ImageRead, MAX_IMAGE_READ_BYTES,
};

const CHANGED: &str = "The file changed while it was read; read it again";

struct ImageFile {
    media_type: ImageMediaType,
    size_bytes: u64,
    stamp: String,
}

pub(super) async fn read_file(
    path: &str,
    offset: u32,
    limit: u32,
    image: Option<ImageRead>,
) -> Result<HostResult> {
    ensure!(
        limit > 0 && limit <= 256 * 1024,
        "Read limit must be between 1 and 262144 bytes"
    );
    let mut file = fs::File::open(path)
        .await
        .context("Could not read the requested file")?;
    match image {
        None => text(file, offset, limit).await,
        Some(ImageRead::Start) => match recognize(&mut file).await? {
            None => text(file, offset, limit).await,
            Some(seen) => {
                ensure!(
                    seen.size_bytes <= u64::from(MAX_IMAGE_READ_BYTES),
                    "{path} is an image ({}) of {} bytes; read_file takes images up to {MAX_IMAGE_READ_BYTES} bytes. Shrink a copy on the host with exec, then read the copy.",
                    serde_json::to_value(seen.media_type)?
                        .as_str()
                        .unwrap_or_default(),
                    seen.size_bytes,
                );
                chunk(file, &seen, 0).await
            }
        },
        Some(ImageRead::Next { at, stamp }) => {
            let seen = recognize(&mut file)
                .await?
                .filter(|seen| seen.stamp == stamp)
                .context(CHANGED)?;
            chunk(file, &seen, at).await
        }
    }
}

async fn text(mut file: fs::File, offset: u32, limit: u32) -> Result<HostResult> {
    file.seek(SeekFrom::Start(offset.into())).await?;
    let mut contents = Vec::new();
    file.take(u64::from(limit) + 1)
        .read_to_end(&mut contents)
        .await?;
    let truncated = contents.len() > usize::try_from(limit)?;
    contents.truncate(usize::try_from(limit)?);
    Ok(HostResult::File {
        content: String::from_utf8_lossy(&contents).into_owned(),
        truncated,
    })
}

/// Only a regular file is checked, so reading its header consumes nothing.
async fn recognize(file: &mut fs::File) -> Result<Option<ImageFile>> {
    let metadata = file.metadata().await?;
    if !metadata.is_file() {
        return Ok(None);
    }
    let mut header = Vec::with_capacity(32);
    (&mut *file).take(32).read_to_end(&mut header).await?;
    Ok(media_type(&header).map(|media_type| ImageFile {
        media_type,
        size_bytes: metadata.len(),
        stamp: stamp(&metadata),
    }))
}

/// Size and modification time catch a rewrite; device and inode catch a rename.
fn stamp(metadata: &std::fs::Metadata) -> String {
    format!(
        "{}:{}:{}:{}.{:09}",
        metadata.dev(),
        metadata.ino(),
        metadata.size(),
        metadata.mtime(),
        metadata.mtime_nsec()
    )
}

/// Signatures only; Photon is the decoder that judges the rest.
fn media_type(header: &[u8]) -> Option<ImageMediaType> {
    match header {
        [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', ..] => Some(ImageMediaType::Png),
        [0xff, 0xd8, 0xff, 0xf7, ..] => None,
        [0xff, 0xd8, 0xff, ..] => Some(ImageMediaType::Jpeg),
        [b'G', b'I', b'F', b'8', b'7' | b'9', b'a', ..] => Some(ImageMediaType::Gif),
        [
            b'R',
            b'I',
            b'F',
            b'F',
            _,
            _,
            _,
            _,
            b'W',
            b'E',
            b'B',
            b'P',
            ..,
        ] => Some(ImageMediaType::Webp),
        [b'B', b'M', ..] if bmp_header(header) => Some(ImageMediaType::Bmp),
        _ => None,
    }
}

/// A known DIB header size and one color plane, so text that starts with "BM" stays text.
fn bmp_header(header: &[u8]) -> bool {
    let Some(&[a, b, c, d]) = header.get(14..18) else {
        return false;
    };
    let planes = match u32::from_le_bytes([a, b, c, d]) {
        12 => 22,
        40..=124 => 26,
        _ => return false,
    };
    header.len() >= 26 && header.get(planes..planes + 2) == Some(&[1, 0])
}

async fn chunk(mut file: fs::File, seen: &ImageFile, at: u32) -> Result<HostResult> {
    let length = seen
        .size_bytes
        .checked_sub(u64::from(at))
        .filter(|remaining| *remaining > 0)
        .context(CHANGED)?
        .min(u64::from(IMAGE_CHUNK_BYTES));
    file.seek(SeekFrom::Start(at.into())).await?;
    let mut data = Vec::with_capacity(usize::try_from(length)?);
    (&mut file).take(length).read_to_end(&mut data).await?;
    ensure!(
        u64::try_from(data.len())? == length && stamp(&file.metadata().await?) == seen.stamp,
        CHANGED
    );
    Ok(HostResult::ImageChunk {
        media_type: seen.media_type,
        size_bytes: u32::try_from(seen.size_bytes)?,
        stamp: seen.stamp.clone(),
        at,
        data_base64: STANDARD.encode(data),
    })
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    use std::fs;

    use base64::{Engine, engine::general_purpose::STANDARD};

    use crate::{
        attachments::MAX_ATTACHMENT_BYTES,
        host::Executor,
        protocol::{
            HostCommand, HostResult, ImageMediaType, ImageRead, PROTOCOL_VERSION, RuntimeCommand,
            RuntimeRequest,
        },
        rex::RexClient,
        runtime::MAX_FRAME_BYTES,
    };

    const MIB: usize = 1024 * 1024;

    struct Host {
        directory: tempfile::TempDir,
        executor: Executor,
    }

    impl Host {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let executor = Executor::new(directory.path(), RexClient::for_process(None).unwrap());
            Self {
                directory,
                executor,
            }
        }

        fn file(&self, name: &str, bytes: &[u8]) -> String {
            let path = self.directory.path().join(name);
            fs::write(&path, bytes).unwrap();
            path.to_string_lossy().into_owned()
        }

        async fn read(
            &self,
            path: &str,
            offset: u32,
            limit: u32,
            image: Option<ImageRead>,
        ) -> HostResult {
            self.executor
                .execute(HostCommand::ReadFile {
                    path: path.into(),
                    offset,
                    limit,
                    image,
                })
                .await
        }
    }

    /// A PNG signature and IHDR header, then bytes that are not UTF-8.
    fn png_like(size: usize) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        bytes.extend((bytes.len()..size).map(|index| u8::try_from(index % 251).unwrap()));
        bytes
    }

    fn next(result: &HostResult) -> ImageRead {
        let HostResult::ImageChunk {
            stamp,
            at,
            data_base64,
            ..
        } = result
        else {
            panic!("Expected an image chunk, got {result:?}");
        };
        ImageRead::Next {
            at: at + u32::try_from(STANDARD.decode(data_base64).unwrap().len()).unwrap(),
            stamp: stamp.clone(),
        }
    }

    fn changed(result: &HostResult) -> bool {
        matches!(result, HostResult::Failed { message, .. } if message.contains("changed while it was read"))
    }

    #[tokio::test]
    async fn start_reads_an_image_by_its_header_and_a_read_without_image_stays_text() {
        let host = Host::new();
        let bytes = png_like(4096);
        let path = host.file("digit.txt", &bytes);
        let HostResult::ImageChunk {
            media_type,
            size_bytes,
            at,
            data_base64,
            ..
        } = host.read(&path, 0, 64_000, Some(ImageRead::Start)).await
        else {
            panic!("A PNG named .txt is an image");
        };
        assert_eq!((media_type, size_bytes, at), (ImageMediaType::Png, 4096, 0));
        assert_eq!(STANDARD.decode(data_base64).unwrap(), bytes);
        let HostResult::File { content, truncated } = host.read(&path, 0, 100, None).await else {
            panic!("A runtime that predates image reads gets text");
        };
        assert_eq!(content, String::from_utf8_lossy(&bytes[..100]));
        assert!(truncated);
    }

    fn bmp(dib_size: u8, planes: u8) -> Vec<u8> {
        let mut bytes = b"BM".to_vec();
        bytes.resize(14, 0);
        bytes.extend([dib_size, 0, 0, 0]);
        bytes.resize(if dib_size == 12 { 22 } else { 26 }, 0);
        bytes.extend([planes, 0, 24, 0]);
        bytes
    }

    #[tokio::test]
    async fn start_names_each_supported_image_by_its_signature() {
        let host = Host::new();
        let cases: [(&str, Vec<u8>, ImageMediaType); 6] = [
            ("a", png_like(64), ImageMediaType::Png),
            (
                "b",
                b"\xff\xd8\xff\xe0\0\x10JFIF".to_vec(),
                ImageMediaType::Jpeg,
            ),
            ("c", b"GIF87a\x01\0\x01\0".to_vec(), ImageMediaType::Gif),
            (
                "d",
                b"RIFF\x24\0\0\0WEBPVP8 ".to_vec(),
                ImageMediaType::Webp,
            ),
            ("e", bmp(12, 1), ImageMediaType::Bmp),
            ("f", bmp(40, 1), ImageMediaType::Bmp),
        ];
        for (name, bytes, expected) in cases {
            let path = host.file(name, &bytes);
            let result = host.read(&path, 0, 1, Some(ImageRead::Start)).await;
            assert!(
                matches!(&result, HostResult::ImageChunk { media_type, .. } if *media_type == expected),
                "{expected:?}: {result:?}"
            );
        }
    }

    #[tokio::test]
    async fn start_on_a_file_that_is_not_an_image_is_exactly_the_text_read() {
        let host = Host::new();
        let planes = bmp(40, 2);
        let cases: [(&str, &[u8], u32, u32); 8] = [
            ("notes.txt", b"alpha beta gamma\n", 6, 5),
            (
                "bmw.txt",
                b"BMW service notes: replace the cabin filter every spring.\n",
                0,
                64_000,
            ),
            ("split.txt", "h\u{e9}llo".as_bytes(), 0, 2),
            ("past.txt", b"tiny", 100, 10),
            ("gif.txt", b"GIF8", 0, 10),
            ("jpeg-ls.jls", b"\xff\xd8\xff\xf7 lossless", 0, 64),
            ("riff.wav", b"RIFF\x24\0\0\0WAVEfmt ", 0, 64),
            ("planes.bin", &planes, 0, 64),
        ];
        for (name, bytes, offset, limit) in cases {
            let path = host.file(name, bytes);
            let text = host.read(&path, offset, limit, None).await;
            assert!(matches!(text, HostResult::File { .. }), "{name}: {text:?}");
            assert_eq!(
                serde_json::to_value(
                    host.read(&path, offset, limit, Some(ImageRead::Start))
                        .await
                )
                .unwrap(),
                serde_json::to_value(text).unwrap(),
                "{name}"
            );
        }
    }

    #[tokio::test]
    async fn chunks_rebuild_a_large_image_byte_for_byte() {
        let host = Host::new();
        let bytes = png_like(5 * MIB / 2);
        let path = host.file("large.txt", &bytes);
        let mut received = Vec::new();
        let mut request = ImageRead::Start;
        let mut calls = 0;
        while received.len() < bytes.len() {
            let result = host.read(&path, 0, 1, Some(request)).await;
            calls += 1;
            let HostResult::ImageChunk {
                size_bytes,
                at,
                data_base64,
                ..
            } = &result
            else {
                panic!("Expected an image chunk, got {result:?}");
            };
            assert_eq!(usize::try_from(*size_bytes).unwrap(), bytes.len());
            assert_eq!(usize::try_from(*at).unwrap(), received.len());
            received.extend(STANDARD.decode(data_base64).unwrap());
            request = next(&result);
        }
        assert_eq!(received, bytes);
        assert_eq!(calls, 3, "1 MiB, 1 MiB, then the last half");
    }

    #[tokio::test]
    async fn a_file_that_changes_between_chunks_fails_instead_of_mixing_versions() {
        let host = Host::new();
        let bytes = png_like(3 * MIB / 2);
        let path = host.file("shot.png", &bytes);
        let first = host.read(&path, 0, 1, Some(ImageRead::Start)).await;
        assert!(
            matches!(
                host.read(&path, 0, 1, Some(next(&first))).await,
                HostResult::ImageChunk { .. }
            ),
            "An unchanged file continues"
        );
        let wrong = ImageRead::Next {
            at: 1024 * 1024,
            stamp: "fixture-stamp".into(),
        };
        assert!(changed(&host.read(&path, 0, 1, Some(wrong)).await));
        let HostResult::ImageChunk { stamp, .. } = &first else {
            panic!("Expected an image chunk, got {first:?}");
        };
        let past = ImageRead::Next {
            at: u32::try_from(bytes.len()).unwrap(),
            stamp: stamp.clone(),
        };
        assert!(changed(&host.read(&path, 0, 1, Some(past)).await));

        let mut rewritten = bytes.clone();
        rewritten[MIB + 10] ^= 1;
        fs::write(&path, &rewritten).unwrap();
        assert!(changed(&host.read(&path, 0, 1, Some(next(&first))).await));

        let restarted = host.read(&path, 0, 1, Some(ImageRead::Start)).await;
        let replacement = host.file("replacement.png", &rewritten);
        fs::rename(replacement, &path).unwrap();
        assert!(changed(
            &host.read(&path, 0, 1, Some(next(&restarted))).await
        ));
    }

    #[tokio::test]
    async fn an_image_over_the_cap_fails_before_any_chunk() {
        let host = Host::new();
        let path = host.file("huge.png", b"\x89PNG\r\n\x1a\n");
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(u64::from(MAX_ATTACHMENT_BYTES) + 1)
            .unwrap();
        let result = host.read(&path, 0, 64_000, Some(ImageRead::Start)).await;
        assert!(
            matches!(&result, HostResult::Failed { message, .. }
                if message.contains(&path) && message.contains("image/png") && message.contains("16777217")),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn a_full_chunk_reply_fits_half_a_frame() {
        let host = Host::new();
        let path = host.file("full.png", &png_like(2 * MIB));
        let result = host.read(&path, 0, 1, Some(ImageRead::Start)).await;
        assert!(
            matches!(&result, HostResult::ImageChunk { data_base64, .. } if STANDARD.decode(data_base64).unwrap().len() == MIB)
        );
        let frame = serde_json::to_vec(&RuntimeRequest {
            version: PROTOCOL_VERSION,
            id: u32::MAX,
            command: RuntimeCommand::HostReply {
                call_id: uuid::Uuid::new_v4().to_string(),
                result,
            },
        })
        .unwrap();
        assert!(frame.len() < MAX_FRAME_BYTES / 2, "{} bytes", frame.len());
    }
}
