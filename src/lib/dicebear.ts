/**
 * Picture avatars from DiceBear (https://www.dicebear.com).
 *
 * A bot's picture is stored as the DiceBear URL it came from — nothing else.
 * That one string is the whole appearance: style, seed and every option the
 * user chose on dicebear.com survive a copy-paste, an export to a team file
 * and an import on someone else's machine.
 *
 * The URL is never fetched. `@dicebear/collection` is bundled, so the SVG is
 * generated locally from the same code the site runs — offline, deterministic,
 * and with no seed leaving the machine. Nothing renders markup we did not
 * generate ourselves.
 *
 * The collection is ~5MB of style data, so it is imported dynamically: a
 * workspace with no picture avatars never loads it.
 */
import type { Options, Result, StyleMeta, StyleSchema } from "@dicebear/core";

/** Every style `@dicebear/collection` ships, in the collection's own order. */
export const DICEBEAR_STYLE_IDS = [
  "adventurer",
  "adventurerNeutral",
  "avataaars",
  "avataaarsNeutral",
  "bigEars",
  "bigEarsNeutral",
  "bigSmile",
  "bottts",
  "botttsNeutral",
  "croodles",
  "croodlesNeutral",
  "dylan",
  "funEmoji",
  "glass",
  "icons",
  "identicon",
  "initials",
  "lorelei",
  "loreleiNeutral",
  "micah",
  "miniavs",
  "notionists",
  "notionistsNeutral",
  "openPeeps",
  "personas",
  "pixelArt",
  "pixelArtNeutral",
  "rings",
  "shapes",
  "thumbs",
  "toonHead",
] as const;

export type DicebearStyleId = (typeof DICEBEAR_STYLE_IDS)[number];

/**
 * The collection is typed by import, so a name here that the package does not
 * export fails to compile rather than failing to render.
 */
type Collection = typeof import("@dicebear/collection");
type CollectionStyle = Collection[DicebearStyleId];

/** Every shape a DiceBear option takes once it has been read off a URL. */
export type DicebearOptionValue = string | number | boolean | string[] | number[];
export type DicebearOptions = Record<string, DicebearOptionValue>;

/** What this module needs of `createAvatar`, for a style chosen at runtime. */
type RenderAvatar = (style: CollectionStyle, options: DicebearOptions) => Result;

const STYLE_IDS = new Set<string>(DICEBEAR_STYLE_IDS);

/** The version segment DiceBear's own URLs carry; only used when writing one. */
const API_VERSION = "9.x";

const kebab = (id: string) => id.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
const camel = (slug: string) => slug.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());

const BY_SLUG = new Map(DICEBEAR_STYLE_IDS.map((id) => [kebab(id), id]));

export function styleSlug(id: DicebearStyleId): string {
  return kebab(id);
}

export function isDicebearStyle(value: string): value is DicebearStyleId {
  return STYLE_IDS.has(value);
}

/** How a value read off a URL should be typed before DiceBear sees it. */
type OptionKind = "boolean" | "number" | "string" | "string[]" | "number[]";

/** One entry of a style's JSON schema, as the schema type itself declares it. */
type SchemaProperty = NonNullable<StyleSchema["properties"]>[string];

/**
 * Core options every style accepts. Style-specific options are typed by the
 * style's own JSON schema; these are not in it, so they are listed here.
 */
const CORE_OPTION_KINDS = {
  flip: "boolean",
  rotate: "number",
  scale: "number",
  radius: "number",
  size: "number",
  translateX: "number",
  translateY: "number",
  clip: "boolean",
  randomizeIds: "boolean",
  backgroundColor: "string[]",
  backgroundType: "string[]",
  backgroundRotation: "number[]",
} satisfies Record<Exclude<keyof Options, "seed">, OptionKind>;

const CORE_KIND_BY_KEY = new Map<string, OptionKind>(Object.entries(CORE_OPTION_KINDS));

/** Query keys that describe the transport rather than the avatar. */
const TRANSPORT_KEYS = new Set(["format", "size", "seed"]);

interface Loaded {
  render: RenderAvatar;
  collection: Collection;
}

let loaded: Loaded | null = null;
let loading: Promise<Loaded> | null = null;
const listeners = new Set<() => void>();

/**
 * Rendered SVG by request. Bounded: a long session that scrolls a big
 * workspace must not grow a cache forever, and re-rendering is cheap.
 */
const RENDER_CACHE_MAX = 240;
const renders = new Map<string, string>();

function remember(key: string, svg: string): string {
  if (renders.size >= RENDER_CACHE_MAX) {
    const oldest = renders.keys().next();
    if (!oldest.done) renders.delete(oldest.value);
  }
  renders.set(key, svg);
  return svg;
}

/** Loads the collection once. Callers re-render through `onDicebearLoad`. */
export function loadDicebear(): Promise<void> {
  loading ??= Promise.all([import("@dicebear/core"), import("@dicebear/collection")]).then(
    ([core, collection]) => {
      // SAFETY: createAvatar is generic over one style's own option type, which
      // cannot be named for a style picked at runtime. The options still reach
      // DiceBear's own schema validation, and `dicebearSvg` falls back to the
      // seed alone when it rejects them.
      loaded = { render: core.createAvatar as RenderAvatar, collection };
      for (const listener of listeners) listener();
      return loaded;
    },
  );
  return loading.then(() => undefined);
}

export function onDicebearLoad(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function dicebearReady(): boolean {
  return loaded !== null;
}

/** What a stored avatar string resolves to. */
export interface DicebearAvatarSpec {
  style: DicebearStyleId;
  /** Absent means the style's own default seed behaviour. */
  seed: string | null;
  /** The option query the URL carried, normalized and without seed/format/size. */
  options: string;
}

/**
 * Reads a stored value — a full DiceBear URL, a style slug or a bare style
 * name. Returns null for anything we cannot render, which is how junk and
 * styles from a newer collection fall back to the mascot.
 */
export function parseDicebearAvatar(value: string | null | undefined): DicebearAvatarSpec | null {
  if (!value) return null;
  const raw = value.trim();
  if (!raw) return null;

  // A bare style id or slug: "bottts", "pixel-art".
  const bare = BY_SLUG.get(raw) ?? (isDicebearStyle(raw) ? raw : null);
  if (bare) return { style: bare, seed: null, options: "" };

  let url: URL;
  try {
    url = new URL(raw, "https://api.dicebear.com");
  } catch {
    return null;
  }

  // api.dicebear.com/9.x/<style>/svg, and the site's own /styles/<style>.
  const segments = url.pathname.split("/").filter(Boolean);
  const slug = segments.find((segment) => BY_SLUG.has(segment) || isDicebearStyle(camel(segment)));
  if (!slug) return null;
  const style = BY_SLUG.get(slug) ?? camel(slug);
  if (!isDicebearStyle(style)) return null;

  // dicebear.com keeps the playground's options in the hash, the API in the query.
  const params = new URLSearchParams(url.search);
  if (url.hash.length > 1) {
    for (const [key, item] of new URLSearchParams(url.hash.slice(1))) {
      if (!params.has(key)) params.append(key, item);
    }
  }

  const seed = params.get("seed");
  const options = new URLSearchParams();
  for (const [key, item] of params) {
    if (TRANSPORT_KEYS.has(key)) continue;
    options.append(key, item);
  }
  options.sort();
  return { style, seed: seed?.trim() || null, options: options.toString() };
}

/** Hosts whose URLs we recognise as DiceBear's, even for styles we lack. */
const DICEBEAR_HOSTS = new Set(["api.dicebear.com", "dicebear.com", "www.dicebear.com"]);

/**
 * The style segment of a DiceBear URL, whether or not we can render it:
 * `/10.x/disco/svg` and `/styles/disco` both name `disco`.
 */
function urlStyleSlug(url: URL): string | null {
  const segments = url.pathname.split("/").filter(Boolean);
  const version = segments.findIndex((segment) => /^\d+\.x$/.test(segment));
  if (version >= 0 && segments[version + 1]) return segments[version + 1];
  const styles = segments.indexOf("styles");
  if (styles >= 0 && segments[styles + 1]) return segments[styles + 1];
  return segments.find((segment) => BY_SLUG.has(segment)) ?? null;
}

/** The style a DiceBear URL names, bundled here or not. */
export function dicebearStyleSlug(value: string | null | undefined): string | null {
  if (!value) return null;
  try {
    return urlStyleSlug(new URL(value.trim(), "https://api.dicebear.com"));
  } catch {
    return null;
  }
}

/**
 * What a pasted URL turned out to be. A DiceBear URL naming a style this
 * build cannot render is a different answer from a URL that is not DiceBear's
 * at all — the styles are bundled, and the hosted API carries styles (all of
 * DiceBear 10's) that were never published as packages.
 */
export type DicebearImport =
  | { ok: true; spec: DicebearAvatarSpec }
  | { ok: false; reason: "not-dicebear" }
  | { ok: false; reason: "style-unavailable"; style: string };

export function importDicebearAvatar(input: string): DicebearImport {
  const spec = parseDicebearAvatar(input);
  if (spec) return { ok: true, spec };

  const raw = input.trim();
  let url: URL | null = null;
  try {
    url = new URL(raw, "https://api.dicebear.com");
  } catch {
    url = null;
  }
  const slug = url && (DICEBEAR_HOSTS.has(url.hostname) || !raw.includes("://")) ? urlStyleSlug(url) : null;
  if (slug) return { ok: false, reason: "style-unavailable", style: slug };
  return { ok: false, reason: "not-dicebear" };
}

/**
 * Whether a stored picture can actually be drawn: either it came with its own
 * markup, or its style is one we bundle. A URL naming a style we lack and
 * carrying no markup — a team file imported on a build without it — is not a
 * picture, and the bot wears its mascot instead of an empty hole.
 */
export function wearsDicebearPicture(look: {
  mascotAvatar?: string | null;
  mascotAvatarSvg?: string | null;
}): boolean {
  return Boolean(look.mascotAvatarSvg) || parseDicebearAvatar(look.mascotAvatar) !== null;
}

/** The canonical URL for a spec — what we store, and what a user can paste back. */
export function dicebearUrl(style: DicebearStyleId, seed: string | null, options = ""): string {
  const params = new URLSearchParams(options);
  if (seed) params.set("seed", seed);
  params.sort();
  const query = params.toString();
  return `https://api.dicebear.com/${API_VERSION}/${styleSlug(style)}/svg${query ? `?${query}` : ""}`;
}

/** A style option's declared type, for the ones the style's schema describes. */
function schemaKind(property: SchemaProperty | undefined): OptionKind | null {
  // `true` is a valid JSON Schema meaning "anything"; it declares no type.
  if (!property || property === true) return null;
  const declared = Array.isArray(property.type) ? property.type[0] : property.type;
  if (declared === "array") return "string[]";
  if (declared === "boolean") return "boolean";
  if (declared === "integer" || declared === "number") return "number";
  if (declared === "string") return "string";
  return null;
}

function optionKind(key: string, schema: StyleSchema | undefined): OptionKind {
  const fromSchema = schemaKind(schema?.properties?.[key]);
  if (fromSchema) return fromSchema;
  return CORE_KIND_BY_KEY.get(key) ?? "string";
}

function optionValue(kind: OptionKind, values: string[]): DicebearOptionValue {
  if (kind === "string[]" || kind === "number[]") {
    const items = values.flatMap((item) => item.split(",")).filter(Boolean);
    return kind === "number[]" ? items.map(Number) : items;
  }
  const first = values[0] ?? "";
  if (kind === "boolean") return first === "true" || first === "1";
  if (kind === "number") return Number(first);
  return first;
}

function styleOptions(spec: DicebearAvatarSpec, schema: StyleSchema | undefined) {
  const grouped = new Map<string, string[]>();
  for (const [key, item] of new URLSearchParams(spec.options)) {
    grouped.set(key, [...(grouped.get(key) ?? []), item]);
  }
  const options: DicebearOptions = {};
  for (const [key, values] of grouped) options[key] = optionValue(optionKind(key, schema), values);
  if (spec.seed) options.seed = spec.seed;
  return options;
}

/**
 * The SVG for a stored avatar, or null while the collection is still loading.
 * A style whose options do not survive the trip renders on its seed alone
 * rather than failing: a plainer avatar beats an empty one.
 */
export function dicebearSvg(value: string | null | undefined, fallbackSeed?: string): string | null {
  const spec = parseDicebearAvatar(value);
  if (!spec) return null;
  const seed = spec.seed ?? fallbackSeed?.trim() ?? null;

  const key = `${spec.style}|${seed ?? ""}|${spec.options}`;
  const cached = renders.get(key);
  if (cached !== undefined) return cached;

  const ready = loaded;
  if (!ready) {
    void loadDicebear();
    return null;
  }
  const style = ready.collection[spec.style];
  const withSeed: DicebearAvatarSpec = { ...spec, seed };
  try {
    return remember(key, ready.render(style, styleOptions(withSeed, style.schema)).toString());
  } catch {
    try {
      return remember(key, ready.render(style, seed ? { seed } : {}).toString());
    } catch {
      return null;
    }
  }
}

/**
 * Rewrites an SVG's internal ids so one document can hold many avatars.
 *
 * Every DiceBear SVG declares the same ids — `viewboxMask` above all, whose
 * rect is sized in that style's own viewBox units (180 for bottts, 16 for
 * pixelArt, 5 for identicon). Duplicate ids in a document all resolve to the
 * first one, so a single pixelArt avatar rendered first masks every other
 * avatar on the page down to a 16-unit corner: they come out cropped or
 * blank. Namespacing per instance is what makes a page of avatars work.
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

/** Title, creator and license of a style — attribution for the picker. */
export function dicebearMeta(style: DicebearStyleId): StyleMeta | null {
  return loaded?.collection[style]?.meta ?? null;
}

/** A fresh seed for the randomize button. */
export function randomSeed(): string {
  return Math.random().toString(36).slice(2, 10);
}
