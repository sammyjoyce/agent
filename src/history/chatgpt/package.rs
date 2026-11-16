use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    io::{self, Read},
    path::{Path, PathBuf},
};

use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{
    ChatGptPackageSummary, Corruption, Incompleteness, PackageError, PackageProgress, UnsafeReason,
    archive::{
        self, Admission, Hashing, Limits, MemberDigest, MemberPath, Method, Region, Spool, Tee,
        ZipMember,
    },
    conversation::{self, FileId, FileLookup, LibraryFile},
    json::{self, Element, Split, SplitError},
};
use crate::history::HistoryThread;

const PACKAGE_FORMAT: u32 = 1;
const THREAD_FORMAT: u32 = 1;
const MAXIMUM_PROBLEMS: usize = 100;
const MAXIMUM_ID_BYTES: usize = 256;
const MANIFEST: &str = "export_manifest.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(super) struct MemberId(usize);

pub(super) struct IndexedFile {
    pub member: MemberId,
    pub digest: MemberDigest,
}

pub(super) struct Member {
    pub path: MemberPath,
    pub size: u64,
    part: usize,
    location: Location,
}

enum Location {
    File(PathBuf),
    Entry { archive: Region, entry: ZipMember },
}

impl Member {
    pub fn open(&self) -> io::Result<Box<dyn Read + Send>> {
        match &self.location {
            Location::File(path) => Ok(Box::new(archive::Exact::new(
                archive::open_regular(path)?,
                self.size,
                None,
            ))),
            Location::Entry { archive, entry } => entry.open(archive),
        }
    }

    pub fn region(&self) -> io::Result<Option<Region>> {
        match &self.location {
            Location::File(path) => Region::whole(archive::open_regular(path)?).map(Some),
            Location::Entry { archive, entry }
                if entry.method == Method::Stored && entry.size == entry.compressed =>
            {
                archive.slice(entry.data_start, entry.size).map(Some)
            }
            _ => Ok(None),
        }
    }
}

pub(super) struct Span {
    shard: usize,
    start: u64,
    len: u64,
    sha256: [u8; 32],
}

pub(super) struct ConversationEntry {
    pub thread: HistoryThread,
    pub span: Span,
    content: [u8; 32],
}

pub(super) struct SpanChanged;

pub(super) struct Package {
    members: Vec<Member>,
    shards: Vec<Region>,
    conversations: Vec<ConversationEntry>,
    by_id: HashMap<String, usize>,
    files: HashMap<FileId, IndexedFile>,
    original_names: HashMap<String, String>,
    library: HashMap<String, Vec<LibraryFile>>,
    pub summary: ChatGptPackageSummary,
}

enum Input {
    Folder(PathBuf),
    Json(PathBuf),
    Zip(Region),
}

impl Package {
    pub fn open(
        paths: &[PathBuf],
        limits: Limits,
        progress: &mut dyn FnMut(PackageProgress),
    ) -> Result<Self, PackageError> {
        let mut builder = Builder {
            limits,
            admission: Admission::new(limits),
            members: Vec::new(),
            parts: Vec::new(),
            zip_parts: Vec::new(),
            spool_remaining: limits.spool_bytes,
            read_whole: HashSet::new(),
        };
        for path in resolve(paths)? {
            let name = path
                .file_name()
                .map(|name| archive::shown(&name.to_string_lossy()))
                .unwrap_or_default();
            progress(PackageProgress::Part { name: name.clone() });
            builder.add_part(name, path)?;
        }
        if !builder.has_conversation_data() {
            builder.open_nested(progress)?;
        }
        let shard_members = builder.shard_members()?;
        let mut scan = Scan::default();
        let mut shards = Vec::new();
        let count = shard_members.len() as u32;
        for (index, member) in shard_members.into_iter().enumerate() {
            let name = builder.members[member.0].path.as_str().to_owned();
            progress(PackageProgress::Shard {
                name: name.clone(),
                index: index as u32 + 1,
                count,
            });
            let bytes = builder.read_shard(member, shards.len(), &mut scan)?;
            shards.push(bytes);
        }
        let Builder {
            members,
            parts,
            read_whole,
            ..
        } = builder;
        let files = verify(&members, file_index(&members), &read_whole, progress)?;
        let (library, original_names) = sidecars(&members, &limits, &mut scan);
        Ok(scan.finish(
            members,
            shards,
            files,
            library,
            original_names,
            parts,
            count,
        ))
    }

    pub fn conversations(&self) -> &[ConversationEntry] {
        &self.conversations
    }

    pub fn conversation(&self, id: &str) -> Option<&ConversationEntry> {
        self.by_id.get(id).map(|index| &self.conversations[*index])
    }

    pub fn read_conversation(&self, entry: &ConversationEntry) -> Result<Value, SpanChanged> {
        let span = &entry.span;
        let mut bytes = vec![0; usize::try_from(span.len).map_err(|_| SpanChanged)?];
        self.shards[span.shard]
            .read_exact_at(&mut bytes, span.start)
            .map_err(|_| SpanChanged)?;
        if <[u8; 32]>::from(Sha256::digest(&bytes)) != span.sha256 {
            return Err(SpanChanged);
        }
        let (repaired, _) = json::repair(&bytes);
        serde_json::from_slice(&repaired).map_err(|_| SpanChanged)
    }

    pub fn file(&self, id: &FileId) -> Option<&IndexedFile> {
        self.files.get(id)
    }

    pub fn member(&self, id: MemberId) -> &Member {
        &self.members[id.0]
    }

    pub fn library(&self, conversation: &str) -> &[LibraryFile] {
        self.library.get(conversation).map_or(&[], Vec::as_slice)
    }
}

impl FileLookup for Package {
    fn stored(&self, file: &FileId) -> Option<(&str, &MemberDigest)> {
        self.file(file).map(|indexed| {
            (
                self.member(indexed.member).path.file_name(),
                &indexed.digest,
            )
        })
    }

    fn original_name(&self, stored: &str) -> Option<&str> {
        self.original_names.get(stored).map(String::as_str)
    }
}

fn unreadable(path: &Path, error: io::Error) -> PackageError {
    PackageError::Unreadable {
        path: archive::shown(&path.to_string_lossy()),
        reason: error.to_string(),
    }
}

fn resolve(paths: &[PathBuf]) -> Result<Vec<PathBuf>, PackageError> {
    let mut seen = BTreeSet::new();
    let mut parts = Vec::new();
    for path in paths {
        let canonical = std::fs::canonicalize(path).map_err(|error| unreadable(path, error))?;
        for part in archive::sibling_parts(&canonical)? {
            if seen.insert(part.clone()) {
                parts.push(part);
            }
        }
    }
    Ok(parts)
}

fn input(part: PathBuf) -> Result<Input, PackageError> {
    let metadata = std::fs::metadata(&part).map_err(|error| unreadable(&part, error))?;
    if metadata.is_dir() {
        return Ok(Input::Folder(part));
    }
    let file = archive::open_regular(&part).map_err(|error| unreadable(&part, error))?;
    let mut magic = [0; 4];
    let zip = std::os::unix::fs::FileExt::read_exact_at(&file, &mut magic, 0).is_ok()
        && (magic == *b"PK\x03\x04" || magic == *b"PK\x05\x06");
    if zip {
        Ok(Input::Zip(
            Region::whole(file).map_err(|error| unreadable(&part, error))?,
        ))
    } else {
        Ok(Input::Json(part))
    }
}

struct Builder {
    limits: Limits,
    admission: Admission,
    members: Vec<Member>,
    parts: Vec<String>,
    zip_parts: Vec<usize>,
    spool_remaining: u64,
    read_whole: HashSet<MemberId>,
}

impl Builder {
    fn part(&mut self, name: String) -> Result<usize, PackageError> {
        self.admission.part()?;
        self.parts.push(name);
        Ok(self.parts.len() - 1)
    }

    fn add_part(&mut self, name: String, path: PathBuf) -> Result<(), PackageError> {
        let part = self.part(name.clone())?;
        match input(path)? {
            Input::Folder(root) => {
                for member in archive::walk_folder(&root, &mut self.admission)? {
                    self.members.push(Member {
                        path: member.path,
                        size: member.size,
                        part,
                        location: Location::File(member.file),
                    });
                }
            }
            Input::Json(path) => {
                let size = std::fs::metadata(&path)
                    .map_err(|error| PackageError::Unreadable {
                        path: name.clone(),
                        reason: error.to_string(),
                    })?
                    .len();
                self.admission.member(size)?;
                self.members.push(Member {
                    path: MemberPath::parse(b"conversations.json", &self.limits)?,
                    size,
                    part,
                    location: Location::File(path),
                });
            }
            Input::Zip(region) => {
                self.zip_parts.push(part);
                self.add_zip(part, &name, region)?;
            }
        }
        Ok(())
    }

    fn add_zip(&mut self, part: usize, name: &str, region: Region) -> Result<(), PackageError> {
        for entry in archive::zip_members(name, &region, &mut self.admission)? {
            self.members.push(Member {
                path: entry.path.clone(),
                size: entry.size,
                part,
                location: Location::Entry {
                    archive: region.clone(),
                    entry,
                },
            });
        }
        Ok(())
    }

    fn has_conversation_data(&self) -> bool {
        self.members.iter().any(|member| {
            member.path.is_root()
                && (member.path.as_str() == MANIFEST
                    || shard_number(member.path.as_str()).is_some())
        })
    }

    /// A privacy-portal export is a ZIP of ZIPs. When no part holds conversation data at its
    /// root, root-level ZIPs of the top-level ZIP parts open as parts, one level deep.
    fn open_nested(
        &mut self,
        progress: &mut dyn FnMut(PackageProgress),
    ) -> Result<(), PackageError> {
        let nested: Vec<usize> = (0..self.members.len())
            .filter(|index| {
                let member = &self.members[*index];
                self.zip_parts.contains(&member.part)
                    && member.path.is_root()
                    && member.path.as_str().to_ascii_lowercase().ends_with(".zip")
            })
            .collect();
        for index in nested {
            let name = self.members[index].path.as_str().to_owned();
            progress(PackageProgress::Part { name: name.clone() });
            let part = self.part(name.clone())?;
            let damaged = |error: io::Error| member_error(&name, error);
            let mut reader = self.members[index].open().map_err(damaged)?;
            let region = match self.members[index].region().map_err(damaged)? {
                Some(region) => {
                    io::copy(&mut reader, &mut io::sink()).map_err(damaged)?;
                    region
                }
                None => {
                    let mut spool = Spool::create(self.spool_remaining).map_err(damaged)?;
                    io::copy(&mut reader, &mut spool).map_err(damaged)?;
                    self.spool_remaining -= spool.len();
                    spool.into_region()
                }
            };
            self.read_whole.insert(MemberId(index));
            self.add_zip(part, &name, region)?;
        }
        Ok(())
    }

    fn shard_members(&self) -> Result<Vec<MemberId>, PackageError> {
        let mut present: BTreeMap<String, MemberId> = BTreeMap::new();
        let mut manifests: Vec<Value> = Vec::new();
        for (index, member) in self.members.iter().enumerate() {
            if !member.path.is_root() {
                continue;
            }
            let name = member.path.as_str();
            if name == MANIFEST {
                let bytes = read_small(member, self.limits.conversation_bytes)?;
                let value: Value =
                    serde_json::from_slice(&bytes).map_err(|_| PackageError::Corrupt {
                        member: MANIFEST.into(),
                        reason: Corruption::NotJson,
                    })?;
                if !manifests.contains(&value) {
                    manifests.push(value);
                }
            } else if shard_number(name).is_some()
                && present.insert(name.to_owned(), MemberId(index)).is_some()
            {
                return Err(PackageError::Unsafe {
                    member: name.to_owned(),
                    reason: UnsafeReason::DuplicateName,
                });
            }
        }
        if manifests.len() > 1 {
            return Err(incomplete(Incompleteness::ConflictingManifests));
        }
        let listed = match manifests.first() {
            Some(manifest) => self.manifest_shards(manifest)?,
            None => None,
        };
        let order: Vec<String> = match listed {
            Some(listed) => {
                for name in &listed {
                    if !present.contains_key(name) {
                        return Err(incomplete(Incompleteness::MissingShard {
                            name: name.clone(),
                        }));
                    }
                }
                if let Some(name) = present.keys().find(|name| !listed.contains(name)) {
                    return Err(incomplete(Incompleteness::UnlistedShard {
                        name: name.clone(),
                    }));
                }
                listed
            }
            None => numbered_shards(&present)?,
        };
        if order.is_empty() {
            return Err(PackageError::Empty);
        }
        Ok(order.iter().map(|name| present[name]).collect())
    }

    fn manifest_shards(&self, manifest: &Value) -> Result<Option<Vec<String>>, PackageError> {
        if let Some(logical) = manifest.pointer("/logical_files/conversations.json") {
            let files: Vec<String> = logical
                .get("files")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|file| {
                    file.as_str()
                        .or_else(|| file.get("path").and_then(Value::as_str))
                        .map(str::to_owned)
                })
                .collect();
            if let Some(declared) = logical.get("shard_count").and_then(Value::as_u64)
                && declared != files.len() as u64
            {
                return Err(incomplete(Incompleteness::ShardCountMismatch {
                    declared: declared as u32,
                    found: files.len() as u32,
                }));
            }
            if files.is_empty() {
                return Ok(Some(vec!["conversations.json".into()]));
            }
            return Ok(Some(files));
        }
        let Some(inventory) = manifest.get("export_files").and_then(Value::as_array) else {
            return Ok(None);
        };
        let mut listed = Vec::new();
        for file in inventory {
            let Some(path) = file.get("path").and_then(Value::as_str) else {
                continue;
            };
            let size = file.get("size_bytes").and_then(Value::as_u64);
            let member = self
                .members
                .iter()
                .find(|member| member.path.as_str() == path);
            if let (Some(member), Some(size)) = (member, size)
                && member.size != size
            {
                return Err(incomplete(Incompleteness::InventorySizeMismatch {
                    path: archive::shown(path),
                }));
            }
            if shard_number(path).is_some() {
                listed.push(path.to_owned());
            }
        }
        Ok((!listed.is_empty()).then_some(listed))
    }

    fn read_shard(
        &mut self,
        member: MemberId,
        shard: usize,
        scan: &mut Scan,
    ) -> Result<Region, PackageError> {
        let name = self.members[member.0].path.as_str().to_owned();
        let damaged = |error: io::Error| member_error(&name, error);
        let maximum = self.limits.conversation_bytes;
        let source = &self.members[member.0];
        let mut reader = source.open().map_err(damaged)?;
        let mut handle = |element: Element<'_>| scan.element(&name, shard, element);
        let region = match source.region().map_err(damaged)? {
            Some(region) => {
                split(&name, &mut reader, maximum, &mut handle)?;
                region
            }
            None => {
                let mut spool = Spool::create(self.spool_remaining).map_err(damaged)?;
                let mut tee = Tee {
                    inner: reader,
                    spool: &mut spool,
                };
                split(&name, &mut tee, maximum, &mut handle)?;
                self.spool_remaining -= spool.len();
                spool.into_region()
            }
        };
        self.read_whole.insert(member);
        Ok(region)
    }
}

fn split(
    name: &str,
    reader: &mut dyn Read,
    maximum: usize,
    handle: &mut dyn FnMut(Element<'_>) -> Result<(), PackageError>,
) -> Result<(), PackageError> {
    json::split_conversations(reader, maximum, handle).map_err(|error| match error {
        Split::Element(error) => error,
        Split::Shape(SplitError::NotJson) => PackageError::Corrupt {
            member: name.to_owned(),
            reason: Corruption::NotJson,
        },
        Split::Shape(SplitError::Read(error)) => member_error(name, error),
    })
}

fn member_error(name: &str, error: io::Error) -> PackageError {
    if let Some(full) = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<archive::SpoolFull>())
    {
        return PackageError::Bounds {
            what: "private spool",
            limit: full.limit,
            found: full.limit.saturating_add(1),
        };
    }
    match archive::corruption(&error) {
        Some(reason) => PackageError::Corrupt {
            member: archive::shown(name),
            reason,
        },
        None => PackageError::Unreadable {
            path: archive::shown(name),
            reason: error.to_string(),
        },
    }
}

fn incomplete(reason: Incompleteness) -> PackageError {
    PackageError::Incomplete { reason }
}

fn read_small(member: &Member, maximum: usize) -> Result<Vec<u8>, PackageError> {
    let name = member.path.as_str();
    if member.size > maximum as u64 {
        return Err(PackageError::Bounds {
            what: "sidecar size",
            limit: maximum as u64,
            found: member.size,
        });
    }
    let mut bytes = Vec::new();
    member
        .open()
        .and_then(|mut reader| reader.read_to_end(&mut bytes))
        .map_err(|error| member_error(name, error))?;
    Ok(bytes)
}

fn shard_number(name: &str) -> Option<u32> {
    if name == "conversations.json" {
        return Some(0);
    }
    let digits = name.strip_prefix("conversations-")?.strip_suffix(".json")?;
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

fn numbered_shards(present: &BTreeMap<String, MemberId>) -> Result<Vec<String>, PackageError> {
    if present.contains_key("conversations.json") {
        if present.len() > 1 {
            return Err(incomplete(Incompleteness::AmbiguousConversations));
        }
        return Ok(vec!["conversations.json".into()]);
    }
    let mut numbered: Vec<(u32, &String)> = present
        .keys()
        .filter_map(|name| Some((shard_number(name)?, name)))
        .collect();
    numbered.sort();
    for (expected, (number, _)) in (0..).zip(&numbered) {
        if *number != expected {
            return Err(incomplete(Incompleteness::MissingShard {
                name: format!("conversations-{expected:03}.json"),
            }));
        }
    }
    Ok(numbered.into_iter().map(|(_, name)| name.clone()).collect())
}

fn sidecars(
    members: &[Member],
    limits: &Limits,
    scan: &mut Scan,
) -> (HashMap<String, Vec<LibraryFile>>, HashMap<String, String>) {
    let mut library: HashMap<String, Vec<LibraryFile>> = HashMap::new();
    let mut names = HashMap::new();
    for member in members.iter().filter(|member| member.path.is_root()) {
        let normalized = member.path.as_str().to_ascii_lowercase().replace('-', "_");
        let sidecar = match normalized.as_str() {
            "library_files.json" | "conversation_asset_file_names.json" => normalized,
            _ => continue,
        };
        let parsed = read_small(member, limits.conversation_bytes)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&json::repair(&bytes).0).ok());
        let accepted = match (sidecar.as_str(), parsed) {
            ("library_files.json", Some(Value::Array(entries))) => {
                for entry in entries {
                    if let Some((conversation, file)) = library_file(entry) {
                        library.entry(conversation).or_default().push(file);
                    }
                }
                true
            }
            (_, Some(Value::Object(map))) if sidecar != "library_files.json" => {
                for (stored, original) in map {
                    if let Value::String(original) = original {
                        names.insert(stored, original);
                    }
                }
                true
            }
            _ => false,
        };
        if !accepted {
            scan.problem(format!(
                "{} could not be read, so its file details are not imported",
                archive::shown(member.path.as_str())
            ));
        }
    }
    for files in library.values_mut() {
        files.sort_by(|left, right| {
            left.created_at
                .unwrap_or(0.0)
                .total_cmp(&right.created_at.unwrap_or(0.0))
                .then_with(|| left.file.cmp(&right.file))
        });
    }
    (library, names)
}

/// A live library entry and the conversation it belongs to. Trashed, deleted and pasted
/// canvas text (`writing_block`) entries are not files anyone can open.
fn library_file(entry: Value) -> Option<(String, LibraryFile)> {
    let text = |key: &str| entry.get(key).and_then(Value::as_str).map(str::to_owned);
    let live = ["trashed_at", "deleted_at"]
        .iter()
        .all(|key| entry.get(*key).is_none_or(Value::is_null));
    if !live || text("library_artifact_type").as_deref() == Some("writing_block") {
        return None;
    }
    let conversation = text("origination_thread_id")?;
    let file = FileId::find(&text("file_id")?)?;
    Some((
        conversation,
        LibraryFile {
            file,
            name: text("file_name"),
            mime_type: text("mime_type"),
            origination_message: text("origination_message_id"),
            created_at: entry.get("created_at").and_then(conversation::seconds),
        },
    ))
}

/// Reads every member to its end, so a damaged byte anywhere in the export refuses it before
/// anything is imported. Shards and nested archives were already read whole while opening.
fn verify(
    members: &[Member],
    index: HashMap<FileId, MemberId>,
    read_whole: &HashSet<MemberId>,
    progress: &mut dyn FnMut(PackageProgress),
) -> Result<HashMap<FileId, IndexedFile>, PackageError> {
    let mut indexed: HashMap<MemberId, FileId> = index
        .into_iter()
        .map(|(file, member)| (member, file))
        .collect();
    let pending: Vec<MemberId> = (0..members.len())
        .map(MemberId)
        .filter(|member| indexed.contains_key(member) || !read_whole.contains(member))
        .collect();
    progress(PackageProgress::Files {
        count: pending.len() as u32,
        bytes: pending.iter().map(|member| members[member.0].size).sum(),
    });
    let mut files = HashMap::with_capacity(indexed.len());
    for member in pending {
        let source = &members[member.0];
        let damaged = |error: io::Error| member_error(source.path.as_str(), error);
        let mut reader = source.open().map_err(damaged)?;
        match indexed.remove(&member) {
            Some(file) => {
                let mut hashing = Hashing::default();
                io::copy(&mut reader, &mut hashing).map_err(damaged)?;
                let digest = hashing.finish(source.size);
                files.insert(file, IndexedFile { member, digest });
            }
            None => {
                io::copy(&mut reader, &mut io::sink()).map_err(damaged)?;
            }
        }
    }
    Ok(files)
}

fn file_index(members: &[Member]) -> HashMap<FileId, MemberId> {
    let mut files: HashMap<FileId, MemberId> = HashMap::new();
    for (index, member) in members.iter().enumerate() {
        let Some(file) = FileId::find(member.path.file_name()) else {
            continue;
        };
        let rank = |member: &Member| (!member.path.is_root(), member.path.clone(), member.part);
        match files.get(&file) {
            Some(existing) if rank(&members[existing.0]) <= rank(member) => {}
            _ => {
                files.insert(file, MemberId(index));
            }
        }
    }
    files
}

struct Surveyed {
    survey: conversation::Survey,
    repairs: u32,
}

#[derive(Default)]
struct Scan {
    conversations: Vec<ConversationEntry>,
    by_id: HashMap<String, usize>,
    surveys: HashMap<String, Surveyed>,
    skipped: u32,
    problems: Vec<String>,
    problem_count: usize,
}

impl Scan {
    fn problem(&mut self, problem: String) {
        self.problem_count += 1;
        if self.problems.len() < MAXIMUM_PROBLEMS {
            self.problems.push(problem);
        }
    }

    fn element(
        &mut self,
        name: &str,
        shard: usize,
        element: Element<'_>,
    ) -> Result<(), PackageError> {
        let (offset, bytes) = match element {
            Element::Oversized { offset, len } => {
                self.problem(format!(
                    "The conversation at byte {offset} of {name} is {len} bytes, over the import limit, and was not imported"
                ));
                return Ok(());
            }
            Element::Value { offset, bytes } => (offset, bytes),
        };
        let sha256: [u8; 32] = Sha256::digest(bytes).into();
        let (repaired, repairs) = json::repair(bytes);
        let Ok(value) = serde_json::from_slice::<Value>(&repaired) else {
            self.problem(format!(
                "The entry at byte {offset} of {name} is not valid JSON and was not imported"
            ));
            return Ok(());
        };
        let object = match &value {
            Value::Object(object) if !object.is_empty() => object,
            _ => {
                self.skipped += 1;
                return Ok(());
            }
        };
        let id = object
            .get("id")
            .or_else(|| object.get("conversation_id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty());
        let (Some(id), Some(mapping)) = (id, object.get("mapping").and_then(Value::as_object))
        else {
            self.problem(format!(
                "The entry at byte {offset} of {name} has no conversation id or messages and was not imported"
            ));
            return Ok(());
        };
        if id.len() > MAXIMUM_ID_BYTES || mapping.keys().any(|node| node.len() > MAXIMUM_ID_BYTES) {
            self.problem(format!(
                "The conversation at byte {offset} of {name} has a conversation or message id over {MAXIMUM_ID_BYTES} bytes and was not imported"
            ));
            return Ok(());
        }
        let content: [u8; 32] = Sha256::digest(json::canonical(&value)).into();
        let entry = ConversationEntry {
            thread: conversation::thread(id, &value, String::new()),
            span: Span {
                shard,
                start: offset,
                len: bytes.len() as u64,
                sha256,
            },
            content,
        };
        let survey = Surveyed {
            survey: conversation::survey(&value),
            repairs,
        };
        if let Some(existing) = self.by_id.get(id).copied() {
            let previous = &self.conversations[existing];
            if previous.content == content {
                return Ok(());
            }
            let newer = (entry.thread.updated_at, entry.content)
                > (previous.thread.updated_at, previous.content);
            self.problem(format!(
                "Conversation {} appears more than once with different content; the newer copy is imported",
                archive::shown(id)
            ));
            if newer {
                self.conversations[existing] = entry;
                self.surveys.insert(id.to_owned(), survey);
            }
        } else {
            self.by_id.insert(id.to_owned(), self.conversations.len());
            self.conversations.push(entry);
            self.surveys.insert(id.to_owned(), survey);
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn finish(
        mut self,
        members: Vec<Member>,
        shards: Vec<Region>,
        files: HashMap<FileId, IndexedFile>,
        mut library: HashMap<String, Vec<LibraryFile>>,
        original_names: HashMap<String, String>,
        parts: Vec<String>,
        shard_count: u32,
    ) -> Package {
        library.retain(|conversation, entries| {
            let Some(surveyed) = self.surveys.get(conversation) else {
                return false;
            };
            entries.retain(|file| surveyed.survey.keeps(file));
            !entries.is_empty()
        });
        let mut referenced = BTreeSet::new();
        let (mut excluded, mut repaired) = (0, 0);
        for Surveyed { survey, repairs } in self.surveys.values() {
            excluded += survey.excluded;
            repaired += repairs;
        }
        for entry in &mut self.conversations {
            let library_files = library.get(&entry.thread.id).map_or(&[][..], Vec::as_slice);
            let mut own: BTreeSet<&FileId> = library_files.iter().map(|file| &file.file).collect();
            if let Some(surveyed) = self.surveys.get(&entry.thread.id) {
                own.extend(&surveyed.survey.files);
            }
            let checked: Vec<(&str, Option<&str>)> = own
                .iter()
                .map(|file| {
                    let sha256 = files
                        .get(*file)
                        .map(|indexed| indexed.digest.sha256.as_str());
                    (file.as_str(), sha256)
                })
                .collect();
            let entries: Vec<Value> = library_files
                .iter()
                .map(|file| {
                    serde_json::json!([
                        file.file.as_str(),
                        file.name,
                        file.mime_type,
                        file.origination_message,
                        file.created_at,
                    ])
                })
                .collect();
            entry.thread.version = digest(&serde_json::json!([
                THREAD_FORMAT,
                conversation::ITEM_FORMAT,
                entry.thread.id,
                hex::encode(entry.content),
                entries,
                checked,
            ]));
            referenced.extend(own.into_iter().cloned());
        }
        self.conversations.sort_by(|left, right| {
            right
                .thread
                .updated_at
                .cmp(&left.thread.updated_at)
                .then_with(|| left.thread.id.cmp(&right.thread.id))
        });
        let by_id = self
            .conversations
            .iter()
            .enumerate()
            .map(|(index, entry)| (entry.thread.id.clone(), index))
            .collect();
        let missing = referenced
            .iter()
            .filter(|file| !files.contains_key(*file))
            .count();
        let mut notes = Vec::new();
        if self.skipped > 0 {
            notes.push(format!(
                "{} empty or non-conversation entries are skipped",
                self.skipped
            ));
        }
        if repaired > 0 {
            notes.push(format!(
                "{repaired} broken characters are replaced with U+FFFD"
            ));
        }
        if self.problem_count > self.problems.len() {
            let more = self.problem_count - self.problems.len();
            self.problems
                .push(format!("{more} more problems are not listed"));
        }
        let mut pairs: Vec<(&str, &str)> = self
            .conversations
            .iter()
            .map(|entry| (entry.thread.id.as_str(), entry.thread.version.as_str()))
            .collect();
        pairs.sort();
        let mut hashes: Vec<(&str, &str)> = files
            .iter()
            .map(|(file, indexed)| (file.as_str(), indexed.digest.sha256.as_str()))
            .collect();
        hashes.sort();
        let summary = ChatGptPackageSummary {
            digest: digest(&serde_json::json!([PACKAGE_FORMAT, pairs, hashes])),
            parts,
            conversations: self.conversations.len() as u32,
            archived: self
                .conversations
                .iter()
                .filter(|entry| entry.thread.archived)
                .count() as u32,
            shards: shard_count,
            attachments: referenced.len() as u32,
            missing_attachments: missing as u32,
            excluded_messages: excluded,
            notes,
            problems: self.problems,
        };
        Package {
            members,
            shards,
            conversations: self.conversations,
            by_id,
            files,
            original_names,
            library,
            summary,
        }
    }
}

fn digest(value: &Value) -> String {
    hex::encode(Sha256::digest(json::canonical(value)))
}

#[cfg(test)]
mod tests {
    use std::{os::unix::ffi::OsStrExt, path::Path, time::Duration};

    use serde_json::{Value, json};

    use super::*;
    use crate::history::chatgpt::fixture::{self, Conversation, Export, Forge};

    fn open_with(paths: &[PathBuf], limits: Limits) -> Result<Package, PackageError> {
        Package::open(paths, limits, &mut |_| {})
    }

    fn open(path: &Path) -> Result<Package, PackageError> {
        open_with(&[path.to_path_buf()], Limits::default())
    }

    fn refused(result: Result<Package, PackageError>) -> PackageError {
        match result {
            Ok(_) => panic!("the package was admitted"),
            Err(error) => {
                assert!(
                    error.to_string().ends_with("Nothing was imported."),
                    "{error}"
                );
                error
            }
        }
    }

    fn picnic(number: u8) -> Value {
        Conversation::new(number, &format!("Picnic {number}"))
            .say("u1", "root", "user", "Plan a picnic for six")
            .say("a1", "u1", "assistant", "Here is a plan for six.")
            .build()
    }

    fn listed(package: &Package, archived: bool) -> Vec<String> {
        package
            .conversations()
            .iter()
            .filter(|entry| entry.thread.archived == archived)
            .map(|entry| entry.thread.id.clone())
            .collect()
    }

    fn member_bytes(package: &Package, file: &str) -> Vec<u8> {
        let indexed = package.file(&FileId::find(file).unwrap()).unwrap();
        let mut bytes = Vec::new();
        package
            .member(indexed.member)
            .open()
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        bytes
    }

    fn image_message(pointer: &str) -> Value {
        json!({
            "author": {"role": "user"},
            "content": {"content_type": "multimodal_text", "parts": [
                {"content_type": "image_asset_pointer", "asset_pointer": pointer},
                "What is in this picture?"
            ]},
        })
    }

    fn incomplete_reason(error: PackageError) -> Incompleteness {
        match error {
            PackageError::Incomplete { reason } => reason,
            other => panic!("expected an incomplete package, got {other}"),
        }
    }

    fn unsafe_reason(error: PackageError) -> UnsafeReason {
        match error {
            PackageError::Unsafe { reason, .. } => reason,
            other => panic!("expected an unsafe package, got {other}"),
        }
    }

    fn corruption(error: PackageError) -> Corruption {
        match error {
            PackageError::Corrupt { reason, .. } => reason,
            other => panic!("expected a damaged package, got {other}"),
        }
    }

    fn bound(error: PackageError) -> &'static str {
        match error {
            PackageError::Bounds { what, .. } => what,
            other => panic!("expected a bound, got {other}"),
        }
    }

    #[test]
    fn single_conversations_json_zip_lists_every_conversation() {
        let directory = tempfile::tempdir().unwrap();
        let archived = Conversation::new(3, "Old")
            .say("u1", "root", "user", "Archived question")
            .set("is_archived", json!(true))
            .build();
        let path = Export::new()
            .conversations(&[picnic(1), picnic(2), archived])
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        assert_eq!(package.summary.conversations, 3);
        assert_eq!(package.summary.archived, 1);
        assert_eq!(package.summary.shards, 1);
        assert_eq!(package.summary.parts, ["export.zip"]);
        assert_eq!(listed(&package, false), [fixture::id(2), fixture::id(1)]);
        assert_eq!(listed(&package, true), [fixture::id(3)]);
    }

    #[test]
    fn bare_conversations_json_file_imports_text_and_reports_attachments_missing() {
        let directory = tempfile::tempdir().unwrap();
        let conversation = Conversation::new(1, "Photo")
            .node("u1", Some("root"), image_message("sediment://file_00ab12"))
            .build();
        let path = directory.path().join("conversations.json");
        std::fs::write(&path, serde_json::to_vec(&[conversation]).unwrap()).unwrap();
        let package = open(&path).unwrap();
        assert_eq!(package.summary.conversations, 1);
        assert_eq!(package.summary.attachments, 1);
        assert_eq!(package.summary.missing_attachments, 1);
    }

    fn manifest(files: &[&str], shard_count: usize) -> Value {
        json!({"version": 1, "logical_files": {"conversations.json": {
            "files": files, "sharded": true, "shard_count": shard_count}}})
    }

    #[test]
    fn manifest_shards_are_read_in_manifest_order() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .json(
                "export_manifest.json",
                &manifest(&["conversations-001.json", "conversations-000.json"], 2),
            )
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-001.json", &[picnic(2)])
            .zip(&directory.path().join("export.zip"));
        let mut shards = Vec::new();
        let package = Package::open(&[path], Limits::default(), &mut |step| {
            if let PackageProgress::Shard { name, .. } = step {
                shards.push(name);
            }
        })
        .unwrap();
        assert_eq!(package.summary.shards, 2);
        assert_eq!(shards, ["conversations-001.json", "conversations-000.json"]);
        assert_eq!(listed(&package, false), [fixture::id(2), fixture::id(1)]);
    }

    #[test]
    fn missing_manifest_shard_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .json(
                "export_manifest.json",
                &manifest(
                    &[
                        "conversations-000.json",
                        "conversations-001.json",
                        "conversations-002.json",
                    ],
                    3,
                ),
            )
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-001.json", &[picnic(2)])
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::MissingShard {
                name: "conversations-002.json".into()
            }
        );
    }

    #[test]
    fn unlisted_shard_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .json(
                "export_manifest.json",
                &manifest(&["conversations-000.json", "conversations-001.json"], 2),
            )
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-001.json", &[picnic(2)])
            .shard("conversations-002.json", &[picnic(3)])
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::UnlistedShard {
                name: "conversations-002.json".into()
            }
        );
    }

    #[test]
    fn shard_count_mismatch_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .json(
                "export_manifest.json",
                &manifest(&["conversations-000.json", "conversations-001.json"], 3),
            )
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-001.json", &[picnic(2)])
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::ShardCountMismatch {
                declared: 3,
                found: 2
            }
        );
    }

    #[test]
    fn unmanifested_shard_numbering_gap_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-002.json", &[picnic(2)])
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::MissingShard {
                name: "conversations-001.json".into()
            }
        );
    }

    #[test]
    fn single_and_sharded_conversations_together_are_ambiguous() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .conversations(&[picnic(1)])
            .shard("conversations-000.json", &[picnic(2)])
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::AmbiguousConversations
        );
    }

    #[test]
    fn inventory_manifest_size_mismatch_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let shard = serde_json::to_vec(&[picnic(1)]).unwrap();
        let inventory = json!({"export_files": [
            {"path": "conversations-000.json", "size_bytes": shard.len() + 1}
        ]});
        let path = Export::new()
            .json("export_manifest.json", &inventory)
            .deflated("conversations-000.json", &shard)
            .zip(&directory.path().join("export.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&path))),
            Incompleteness::InventorySizeMismatch {
                path: "conversations-000.json".into()
            }
        );
    }

    #[test]
    fn extracted_folder_and_zip_have_equal_digests_and_versions() {
        let directory = tempfile::tempdir().unwrap();
        let export = Export::new()
            .conversations(&[
                picnic(1),
                Conversation::new(2, "Photo")
                    .node("u1", Some("root"), image_message("sediment://file_00ab12"))
                    .build(),
            ])
            .stored("file_00ab12-beach.dat", fixture::PNG);
        let zip = open(&export.zip(&directory.path().join("export.zip"))).unwrap();
        let folder_path = directory.path().join("export");
        std::fs::create_dir(&folder_path).unwrap();
        let folder = open(&export.folder(&folder_path)).unwrap();
        assert_eq!(zip.summary.digest, folder.summary.digest);
        assert_eq!(zip.summary.missing_attachments, 0);
        let versions = |package: &Package| {
            package
                .conversations()
                .iter()
                .map(|entry| (entry.thread.id.clone(), entry.thread.version.clone()))
                .collect::<Vec<_>>()
        };
        assert_eq!(versions(&zip), versions(&folder));
    }

    #[test]
    fn nested_privacy_portal_zip_opens_inner_archives() {
        let directory = tempfile::tempdir().unwrap();
        let photo = Conversation::new(1, "Photo")
            .node("u1", Some("root"), image_message("sediment://file_00ab12"))
            .build();
        let conversations = Export::new().conversations(&[photo]).zip_bytes();
        let files = Export::new()
            .stored("file_00ab12-beach.dat", fixture::PNG)
            .zip_bytes();
        let path = Export::new()
            .stored("Conversations__x.zip", &conversations)
            .deflated("Files__x.zip", &files)
            .zip(&directory.path().join("portal.zip"));
        let package = open(&path).unwrap();
        assert_eq!(listed(&package, false), [fixture::id(1)]);
        assert_eq!(package.summary.missing_attachments, 0);
        assert_eq!(member_bytes(&package, "file_00ab12"), fixture::PNG);
    }

    #[test]
    fn nested_zip_beside_conversation_data_stays_an_attachment() {
        let directory = tempfile::tempdir().unwrap();
        let upload = json!({
            "author": {"role": "user"},
            "content": {"content_type": "text", "parts": ["Here is the report"]},
            "metadata": {"attachments": [{"id": "file-Report1", "name": "report.zip"}]},
        });
        let conversation = Conversation::new(1, "Report")
            .node("u1", Some("root"), upload)
            .build();
        let report = Export::new().conversations(&[picnic(9)]).zip_bytes();
        let path = Export::new()
            .conversations(&[conversation])
            .stored("file-Report1-report.zip", &report)
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        assert_eq!(package.summary.parts, ["export.zip"]);
        assert_eq!(listed(&package, false), [fixture::id(1)]);
        assert_eq!(member_bytes(&package, "file-Report1"), report);
    }

    #[test]
    fn stored_nested_zip_with_a_wrong_outer_checksum_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let inner = Export::new().conversations(&[picnic(1)]).zip_bytes();
        let path = Forge::new(&Export::new().stored("Conversations__x.zip", &inner))
            .crc("Conversations__x.zip", crc32fast::hash(&inner) ^ 1)
            .write(&directory.path().join("portal.zip"));
        assert_eq!(corruption(refused(open(&path))), Corruption::CrcMismatch);
    }

    #[test]
    fn zip_nested_deeper_than_one_level_is_not_opened() {
        let directory = tempfile::tempdir().unwrap();
        let inner = Export::new().conversations(&[picnic(2)]).zip_bytes();
        let middle = Export::new()
            .conversations(&[picnic(1)])
            .stored("inner.zip", &inner)
            .zip_bytes();
        let path = Export::new()
            .stored("Conversations__x.zip", &middle)
            .zip(&directory.path().join("portal.zip"));
        let package = open(&path).unwrap();
        assert_eq!(listed(&package, false), [fixture::id(1)]);
        assert_eq!(
            package.summary.parts,
            ["portal.zip", "Conversations__x.zip"]
        );
    }

    #[test]
    fn sibling_parts_are_discovered_from_the_first_part() {
        let directory = tempfile::tempdir().unwrap();
        let photo = Conversation::new(1, "Photo")
            .node("u1", Some("root"), image_message("sediment://file_00ab12"))
            .build();
        let first = Export::new()
            .conversations(&[photo])
            .zip(&directory.path().join("export-part-0001.zip"));
        Export::new()
            .stored("file_00ab12-beach.dat", fixture::PNG)
            .zip(&directory.path().join("export-part-0002.zip"));
        Export::new()
            .stored("file_00ff-other.dat", fixture::PNG)
            .zip(&directory.path().join("unrelated-part-0001.zip"));
        let package = open(&first).unwrap();
        assert_eq!(
            package.summary.parts,
            ["export-part-0001.zip", "export-part-0002.zip"]
        );
        assert_eq!(member_bytes(&package, "file_00ab12"), fixture::PNG);
    }

    #[test]
    fn sibling_part_numbering_gap_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let first = Export::new()
            .conversations(&[picnic(1)])
            .zip(&directory.path().join("export-part-0001.zip"));
        Export::new()
            .stored("file_00ab12-beach.dat", fixture::PNG)
            .zip(&directory.path().join("export-part-0003.zip"));
        assert_eq!(
            incomplete_reason(refused(open(&first))),
            Incompleteness::MissingPart { number: 2 }
        );
    }

    fn listing(directory: &Path) -> Vec<PathBuf> {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        entries.sort();
        entries
    }

    #[test]
    fn traversal_member_names_refuse_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let sandbox = directory.path().join("sandbox");
        std::fs::create_dir(&sandbox).unwrap();
        for (name, expected) in [
            ("../escape.json", UnsafeReason::Traversal),
            ("a/../../b.dat", UnsafeReason::Traversal),
            ("/abs.dat", UnsafeReason::Absolute),
            ("C:\\x.dat", UnsafeReason::Absolute),
            ("a\\..\\b", UnsafeReason::Traversal),
        ] {
            let path = Export::new()
                .conversations(&[picnic(1)])
                .stored(name, b"Invented escape attempt")
                .zip(&sandbox.join("export.zip"));
            let before = (listing(directory.path()), listing(&sandbox));
            assert_eq!(unsafe_reason(refused(open(&path))), expected, "{name}");
            assert_eq!((listing(directory.path()), listing(&sandbox)), before);
        }
    }

    #[test]
    fn symlink_zip_member_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let path = Forge::new(
            &Export::new()
                .conversations(&[picnic(1)])
                .stored("file_01-photo.dat", b"/etc/hosts"),
        )
        .mode("file_01-photo.dat", 0o120_777)
        .write(&directory.path().join("export.zip"));
        assert_eq!(unsafe_reason(refused(open(&path))), UnsafeReason::Symlink);
    }

    #[test]
    fn symlink_inside_extracted_folder_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let secret = directory.path().join("secret.txt");
        std::fs::write(&secret, "INVENTED-LINK-TARGET-MARKER").unwrap();
        let root = directory.path().join("export");
        std::fs::create_dir(&root).unwrap();
        Export::new().conversations(&[picnic(1)]).folder(&root);
        std::os::unix::fs::symlink(&secret, root.join("file_01-photo.dat")).unwrap();
        let error = refused(open(&root));
        assert!(!error.to_string().contains("INVENTED-LINK-TARGET-MARKER"));
        assert_eq!(unsafe_reason(error), UnsafeReason::Symlink);
    }

    #[test]
    fn fifo_inside_extracted_folder_refuses_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        Export::new().conversations(&[picnic(1)]).folder(&root);
        let fifo =
            std::ffi::CString::new(root.join("file_01-pipe.dat").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = sender.send(open(&root).err().map(unsafe_reason));
        });
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(5)).unwrap(),
            Some(UnsafeReason::SpecialFile)
        );
    }

    #[test]
    fn duplicate_member_names_refuse_the_package() {
        let directory = tempfile::tempdir().unwrap();
        let path = Forge::new(
            &Export::new()
                .conversations(&[picnic(1)])
                .stored("conversationz.json", b"[]"),
        )
        .rename("conversationz.json", "conversations.json")
        .write(&directory.path().join("export.zip"));
        assert_eq!(
            unsafe_reason(refused(open(&path))),
            UnsafeReason::DuplicateName
        );
    }

    #[test]
    fn encrypted_conversation_member_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let path = Forge::new(&Export::new().conversations(&[picnic(1)]))
            .flag("conversations.json", 1)
            .write(&directory.path().join("export.zip"));
        assert_eq!(unsafe_reason(refused(open(&path))), UnsafeReason::Encrypted);
    }

    #[test]
    fn zip_bomb_ratio_refuses_before_inflating() {
        let directory = tempfile::tempdir().unwrap();
        let path = Forge::new(
            &Export::new()
                .conversations(&[picnic(1)])
                .deflated("file_00bb-zeros.dat", &vec![0; 4 << 20]),
        )
        .flip("file_00bb-zeros.dat", 0)
        .write(&directory.path().join("export.zip"));
        let limits = Limits {
            ratio: 100,
            ..Limits::default()
        };
        assert_eq!(
            bound(refused(open_with(&[path], limits))),
            "compression ratio"
        );
    }

    #[test]
    fn declared_expansion_over_package_limit_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let export = (0..40).fold(
            Export::new().conversations(&[picnic(1)]),
            |export, index| export.stored(&format!("file_{index:04x}-blob.dat"), &[7; 1024]),
        );
        let path = export.zip(&directory.path().join("export.zip"));
        let limits = Limits {
            package_bytes: 32 * 1024,
            ..Limits::default()
        };
        assert_eq!(bound(refused(open_with(&[path], limits))), "package size");
    }

    #[test]
    fn every_input_form_is_admitted_by_the_same_size_limits() {
        let directory = tempfile::tempdir().unwrap();
        let conversations = [picnic(1), picnic(2)];
        let export = Export::new().conversations(&conversations);
        let json = directory.path().join("conversations.json");
        std::fs::write(&json, serde_json::to_vec(&conversations).unwrap()).unwrap();
        let folder = directory.path().join("folder");
        std::fs::create_dir(&folder).unwrap();
        export.folder(&folder);
        let zip = export.zip(&directory.path().join("export.zip"));
        let size = std::fs::metadata(&json).unwrap().len();
        let member = Limits {
            member_bytes: size - 1,
            ..Limits::default()
        };
        let package = Limits {
            package_bytes: size - 1,
            ..Limits::default()
        };
        let found: Vec<(&str, Option<&str>)> =
            [("json", &json), ("folder", &folder), ("zip", &zip)]
                .into_iter()
                .flat_map(|(form, path)| {
                    [member, package].map(|limits| {
                        (
                            form,
                            open_with(std::slice::from_ref(path), limits)
                                .err()
                                .map(bound),
                        )
                    })
                })
                .collect();
        assert_eq!(
            found,
            [
                ("json", Some("member size")),
                ("json", Some("package size")),
                ("folder", Some("member size")),
                ("folder", Some("package size")),
                ("zip", Some("member size")),
                ("zip", Some("package size")),
            ]
        );
    }

    #[test]
    fn nested_archives_count_against_the_parts_limit() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .stored(
                "Conversations__x.zip",
                &Export::new().conversations(&[picnic(1)]).zip_bytes(),
            )
            .stored(
                "Files__x.zip",
                &Export::new()
                    .stored("file_00ab12-beach.dat", fixture::PNG)
                    .zip_bytes(),
            )
            .zip(&directory.path().join("portal.zip"));
        let limits = |parts| Limits {
            parts,
            ..Limits::default()
        };
        assert_eq!(
            bound(refused(open_with(std::slice::from_ref(&path), limits(2)))),
            "parts"
        );
        assert_eq!(
            open_with(&[path], limits(3)).unwrap().summary.parts.len(),
            3
        );
    }

    #[test]
    fn member_count_over_limit_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let export = (0..6).fold(
            Export::new().conversations(&[picnic(1)]),
            |export, index| export.stored(&format!("file_{index:04x}-blob.dat"), b"blob"),
        );
        let path = export.zip(&directory.path().join("export.zip"));
        let limits = Limits {
            members_per_archive: 5,
            ..Limits::default()
        };
        assert_eq!(bound(refused(open_with(&[path], limits))), "members");
    }

    #[test]
    fn forged_short_size_on_a_shard_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let shard = serde_json::to_vec(&[picnic(1)]).unwrap();
        let path = Forge::new(&Export::new().deflated("conversations.json", &shard))
            .size("conversations.json", shard.len() as u32 - 5)
            .write(&directory.path().join("export.zip"));
        assert_eq!(
            corruption(refused(open(&path))),
            Corruption::LongerThanDeclared
        );
    }

    #[test]
    fn forged_long_size_on_a_shard_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let shard = serde_json::to_vec(&[picnic(1)]).unwrap();
        let path = Forge::new(&Export::new().deflated("conversations.json", &shard))
            .size("conversations.json", shard.len() as u32 + 5)
            .write(&directory.path().join("export.zip"));
        assert_eq!(
            corruption(refused(open(&path))),
            Corruption::ShorterThanDeclared
        );
    }

    #[test]
    fn crc_mismatch_on_a_shard_refuses() {
        let directory = tempfile::tempdir().unwrap();
        let shard = serde_json::to_vec(&[picnic(1)]).unwrap();
        let position = shard
            .windows(6)
            .position(|window| window == b"Picnic")
            .unwrap();
        let path = Forge::new(&Export::new().stored("conversations.json", &shard))
            .flip("conversations.json", position)
            .write(&directory.path().join("export.zip"));
        assert!(matches!(
            corruption(refused(open(&path))),
            Corruption::CrcMismatch | Corruption::NotJson
        ));
    }

    #[test]
    fn conversation_over_element_limit_is_a_problem_not_a_crash() {
        let directory = tempfile::tempdir().unwrap();
        let large = Conversation::new(2, "Long")
            .say("u1", "root", "user", &"long words ".repeat(400))
            .build();
        let path = Export::new()
            .conversations(&[picnic(1), large, picnic(3)])
            .zip(&directory.path().join("export.zip"));
        let limits = Limits {
            conversation_bytes: 2048,
            ..Limits::default()
        };
        let package = open_with(&[path], limits).unwrap();
        assert_eq!(listed(&package, false), [fixture::id(3), fixture::id(1)]);
        assert_eq!(package.summary.problems.len(), 1);
        assert!(package.summary.problems[0].contains("conversations.json"));
    }

    #[test]
    fn junk_entries_are_notes_and_unusable_entries_are_problems() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .conversations(&[
                json!({}),
                json!(42),
                json!({"title": "No identity"}),
                picnic(1),
            ])
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        assert_eq!(listed(&package, false), [fixture::id(1)]);
        assert_eq!(
            package.summary.notes,
            ["2 empty or non-conversation entries are skipped"]
        );
        assert_eq!(package.summary.problems.len(), 1);
        assert!(package.summary.problems[0].contains("no conversation id"));
    }

    #[test]
    fn conflicting_duplicate_conversation_keeps_the_newer_and_reports_it() {
        let directory = tempfile::tempdir().unwrap();
        let older = picnic(1);
        let newer = Conversation::new(1, "Picnic renamed")
            .say("u1", "root", "user", "Plan a picnic for six")
            .set("update_time", json!(1_800_000_000.0))
            .build();
        let path = Export::new()
            .shard("conversations-000.json", &[newer])
            .shard("conversations-001.json", &[older])
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        assert_eq!(package.conversations().len(), 1);
        assert_eq!(package.conversations()[0].thread.title, "Picnic renamed");
        assert_eq!(package.summary.problems.len(), 1);
        assert!(package.summary.problems[0].contains(&fixture::id(1)));
    }

    #[test]
    fn identical_duplicate_conversation_is_silent() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .shard("conversations-000.json", &[picnic(1)])
            .shard("conversations-001.json", &[picnic(1)])
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        assert_eq!(package.conversations().len(), 1);
        assert!(package.summary.problems.is_empty());
    }

    #[test]
    fn sidecar_names_match_ignoring_case_and_separator() {
        let directory = tempfile::tempdir().unwrap();
        let library = json!([{
            "file_id": "file_00cc", "file_name": "chart.png", "mime_type": "image/png",
            "origination_thread_id": fixture::id(1), "created_at": 1_767_300_000.0,
        }, {
            "file_id": "file_00dd", "file_name": "gone.png",
            "origination_thread_id": fixture::id(1), "trashed_at": 1_767_300_001.0,
        }]);
        let path = Export::new()
            .conversations(&[picnic(1)])
            .json("Library-Files.json", &library)
            .stored("file_00cc-chart.dat", fixture::PNG)
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        let files: Vec<&str> = package
            .library(&fixture::id(1))
            .iter()
            .map(|file| file.file.as_str())
            .collect();
        assert_eq!(files, ["file_00cc"]);
        assert_eq!(package.summary.attachments, 1);
    }

    fn normalized(package: &Package, id: &str) -> conversation::Normalized {
        let entry = package.conversation(id).unwrap();
        let Ok(raw) = package.read_conversation(entry) else {
            panic!("the checked conversation could not be reread");
        };
        conversation::normalize(id, &raw, package.library(id), package)
    }

    #[test]
    fn unicode_survives_and_lone_surrogates_are_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let text = "Emoji 🧺, 漢字, עברית, e\u{301} and a broken LONE half";
        let conversation = Conversation::new(1, "Unicode")
            .say("u1", "root", "user", text)
            .build();
        let shard = serde_json::to_string(&[conversation])
            .unwrap()
            .replace("LONE", "\\ud83d");
        let path = directory.path().join("conversations.json");
        std::fs::write(&path, shard).unwrap();
        let package = open(&path).unwrap();
        assert_eq!(
            package.summary.notes,
            ["1 broken characters are replaced with U+FFFD"]
        );
        let normalized = normalized(&package, &fixture::id(1));
        assert_eq!(normalized.items[0].text, text.replace("LONE", "\u{FFFD}"));
    }

    #[test]
    fn trashed_and_writing_block_library_entries_are_ignored() {
        let directory = tempfile::tempdir().unwrap();
        let entry = |file: &str, extra: Value| {
            let mut entry = json!({"file_id": file, "file_name": "draft.txt",
                "origination_thread_id": fixture::id(1)});
            entry
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            entry
        };
        let library = json!([
            entry("file_0a01", json!({"trashed_at": 1_767_300_000.0})),
            entry("file_0a02", json!({"deleted_at": 1_767_300_000.0})),
            entry(
                "file_0a03",
                json!({"library_artifact_type": "writing_block"})
            ),
        ]);
        let path = Export::new()
            .conversations(&[picnic(1)])
            .json("library_files.json", &library)
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        let normalized = normalized(&package, &fixture::id(1));
        assert_eq!(normalized.items.len(), 2);
        assert!(normalized.items.iter().all(|item| item.assets.is_empty()));
        assert!(normalized.gaps.is_empty());
    }

    fn thread_version(conversation: &Value) -> String {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("conversations.json");
        std::fs::write(&path, serde_json::to_vec(&[conversation]).unwrap()).unwrap();
        open(&path).unwrap().conversations()[0]
            .thread
            .version
            .clone()
    }

    #[test]
    fn thread_version_is_stable_and_content_defined() {
        let raw = picnic(1);
        let text = serde_json::to_string(&raw).unwrap();
        let mut reordered = serde_json::Map::new();
        for (key, value) in raw.as_object().unwrap().iter().rev() {
            reordered.insert(key.clone(), value.clone());
        }
        let reordered = serde_json::to_string(&reordered)
            .unwrap()
            .replace(r#""title":"Picnic 1""#, r#""title" : "Picnic 1""#);
        assert_ne!(text, reordered);
        let version = thread_version(&raw);
        assert_eq!(version, thread_version(&raw));
        assert_eq!(
            version,
            thread_version(&serde_json::from_str(&reordered).unwrap())
        );
    }

    #[test]
    fn thread_version_changes_when_current_node_moves() {
        let mut moved = picnic(1);
        moved["current_node"] = json!("u1");
        assert_ne!(thread_version(&picnic(1)), thread_version(&moved));
    }

    #[test]
    fn personal_sidecars_are_never_opened() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .conversations(&[picnic(1)])
            .stored("user.json", b"{INVENTED-PERSONAL-MARKER")
            .zip(&directory.path().join("export.zip"));
        let package = open(&path).unwrap();
        let summary = serde_json::to_string(&package.summary).unwrap();
        assert!(!summary.contains("INVENTED-PERSONAL-MARKER"));
        assert!(package.summary.problems.is_empty());
    }
}
