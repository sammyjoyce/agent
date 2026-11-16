import { crc32, deflateSync } from "node:zlib";

const stripes: [number, number, number][] = [[0xd0, 0x30, 0x30], [0x30, 0xa0, 0x40], [0x30, 0x50, 0xd0]];

function chunk(kind: string, data: Buffer): Buffer {
  const body = Buffer.concat([Buffer.from(kind, "ascii"), data]);
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** An uncompressed 8-bit RGB PNG of these scanlines, each with its filter byte, and any extra chunks before the end. */
function png(width: number, height: number, scanlines: Buffer, extra: Buffer[] = []): Buffer {
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from("\x89PNG\r\n\x1a\n", "latin1"), chunk("IHDR", header), chunk("IDAT", deflateSync(scanlines, { level: 0 })), ...extra,
    chunk("IEND", Buffer.alloc(0))]);
}

export function capturePng(width: number, height: number): Buffer {
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.set(stripes[Math.floor(x * stripes.length / width)] ?? [0, 0, 0], 1 + x * 3);
  return png(width, height, Buffer.concat(Array.from({ length: height }, () => row)));
}

/**
 * A square PNG of exactly `bytes` bytes whose pixels are noise, so no encoder
 * can make it small. A private ancillary chunk, which decoders skip, pads the
 * file to its size.
 */
export function noisePng(seed: number, bytes: number): Buffer {
  const side = Math.floor(Math.sqrt(bytes / 3) * 0.995), scanlines = Buffer.alloc(side * (1 + side * 3));
  let state = seed;
  for (let index = 0; index < scanlines.length; index += 1) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    scanlines[index] = index % (1 + side * 3) === 0 ? 0 : state >> 16;
  }
  const unpadded = png(side, side, scanlines), padding = bytes - unpadded.length - 12;
  if (padding < 0) throw new Error(`A noise PNG of side ${side} is already ${unpadded.length} bytes`);
  return png(side, side, scanlines, [chunk("prVt", Buffer.alloc(padding))]);
}

export function pngSize(png: Buffer): [number, number] { return [png.readUInt32BE(16), png.readUInt32BE(20)]; }
