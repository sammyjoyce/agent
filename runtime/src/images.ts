import type { Context } from "@earendil-works/chord/context";
import type { ToolExecutionApi, ToolExecutionResult } from "@earendil-works/pi-durable";
import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { DEFAULT_IMAGE_LIMITS, type ImageLimits, type ImageProcessor, type PreparedImage } from "@earendil-works/pi-durable/tools";
import type { HostCommand } from "./generated/HostCommand.js";
import type { HostResult } from "./generated/HostResult.js";
import { IMAGE_CHUNK_BYTES, MAX_IMAGE_READ_BYTES } from "./generated/image-read-limits.js";
import { hostOutput } from "./host-output.js";
import type { HostCall } from "./tasks.js";

export type ReadFileCommand = Extract<HostCommand, { type: "read_file" }>;
type ImageChunk = Extract<HostResult, { type: "image_chunk" }>;
/** What the conversation's model takes as image input. */
export type ImageInput = { readonly vision: boolean; readonly limits: ImageLimits };

/** One Photon worker per runtime process, shared by attachments and file reads; it exits after 1 s idle. */
let processor: Promise<ImageProcessor> | undefined;

/** Undefined when Photon cannot decode the bytes or make them fit `limits`. */
export async function prepareImage(bytes: Uint8Array, mimeType: string, limits: ImageLimits): Promise<PreparedImage | undefined> {
  processor ??= createNodePhotonImages({ idleMs: 1000 });
  return (await processor).prepare(bytes, mimeType, limits);
}

/** As upstream `read` resolves it: a model that cannot be resolved counts as one that takes images within the defaults. */
export async function imageInput(api: Pick<ToolExecutionApi, "agent" | "models">, context: Context): Promise<ImageInput> {
  const ref = (await api.agent(context)).model;
  const model = ref === undefined ? undefined : api.models.getModel(ref.provider, ref.modelId);
  const resize = model?.inputLimits?.images?.resize;
  return {
    vision: model?.input.includes("image") ?? true,
    limits: {
      maxWidth: resize?.maxWidth ?? DEFAULT_IMAGE_LIMITS.maxWidth,
      maxHeight: resize?.maxHeight ?? DEFAULT_IMAGE_LIMITS.maxHeight,
      maxBytes: resize?.maxBytes ?? DEFAULT_IMAGE_LIMITS.maxBytes,
    },
  };
}

/**
 * Pulls the rest of the image `first` began and prepares it for `input`. A host failure reads as any failed host
 * result; any reply that does not continue the same file version ends the read without an image.
 */
export async function readImageFile(call: HostCall, command: ReadFileCommand, first: ImageChunk, input: ImageInput): Promise<ToolExecutionResult> {
  const changed = imageError(`${command.path} changed while it was read; read it again.`);
  const size = first.size_bytes;
  if (first.at !== 0 || size < 1 || size > MAX_IMAGE_READ_BYTES) return changed;
  const bytes = new Uint8Array(size);
  let reply: HostResult = first;
  for (let filled = 0; filled < size;) {
    if (reply.type === "failed") return hostOutput(reply);
    const data = reply.type === "image_chunk" && reply.at === filled && reply.stamp === first.stamp &&
      reply.media_type === first.media_type && reply.size_bytes === size ? Buffer.from(reply.data_base64, "base64") : undefined;
    if (data?.length !== Math.min(IMAGE_CHUNK_BYTES, size - filled)) return changed;
    bytes.set(data, filled);
    filled += data.length;
    if (filled < size) reply = await call({ ...command, image: { type: "next", at: filled, stamp: first.stamp } });
  }
  const prepared = await prepareImage(bytes, first.media_type, input.limits).catch(() => undefined);
  if (prepared === undefined) return imageError(`${command.path} is an image (${first.media_type}) that cannot be prepared for the model`);
  const notes = [`Read image file [${prepared.mimeType}].`];
  if (prepared.convertedFrom !== undefined) notes.push(`Converted from ${prepared.convertedFrom} to ${prepared.mimeType}.`);
  if (prepared.resized !== undefined) {
    const { from, to } = prepared.resized;
    notes.push(`Resized from ${from.width}x${from.height} to ${to.width}x${to.height}. Multiply coordinates by ${(from.width / to.width).toFixed(2)} to map them to the original.`);
  }
  if (!input.vision) notes.push("The current model does not support images; it sees a placeholder instead.");
  return { output: [{ type: "image", data: prepared.data, mimeType: prepared.mimeType }],
    diagnostics: [{ severity: "info", code: "image", message: notes.join(" ") }] };
}

function imageError(message: string): ToolExecutionResult {
  return { output: [], isError: true, diagnostics: [{ severity: "error", code: "unsupported_image", message }] };
}
