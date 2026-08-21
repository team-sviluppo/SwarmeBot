/**
 * Importing a DiceBear style this build cannot draw itself.
 *
 * The client bundles `@dicebear/collection` and renders those styles locally,
 * so nothing here runs for them. DiceBear 10 added styles that were never
 * published as packages (`disco` among them) and exist only on the hosted API:
 * for those we fetch the SVG once, at import, and store it with the bot. After
 * that the avatar is local markup again — it survives going offline, and no
 * request repeats on later renders.
 *
 * Two boundaries matter here. The URL is rebuilt from its parts against a
 * fixed host, so a pasted string can never aim this fetch anywhere else. And
 * the response is *validated, not cleaned*: markup that carries anything we
 * would not put in a page is refused outright rather than patched up, because
 * a sanitizer that silently rewrites third-party markup is the kind of thing
 * that is wrong in a way nobody notices.
 */

/** The only host this module will fetch from. */
const DICEBEAR_HOST = "api.dicebear.com";

/** Hosts a user may paste; all of them resolve to the API host above. */
const PASTEABLE_HOSTS = new Set([DICEBEAR_HOST, "dicebear.com", "www.dicebear.com"]);

const DEFAULT_VERSION = "9.x";

/**
 * How much markup one avatar may be. Kept small on purpose: the picture rides
 * along in every bot frame the server broadcasts, and it has to fit inside a
 * shared team file. Real styles land between 5 and 25KB.
 */
export const MAX_AVATAR_SVG_BYTES = 64_000;
const FETCH_TIMEOUT_MS = 8_000;

/** Query keys we forward. Anything else is dropped rather than guessed at. */
const FORWARDED = new Set([
  "seed",
  "flip",
  "rotate",
  "scale",
  "radius",
  "translateX",
  "translateY",
  "clip",
  "backgroundColor",
  "backgroundType",
  "backgroundRotation",
]);

export interface DicebearRequest {
  /** Canonical URL, rebuilt against the API host — what we fetch and store. */
  url: string;
  style: string;
}

/**
 * Rebuilds a pasted DiceBear URL from its recognised parts, or returns null.
 * Everything the caller hands us is treated as a suggestion: the host, the
 * path shape and the forwarded query keys are all ours.
 */
export function canonicalDicebearRequest(input: string): DicebearRequest | null {
  const raw = input.trim();
  if (!raw || raw.length > 2_000) return null;

  let url: URL;
  try {
    url = new URL(raw, `https://${DICEBEAR_HOST}`);
  } catch {
    return null;
  }
  // The host is checked after resolution, not by looking for "://" in the
  // input: "//evil.com/10.x/disco/svg" carries no scheme and would otherwise
  // resolve to a host of the paster's choosing. A bare path or style name
  // resolves against the API host and passes this on its own.
  if (!PASTEABLE_HOSTS.has(url.hostname)) return null;

  const segments = url.pathname.split("/").filter(Boolean);
  const versionAt = segments.findIndex((segment) => /^\d+\.x$/.test(segment));
  const stylesAt = segments.indexOf("styles");
  const style =
    versionAt >= 0 ? segments[versionAt + 1] : stylesAt >= 0 ? segments[stylesAt + 1] : segments[0];
  if (!style || !/^[a-z0-9-]{1,40}$/.test(style)) return null;
  const version = versionAt >= 0 ? segments[versionAt]! : DEFAULT_VERSION;

  const params = new URLSearchParams(url.search);
  // The playground keeps its options in the hash; the API takes them as query.
  if (url.hash.length > 1) {
    for (const [key, value] of new URLSearchParams(url.hash.slice(1))) {
      if (!params.has(key)) params.append(key, value);
    }
  }
  const forwarded = new URLSearchParams();
  for (const [key, value] of params) {
    if (FORWARDED.has(key) && value.length <= 200) forwarded.append(key, value);
  }
  forwarded.sort();
  const query = forwarded.toString();
  return {
    style,
    url: `https://${DICEBEAR_HOST}/${version}/${style}/svg${query ? `?${query}` : ""}`,
  };
}

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
  if (!svg) return { ok: false, error: "The style returned an empty image" };
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

export type DicebearFetch =
  | { ok: true; url: string; style: string; svg: string }
  | { ok: false; status: number; error: string };

/** Fetches one avatar from the API host, bounded in time and in size. */
export async function fetchDicebearAvatar(input: string): Promise<DicebearFetch> {
  const request = canonicalDicebearRequest(input);
  if (!request) return { ok: false, status: 400, error: "That is not a DiceBear avatar URL" };

  let response: Response;
  try {
    response = await fetch(request.url, {
      headers: { accept: "image/svg+xml" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch {
    return { ok: false, status: 502, error: "Could not reach dicebear.com" };
  }
  if (response.status === 404) {
    return { ok: false, status: 404, error: `dicebear.com has no ${request.style} style` };
  }
  if (!response.ok) {
    return { ok: false, status: 502, error: `dicebear.com answered ${response.status}` };
  }
  const type = response.headers.get("content-type") ?? "";
  if (!type.includes("svg")) return { ok: false, status: 502, error: "dicebear.com did not return an SVG" };

  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > MAX_AVATAR_SVG_BYTES) return { ok: false, status: 502, error: "That image is too large to store" };
  const text = await response.text();

  const verdict = validateAvatarSvg(text);
  if (!verdict.ok) return { ok: false, status: 502, error: verdict.error };
  return { ok: true, url: request.url, style: request.style, svg: verdict.svg };
}
