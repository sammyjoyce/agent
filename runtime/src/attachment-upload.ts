import { randomUUID } from "node:crypto";
import { chmod, mkdir, open, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

// The writes of an attachment upload before it completes. They stay local on
// every coordinator: a reader takes an upload as real only once its metadata
// says it is complete, and the store writes that metadata, with the content,
// through RetainedFiles. These are the only other file writes under attachments/.

/** Creates an upload's folder, its empty content and its metadata, which says it is incomplete. */
export async function beginUpload(folder: string, metadata: { readonly complete: false }): Promise<void> {
  const root = dirname(folder);
  await mkdir(root, { recursive: true, mode: 0o700 }); await chmod(root, 0o700);
  await mkdir(folder, { mode: 0o700 });
  await writeFile(join(folder, "content"), Buffer.alloc(0), { flag: "wx", mode: 0o600 });
  // A torn metadata file would stop the quota scan of every later upload, so it takes its name only once synced.
  const temporary = join(folder, `.${randomUUID()}.tmp`);
  const file = await open(temporary, "wx", 0o600);
  try { await file.writeFile(JSON.stringify(metadata)); await file.sync(); } finally { await file.close(); }
  await rename(temporary, join(folder, "metadata.json"));
}

/**
 * Writes bytes at the end of an upload's content and syncs it, which also
 * makes an earlier unsynced chunk durable. Returns false when the file
 * stopped taking bytes.
 */
export async function writeChunk(content: string, end: number, bytes: Buffer): Promise<boolean> {
  const file = await open(content, "r+");
  try {
    for (let written = 0; written < bytes.length;) {
      const { bytesWritten } = await file.write(bytes, written, bytes.length - written, end + written);
      if (bytesWritten === 0) return false;
      written += bytesWritten;
    }
    await file.sync();
    return true;
  } finally { await file.close(); }
}
