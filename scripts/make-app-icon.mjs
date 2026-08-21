// Writes the iOS App Store icon from build/icon-1024.png.
//
//   node scripts/make-app-icon.mjs
//
// iOS wants full-bleed art with no alpha. The macOS Dock icon keeps the
// rounded PNG / icns with transparency; this file only flattens a copy
// onto black for AppIcon.appiconset.
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { deflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = join(ROOT, "build", "icon-1024.png");
const OUT_DIR = join(ROOT, "ios", "App", "Assets.xcassets", "AppIcon.appiconset");

function crc32(buf) {
  let c = -1;
  for (const byte of buf) {
    c ^= byte;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function encodePngRgb(pixels, size) {
  const raw = Buffer.alloc((size * 3 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 3 + 1)] = 0;
    pixels.copy(raw, y * (size * 3 + 1) + 1, y * size * 3, (y + 1) * size * 3);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const bmpPath = join(tmpdir(), "swarmebot-app-icon.bmp");
const converted = spawnSync("sips", ["-s", "format", "bmp", SOURCE, "--out", bmpPath], { encoding: "utf8" });
if (converted.status !== 0) {
  throw new Error(converted.stderr || "sips failed to flatten the app icon");
}
const data = readFileSync(bmpPath);
const off = data.readUInt32LE(10);
const width = data.readInt32LE(18);
let height = data.readInt32LE(22);
const bpp = data.readUInt16LE(28);
const topDown = height < 0;
height = Math.abs(height);
if (width !== 1024 || height !== 1024) throw new Error(`expected 1024×1024, got ${width}×${height}`);
const bytes = bpp / 8;
const row = Math.floor((width * bytes + 3) / 4) * 4;
const rgb = Buffer.alloc(width * height * 3);
for (let y = 0; y < height; y++) {
  const srcY = topDown ? y : height - 1 - y;
  const start = off + srcY * row;
  for (let x = 0; x < width; x++) {
    const i = start + x * bytes;
    let b = data[i];
    let g = data[i + 1];
    let r = data[i + 2];
    const a = bpp === 32 ? data[i + 3] : 255;
    if (a < 255) {
      r = Math.round((r * a) / 255);
      g = Math.round((g * a) / 255);
      b = Math.round((b * a) / 255);
    }
    const at = (y * width + x) * 3;
    rgb[at] = r;
    rgb[at + 1] = g;
    rgb[at + 2] = b;
  }
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(join(OUT_DIR, "icon-1024.png"), encodePngRgb(rgb, 1024));
writeFileSync(
  join(OUT_DIR, "Contents.json"),
  JSON.stringify(
    {
      images: [{ filename: "icon-1024.png", idiom: "universal", platform: "ios", size: "1024x1024" }],
      info: { author: "xcode", version: 1 },
    },
    null,
    2,
  ) + "\n",
);
console.log(`wrote 1024×1024 iOS icon from build/icon-1024.png`);
