import { useEffect, useState, type CSSProperties } from "react";
import {
  SHEET_COLS,
  SHEET_FRAME_MS,
  SHEET_ROWS,
  clampSheetRow,
  loadSheetFrameCounts,
} from "@/lib/sprite-sheet";

/**
 * How many frames this row of this sheet draws. Sheets are padded out to 8
 * cells per row, so a short row would otherwise spend part of its loop on
 * blank cells; measuring the image says where it really ends. Until the
 * measurement lands the full row plays, which is what it looked like before.
 */
function useRowFrames(src: string, row: number): number {
  const [counts, setCounts] = useState<number[] | null>(null);
  useEffect(() => {
    let live = true;
    setCounts(null);
    void loadSheetFrameCounts(src).then((measured) => {
      if (live) setCounts(measured);
    });
    return () => {
      live = false;
    };
  }, [src]);
  return counts?.[row] ?? SHEET_COLS;
}

export function SpriteSheetAvatar({
  src,
  row,
  size,
  label,
  animated = true,
}: {
  src: string;
  row: number;
  size: number;
  label?: string;
  animated?: boolean;
}) {
  const sheetRow = clampSheetRow(row) ?? 0;
  const frames = useRowFrames(src, sheetRow);
  return (
    <span
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      className="ogb-sprite-sheet inline-block shrink-0 overflow-hidden rounded-full bg-black"
      style={
        {
          width: size,
          height: size,
          "--sheet-size": `${size}px`,
          "--sheet-frames": frames,
          backgroundImage: `url(${src})`,
          backgroundRepeat: "no-repeat",
          backgroundSize: `calc(${SHEET_COLS} * var(--sheet-size)) calc(${SHEET_ROWS} * var(--sheet-size))`,
          backgroundPosition: `0 calc(-1 * var(--sheet-size) * ${sheetRow})`,
          // A single-frame row is a still picture, not a one-step loop.
          animation:
            animated && frames > 1
              ? `ogb-sprite-sheet ${frames * SHEET_FRAME_MS}ms steps(${frames}) infinite`
              : "none",
        } as CSSProperties
      }
    />
  );
}
