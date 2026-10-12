/**
 * Validating an SVG a user uploads as a bot's picture.
 *
 * The markup is stored with the bot and painted inline, so it is *validated,
 * not cleaned*: markup that carries anything we would not put in a page is
 * refused outright rather than patched up, because a sanitizer that silently
 * rewrites someone else's markup is the kind of thing that is wrong in a way
 * nobody notices.
 */

/**
 * How much markup one avatar may be. Kept small on purpose: the picture rides
 * along in every bot frame the server broadcasts, and it has to fit inside a
 * shared team file.
 */
export const MAX_AVATAR_SVG_BYTES = 64_000;

/**
 * Markup we refuse to store. Scripting, anything that would reach back out to
 * the network, and any reference that is not a same-document fragment.
 */
const FORBIDDEN: Array<{ pattern: RegExp; what: string }> = [
  { pattern: /<\s*(script|foreignObject|iframe|object|embed|audio|video|link|meta|handler)\b/i, what: "an element we do not allow" },
  { pattern: /\son[a-z]+\s*=/i, what: "an event handler" },
  { pattern: /(javascript|vbscript)\s*:/i, what: "a script URL" },
  { pattern: /<!ENTITY|<!DOCTYPE/i, what: "a document definition" },
  { pattern: /(?:xlink:)?href\s*=\s*["'](?!#)/i, what: "a reference outside the document" },
  { pattern: /\bsrc\s*=/i, what: "an external source" },
  { pattern: /url\(\s*["']?(?!#)/i, what: "a reference outside the document" },
  { pattern: /@import/i, what: "a stylesheet import" },
];

export type SvgVerdict = { ok: true; svg: string } | { ok: false; error: string };

/** Accepts a plain, self-contained SVG document and nothing else. */
export function validateAvatarSvg(input: string): SvgVerdict {
  const svg = input.trim();
  if (!svg) return { ok: false, error: "That image is empty" };
  if (svg.length > MAX_AVATAR_SVG_BYTES) return { ok: false, error: "That image is too large to store" };
  // An XML declaration is fine; anything else before the root is not.
  const body = svg.replace(/^<\?xml[^>]*\?>\s*/i, "");
  if (!body.startsWith("<svg")) return { ok: false, error: "That is not an SVG image" };
  if (!/<\/svg>\s*$/i.test(body)) return { ok: false, error: "That SVG image is incomplete" };
  for (const { pattern, what } of FORBIDDEN) {
    if (pattern.test(body)) return { ok: false, error: `That SVG image carries ${what}` };
  }
  return { ok: true, svg: body };
}
