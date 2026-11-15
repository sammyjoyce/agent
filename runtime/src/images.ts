import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import type { ImageLimits, ImageProcessor, PreparedImage } from "@earendil-works/pi-durable/tools";

/** One Photon worker per runtime process, shared by attachments and file reads; it exits after 1 s idle. */
let processor: Promise<ImageProcessor> | undefined;

/** Undefined when Photon cannot decode the bytes or make them fit `limits`. */
export async function prepareImage(bytes: Uint8Array, mimeType: string, limits: ImageLimits): Promise<PreparedImage | undefined> {
  processor ??= createNodePhotonImages({ idleMs: 1000 });
  return (await processor).prepare(bytes, mimeType, limits);
}
