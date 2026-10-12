import {
  CURSOR_STATES,
  DEFAULT_SILHOUETTE,
  type CursorSilhouette,
  type CursorState,
} from "@/components/CursorAvatar";

/** The mascot's behaviour vocabulary — CursorAvatar's 39 states, under the
 * app's historical names. */
export type MausState = CursorState;
export const MAUS_STATES = CURSOR_STATES;

/** CursorAvatar ships French group labels; the app shows these instead. The
 * memberships mirror its STATE_GROUPS exactly. */
export const STATE_GROUPS = {
  Lifecycle: ["sleeping", "waking", "idle", "listening", "thinking", "searching", "working"],
  Reactions: [
    "excited",
    "surprised",
    "suspicious",
    "angry",
    "drowsy",
    "happy",
    "curious",
    "confused",
    "bored",
    "proud",
    "shy",
    "sad",
    "laughing",
    "scared",
    "playful",
    "celebrate",
  ],
  "Agent morphs": ["orbit", "radar", "progress"],
  "Product cycle": [
    "spawning",
    "humming",
    "loading",
    "dictating",
    "writing",
    "sending",
    "receiving",
    "uploading",
    "notifying",
    "alerting",
    "dragging",
    "bouncing",
    "powering-down",
  ],
} satisfies Record<string, MausState[]>;

export const MAUS_COLOR_NAMES = [
  "white",
  "green",
  "blue",
  "red",
  "orange",
  "purple",
  "cyan",
  "pink",
  "yellow",
  "teal",
  "coral",
] as const;

export type MausColor = (typeof MAUS_COLOR_NAMES)[number];

export const MAUS_COLORS = {
  // Not #ffffff: the mascot is drawn on light cards too, and a pure-white body
  // would lose its edge against them. This is white enough to read as white
  // and still has a silhouette.
  white: "#F1F1F3",
  green: "#009957",
  blue: "#377FE6",
  red: "#D94B52",
  orange: "#E78531",
  purple: "#8057C8",
  cyan: "#0EA5C6",
  pink: "#D84F8B",
  yellow: "#D8A729",
  teal: "#01A492",
  coral: "#E5634E",
} satisfies Record<MausColor, string>;

/** Perceived lightness of a hex colour, 0..1 (Rec. 709 luma). */
function luma(hex: string): number {
  const n = Number.parseInt(hex.slice(1), 16);
  return (0.2126 * ((n >> 16) & 0xff) + 0.7152 * ((n >> 8) & 0xff) + 0.0722 * (n & 0xff)) / 255;
}

/**
 * The eyes and mouth are painted in one flat colour on top of the body, so a
 * light body needs dark ink: white-on-white is a blob with no face at all.
 * Derived from the body colour rather than listed per colour, so a light
 * colour added later cannot forget to do this.
 */
export function eyeInkFor(color: MausColor): string {
  return luma(MAUS_COLORS[color] ?? MAUS_COLORS.green) > 0.72 ? "#2A2A30" : "#ffffff";
}

export const MAUS_MOTIONS = [
  "arrive",
  "switch",
  "customize",
  "alert",
  "thinking",
  "working",
  "launch",
  "success",
  "celebrate",
  "blink",
  "surprise",
  "failure",
] as const;

export type MausMotion = "none" | (typeof MAUS_MOTIONS)[number];

/**
 * The face used to be ten hand-drawn SVGs; it is now the engine's 39 states.
 * Bots saved under the old vocabulary still carry one of these ten names, so
 * they are translated on read rather than migrated in place — a bot's stored
 * face should survive a downgrade too.
 */
interface LegacyStates {
  [state: string]: MausState;
}

const LEGACY_STATES: LegacyStates = {
  deadpan: "idle",
  friendly: "happy",
  focused: "working",
  thinking: "thinking",
  excited: "excited",
  sleepy: "drowsy",
  surprised: "surprised",
  skeptical: "suspicious",
  worried: "scared",
  mischievous: "playful",
};

const KNOWN_STATES = new Set<string>(MAUS_STATES);

/** Resolves any stored value — current, legacy or junk — to a real state. */
export function normalizeState(value: string | null | undefined): MausState | null {
  if (!value) return null;
  if (KNOWN_STATES.has(value)) return value as MausState;
  return LEGACY_STATES[value] ?? null;
}

/**
 * The states worth offering in the appearance picker.
 *
 * The engine carries 39, but many are transient beats the app drives itself
 * (`sending`, `alerting`, `powering-down`) and make no sense as a bot's resting
 * face. More importantly, states share resting faces: `happy`, `excited` and
 * `playful` all rest on expression 2, and `curious`, `surprised` and `scared`
 * all rest on 3 — they differ in which faces they *drift* to, which a static
 * swatch cannot show. Offering them all gave 15 buttons showing 8 pictures.
 *
 * Across all 39 states there are only 11 distinct resting faces, so this is one
 * state per face, chosen for the clearest name. Every swatch looks different.
 */
export const PICKABLE_STATES: MausState[] = [
  "idle", // expression 0
  "happy", // 2
  "curious", // 3
  "drowsy", // 4
  "working", // 7
  "thinking", // 8
  "listening", // 10
  "sleeping", // 13
  "suspicious", // 14
  "proud", // 15
];

/**
 * The resting faces a bot with nothing to say about itself can wear.
 *
 * `stateForBot` used to end in `return "idle"`, so every bot whose name and
 * title missed the keyword table below wore expression 0 — which is most of a
 * fresh roster, and is why a sidebar of bots looked like one bot repeated.
 * Picking from this list by identity gives that roster visible variety while
 * keeping each bot's face fixed forever: the same bot must not change face
 * between two launches, or its avatar stops being recognisable.
 *
 * A subset of PICKABLE_STATES, not the whole thing: `sleeping` and `drowsy`
 * read as an engine that failed to start, and `suspicious` reads as a warning.
 * A bot that has told us nothing has nothing to warn about, so the fallback
 * stays inside the faces that mean "here, and fine".
 */
export const RESTING_FACES: MausState[] = [
  "idle",
  "happy",
  "curious",
  "working",
  "thinking",
  "listening",
  "proud",
];

/** FNV-1a. Any stable string hash would do; this one is short and has no
 * clustering on the short, similar strings bot names actually are. */
function hash(value: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < value.length; i++) {
    h ^= value.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/**
 * The face a bot wears when nothing else has claimed it — derived from its
 * identity, so it is varied across the roster and stable for each bot.
 * Prefers the id: a rename should not repaint the face, and two bots that
 * happen to share a name should still differ.
 */
export function restingFaceFor(identity: string): MausState {
  return RESTING_FACES[hash(identity) % RESTING_FACES.length];
}

/* ---------------------------------------------------------------- silhouettes */

/**
 * The body shape a bot wears.
 *
 * The avatar engine is shape-agnostic: it clips, paints and animates whatever
 * silhouette it is handed, so a shape is just a path plus where the face sits
 * inside it. Every shape below is authored directly in the engine's
 * 228.541-unit face box, which is why `fit` is empty — only the packaged
 * cursor keeps the transform its export shipped with.
 *
 * `anchor.scale` is calibrated against the cursor's 0.74: across the 25
 * expressions the eyes reach ~97 units either side of the face centre, and the
 * face is clipped to the silhouette, so a shape narrower than a circle takes a
 * smaller scale rather than letting the eyes ride its edge.
 */
const fromPath = (
  name: string,
  d: string,
  anchor: CursorSilhouette["anchor"],
): CursorSilhouette => ({
  name,
  fit: "",
  body: `<path d="${d}" fill="{{GRADIENT}}"/>`,
  clip: `<path d="${d}"/>`,
  anchor,
});

/** Centre of the face box, which every generated shape is drawn around. */
const BOX_CENTRE = 114.27;

type Point = [number, number];

const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * A closed curve through every point, smooth at each one: a Catmull-Rom
 * spline written out as the cubic Béziers SVG understands.
 */
function smoothClosedPath(points: Point[]): string {
  const at = (i: number) => points[(i + points.length) % points.length]!;
  let d = `M ${round2(points[0]![0])} ${round2(points[0]![1])}`;
  for (let i = 0; i < points.length; i++) {
    const [p0, p1, p2, p3] = [at(i - 1), at(i), at(i + 1), at(i + 2)];
    d += ` C ${round2(p1[0] + (p2[0] - p0[0]) / 6)} ${round2(p1[1] + (p2[1] - p0[1]) / 6)}`;
    d += ` ${round2(p2[0] - (p3[0] - p1[0]) / 6)} ${round2(p2[1] - (p3[1] - p1[1]) / 6)}`;
    d += ` ${round2(p2[0])} ${round2(p2[1])}`;
  }
  return `${d} Z`;
}

/**
 * A shape described by its radius at each angle around the box centre — how
 * the lobed and spiked shapes (cloud, flower, sparkle, burst) are drawn.
 * `sx`/`sy` stretch it before `rotate` (degrees) tilts it.
 */
function polarPath(
  radius: (angle: number) => number,
  { samples = 96, rotate = 0, sx = 1, sy = 1 } = {},
): string {
  const tilt = (rotate * Math.PI) / 180;
  const points = Array.from({ length: samples }, (_, i): Point => {
    const angle = (i / samples) * 2 * Math.PI;
    const r = radius(angle);
    const x = r * Math.cos(angle) * sx;
    const y = r * Math.sin(angle) * sy;
    return [
      BOX_CENTRE + x * Math.cos(tilt) - y * Math.sin(tilt),
      BOX_CENTRE + x * Math.sin(tilt) + y * Math.cos(tilt),
    ];
  });
  return smoothClosedPath(points);
}

/** `count` rounded bumps around the edge, meeting in soft creases. */
const lobes = (count: number, fullness: number) => (angle: number) =>
  Math.abs(Math.cos((count / 2) * angle)) ** fullness;

/** `count` points around the edge; a higher `sharpness` narrows each one. */
const spikes = (count: number, sharpness: number) => (angle: number) =>
  ((1 + Math.cos(count * angle)) / 2) ** sharpness;

/**
 * A regular polygon whose corners are rounded with a quadratic through each
 * vertex, like the triangle below. `rounding` is how far along each edge the
 * curve starts, as a fraction of the edge; `rotate` is in degrees.
 */
function roundedPolygon(sides: number, radius: number, rounding: number, rotate = 0): string {
  const vertices = Array.from({ length: sides }, (_, i): Point => {
    const angle = ((rotate - 90) * Math.PI) / 180 + (i / sides) * 2 * Math.PI;
    return [BOX_CENTRE + radius * Math.cos(angle), BOX_CENTRE + radius * Math.sin(angle)];
  });
  const toward = (from: Point, to: Point): string =>
    `${round2(from[0] + (to[0] - from[0]) * rounding)} ${round2(from[1] + (to[1] - from[1]) * rounding)}`;
  const corners = vertices.map((vertex, i) => {
    const prev = vertices[(i - 1 + sides) % sides]!;
    const next = vertices[(i + 1) % sides]!;
    return `${toward(vertex, prev)} Q ${round2(vertex[0])} ${round2(vertex[1])} ${toward(vertex, next)}`;
  });
  return `M ${corners.join(" L ")} Z`;
}

/**
 * The pack's baked-in silhouette was exported with the body fill hardcoded to
 * black instead of the {{GRADIENT}} placeholder the component substitutes,
 * which painted every bot the same. Restore the slot so the per-bot gradient
 * actually lands on the body.
 */
const CURSOR_SILHOUETTE: CursorSilhouette = {
  ...DEFAULT_SILHOUETTE,
  body: DEFAULT_SILHOUETTE.body.replace(/fill="#000000"/g, 'fill="{{GRADIENT}}"'),
};

export const MAUS_SILHOUETTES = {
  cursor: CURSOR_SILHOUETTE,
  circle: fromPath(
    "circle",
    "M 114.27 9.27 A 105 105 0 1 1 114.27 219.27 A 105 105 0 1 1 114.27 9.27 Z",
    { x: 114.27, y: 116, scale: 0.86 },
  ),
  squircle: fromPath(
    "squircle",
    "M 68 12 H 160.54 A 56 56 0 0 1 216.54 68 V 160.54 A 56 56 0 0 1 160.54 216.54 H 68 A 56 56 0 0 1 12 160.54 V 68 A 56 56 0 0 1 68 12 Z",
    { x: 114.27, y: 116, scale: 0.88 },
  ),
  hexagon: fromPath(
    "hexagon",
    "M 114.27 6.27 L 207.8 60.27 L 207.8 168.27 L 114.27 222.27 L 20.74 168.27 L 20.74 60.27 Z",
    { x: 114.27, y: 118, scale: 0.8 },
  ),
  octagon: fromPath(
    "octagon",
    "M 155.6 14.49 L 214.05 72.94 L 214.05 155.6 L 155.6 214.05 L 72.94 214.05 L 14.49 155.6 L 14.49 72.94 L 72.94 14.49 Z",
    { x: 114.27, y: 116, scale: 0.86 },
  ),
  shield: fromPath(
    "shield",
    "M 114.27 8 L 204.27 44 V 116 C 204.27 170 168 204 114.27 220.54 C 60.54 204 24.27 170 24.27 116 V 44 Z",
    { x: 114.27, y: 106, scale: 0.76 },
  ),
  droplet: fromPath(
    "droplet",
    "M 114.27 6 C 114.27 6 197.27 92 197.27 141.27 A 83 83 0 0 1 31.27 141.27 C 31.27 92 114.27 6 114.27 6 Z",
    { x: 114.27, y: 141, scale: 0.72 },
  ),
  egg: fromPath(
    "egg",
    "M 114.27 8 C 158 8 197.27 62 197.27 130 A 83 83 0 0 1 31.27 130 C 31.27 62 70.54 8 114.27 8 Z",
    { x: 114.27, y: 124, scale: 0.78 },
  ),
  capsule: fromPath(
    "capsule",
    "M 114.27 12 A 62 62 0 0 1 176.27 74 V 154.54 A 62 62 0 0 1 52.27 154.54 V 74 A 62 62 0 0 1 114.27 12 Z",
    { x: 114.27, y: 114, scale: 0.64 },
  ),
  star: fromPath(
    "star",
    "M 114.27 4.27 L 141.31 77.06 L 218.89 80.28 L 158.02 128.49 L 178.93 203.26 L 114.27 160.27 L 49.61 203.26 L 70.52 128.49 L 9.65 80.28 L 87.23 77.06 Z",
    { x: 114.27, y: 110, scale: 0.62 },
  ),
  // A rounded rectangle wider than it is tall. The face scale is set by the
  // HEIGHT here, not the width: at a circle's 0.86 the eyes would ride the
  // flat top and bottom edges.
  tile: fromPath(
    "tile",
    "M 52 40 H 176.54 A 46 46 0 0 1 222.54 86 V 142 A 46 46 0 0 1 176.54 188 H 52 A 46 46 0 0 1 6 142 V 86 A 46 46 0 0 1 52 40 Z",
    { x: 114.27, y: 114, scale: 0.7 },
  ),
  oval: fromPath(
    "oval",
    "M 114.27 30.27 A 108 84 0 1 1 114.27 198.27 A 108 84 0 1 1 114.27 30.27 Z",
    { x: 114.27, y: 115, scale: 0.74 },
  ),
  // Rounded through its vertices rather than mitred at them: three quadratics
  // that bulge out to each corner, which is the soft triangle the design shows
  // and needs no corner-arc arithmetic to stay closed.
  triangle: fromPath(
    "triangle",
    "M 161.1 108 Q 208 198 114.25 198 Q 20.5 198 67.4 108 Q 114.27 18 161.1 108 Z",
    { x: 114.27, y: 143, scale: 0.56 },
  ),
  blob: fromPath(
    "blob",
    "M 114 14 C 160 8 208 40 214 88 C 220 136 196 186 148 206 C 104 224 48 210 26 172 C 6 136 12 82 44 48 C 66 24 90 18 114 14 Z",
    { x: 112, y: 116, scale: 0.78 },
  ),
  // The shapes below are generated rather than hand-written: lobes, spikes
  // and rounded corners are much easier to tune as numbers than as paths.
  cloud: fromPath(
    "cloud",
    polarPath((a) => 92 * (0.9 + 0.1 * lobes(6, 1)(a)), { sx: 1.12, sy: 0.96, rotate: 8 }),
    { x: 114.27, y: 116, scale: 0.8 },
  ),
  // A squircle leaning to one side; the face stays level.
  slanted: fromPath(
    "slanted",
    polarPath((a) => 86 / (Math.abs(Math.cos(a)) ** 4 + Math.abs(Math.sin(a)) ** 4) ** 0.25, {
      rotate: -16,
    }),
    { x: 114.27, y: 116, scale: 0.78 },
  ),
  sparkle: fromPath(
    "sparkle",
    polarPath((a) => 110 * (0.6 + 0.4 * spikes(4, 1.6)(a)), { rotate: -8, samples: 128 }),
    { x: 114.27, y: 116, scale: 0.58 },
  ),
  clover: fromPath(
    "clover",
    polarPath((a) => 106 * (0.78 + 0.22 * lobes(4, 0.8)(a - Math.PI / 4)), { rotate: 8, samples: 128 }),
    { x: 114.27, y: 116, scale: 0.78 },
  ),
  // An egg on its side, its narrow end pointing up and to the left.
  pebble: fromPath(
    "pebble",
    polarPath((a) => 88 * (1 + 0.24 * spikes(1, 5)(a - Math.PI)), { sy: 0.9, rotate: -20 }),
    { x: 124, y: 118, scale: 0.72 },
  ),
  flower: fromPath(
    "flower",
    polarPath((a) => 104 * (0.8 + 0.2 * lobes(7, 0.8)(a)), { samples: 140 }),
    { x: 114.27, y: 116, scale: 0.72 },
  ),
  pill: fromPath(
    "pill",
    "M 66 50 H 162.54 A 64 64 0 0 1 162.54 178 H 66 A 64 64 0 0 1 66 50 Z",
    { x: 114.27, y: 114, scale: 0.66 },
  ),
  pentagon: fromPath("pentagon", roundedPolygon(5, 108, 0.2, -12), {
    x: 114.27,
    y: 120,
    scale: 0.76,
  }),
  burst: fromPath(
    "burst",
    polarPath((a) => 108 * (0.72 + 0.28 * spikes(7, 1)(a)), { rotate: -90, samples: 168 }),
    { x: 114.27, y: 116, scale: 0.62 },
  ),
  gem: fromPath("gem", roundedPolygon(6, 106, 0.2, 18), { x: 114.27, y: 116, scale: 0.8 }),
} satisfies Record<string, CursorSilhouette>;

export type MausSilhouetteId = keyof typeof MAUS_SILHOUETTES;

const isSilhouetteId = (value: string): value is MausSilhouetteId =>
  Object.prototype.hasOwnProperty.call(MAUS_SILHOUETTES, value);

/**
 * Every shape the engine draws, in the order the appearance picker shows
 * them: the designed set first, then the earlier shapes.
 */
export const MAUS_SILHOUETTE_IDS: MausSilhouetteId[] = [
  "circle",
  "cloud",
  "slanted",
  "sparkle",
  "clover",
  "pebble",
  "flower",
  "droplet",
  "pill",
  "triangle",
  "pentagon",
  "burst",
  "gem",
  "squircle",
  "tile",
  "oval",
  "hexagon",
  "blob",
  "cursor",
  "octagon",
  "shield",
  "egg",
  "capsule",
  "star",
];

export const DEFAULT_SILHOUETTE_ID: MausSilhouetteId = "circle";

/**
 * The id a picker should show as selected for a stored value. Unknown ids
 * resolve to the default rather than throwing: a bot saved by a newer build —
 * or seeded from a shared team file, which is untrusted input — must still
 * render.
 */
export function normalizeSilhouette(id: string | null | undefined): MausSilhouetteId {
  return id && isSilhouetteId(id) ? id : DEFAULT_SILHOUETTE_ID;
}

/** The shape a stored value renders as. */
export function silhouetteFor(id: string | null | undefined): CursorSilhouette {
  return MAUS_SILHOUETTES[normalizeSilhouette(id)];
}

type MascotMessage = {
  kind: string;
  tool?: { ok?: boolean };
};

export type MascotBotProfile = {
  /** Seeds the resting face. Absent falls back to the name. */
  id?: string;
  name: string;
  title?: string;
  description?: string;
  mascotExpression?: string | null;
  mascotSilhouette?: string | null;
  busy?: boolean;
  unread?: boolean;
  messages?: MascotMessage[];
};

/**
 * Selects a state from live state first, then from what the bot is about.
 * The keyword groups deliberately overlap as little as possible so a bot's
 * visual identity stays stable while its title and description are edited.
 */
export function stateForBot(bot: MascotBotProfile): MausState {
  const pinned = normalizeState(bot.mascotExpression);
  if (pinned) return pinned;

  const last = bot.messages?.[bot.messages.length - 1];

  if (last?.kind === "activity" && last.tool?.ok === false) return "alerting";
  if (bot.busy) return "working";
  if (bot.unread) return "notifying";
  if (last?.kind === "options") return "curious";

  const profile = `${bot.name} ${bot.title ?? ""} ${bot.description ?? ""}`.toLowerCase();
  const matches = (words: RegExp) => words.test(profile);

  if (matches(/\b(code|coding|developer|development|engineer|engineering|build|debug|program|software)\b/)) {
    return "working";
  }
  if (matches(/\b(research|researcher|search|investigate|strategy|strategist|study|learn|knowledge)\b/)) {
    return "searching";
  }
  if (matches(/\b(marketing|growth|launch|campaign|social|sales|outreach|brand)\b/)) {
    return "excited";
  }
  if (matches(/\b(overnight|night|background|async|queue|batch|long-running)\b/)) {
    return "drowsy";
  }
  if (matches(/\b(monitor|monitoring|incident|alert|watch|status|uptime)\b/)) {
    return "radar";
  }
  if (matches(/\b(review|reviewer|audit|critic|critique|quality|qa|test|legal)\b/)) {
    return "suspicious";
  }
  if (matches(/\b(security|secure|compliance|risk|privacy|finance|financial)\b/)) {
    return "scared";
  }
  if (matches(/\b(design|designer|creative|brainstorm|art|illustration|music|story)\b/)) {
    return "playful";
  }
  if (matches(/\b(support|help|success|onboarding|coach|teacher|guide|welcome)\b/)) {
    return "happy";
  }

  return restingFaceFor(bot.id ?? bot.name);
}
