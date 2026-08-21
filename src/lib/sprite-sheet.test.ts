import { describe, expect, it } from "vitest";
import {
  clampSheetRow,
  sheetDownscale,
  sheetFrameCounts,
  sheetFrameSize,
  SHEET_COLS,
  SHEET_MAX_FRAME,
  SHEET_ROWS,
} from "./sprite-sheet";

describe("sprite sheet contract", () => {
  it("is a fixed 9×8 grid", () => {
    expect(SHEET_ROWS).toBe(9);
    expect(SHEET_COLS).toBe(8);
  });

  it("accepts only an integer row in range", () => {
    expect(clampSheetRow(0)).toBe(0);
    expect(clampSheetRow(8)).toBe(8);
    expect(clampSheetRow(9)).toBeNull();
    expect(clampSheetRow(-1)).toBeNull();
    expect(clampSheetRow(1.5)).toBeNull();
    expect(clampSheetRow("1")).toBeNull();
  });
});

/** An 8×9-frame sheet, one pixel per frame, with `drawn[row]` frames inked. */
function sheet(drawn: number[]): Uint8ClampedArray {
  const pixels = new Uint8ClampedArray(SHEET_COLS * SHEET_ROWS * 4);
  drawn.forEach((count, row) => {
    for (let col = 0; col < count; col++) {
      const at = (row * SHEET_COLS + col) * 4;
      pixels[at] = 200;
      pixels[at + 1] = 40;
      pixels[at + 2] = 90;
      pixels[at + 3] = 255;
    }
  });
  return pixels;
}

describe("sheetFrameCounts", () => {
  it("counts each row's drawn frames, ignoring the padding", () => {
    const drawn = [8, 6, 4, 3, 2, 8, 1, 5, 7];
    expect(sheetFrameCounts(sheet(drawn), SHEET_COLS, SHEET_ROWS)).toEqual(drawn);
  });

  it("runs to the last drawn frame, so a gap inside a row does not cut it", () => {
    const pixels = sheet([2, 0, 0, 0, 0, 0, 0, 0, 0]);
    const fifth = (0 * SHEET_COLS + 4) * 4;
    pixels[fifth + 1] = 180;
    pixels[fifth + 3] = 255;
    expect(sheetFrameCounts(pixels, SHEET_COLS, SHEET_ROWS)[0]).toBe(5);
  });

  it("holds an empty row on one frame rather than zero", () => {
    expect(sheetFrameCounts(sheet(Array(SHEET_ROWS).fill(0)), SHEET_COLS, SHEET_ROWS)).toEqual(
      Array(SHEET_ROWS).fill(1),
    );
  });

  it("reads transparent and plain-black cells alike as padding", () => {
    const pixels = sheet([3, 0, 0, 0, 0, 0, 0, 0, 0]);
    // Opaque black in the fourth cell is padding, not a frame.
    pixels[3 * 4 + 3] = 255;
    expect(sheetFrameCounts(pixels, SHEET_COLS, SHEET_ROWS)[0]).toBe(3);
  });

  it("falls back to full rows when the image is too small to hold the grid", () => {
    expect(sheetFrameCounts(new Uint8ClampedArray(4), 1, 1)).toEqual(
      Array(SHEET_ROWS).fill(SHEET_COLS),
    );
  });
});

describe("sheetFrameSize", () => {
  it("reads the frame out of a real sheet's pixels", () => {
    expect(sheetFrameSize(1536, 1872)).toEqual({ width: 192, height: 208 });
  });

  it("is not a sheet when the grid does not divide, or the cells are photo-shaped", () => {
    expect(sheetFrameSize(1200, 800)).toBeNull();
    expect(sheetFrameSize(1440, 1080)).toBeNull(); // divides, but 180x120 cells
    expect(sheetFrameSize(0, 0)).toBeNull();
  });
});

describe("sheetDownscale", () => {
  it("shrinks an oversized sheet to the frame cap, staying on the grid", () => {
    const target = sheetDownscale(1536, 1872)!;
    expect(target.width % SHEET_COLS).toBe(0);
    expect(target.height % SHEET_ROWS).toBe(0);
    expect(Math.max(target.width / SHEET_COLS, target.height / SHEET_ROWS)).toBe(SHEET_MAX_FRAME);
    // Still a sheet to whoever reads the stored pixels next.
    expect(sheetFrameSize(target.width, target.height)).not.toBeNull();
  });

  it("leaves a sheet that already fits, and anything that is not one", () => {
    expect(sheetDownscale(8 * 64, 9 * 64)).toBeNull();
    expect(sheetDownscale(8 * SHEET_MAX_FRAME, 9 * SHEET_MAX_FRAME)).toBeNull();
    expect(sheetDownscale(1200, 800)).toBeNull();
  });
});
