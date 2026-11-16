import { crc32, deflateSync } from "node:zlib";

const stripes: [number, number, number][] = [[0xd0, 0x30, 0x30], [0x30, 0xa0, 0x40], [0x30, 0x50, 0xd0]];

export function capturePng(width: number, height: number): Buffer {
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.set(stripes[Math.floor(x * stripes.length / width)] ?? [0, 0, 0], 1 + x * 3);
  const chunk = (kind: string, data: Buffer) => {
    const body = Buffer.concat([Buffer.from(kind, "ascii"), data]);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from("\x89PNG\r\n\x1a\n", "latin1"), chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(Array.from({ length: height }, () => row)), { level: 0 })), chunk("IEND", Buffer.alloc(0))]);
}

export function pngSize(png: Buffer): [number, number] { return [png.readUInt32BE(16), png.readUInt32BE(20)]; }
