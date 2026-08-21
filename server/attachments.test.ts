// attachments.ts: save + read-back, the mime allowlist, size ceiling, and
// the name-lock that keeps the serving route inside the attachments dir.
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

// The module reads DATA_DIR at import time, so the env var must be set
// before the import is evaluated.
const DATA_ROOT = mkdtempSync(join(tmpdir(), "omb-attachments-"));
process.env.OMB_DATA_DIR = join(DATA_ROOT, "data");

const {
  ATTACHMENTS_DIR,
  IMAGE_MAX_BYTES,
  extensionForMime,
  imageDimensions,
  looksLikeSpriteSheet,
  readAttachment,
  saveImage,
} = await import("./attachments.ts");

/** A PNG header of the given size — only the bytes the size reader looks at. */
function png(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes, 0);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

describe("imageDimensions", () => {
  it("reads a PNG header", () => {
    expect(imageDimensions(png(320, 360))).toEqual({ width: 320, height: 360 });
  });

  it("reads a GIF screen size", () => {
    const gif = Buffer.alloc(10);
    gif.write("GIF89a", 0, "ascii");
    gif.writeUInt16LE(64, 6);
    gif.writeUInt16LE(72, 8);
    expect(imageDimensions(gif)).toEqual({ width: 64, height: 72 });
  });

  it("reads a JPEG frame header past its APP segments", () => {
    const jpeg = Buffer.concat([
      Buffer.from([0xff, 0xd8]),
      Buffer.from([0xff, 0xe0, 0x00, 0x04, 0x00, 0x00]), // APP0, skipped
      Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0x68, 0x02, 0x80]),
      Buffer.alloc(4),
    ]);
    expect(imageDimensions(jpeg)).toEqual({ width: 640, height: 360 });
  });

  it("gives up on bytes it does not recognise", () => {
    expect(imageDimensions(Buffer.from("not an image"))).toBeNull();
  });
});

describe("looksLikeSpriteSheet", () => {
  it("accepts a 9x8 grid of square frames", () => {
    expect(looksLikeSpriteSheet(png(8 * 40, 9 * 40))).toBe(true);
    expect(looksLikeSpriteSheet(png(8, 9))).toBe(true);
  });

  it("refuses a still photo — square, 3:2, or off-grid", () => {
    expect(looksLikeSpriteSheet(png(512, 512))).toBe(false);
    expect(looksLikeSpriteSheet(png(1200, 800))).toBe(false);
    expect(looksLikeSpriteSheet(png(320, 359))).toBe(false);
    // Divides the grid, but the frames would not be square.
    expect(looksLikeSpriteSheet(png(8 * 40, 9 * 41))).toBe(false);
  });

  it("refuses bytes whose size it cannot read", () => {
    expect(looksLikeSpriteSheet(Buffer.from("nope"))).toBe(false);
  });
});

describe("extensionForMime", () => {
  it("maps the accepted image mimes to extensions", () => {
    expect(extensionForMime("image/png")).toBe(".png");
    expect(extensionForMime("image/jpeg")).toBe(".jpg");
    expect(extensionForMime("image/gif")).toBe(".gif");
    expect(extensionForMime("image/webp")).toBe(".webp");
  });

  it("tolerates parameters and casing", () => {
    expect(extensionForMime("Image/PNG; charset=binary")).toBe(".png");
    expect(extensionForMime("  image/webp  ")).toBe(".webp");
  });

  it("refuses everything else — including svg, which executes script", () => {
    expect(extensionForMime("image/svg+xml")).toBeNull();
    expect(extensionForMime("text/plain")).toBeNull();
    expect(extensionForMime(undefined)).toBeNull();
  });
});

describe("saveImage", () => {
  beforeEach(() => {
    rmSync(ATTACHMENTS_DIR, { recursive: true, force: true });
  });
  afterEach(() => {
    rmSync(ATTACHMENTS_DIR, { recursive: true, force: true });
  });

  it("persists bytes under the attachments dir with a generated name", () => {
    const saved = saveImage(Buffer.from("png-bytes"), "image/png");
    expect(saved.path.startsWith(ATTACHMENTS_DIR)).toBe(true);
    expect(saved.path.endsWith(".png")).toBe(true);
    expect(saved.bytes).toBe(9);
    expect(saved.mime).toBe("image/png");
    if (process.platform !== "win32") {
      expect(statSync(ATTACHMENTS_DIR).mode & 0o777).toBe(0o700);
      expect(statSync(saved.path).mode & 0o777).toBe(0o600);
    }
  });

  it("round-trips through readAttachment with the right mime", () => {
    const saved = saveImage(Buffer.from("gif!"), "image/gif");
    const name = saved.path.split(/[\\/]/).pop()!;
    const back = readAttachment(name);
    expect(back?.bytes.toString()).toBe("gif!");
    expect(back?.mime).toBe("image/gif");
  });

  it("rejects unsupported mimes, empty bodies, and oversize bodies", () => {
    expect(() => saveImage(Buffer.from("x"), "image/svg+xml")).toThrow(/unsupported image type/);
    expect(() => saveImage(Buffer.alloc(0), "image/png")).toThrow(/empty/);
    expect(() => saveImage(Buffer.alloc(IMAGE_MAX_BYTES + 1), "image/png")).toThrow(/exceeds/);
  });
});

describe("readAttachment name lock", () => {
  beforeEach(() => {
    rmSync(ATTACHMENTS_DIR, { recursive: true, force: true });
  });
  afterEach(() => {
    rmSync(ATTACHMENTS_DIR, { recursive: true, force: true });
  });

  it("refuses traversal, dotfiles, and names the saver never writes", () => {
    expect(readAttachment("..%2F..%2Fconfig.json")).toBeNull();
    expect(readAttachment(".env")).toBeNull();
    expect(readAttachment("a/b.png")).toBeNull();
    expect(readAttachment("no-extension")).toBeNull();
    expect(readAttachment("uuid.jpeg")).toBeNull(); // saved as .jpg
  });
});
