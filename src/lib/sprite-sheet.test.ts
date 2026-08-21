import { describe, expect, it } from "vitest";
import { clampSheetRow, sheetFrameCounts, SHEET_COLS, SHEET_ROWS } from "./sprite-sheet";

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
