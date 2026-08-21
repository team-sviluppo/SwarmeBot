import { describe, expect, it } from "vitest";
import { clampSheetRow, SHEET_COLS, SHEET_ROWS } from "./sprite-sheet";

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
