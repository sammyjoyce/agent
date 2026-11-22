import { createHash, randomUUID } from "node:crypto";
import { open, readFile, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import type { InputEntry, UserInput } from "@earendil-works/pi-durable";
import { DEFAULT_IMAGE_LIMITS, type ImageLimits } from "@earendil-works/pi-durable/tools";
import type { InputOrigin } from "./generated/InputOrigin.js";
import type { AttachmentRef } from "./generated/AttachmentRef.js";
import type { AttachmentRequest } from "./generated/AttachmentRequest.js";
import type { AttachmentResponse } from "./generated/AttachmentResponse.js";
import { beginUpload, writeChunk } from "./attachment-upload.js";
import type { RetainedFiles, RetainedWrite } from "./failover/retained-files.js";
import type { HostCall } from "./tasks.js";
import { prepareImage } from "./images.js";

import { MAX_ATTACHMENT_BYTES, ATTACHMENT_CHUNK_BYTES, MAX_ATTACHMENTS, MAX_ATTACHMENT_NAME_BYTES, ATTACHMENT_STAGING_MILLIS } from "./generated/attachment-limits.js";
export class AttachmentError extends Error {}
const QUOTA = 512 * 1024 * 1024;
export function validateInput(text: string, attachments?: readonly AttachmentRef[]): void {
  if (Buffer.byteLength(text, "utf8") > 65536 || (text.trim().length === 0 && (attachments?.length ?? 0) === 0)) {
    throw new AttachmentError("Input needs text or an attachment, with text at most 65536 UTF-8 bytes");
  }
  if ((attachments?.length ?? 0) > MAX_ATTACHMENTS) throw new AttachmentError("Choose at most eight attachments");
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Metadata = { attachment: AttachmentRef; retained: boolean; complete: boolean; created: number };
function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
function decode(value: unknown): Metadata {
  if (!object(value) || !object(value.attachment)) throw new AttachmentError("Invalid attachment metadata");
  const item = value.attachment;
  if (typeof item.id !== "string" || typeof item.name !== "string" || typeof item.media_type !== "string" ||
      typeof item.size_bytes !== "number" || typeof item.sha256 !== "string" || typeof value.retained !== "boolean" ||
      typeof value.complete !== "boolean" || typeof value.created !== "number") throw new AttachmentError("Invalid attachment metadata");
  return { attachment: { id: item.id, name: item.name, media_type: item.media_type, size_bytes: item.size_bytes, sha256: item.sha256 },
    retained: value.retained, complete: value.complete, created: value.created };
}
function requireId(id: string): void {
  if (!UUID.test(id) || id === "00000000-0000-0000-0000-000000000000") throw new AttachmentError("Invalid attachment ID");
}
function same(left: AttachmentRef, right: AttachmentRef): boolean {
  return left.id === right.id && left.name === right.name && left.media_type === right.media_type &&
    left.size_bytes === right.size_bytes && left.sha256 === right.sha256;
}

/** Originals are immutable, bounded and private. Staged orphans expire; admitted refs follow durable history. */
export class AttachmentStore {
  private readonly directory: string;
  private serial: Promise<void> = Promise.resolve();
  constructor(private readonly files: RetainedFiles) { this.directory = join(files.stateDirectory, "attachments"); }
  private folder(id: string): string { requireId(id); return join(this.directory, id); }
  private async metadata(id: string): Promise<Metadata> {
    const value: unknown = JSON.parse(await readFile(join(this.folder(id), "metadata.json"), "utf8"));
    const metadata = decode(value);
    if (metadata.attachment.id !== id) throw new AttachmentError("Attachment metadata identity does not match its directory");
    return metadata;
  }
  /** Metadata for `write`. A rewrite happens only once the upload is complete, so every logged metadata file says it is. */
  private metadataFile(metadata: Metadata): RetainedWrite {
    return { path: `attachments/${metadata.attachment.id}/metadata.json`, bytes: Buffer.from(JSON.stringify(metadata)) };
  }
  private remove(id: string): Promise<void> { requireId(id); return this.files.remove(`attachments/${id}`); }
  async request(request: AttachmentRequest): Promise<AttachmentResponse> {
    // A download reads a complete upload, so it does not wait behind a write that waits for the authority.
    if (request.type === "download") return this.download(request);
    const operation = this.serial.catch(() => {}).then(() => this.transfer(request));
    this.serial = operation.then(() => {}, () => {});
    return operation;
  }
  private async download(request: Extract<AttachmentRequest, { type: "download" }>): Promise<AttachmentResponse> {
    if (request.limit <= 0 || request.limit > ATTACHMENT_CHUNK_BYTES) throw new AttachmentError("Invalid attachment read limit");
    const metadata = await this.metadata(request.id);
    if (!metadata.complete || request.offset > metadata.attachment.size_bytes) throw new AttachmentError("Attachment is not available at this offset");
    const file = await open(join(this.folder(request.id), "content"), "r");
    try {
      const bytes = Buffer.alloc(Math.min(request.limit, metadata.attachment.size_bytes - request.offset));
      const read = await file.read(bytes, 0, bytes.length, request.offset);
      const next = request.offset + read.bytesRead;
      return { type: "download", data_base64: bytes.subarray(0, read.bytesRead).toString("base64"),
        next_offset: next < metadata.attachment.size_bytes ? next : null };
    } finally { await file.close(); }
  }
  private async transfer(request: Exclude<AttachmentRequest, { type: "download" }>): Promise<AttachmentResponse> {
    requireId(request.id);
    const folder = this.folder(request.id);
    if (request.type === "discard") {
      let metadata: Metadata;
      try { metadata = await this.metadata(request.id); } catch (error) {
        if (object(error) && error.code === "ENOENT") return { type: "discarded" }; throw error;
      }
      if (metadata.retained) throw new AttachmentError("An admitted attachment is retained with its conversation");
      await this.remove(request.id); return { type: "discarded" };
    }
    if (request.name.length === 0 || Buffer.byteLength(request.name) > MAX_ATTACHMENT_NAME_BYTES || /[\/\\\x00-\x1f\x7f]/.test(request.name) ||
      request.name === "." || request.name === ".." || !/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(request.media_type) ||
      request.media_type.length > 127 || request.size_bytes > MAX_ATTACHMENT_BYTES || request.data_base64.length > Math.ceil(ATTACHMENT_CHUNK_BYTES / 3) * 4) {
      throw new AttachmentError("Invalid attachment metadata or chunk size");
    }
    const bytes = Buffer.from(request.data_base64, "base64"), end = request.offset + bytes.length;
    if (bytes.length > ATTACHMENT_CHUNK_BYTES || bytes.toString("base64") !== request.data_base64 || end > request.size_bytes ||
      (request.complete && end !== request.size_bytes)) throw new AttachmentError("Invalid attachment chunk encoding or range");
    let metadata: Metadata;
    try { metadata = await this.metadata(request.id); } catch (error) {
      if (!object(error) || error.code !== "ENOENT") throw error;
      if (request.offset !== 0) throw new AttachmentError("Attachment upload must start at offset zero");
      let reserved = 0;
      const uploads = await readdir(this.directory, { withFileTypes: true }).catch((error: unknown) => {
        if (object(error) && error.code === "ENOENT") return []; throw error;
      });
      for (const entry of uploads) {
        if (!entry.isDirectory() || !UUID.test(entry.name)) continue;
        let saved: Metadata;
        try { saved = await this.metadata(entry.name); } catch (error) {
          // A crash before the first metadata rename never returned a receipt.
          if (object(error) && error.code === "ENOENT") { await this.remove(entry.name); continue; }
          throw error;
        }
        if (!saved.retained && Date.now() - saved.created > ATTACHMENT_STAGING_MILLIS) await this.remove(entry.name);
        else reserved += saved.attachment.size_bytes + 4096;
      }
      if (reserved + request.size_bytes + 4096 > QUOTA) throw new AttachmentError("Attachment storage is full; no input was admitted");
      const started = { attachment: { id: request.id, name: request.name, media_type: request.media_type, size_bytes: request.size_bytes, sha256: "" },
        retained: false, complete: false as const, created: Date.now() };
      await beginUpload(folder, started);
      metadata = started;
    }
    const reference = metadata.attachment;
    if (reference.name !== request.name || reference.media_type !== request.media_type || reference.size_bytes !== request.size_bytes) {
      throw new AttachmentError("Attachment identity was reused with different content");
    }
    const content = join(folder, "content"), current = (await stat(content)).size;
    if (request.offset > current) throw new AttachmentError("Attachment chunk is out of order");
    const existing = Math.min(current - request.offset, bytes.length);
    if (existing > 0) {
      const file = await open(content, "r");
      try {
        const previous = Buffer.alloc(existing); const read = await file.read(previous, 0, existing, request.offset);
        if (read.bytesRead !== existing || !previous.equals(bytes.subarray(0, existing))) throw new AttachmentError("Attachment retry changed its bytes");
      } finally { await file.close(); }
    }
    if (!await writeChunk(content, request.offset + existing, bytes.subarray(existing))) throw new AttachmentError("Attachment write stopped before the chunk completed");
    if (request.complete) {
      const uploaded = await readFile(content);
      if (uploaded.length !== reference.size_bytes) throw new AttachmentError("Attachment size does not match its declared size");
      const sha256 = createHash("sha256").update(uploaded).digest("hex");
      if (metadata.complete && reference.sha256 !== sha256) throw new AttachmentError("Attachment checksum mismatch");
      if (!metadata.complete) {
        metadata.attachment.sha256 = sha256; metadata.complete = true;
        // The upload becomes real when its metadata says complete, so the content takes its logged name with it.
        await this.files.write([{ path: `attachments/${request.id}/content`, staged: content }, this.metadataFile(metadata)]);
      }
    }
    return { type: "uploaded", next_offset: end, attachment: request.complete ? { ...metadata.attachment } : null };
  }
  async references(ids: readonly string[] = []): Promise<AttachmentRef[]> {
    if (ids.length > MAX_ATTACHMENTS || new Set(ids).size !== ids.length) throw new AttachmentError("Choose at most eight distinct attachments");
    return Promise.all(ids.map(async (id) => {
      const metadata = await this.metadata(id);
      if (!metadata.complete) throw new AttachmentError("Finish uploading attachments before sending");
      return { ...metadata.attachment };
    }));
  }
  async retain(refs: readonly AttachmentRef[] = []): Promise<AttachmentRef[]> {
    const operation = this.serial.catch(() => {}).then(async () => {
      const canonical = await this.resolve(refs);
      await this.keep(canonical);
      return canonical;
    });
    this.serial = operation.then(() => {}, () => {}); return operation;
  }
  async retainBytes(name: string, mediaType: string, bytes: Buffer): Promise<AttachmentRef> {
    const id = randomUUID();
    const operation = this.serial.catch(() => {}).then(async () => {
      let attachment: AttachmentRef | null = null;
      for (let offset = 0; attachment === null; offset += ATTACHMENT_CHUNK_BYTES) {
        const end = Math.min(offset + ATTACHMENT_CHUNK_BYTES, bytes.length);
        const response = await this.transfer({ type: "upload", id, name, media_type: mediaType, size_bytes: bytes.length, offset,
          data_base64: bytes.subarray(offset, end).toString("base64"), complete: end === bytes.length });
        if (response.type !== "uploaded") throw new AttachmentError("Attachment storage did not confirm the upload");
        attachment = response.attachment;
      }
      await this.keep([attachment]);
      return attachment;
    });
    this.serial = operation.then(() => {}, () => {});
    return operation;
  }
  private async keep(refs: readonly AttachmentRef[]): Promise<void> {
    const released = (await Promise.all(refs.map((ref) => this.metadata(ref.id)))).filter((saved) => !saved.retained);
    await this.files.write(released.map((saved) => this.metadataFile({ ...saved, retained: true })));
  }
  /** Retain bytes before Pi can own their references. The callback checks its
   * live owner after filesystem work; undefined releases provisional retention.
   * Await Pi's receipt outside this queue, retaining bytes on uncertain failure. */
  async admit<T>(refs: readonly AttachmentRef[] | undefined, submit: () => Promise<T> | undefined): Promise<T | undefined> {
    const operation = this.serial.catch(() => {}).then(async () => {
      const canonical = await this.resolve(refs);
      const previous = await Promise.all(canonical.map(ref => this.metadata(ref.id)));
      const restore = () => this.files.write(previous.filter((saved) => !saved.retained).map((saved) => this.metadataFile(saved)));
      try { await this.keep(canonical); }
      catch (error) { await restore(); throw error; }
      const pending = submit();
      if (pending === undefined) { await restore(); return undefined; }
      void pending.catch(() => {});
      // Release the store queue before Pi's SQLite receipt: another SQLite
      // transaction may already be waiting to retain its own attachment refs.
      return { pending };
    });
    this.serial = operation.then(() => {}, () => {});
    return (await operation)?.pending;
  }
  async resolve(refs: readonly AttachmentRef[] = []): Promise<AttachmentRef[]> {
    const canonical = await this.references(refs.map((ref) => ref.id));
    if (canonical.some((ref, index) => refs[index] === undefined || !same(ref, refs[index]))) throw new AttachmentError("Attachment receipt does not match its stored content");
    return canonical;
  }
  async materialize(ref: AttachmentRef, call: HostCall): Promise<string> {
    const bytes = await readFile(join(this.folder(ref.id), "content"));
    if (bytes.length !== ref.size_bytes || createHash("sha256").update(bytes).digest("hex") !== ref.sha256) throw new AttachmentError("Attachment bytes no longer match their receipt");
    for (let offset = 0; offset <= bytes.length; offset += ATTACHMENT_CHUNK_BYTES) {
      const end = Math.min(offset + ATTACHMENT_CHUNK_BYTES, bytes.length), complete = end === bytes.length;
      const result = await call({ type: "attachment_write", attachment: ref, offset, data_base64: bytes.subarray(offset, end).toString("base64"), complete });
      if (result.type !== "attachment_written" || result.next_offset !== end) throw new AttachmentError(result.type === "failed" ? result.message : "Execution host did not confirm the attachment");
      if (complete) { if (result.path === null) throw new AttachmentError("Execution host returned no attachment path"); return result.path; }
    }
    throw new AttachmentError("Attachment transfer did not complete");
  }
  async input(text: string, refs: readonly AttachmentRef[] | undefined, call: HostCall, origin?: InputOrigin, limits: ImageLimits = DEFAULT_IMAGE_LIMITS): Promise<{ content: UserInput; entry?: InputEntry }> {
    if (refs === undefined || refs.length === 0) return { content: text, ...(origin === undefined ? {} : {
      entry: { kind: "agent.input", data: { origin, text } },
    }) };
    const canonical = await this.resolve(refs), content: Exclude<UserInput, string> = [{ type: "text", text }];
    for (const ref of canonical) {
      const path = await this.materialize(ref, call);
      content.push({ type: "text", text: `Attached file ${JSON.stringify(ref.name)} (attachment ID ${ref.id}, SHA-256 ${ref.sha256}): ${JSON.stringify(path)} on this execution host. If the cache path expires, use read_attachment with this attachment ID.` });
      if (ref.media_type.startsWith("image/")) {
        const prepared = await prepareImage(await readFile(join(this.folder(ref.id), "content")), ref.media_type, limits);
        if (prepared === undefined) {
          if (["image/png", "image/jpeg", "image/gif", "image/webp"].includes(ref.media_type)) throw new AttachmentError("This image could not be prepared for the model; convert it to PNG or JPEG");
          content.push({ type: "text", text: `The original ${ref.media_type} file is available at the attachment path above; native image conversion was unavailable. Use file tools to inspect or convert the original.` });
        } else content.push({ type: "image", data: prepared.data, mimeType: prepared.mimeType });
      }
    }
    return { content, entry: { kind: "agent.input", data: { attachments: canonical, text, ...(origin === undefined ? {} : { origin }) } } };
  }
}
