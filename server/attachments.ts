// Image attachments: pasted/dropped images become files under
// ~/.swarmebot/attachments so every CLI engine can open them by path —
// the app never ships image bytes through the prompt itself.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, extname } from "node:path";
import { DATA_DIR } from "./config.ts";

export const ATTACHMENTS_DIR = join(DATA_DIR, "attachments");

/** The spec's ceiling: a screenshot bigger than this is rejected before it
 * is ever buffered, matching the composer's existing size discipline. */
export const IMAGE_MAX_BYTES = 10 * 1024 * 1024;

/** Mimes the endpoint accepts, mapped to the extension stored on disk.
 * Sniffing is not attempted — a lie here only changes the filename. */
const IMAGE_MIMES: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/gif": ".gif",
  "image/webp": ".webp",
};

/** A bot's picture is drawn at many sizes in many places at once, and each
 * one decodes the file it is handed; a chat attachment is decoded once. */
export const AVATAR_IMAGE_MAX_BYTES = 2 * 1024 * 1024;

export function extensionForMime(mime: string | undefined): string | null {
  if (!mime) return null;
  return IMAGE_MIMES[mime.split(";")[0]!.trim().toLowerCase()] ?? null;
}

export function ensureAttachmentsDir(): void {
  mkdirSync(ATTACHMENTS_DIR, { recursive: true, mode: 0o700 });
}

export interface SavedAttachment {
  path: string;
  mime: string;
  bytes: number;
}

/** Persist one image and return its path. The UUID filename means the name
 * is never attacker-controlled and never collides; the extension preserves
 * the format the sender claimed. */
export function saveImage(bytes: Buffer, mime: string): SavedAttachment {
  const ext = extensionForMime(mime);
  if (!ext) throw Object.assign(new Error("unsupported image type"), { status: 400 });
  if (bytes.byteLength === 0) throw Object.assign(new Error("empty image"), { status: 400 });
  if (bytes.byteLength > IMAGE_MAX_BYTES) {
    throw Object.assign(new Error(`image exceeds ${IMAGE_MAX_BYTES} bytes`), { status: 413 });
  }
  ensureAttachmentsDir();
  const name = `${randomUUID()}${ext}`;
  const path = join(ATTACHMENTS_DIR, name);
  writeFileSync(path, bytes, { mode: 0o600, flag: "wx" });
  return { path, mime: mime.split(";")[0]!.trim().toLowerCase(), bytes: bytes.byteLength };
}

/** Read an attachment back for serving. Only names that are exactly a bare
 * filename (no separators, no dotfiles) inside ATTACHMENTS_DIR resolve —
 * the route must never become a general file server for the data dir. */
export function readAttachment(name: string): { bytes: Buffer; mime: string } | null {
  if (!/^[A-Za-z0-9-]+\.(png|jpg|jpeg|gif|webp)$/.test(name)) return null;
  const path = join(ATTACHMENTS_DIR, name);
  if (extname(path) === ".jpeg") return null; // saved as .jpg; .jpeg is not a name we write
  try {
    return { bytes: readFileSync(path), mime: mimeForExt(extname(path)) };
  } catch {
    return null;
  }
}

function mimeForExt(ext: string): string {
  switch (ext) {
    case ".png":
      return "image/png";
    case ".jpg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    default:
      return "application/octet-stream";
  }
}

/**
 * Pixel size of an image, read from its header — enough to tell an uploaded
 * sprite sheet from an ordinary photo without decoding the whole file.
 * Returns null for anything whose header we do not recognise, which the
 * callers treat as "not a sheet".
 */
export function imageDimensions(bytes: Buffer): { width: number; height: number } | null {
  // PNG: 8-byte signature, then an IHDR chunk whose first two fields are the
  // dimensions as big-endian uint32s.
  if (bytes.byteLength >= 24 && bytes.subarray(0, 8).equals(PNG_MAGIC)) {
    if (bytes.subarray(12, 16).toString("ascii") !== "IHDR") return null;
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  // GIF: "GIF87a"/"GIF89a", then the logical screen size as little-endian
  // uint16s.
  if (bytes.byteLength >= 10 && bytes.subarray(0, 3).toString("ascii") === "GIF") {
    return { width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8) };
  }
  // WebP: RIFF container, dimensions laid out differently per codec chunk.
  if (
    bytes.byteLength >= 30 &&
    bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
    bytes.subarray(8, 12).toString("ascii") === "WEBP"
  ) {
    const chunk = bytes.subarray(12, 16).toString("ascii");
    if (chunk === "VP8 ") return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
    if (chunk === "VP8L") {
      const bits = bytes.readUInt32LE(21);
      return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
    }
    if (chunk === "VP8X") {
      return {
        width: (bytes.readUIntLE(24, 3) & 0xffffff) + 1,
        height: (bytes.readUIntLE(27, 3) & 0xffffff) + 1,
      };
    }
    return null;
  }
  // JPEG: walk the marker segments to the first frame header (SOFn), whose
  // payload carries height then width as big-endian uint16s.
  if (bytes.byteLength >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let at = 2;
    while (at + 9 < bytes.byteLength) {
      if (bytes[at] !== 0xff) {
        at++;
        continue;
      }
      const marker = bytes[at + 1]!;
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        at += 2;
        continue;
      }
      const length = bytes.readUInt16BE(at + 2);
      // SOF0..SOF15, minus the DHT/JPG/DAC markers interleaved in that range.
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) };
      }
      at += 2 + length;
    }
    return null;
  }
  return null;
}

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** The grid an uploaded sprite sheet is always laid out on: 9 rows of 8
 * square frames, mirroring SHEET_ROWS/SHEET_COLS in src/lib/sprite-sheet.ts. */
const SHEET_ROWS = 9;
const SHEET_COLS = 8;

/**
 * Whether an uploaded picture is a sprite sheet rather than a still photo:
 * its pixels must divide into the 9x8 grid exactly, with square frames. A
 * photo — square, 3:2, anything else — fails one of those and stays still.
 */
export function looksLikeSpriteSheet(bytes: Buffer): boolean {
  const size = imageDimensions(bytes);
  if (!size || size.width <= 0 || size.height <= 0) return false;
  if (size.width % SHEET_COLS !== 0 || size.height % SHEET_ROWS !== 0) return false;
  return size.width / SHEET_COLS === size.height / SHEET_ROWS;
}
