/** Uploaded bot pictures that are sprite sheets are always this grid. */
export const SHEET_ROWS = 9;
export const SHEET_COLS = 8;
export const SHEET_FRAME_MS = 100;

export function clampSheetRow(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isInteger(value)) return null;
  if (value < 0 || value >= SHEET_ROWS) return null;
  return value;
}
