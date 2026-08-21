import type { CSSProperties } from "react";
import { SHEET_COLS, SHEET_FRAME_MS, SHEET_ROWS, clampSheetRow } from "@/lib/sprite-sheet";

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
          backgroundImage: `url(${src})`,
          backgroundRepeat: "no-repeat",
          backgroundSize: `calc(${SHEET_COLS} * var(--sheet-size)) calc(${SHEET_ROWS} * var(--sheet-size))`,
          backgroundPosition: `0 calc(-1 * var(--sheet-size) * ${sheetRow})`,
          animation: animated
            ? `ogb-sprite-sheet ${SHEET_COLS * SHEET_FRAME_MS}ms steps(${SHEET_COLS}) infinite`
            : "none",
        } as CSSProperties
      }
    />
  );
}
