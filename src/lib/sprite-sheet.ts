/** Uploaded bot pictures that are sprite sheets are always this grid. */
export const SHEET_ROWS = 9;
export const SHEET_COLS = 8;
export const SHEET_FRAME_MS = 250;

export function clampSheetRow(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isInteger(value)) return null;
  if (value < 0 || value >= SHEET_ROWS) return null;
  return value;
}

/**
 * A frame counts as drawn when some pixel is neither transparent nor plain
 * black: sheets are exported padded, and the unused cells of a short row come
 * back as either. The thresholds are deliberately low — a dark frame with any
 * real art in it clears them easily.
 */
const INK_ALPHA = 8;
const INK_LIGHT = 12;

/**
 * How many frames each row of a sheet actually draws, from its RGBA pixels.
 * Rows are padded out to 8 cells on export, so animating all 8 parks the
 * avatar on empty cells for part of the loop; the count runs to the last
 * drawn frame, so a gap inside a row does not cut it short. An entirely
 * empty row reports 1, which holds still rather than dividing by zero.
 */
export function sheetFrameCounts(
  pixels: Uint8ClampedArray | Uint8Array,
  width: number,
  height: number,
): number[] {
  const frameW = Math.floor(width / SHEET_COLS);
  const frameH = Math.floor(height / SHEET_ROWS);
  if (frameW < 1 || frameH < 1) return Array.from({ length: SHEET_ROWS }, () => SHEET_COLS);
  return Array.from({ length: SHEET_ROWS }, (_, row) => {
    let last = -1;
    for (let col = 0; col < SHEET_COLS; col++) {
      if (frameHasInk(pixels, width, col * frameW, row * frameH, frameW, frameH)) last = col;
    }
    return last + 1 || 1;
  });
}

function frameHasInk(
  pixels: Uint8ClampedArray | Uint8Array,
  width: number,
  x0: number,
  y0: number,
  frameW: number,
  frameH: number,
): boolean {
  for (let y = y0; y < y0 + frameH; y++) {
    let at = (y * width + x0) * 4;
    for (let x = 0; x < frameW; x++, at += 4) {
      if (
        pixels[at + 3]! > INK_ALPHA &&
        Math.max(pixels[at]!, pixels[at + 1]!, pixels[at + 2]!) > INK_LIGHT
      ) {
        return true;
      }
    }
  }
  return false;
}

/**
 * The per-row frame counts for one sheet, measured once per image and kept
 * for the session: an avatar is drawn in dozens of places at once, and they
 * all ask about the same handful of files.
 */
const counted = new Map<string, Promise<number[] | null>>();

export function loadSheetFrameCounts(src: string): Promise<number[] | null> {
  const known = counted.get(src);
  if (known) return known;
  const measuring = measureSheet(src).catch(() => null);
  counted.set(src, measuring);
  return measuring;
}

async function measureSheet(src: string): Promise<number[] | null> {
  if (typeof document === "undefined") return null;
  const image = new Image();
  image.crossOrigin = "anonymous";
  image.src = src;
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = image.naturalWidth;
  canvas.height = image.naturalHeight;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context || !canvas.width || !canvas.height) return null;
  context.drawImage(image, 0, 0);
  const { data } = context.getImageData(0, 0, canvas.width, canvas.height);
  return sheetFrameCounts(data, canvas.width, canvas.height);
}

/**
 * The largest frame worth storing. An avatar is drawn at 16 to 220 CSS
 * pixels, so at a retina display's 2x a 128-pixel frame covers every place
 * the sheet appears except the call screen's 220-pixel portrait, which takes
 * a mild upscale. Sheets are authored far larger than that — a 1536x1872 one
 * is eleven megabytes once decoded, and the browser rescales it on every
 * paint, four times a second per animated avatar.
 */
export const SHEET_MAX_FRAME = 128;

/** The frame size a sheet of these pixels implies, or null if this is not a
 * sheet: it must divide the 9x8 grid exactly and leave frames roughly as tall
 * as they are wide. Mirrors looksLikeSpriteSheet in server/attachments.ts. */
export function sheetFrameSize(
  width: number,
  height: number,
): { width: number; height: number } | null {
  if (width <= 0 || height <= 0) return null;
  if (width % SHEET_COLS !== 0 || height % SHEET_ROWS !== 0) return null;
  const frame = { width: width / SHEET_COLS, height: height / SHEET_ROWS };
  const aspect = frame.width / frame.height;
  return aspect >= 0.7 && aspect <= 1.4 ? frame : null;
}

/**
 * The size to store a sheet at, or null to leave it alone. The result stays
 * an exact multiple of the grid — the server reads the stored pixels to
 * decide a sheet is a sheet, and a rounded-off edge would demote it to a
 * still photo.
 */
export function sheetDownscale(
  width: number,
  height: number,
  maxFrame: number = SHEET_MAX_FRAME,
): { width: number; height: number } | null {
  const frame = sheetFrameSize(width, height);
  if (!frame) return null;
  const longest = Math.max(frame.width, frame.height);
  if (longest <= maxFrame) return null;
  const scale = maxFrame / longest;
  return {
    width: Math.max(1, Math.round(frame.width * scale)) * SHEET_COLS,
    height: Math.max(1, Math.round(frame.height * scale)) * SHEET_ROWS,
  };
}

/**
 * A sheet, resampled to SHEET_MAX_FRAME before it is uploaded. Anything that
 * is not an oversized sheet — a photo, a small sheet, an SVG, an animated GIF
 * — comes back untouched, as does a resample that fails or lands bigger than
 * what it replaced.
 */
export async function downscaleSheetFile(file: File): Promise<File> {
  if (!/^image\/(png|jpeg|webp|gif)$/.test(file.type)) return file;
  try {
    const source = await createImageBitmap(file);
    const target = sheetDownscale(source.width, source.height);
    if (!target) {
      source.close();
      return file;
    }
    const canvas = document.createElement("canvas");
    canvas.width = target.width;
    canvas.height = target.height;
    const context = canvas.getContext("2d");
    if (!context) return file;
    context.imageSmoothingQuality = "high";
    context.drawImage(source, 0, 0, target.width, target.height);
    source.close();
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, "image/webp", 0.95),
    );
    if (!blob || blob.size >= file.size) return file;
    return new File([blob], `${file.name.replace(/\.[^.]+$/, "")}.webp`, { type: "image/webp" });
  } catch {
    return file;
  }
}
