use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    io::{Cursor, Write},
    path::{Path, PathBuf},
};

use serde_json::{Value, json};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

/// Counts heap bytes per thread so a test can bound what one call retains.
struct Tracked;

thread_local! {
    static HEAP: Cell<Option<(usize, usize)>> = const { Cell::new(None) };
}

fn track(grow: usize, shrink: usize) {
    let _ = HEAP.try_with(|heap| {
        if let Some((live, peak)) = heap.get() {
            let live = (live + grow).saturating_sub(shrink);
            heap.set(Some((live, peak.max(live))));
        }
    });
}

unsafe impl GlobalAlloc for Tracked {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        track(layout.size(), 0);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        track(0, layout.size());
        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        track(layout.size(), 0);
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        track(size, layout.size());
        unsafe { System.realloc(pointer, layout, size) }
    }
}

#[global_allocator]
static TRACKED: Tracked = Tracked;

/// The most heap this thread held at once while `run` ran, above what it held before.
pub(super) fn peak_heap<T>(run: impl FnOnce() -> T) -> (T, usize) {
    HEAP.with(|heap| heap.set(Some((0, 0))));
    let output = run();
    let peak = HEAP.with(|heap| heap.take()).map_or(0, |(_, peak)| peak);
    (output, peak)
}

pub(super) const PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

pub(super) const PDF: &[u8] = b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n";

pub(super) fn wav() -> Vec<u8> {
    let samples = 800u32;
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + samples).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&8000u32.to_le_bytes());
    bytes.extend_from_slice(&8000u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&8u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&samples.to_le_bytes());
    bytes.resize(bytes.len() + samples as usize, 0x80);
    bytes
}

pub(super) fn id(number: u8) -> String {
    format!("00000000-0000-4000-8000-{number:012x}")
}

pub(super) fn text_message(role: &str, text: &str) -> Value {
    json!({
        "author": {"role": role},
        "content": {"content_type": "text", "parts": [text]},
        "metadata": {},
    })
}

#[derive(Clone)]
pub(super) struct Conversation {
    value: Value,
    clock: f64,
}

impl Conversation {
    pub fn new(number: u8, title: &str) -> Self {
        let id = id(number);
        let created = 1_767_225_600.0 + f64::from(number) * 100.0;
        Self {
            value: json!({
                "id": id,
                "conversation_id": id,
                "title": title,
                "create_time": created,
                "update_time": created,
                "mapping": {"root": {"id": "root", "message": null, "parent": null}},
                "current_node": "root",
                "is_archived": false,
            }),
            clock: created,
        }
    }

    pub fn node(mut self, node: &str, parent: Option<&str>, message: Value) -> Self {
        self.clock += 1.0;
        let mut message = message;
        if let Value::Object(object) = &mut message {
            object.entry("id").or_insert_with(|| json!(node));
            object
                .entry("create_time")
                .or_insert_with(|| json!(self.clock));
        }
        self.value["mapping"][node] = json!({"id": node, "message": message, "parent": parent});
        self.value["current_node"] = json!(node);
        self
    }

    pub fn say(self, node: &str, parent: &str, role: &str, text: &str) -> Self {
        self.node(node, Some(parent), text_message(role, text))
    }

    pub fn current(mut self, node: &str) -> Self {
        self.value["current_node"] = json!(node);
        self
    }

    pub fn set(mut self, key: &str, value: Value) -> Self {
        self.value[key] = value;
        self
    }

    pub fn build(self) -> Value {
        self.value
    }
}

#[derive(Clone)]
struct Entry {
    name: String,
    bytes: Vec<u8>,
    deflated: bool,
}

#[derive(Clone, Default)]
pub(super) struct Export {
    entries: Vec<Entry>,
}

impl Export {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn conversations(self, conversations: &[Value]) -> Self {
        self.shard("conversations.json", conversations)
    }

    pub fn shard(self, name: &str, conversations: &[Value]) -> Self {
        self.deflated(name, &serde_json::to_vec(conversations).unwrap())
    }

    pub fn json(self, name: &str, value: &Value) -> Self {
        self.deflated(name, &serde_json::to_vec(value).unwrap())
    }

    pub fn stored(mut self, name: &str, bytes: &[u8]) -> Self {
        self.entries.push(Entry {
            name: name.into(),
            bytes: bytes.to_vec(),
            deflated: false,
        });
        self
    }

    pub fn deflated(mut self, name: &str, bytes: &[u8]) -> Self {
        self.entries.push(Entry {
            name: name.into(),
            bytes: bytes.to_vec(),
            deflated: true,
        });
        self
    }

    pub fn zip_bytes(&self) -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        for entry in &self.entries {
            let method = if entry.deflated {
                CompressionMethod::Deflated
            } else {
                CompressionMethod::Stored
            };
            let options = SimpleFileOptions::default()
                .compression_method(method)
                .unix_permissions(0o644);
            writer.start_file(&entry.name, options).unwrap();
            writer.write_all(&entry.bytes).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    pub fn zip(&self, path: &Path) -> PathBuf {
        std::fs::write(path, self.zip_bytes()).unwrap();
        path.to_path_buf()
    }

    pub fn folder(&self, path: &Path) -> PathBuf {
        for entry in &self.entries {
            let file = path.join(&entry.name);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, &entry.bytes).unwrap();
        }
        path.to_path_buf()
    }
}

pub(super) struct Forge {
    pub bytes: Vec<u8>,
}

impl Forge {
    pub fn new(export: &Export) -> Self {
        Self {
            bytes: export.zip_bytes(),
        }
    }

    fn u16_at(&self, offset: usize) -> usize {
        u16::from_le_bytes([self.bytes[offset], self.bytes[offset + 1]]) as usize
    }

    fn u32_at(&self, offset: usize) -> usize {
        u32::from_le_bytes(self.bytes[offset..offset + 4].try_into().unwrap()) as usize
    }

    fn put_u32(&mut self, offset: usize, value: u32) {
        self.bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn central(&self, name: &str) -> usize {
        (0..self.bytes.len() - 46)
            .find(|offset| {
                self.bytes[*offset..offset + 4] == *b"PK\x01\x02"
                    && self.u16_at(offset + 28) == name.len()
                    && self.bytes[offset + 46..offset + 46 + name.len()] == *name.as_bytes()
            })
            .unwrap_or_else(|| panic!("no central header for {name}"))
    }

    fn local(&self, name: &str) -> usize {
        self.u32_at(self.central(name) + 42)
    }

    fn data(&self, name: &str) -> usize {
        let local = self.local(name);
        local + 30 + self.u16_at(local + 26) + self.u16_at(local + 28)
    }

    pub fn size(mut self, name: &str, size: u32) -> Self {
        let (central, local) = (self.central(name), self.local(name));
        self.put_u32(central + 24, size);
        self.put_u32(local + 22, size);
        self
    }

    pub fn crc(mut self, name: &str, crc: u32) -> Self {
        let (central, local) = (self.central(name), self.local(name));
        self.put_u32(central + 16, crc);
        self.put_u32(local + 14, crc);
        self
    }

    pub fn mode(mut self, name: &str, mode: u32) -> Self {
        let central = self.central(name);
        self.bytes[central + 5] = 3;
        self.put_u32(central + 38, mode << 16);
        self
    }

    pub fn flag(mut self, name: &str, bit: u16) -> Self {
        let (central, local) = (self.central(name), self.local(name));
        for offset in [central + 8, local + 6] {
            let flags = self.u16_at(offset) as u16 | bit;
            self.bytes[offset..offset + 2].copy_from_slice(&flags.to_le_bytes());
        }
        self
    }

    pub fn rename(mut self, from: &str, to: &str) -> Self {
        assert_eq!(from.len(), to.len(), "a forged name keeps its length");
        let (central, local) = (self.central(from), self.local(from));
        self.bytes[central + 46..central + 46 + to.len()].copy_from_slice(to.as_bytes());
        self.bytes[local + 30..local + 30 + to.len()].copy_from_slice(to.as_bytes());
        self
    }

    pub fn flip(mut self, name: &str, index: usize) -> Self {
        let data = self.data(name);
        self.bytes[data + index] ^= 0x01;
        self
    }

    pub fn write(&self, path: &Path) -> PathBuf {
        std::fs::write(path, &self.bytes).unwrap();
        path.to_path_buf()
    }
}
