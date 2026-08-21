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
