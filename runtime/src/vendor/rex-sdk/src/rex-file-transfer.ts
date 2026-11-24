/**
 * File transfers with a terminal's machine: downloading files from it, and pasting files into it.
 *
 * A download reserves the file with `com.superlogical.terminal.download_begin`, then reads its
 * bytes from a byte stream. A paste reserves each file with `com.superlogical.terminal.upload_begin`,
 * sends its bytes, and Rex then types the stored files' paths into the terminal, as dropping files
 * on it does. Tickets stay inside this module: callers see files and bytes, never tickets.
 *
 * @since 0.1.0
 */
import { randomUUID } from "node:crypto";
import { Duration, Effect, FileSystem, Option, Scope, Stream } from "effect";
import type { PlatformError } from "effect/PlatformError";
import type { NonEmptyReadonlyArray } from "effect/Array";
import type { IRexAttachments } from "./rex-attachments.ts";
import { openRexBytesStream, type RexBytesStreamLimits } from "./rex-bytes-stream.ts";
import type { IRexConfig } from "./rex-config.ts";
import type { IRexControl, RexRequestOptions } from "./rex-control.ts";
import { rexDataHelloFromTicket } from "./rex-data-connection.ts";
import {
  RexInvalidResponse,
  RexTransferIncomplete,
  RexTransferStalled,
  type RexBytesStreamError,
  type RexDataError,
  type RexOperationError,
} from "./rex-errors.ts";
import { rexBlockMethodOperation, type RexBlockTarget } from "./rex-operation.ts";

/** Downloads stop when nothing arrives for this long, unless the caller sets `stallTimeout`. */
const defaultDownloadStallTimeout = Duration.seconds(30);

/** `readFile` stops past this many bytes, unless the caller sets `maxBytes`. */
const defaultReadFileMaxBytes = 64 * 1024 * 1024;

/** How long to wait for Rex to confirm an upload after its last byte. */
const uploadConfirmTimeout = Duration.seconds(120);

/**
 * A file on a terminal's machine, as `download_begin` described it.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexRemoteFile {
  /** The file's absolute path, with symlinks left as they are. */
  readonly path: string;
  /**
   * The last element of `path`, exactly as the file system has it, control characters included.
   * Sanitize it before using it as a local file name or showing it.
   */
  readonly name: string;
  /** The file's size when it was opened. A hint for progress: the stream may carry more or less. */
  readonly size: number;
  /** The modification time, as an RFC 3339 timestamp. Not a reliable cache key; use `version`. */
  readonly modifiedAt: string;
  /** Changes whenever the contents may have; none when the file changed in the last second. */
  readonly version: Option.Option<string>;
}

/**
 * Options for a download.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexDownloadOptions extends RexBytesStreamLimits {
  /** The `version` of a copy you already have; if it is still current, nothing is sent. */
  readonly ifNoneMatch?: string | undefined;
}

/**
 * A download: the file's bytes, or word that the copy named in `ifNoneMatch` is current.
 *
 * @category models
 * @since 0.1.0
 */
export type RexDownload =
  | { readonly _tag: "NotModified"; readonly file: RexRemoteFile }
  | {
      readonly _tag: "Download";
      readonly file: RexRemoteFile;
      /**
       * The file's bytes. Completes only when the whole file arrived; read it once, within the
       * scope of the download.
       */
      readonly bytes: Stream.Stream<Uint8Array, RexBytesStreamError>;
    };

/**
 * A whole file read into memory.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexFileContents {
  readonly file: RexRemoteFile;
  readonly bytes: Uint8Array;
}

/**
 * The outcome of {@link IRexFileTransfer.downloadToFile}.
 *
 * @category models
 * @since 0.1.0
 */
export type RexDownloadToFileResult =
  | { readonly _tag: "NotModified"; readonly file: RexRemoteFile }
  | {
      readonly _tag: "Downloaded";
      readonly file: RexRemoteFile;
      /** The local path written. */
      readonly destination: string;
      readonly bytesWritten: number;
    };

/**
 * A file to paste into a terminal: its bytes in memory, or a stream of exactly `size` bytes.
 *
 * @category models
 * @since 0.1.0
 */
export type RexPasteFile<E = never> =
  | {
      /** The file's name; Rex keeps only its last path component. */
      readonly name: string;
      /** The file's contents; a string is sent as UTF-8. */
      readonly data: Uint8Array | string;
    }
  | {
      readonly name: string;
      /** The exact number of bytes `stream` yields. */
      readonly size: number;
      readonly stream: Stream.Stream<Uint8Array, E>;
    };

/**
 * File transfer operations on terminal blocks.
 *
 * @category models
 * @since 0.1.0
 */
export interface IRexFileTransfer {
  /**
   * Downloads a file from the terminal's machine as a stream of bytes.
   *
   * A relative `path` is relative to the working directory of the terminal's foreground process;
   * when the terminal hasn't reported one, use an absolute path. The data connection opens at
   * once, so the reservation can't expire unused; closing the scope cancels the download.
   * Stops with `RexTransferStalled` after 30 seconds without bytes unless `stallTimeout` is set.
   */
  readonly download: (
    target: RexBlockTarget,
    path: string,
    options?: RexDownloadOptions,
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<RexDownload, RexOperationError | RexDataError, Scope.Scope>;
  /** Downloads a whole file into memory; stops past `maxBytes` (default 64 MiB). */
  readonly readFile: (
    target: RexBlockTarget,
    path: string,
    options?: RexBytesStreamLimits,
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<RexFileContents, RexOperationError | RexBytesStreamError>;
  /**
   * Downloads a file to a local path. Writes a temporary file beside `destination` and renames
   * it once the download is complete, so `destination` never holds a partial file.
   */
  readonly downloadToFile: (
    target: RexBlockTarget,
    path: string,
    destination: string,
    options?: RexDownloadOptions,
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<
    RexDownloadToFileResult,
    RexOperationError | RexBytesStreamError | PlatformError,
    FileSystem.FileSystem
  >;
  /**
   * Uploads files to the terminal's machine and has the terminal **type their paths**, as
   * dropping files on it does. Whatever runs in the terminal receives the paths as typed input,
   * so paste into a shell prompt or a program that expects them.
   *
   * Files go one at a time, as one batch: the paths are typed once every file has arrived. Rex
   * stores them with the block and deletes them when the session is destroyed.
   */
  readonly pasteFiles: <E = never>(
    target: RexBlockTarget,
    files: NonEmptyReadonlyArray<RexPasteFile<E>>,
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<void, RexOperationError | RexBytesStreamError | E>;
}

const textEncoder = new TextEncoder();

/** Builds a fresh `download:` or `upload:` reference: the prefix and a lower-case UUID. */
function newRef(prefix: "download" | "upload"): string {
  return `${prefix}:${randomUUID()}`;
}

function concatBytes(chunks: ReadonlyArray<Uint8Array>, length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

/**
 * Builds the file transfer operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export function makeRexFileTransfer(
  config: IRexConfig,
  control: IRexControl,
  attachments: IRexAttachments,
): IRexFileTransfer {
  const downloadBegin = rexBlockMethodOperation(
    control,
    attachments,
    "com.superlogical.terminal.download_begin",
  );
  const uploadBegin = rexBlockMethodOperation(
    control,
    attachments,
    "com.superlogical.terminal.upload_begin",
  );

  const download: IRexFileTransfer["download"] = (target, path, options = {}, requestOptions) =>
    Effect.gen(function* () {
      const reply = yield* downloadBegin(
        target,
        {
          ref: newRef("download"),
          path,
          ...(options.ifNoneMatch === undefined ? {} : { ifNoneMatch: options.ifNoneMatch }),
        },
        requestOptions,
      );
      const file: RexRemoteFile = {
        path: reply.path,
        name: reply.name,
        size: reply.size,
        modifiedAt: reply.modifiedAt,
        version: reply.version,
      };
      if (Option.getOrElse(reply.notModified, () => false)) {
        return { _tag: "NotModified", file } satisfies RexDownload;
      }
      if (Option.isNone(reply.ticket)) {
        return yield* new RexInvalidResponse(
          "com.superlogical.terminal.download_begin",
          undefined,
          "the reply has neither a ticket nor not_modified",
        );
      }
      const hello = yield* rexDataHelloFromTicket(
        "com.superlogical.terminal.download_begin",
        reply.ticket.value,
      );
      const stallTimeout = options.stallTimeout ?? defaultDownloadStallTimeout;
      // A download ends with the server's half-close, then its close; bound that wait as well.
      const stream = yield* openRexBytesStream(config, hello, target.blockId, {
        maxBytes: options.maxBytes,
        stallTimeout,
        closeTimeout: stallTimeout,
      });
      return {
        _tag: "Download",
        file,
        bytes: stream.incoming.pipe(Stream.concat(Stream.fromEffectDrain(stream.done))),
      } satisfies RexDownload;
    }).pipe(Effect.withSpan("RexFileTransfer.download"));

  const readFile: IRexFileTransfer["readFile"] = (target, path, options = {}, requestOptions) =>
    Effect.scoped(
      Effect.gen(function* () {
        const result = yield* download(
          target,
          path,
          { ...options, maxBytes: options.maxBytes ?? defaultReadFileMaxBytes },
          requestOptions,
        );
        if (result._tag === "NotModified") {
          return yield* new RexInvalidResponse(
            "com.superlogical.terminal.download_begin",
            undefined,
            "not_modified without if_none_match",
          );
        }
        const chunks: Array<Uint8Array> = [];
        let length = 0;
        yield* Stream.runForEach(result.bytes, (chunk) =>
          Effect.sync(() => {
            chunks.push(chunk);
            length += chunk.length;
          }),
        );
        return { file: result.file, bytes: concatBytes(chunks, length) } satisfies RexFileContents;
      }),
    ).pipe(Effect.withSpan("RexFileTransfer.readFile"));

  const downloadToFile: IRexFileTransfer["downloadToFile"] = (
    target,
    path,
    destination,
    options,
    requestOptions,
  ) =>
    Effect.scoped(
      Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const result = yield* download(target, path, options, requestOptions);
        if (result._tag === "NotModified") return result satisfies RexDownloadToFileResult;
        const partial = `${destination}.rex-partial-${randomUUID()}`;
        let bytesWritten = 0;
        yield* result.bytes.pipe(
          Stream.tap((chunk) =>
            Effect.sync(() => {
              bytesWritten += chunk.length;
            }),
          ),
          Stream.run(fileSystem.sink(partial)),
          Effect.flatMap(() => fileSystem.rename(partial, destination)),
          Effect.onError(() => Effect.ignore(fileSystem.remove(partial))),
        );
        return {
          _tag: "Downloaded",
          file: result.file,
          destination,
          bytesWritten,
        } satisfies RexDownloadToFileResult;
      }),
    ).pipe(Effect.withSpan("RexFileTransfer.downloadToFile"));

  const pasteFile = <E>(
    target: RexBlockTarget,
    file: RexPasteFile<E>,
    batch: Option.Option<{ readonly id: string; readonly index: number; readonly count: number }>,
    requestOptions: RexRequestOptions | undefined,
  ) =>
    Effect.scoped(
      Effect.gen(function* () {
        const source =
          "data" in file
            ? Option.some(typeof file.data === "string" ? textEncoder.encode(file.data) : file.data)
            : Option.none<Uint8Array>();
        const size = Option.match(source, {
          onNone: () => ("size" in file ? file.size : 0),
          onSome: (bytes) => bytes.length,
        });
        const reply = yield* uploadBegin(
          target,
          {
            ref: newRef("upload"),
            name: file.name,
            size,
            ...Option.match(batch, {
              onNone: () => ({}),
              onSome: (current) => ({
                batch: current.id,
                index: current.index,
                count: current.count,
              }),
            }),
          },
          requestOptions,
        );
        const hello = yield* rexDataHelloFromTicket(
          "com.superlogical.terminal.upload_begin",
          reply.ticket,
        );
        const stream = yield* openRexBytesStream(config, hello, target.blockId);
        let sent = 0;
        const chunks: Stream.Stream<Uint8Array, E> =
          "stream" in file ? file.stream : Stream.fromIterable(Option.toArray(source));
        yield* Stream.runForEach(chunks, (chunk) =>
          Effect.gen(function* () {
            sent += chunk.length;
            if (sent > size) {
              return yield* new RexTransferIncomplete(
                target.blockId,
                `${file.name} has more than the ${size} bytes it declared`,
              );
            }
            yield* stream.write(chunk);
          }),
        );
        if (sent !== size) {
          return yield* new RexTransferIncomplete(
            target.blockId,
            `${file.name} has ${sent} bytes, not the ${size} it declared`,
          );
        }
        yield* stream.end;
        yield* stream.done.pipe(
          Effect.timeoutOrElse({
            duration: uploadConfirmTimeout,
            orElse: () =>
              Effect.fail(
                new RexTransferStalled(target.blockId, Duration.toMillis(uploadConfirmTimeout)),
              ),
          }),
        );
      }),
    );

  const pasteFiles: IRexFileTransfer["pasteFiles"] = (target, files, requestOptions) =>
    Effect.gen(function* () {
      const batchId = randomUUID();
      for (const [index, file] of files.entries()) {
        yield* pasteFile(
          target,
          file,
          files.length === 1
            ? Option.none()
            : Option.some({ id: batchId, index, count: files.length }),
          requestOptions,
        );
      }
    }).pipe(Effect.withSpan("RexFileTransfer.pasteFiles"));

  return { download, readFile, downloadToFile, pasteFiles };
}
