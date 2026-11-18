import { open, readdir, readFile, rm, type FileHandle } from "node:fs/promises";
import { dirname, join } from "node:path";
import { REPLICATED_FILE_ROOTS } from "../generated/replicated-file-roots.js";
import { repeatUntilAnswered } from "./authority-link.js";
import { isStatePath } from "./authority-wire.js";
import { sha256Hex } from "./log-entry.js";
import type { LogWriter, StagedFile } from "./replicated-storage.js";
import { isTemporaryName, makeDirectory, publishFiles, temporaryPath, writeTemporary, type LogFollower } from "./standby.js";

/** One retained file on its way to a final name. `path` is relative to the state directory. */
export type RetainedWrite =
  | { readonly path: string; readonly bytes: Uint8Array }
  /** A synced local file, for content that arrived in chunks. It may already be at its final path. */
  | { readonly path: string; readonly staged: string };

/** Every write under attachments/, history/assets/ and feedback/ goes through it, except the local writes of an attachment upload before it completes. */
export interface RetainedFiles {
  readonly stateDirectory: string;
  /**
   * Gives every file its final name. The replicated implementation names all
   * of them or, after a restart, none. The local one names them in order, so a
   * caller lists last the file a reader takes as the mark of completion.
   * Removes the temporary files it made, and never a staged file it was given.
   */
  write(files: readonly RetainedWrite[]): Promise<void>;
  /** Removes a file or a directory. The replicated implementation logs the removal first, so a standby removes it too. */
  remove(path: string): Promise<void>;
}

/** A coordinator without replication: each file is synced, renamed and its directory synced, as one local step. */
export class LocalFiles implements RetainedFiles {
  constructor(readonly stateDirectory: string) {}

  write(files: readonly RetainedWrite[]): Promise<void> {
    return writeRetained(this.stateDirectory, files, async (publishing) => {
      await publishFiles(publishing.map(({ staged, final }) => ({ synced: staged, path: final })));
    });
  }

  remove(path: string): Promise<void> { return removeRetained(this.stateDirectory, path); }
}

/**
 * A replicated owner: each file's bytes go to the blob store, then one log
 * entry names them all, and only then do they take their final names. A crash
 * after the append is repaired by the catch-up on open, and one before it
 * leaves only temporary files, which `cleanRetainedFiles` removes.
 */
export class ReplicatedFiles implements RetainedFiles {
  readonly stateDirectory: string;
  readonly #log: LogWriter;
  readonly #options: Pick<LogFollower, "link" | "signal">;

  /** `options` are the ones the owner's storage opened with, so the log and these files share one state directory. */
  constructor(log: LogWriter, options: Pick<LogFollower, "link" | "stateDirectory" | "signal">) {
    this.#log = log; this.#options = options; this.stateDirectory = options.stateDirectory;
  }

  write(files: readonly RetainedWrite[]): Promise<void> {
    return writeRetained(this.stateDirectory, files, async (publishing) => {
      const { link, signal } = this.#options;
      const staged: StagedFile[] = [];
      for (const file of publishing) {
        const bytes = file.bytes ?? await readFile(file.staged);
        const sha256 = sha256Hex(bytes);
        await repeatUntilAnswered(() => link.putBlob(sha256, bytes), signal);
        staged.push({ record: { path: file.path, sha256, size: bytes.byteLength }, staged: file.staged });
      }
      await this.#log.appendFiles(staged);
    });
  }

  remove(path: string): Promise<void> { return this.#log.removeFiles([statePath(path)]); }
}

/** A temporary file beside a retained file's final path, for content that arrives in chunks. */
export class StagingFile {
  readonly path: string;
  readonly #handle: FileHandle;

  private constructor(path: string, handle: FileHandle) { this.path = path; this.#handle = handle; }

  static async create(directory: string): Promise<StagingFile> {
    await makeDirectory(directory);
    const path = temporaryPath(directory);
    return new StagingFile(path, await open(path, "wx", 0o600));
  }

  append(bytes: Uint8Array): Promise<void> { return this.#handle.writeFile(bytes); }

  /** Syncs and closes the file. It is then ready for `write` as `staged`. */
  async sync(): Promise<void> {
    await this.#handle.sync();
    await this.#handle.close();
  }

  /** Closes and removes the file, unless `write` already gave it its final name. */
  async discard(): Promise<void> {
    await this.#handle.close().catch(() => {});
    await rm(this.path, { force: true });
  }
}

/**
 * Removes what a crash leaves under the retained trees: temporary files, and
 * attachment uploads whose metadata is missing or says they are incomplete.
 */
export async function cleanRetainedFiles(stateDirectory: string): Promise<void> {
  for (const root of REPLICATED_FILE_ROOTS) await removeTemporaries(join(stateDirectory, root));
  const attachments = join(stateDirectory, "attachments");
  for (const entry of await directoryEntries(attachments)) {
    const folder = join(attachments, entry.name);
    if (entry.isDirectory() && await unfinishedUpload(folder)) await rm(folder, { recursive: true, force: true });
  }
}

interface Publishing {
  readonly path: string;
  readonly final: string;
  readonly staged: string;
  readonly bytes?: Uint8Array;
}

async function writeRetained(stateDirectory: string, files: readonly RetainedWrite[], publish: (files: readonly Publishing[]) => Promise<void>): Promise<void> {
  const named = files.map((file) => ({ file, final: join(stateDirectory, finalPath(file.path)) }));
  if (named.length === 0) return;
  const made: string[] = [];
  try {
    const publishing: Publishing[] = [];
    for (const { file, final } of named) {
      if ("staged" in file) { publishing.push({ path: file.path, final, staged: file.staged }); continue; }
      const staged = await writeTemporary(dirname(final), file.bytes);
      made.push(staged);
      publishing.push({ path: file.path, final, staged, bytes: file.bytes });
    }
    await publish(publishing);
  } finally {
    await Promise.all(made.map((path) => rm(path, { force: true })));
  }
}

async function removeRetained(stateDirectory: string, path: string): Promise<void> {
  await rm(join(stateDirectory, statePath(path)), { recursive: true, force: true });
}

function statePath(path: string): string {
  if (!isStatePath(path)) throw new Error(`The retained file path ${path} must be relative and lie under attachments, history/assets or feedback`);
  return path;
}

/** A path a file may take as its final name. A temporary name is refused, so the cleanup never removes a file the log names. */
function finalPath(path: string): string {
  if (statePath(path).split("/").some(isTemporaryName)) throw new Error(`The retained file path ${path} has a temporary name, which the startup cleanup removes`);
  return path;
}

async function removeTemporaries(directory: string): Promise<void> {
  for (const entry of await directoryEntries(directory)) {
    const path = join(directory, entry.name);
    if (isTemporaryName(entry.name)) await rm(path, { recursive: true, force: true });
    else if (entry.isDirectory()) await removeTemporaries(path);
  }
}

/** An attachment upload is complete only once its metadata says so. */
async function unfinishedUpload(folder: string): Promise<boolean> {
  let text: string;
  try { text = await readFile(join(folder, "metadata.json"), "utf8"); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return true;
    throw error;
  }
  try {
    const metadata: unknown = JSON.parse(text);
    return metadata !== null && typeof metadata === "object" && "complete" in metadata && metadata.complete === false;
  } catch { return false; }
}

async function directoryEntries(directory: string) {
  return readdir(directory, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
}
