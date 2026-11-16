import { createHash } from "node:crypto";
import { mkdir, open, readdir, rename } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { CheckpointFile } from "../generated/CheckpointFile.js";
import type { CheckpointManifest } from "../generated/CheckpointManifest.js";
import { CHECKPOINT_FORMAT, CHECKPOINT_PART_BYTES } from "../generated/failover-operator.js";
import type { AuthorityLink } from "./authority-link.js";
import { isLowercaseUuid, isSha256Hex } from "./authority-wire.js";
import { sha256Hex } from "./log-entry.js";

/** How many parts are in flight at once, which bounds memory at this many parts. */
const TRANSFERS = 4;

type BlobStore = Pick<AuthorityLink, "putBlob" | "getBlob">;

/** Runs uploads with at most `TRANSFERS` in flight. The first failure ends the checkpoint. */
class Uploads {
  readonly #active = new Set<Promise<void>>();
  #failure: { readonly error: unknown } | undefined;

  async start(upload: () => Promise<void>): Promise<void> {
    while (this.#active.size >= TRANSFERS) await Promise.race(this.#active);
    if (this.#failure !== undefined) throw this.#failure.error;
    const running: Promise<void> = upload().catch((error: unknown) => { this.#failure ??= { error }; }).finally(() => this.#active.delete(running));
    this.#active.add(running);
  }

  async finish(): Promise<void> {
    await Promise.all(this.#active);
    if (this.#failure !== undefined) throw this.#failure.error;
  }
}

/** Every file under `root`, as sorted paths relative to it. */
async function archiveFiles(root: string): Promise<string[]> {
  const entries = await readdir(root, { recursive: true, withFileTypes: true });
  return entries.filter((entry) => entry.isFile()).map((entry) => join(entry.parentPath, entry.name).slice(root.length + 1)).sort();
}

/**
 * Stores the backup archive at `archive` as a checkpoint: each file in parts
 * of at most `partBytes`, then the manifest that names them. Returns the
 * manifest's SHA-256, which the checkpoint record carries.
 */
export async function storeCheckpoint(store: BlobStore, archive: string, header: Pick<CheckpointManifest, "through" | "coordinator_id">,
  partBytes: number = CHECKPOINT_PART_BYTES): Promise<{ manifest: string; files: number; bytes: number }> {
  if (!Number.isSafeInteger(partBytes) || partBytes < 1 || partBytes > CHECKPOINT_PART_BYTES) {
    throw new Error(`A checkpoint part holds from 1 to ${CHECKPOINT_PART_BYTES} bytes, not ${partBytes}`);
  }
  const uploads = new Uploads(), files: CheckpointFile[] = [];
  for (const path of await archiveFiles(archive)) {
    const handle = await open(join(archive, path), "r"), whole = createHash("sha256"), parts: string[] = [];
    let size = 0;
    try {
      for (;;) {
        const part = Buffer.allocUnsafe(partBytes);
        let filled = 0;
        while (filled < partBytes) {
          const { bytesRead } = await handle.read(part, filled, partBytes - filled, null);
          if (bytesRead === 0) break;
          filled += bytesRead;
        }
        if (filled === 0) break;
        const bytes = part.subarray(0, filled), sha256 = sha256Hex(bytes);
        whole.update(bytes);
        parts.push(sha256);
        size += filled;
        await uploads.start(() => store.putBlob(sha256, bytes));
        if (filled < partBytes) break;
      }
    } finally { await handle.close(); }
    files.push({ path, size, sha256: whole.digest("hex"), parts });
  }
  await uploads.finish();
  const manifest: CheckpointManifest = { format: CHECKPOINT_FORMAT, through: header.through, coordinator_id: header.coordinator_id, files };
  const bytes = Buffer.from(JSON.stringify(manifest), "utf8"), sha256 = sha256Hex(bytes);
  await store.putBlob(sha256, bytes);
  return { manifest: sha256, files: files.length, bytes: files.reduce((total, file) => total + file.size, 0) };
}

/** Reads and checks the manifest blob that a checkpoint record names. */
export async function readCheckpointManifest(store: BlobStore, sha256: string): Promise<CheckpointManifest> {
  const bytes = await store.getBlob(sha256);
  if (sha256Hex(bytes) !== sha256) throw new Error(`The blob store returned bytes that do not match checkpoint manifest ${sha256}`);
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch (error) { throw new Error(`Checkpoint manifest ${sha256} is not UTF-8 JSON`, { cause: error }); }
  return parseCheckpointManifest(value);
}

const object = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const counter = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
/** `ArchivePath` in `src/failover.rs`. */
const archivePath = (value: unknown): value is string => typeof value === "string"
  && value.split("/").every((segment) => segment !== "" && segment !== "." && segment !== ".." && !/[\\\0]/.test(segment));
const digest = (value: unknown): value is string => typeof value === "string" && isSha256Hex(value);
const only = (value: Record<string, unknown>, ...keys: string[]) => Object.keys(value).length === keys.length && keys.every((key) => key in value);

/** Parses a checkpoint manifest strictly: no unknown field, no path that leaves the archive, no file named twice. */
export function parseCheckpointManifest(value: unknown): CheckpointManifest {
  const invalid = (problem: string): never => { throw new Error(`The checkpoint manifest ${problem}`); };
  if (!object(value) || !only(value, "format", "through", "coordinator_id", "files")) return invalid("is not a manifest object");
  const { format, through, coordinator_id, files } = value;
  if (format !== CHECKPOINT_FORMAT) return invalid(`uses format ${String(format)}, and this build reads format ${CHECKPOINT_FORMAT}`);
  if (!counter(through)) return invalid("names no log position");
  if (typeof coordinator_id !== "string" || !isLowercaseUuid(coordinator_id)) return invalid("names no coordinator");
  if (!Array.isArray(files)) return invalid("lists no files");
  const paths = new Set<string>();
  const parsed = files.map((file: unknown): CheckpointFile => {
    if (!object(file) || !only(file, "path", "size", "sha256", "parts")) return invalid("lists a file that is not a file record");
    const { path, size, sha256, parts } = file;
    if (!archivePath(path) || paths.has(path)) return invalid(`lists the path ${JSON.stringify(path)}, which is not a new relative path inside the archive`);
    paths.add(path);
    if (!counter(size) || !digest(sha256) || !Array.isArray(parts) || !parts.every(digest)) return invalid(`lists ${path} without a size, a SHA-256 and its parts`);
    return { path, size, sha256, parts };
  });
  return { format, through, coordinator_id, files: parsed };
}

/**
 * Downloads a checkpoint into the new directory `archive`. Every part and
 * every whole file is checked against its SHA-256, and a file has its name
 * only after it passed.
 */
export async function fetchCheckpoint(store: BlobStore, manifest: CheckpointManifest, archive: string): Promise<{ files: number; bytes: number }> {
  await mkdir(archive, { mode: 0o700 });
  for (const file of manifest.files) await fetchFile(store, file, join(archive, file.path));
  return { files: manifest.files.length, bytes: manifest.files.reduce((total, file) => total + file.size, 0) };
}

async function fetchFile(store: BlobStore, file: CheckpointFile, path: string): Promise<void> {
  const part = async (sha256: string): Promise<Uint8Array> => {
    const bytes = await store.getBlob(sha256);
    if (bytes.byteLength > CHECKPOINT_PART_BYTES || sha256Hex(bytes) !== sha256) throw new Error(`The blob store returned bytes that do not match part ${sha256} of ${file.path}`);
    return bytes;
  };
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const partial = `${path}.partial`, handle = await open(partial, "wx", 0o600), whole = createHash("sha256"), ahead: Promise<Uint8Array>[] = [];
  let next = 0, size = 0;
  try {
    while (next < file.parts.length || ahead.length > 0) {
      while (ahead.length < TRANSFERS && next < file.parts.length) {
        const fetching = part(file.parts[next++] ?? "");
        // The first failure is thrown below, in order. A later one must not go unhandled.
        fetching.catch(() => {});
        ahead.push(fetching);
      }
      const bytes = await ahead.shift();
      if (bytes === undefined) break;
      await handle.writeFile(bytes);
      whole.update(bytes);
      size += bytes.byteLength;
    }
    await handle.sync();
  } finally { await handle.close(); }
  if (size !== file.size || whole.digest("hex") !== file.sha256) throw new Error(`The parts of ${file.path} do not add up to the file its checkpoint manifest names`);
  await rename(partial, path);
}
