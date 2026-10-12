// A bot wearing an uploaded SVG instead of the animated mascot. The markup was
// validated against an allowlist when it was uploaded (server/avatar-svg.ts).
import { useId, useMemo } from "react";
import { cn } from "@/lib/cn";

/**
 * Rewrites an SVG's internal ids so one document can hold many avatars.
 *
 * Exported SVGs routinely reuse the same ids (`mask0`, `clip0`, `gradient`).
 * Duplicate ids in a document all resolve to the first one, so the first
 * avatar on the page would mask, clip or paint every other one with its own
 * definitions. Namespacing per instance is what makes a page of avatars work.
 */
export function namespaceSvgIds(svg: string, prefix: string): string {
  return svg
    .replace(/(?<![\w:-])id="([^"]+)"/g, (_, id: string) => `id="${prefix}-${id}"`)
    .replace(/url\(#([^)"']+)\)/g, (_, id: string) => `url(#${prefix}-${id})`)
    .replace(
      /(?<![\w-])(xlink:href|href)="#([^"]+)"/g,
      (_, attr: string, id: string) => `${attr}="#${prefix}-${id}"`,
    );
}

export function SvgAvatar({
  svg,
  size = 44,
  label,
  className,
}: {
  /** The stored markup. */
  svg: string;
  size?: number;
  label?: string | null;
  className?: string;
}) {
  // One prefix per mounted avatar, so the ids in the markup cannot be
  // captured by another avatar's. Fragment references only allow a subset of
  // characters, and React's ids carry colons.
  const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
  const painted = useMemo(() => namespaceSvgIds(svg, `sv${uid}`), [svg, uid]);
  return (
    <span
      className={cn("inline-flex shrink-0 overflow-hidden rounded-full [&>svg]:size-full", className)}
      style={{ width: size, height: size }}
      role={label ? "img" : undefined}
      aria-label={label ?? undefined}
      aria-hidden={label ? undefined : true}
      // SAFETY: the markup passed the server's SVG allowlist at upload — no
      // scripts, handlers or references outside the document.
      dangerouslySetInnerHTML={{ __html: painted }}
    />
  );
}
