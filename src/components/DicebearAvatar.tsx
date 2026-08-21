// A bot wearing a DiceBear picture instead of the animated mascot. The SVG is
// generated locally (see @/lib/dicebear) and the collection loads on demand,
// so the first paint after a cold start can be a placeholder.
import { useEffect, useId, useMemo, useState } from "react";
import {
  dicebearReady,
  dicebearSvg,
  loadDicebear,
  namespaceSvgIds,
  onDicebearLoad,
} from "@/lib/dicebear";
import { cn } from "@/lib/cn";

/** The SVG for a stored avatar, re-rendering once the collection has loaded. */
export function useDicebearSvg(value: string | null | undefined, fallbackSeed?: string): string | null {
  const [, redraw] = useState(0);
  useEffect(() => {
    if (!value || dicebearReady()) return;
    const stop = onDicebearLoad(() => redraw((n) => n + 1));
    void loadDicebear();
    return stop;
  }, [value]);
  return dicebearSvg(value, fallbackSeed);
}

/**
 * True once the collection is loaded — for UI that reads style metadata
 * (titles, licenses) rather than rendering one avatar.
 */
export function useDicebearReady(): boolean {
  const [ready, setReady] = useState(dicebearReady);
  useEffect(() => {
    if (dicebearReady()) {
      setReady(true);
      return;
    }
    const stop = onDicebearLoad(() => setReady(true));
    void loadDicebear();
    return stop;
  }, []);
  return ready;
}

export function DicebearAvatar({
  avatar,
  svg: stored,
  seed,
  size = 44,
  label,
  className,
}: {
  /** The stored DiceBear URL (or style name). */
  avatar?: string | null;
  /**
   * Markup imported for a style this build cannot draw itself. When present
   * it is the picture, and the collection is never loaded for this avatar.
   */
  svg?: string | null;
  /** Seed to use when the stored URL carries none — the bot's name. */
  seed?: string;
  size?: number;
  label?: string | null;
  className?: string;
}) {
  const generated = useDicebearSvg(stored ? null : avatar, seed);
  const svg = stored ?? generated;
  // One prefix per mounted avatar, so the ids in the markup cannot be
  // captured by another avatar's. Fragment references only allow a subset of
  // characters, and React's ids carry colons.
  const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
  const painted = useMemo(() => (svg ? namespaceSvgIds(svg, `db${uid}`) : null), [svg, uid]);
  return (
    <span
      className={cn(
        "inline-flex shrink-0 overflow-hidden rounded-full [&>svg]:size-full",
        !painted && "bg-raised",
        className,
      )}
      style={{ width: size, height: size }}
      role={label ? "img" : undefined}
      aria-label={label ?? undefined}
      aria-hidden={label ? undefined : true}
      // SAFETY: the markup is produced by @dicebear/collection in this
      // process from a style id we resolved ourselves — never from the
      // stored string, which only ever contributes a style name and options.
      dangerouslySetInnerHTML={painted ? { __html: painted } : undefined}
    />
  );
}
