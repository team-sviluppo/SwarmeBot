#!/usr/bin/env node
// Generates Sources/SwarmeBot/Mascot/MausFaceData.swift from the React
// mascot modules, so the Swift port carries the desktop's numbers verbatim:
// silhouettes (path data + face anchor), the 25 expressions, mouths, pools,
// cadences, blink rhythm, body motion, effects, palette and resting faces.
//
//   node scripts/gen-mascot-data.mjs [path/to/SwarmeBot]
//
// The React repo defaults to ../SwarmeBot. Its own esbuild bundles
// src/lib/mascot.ts (which imports src/components/CursorAvatar.tsx); a tiny
// plugin re-exports the two tables CursorAvatar keeps private.
import { createRequire } from "node:module";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const web = resolve(process.argv[2] ?? join(root, "..", "SwarmeBot"));
const require = createRequire(join(web, "package.json"));
const esbuild = require("esbuild");

const out = mkdtempSync(join(tmpdir(), "maus-gen-"));
const bundle = join(out, "mascot.mjs");
const entry = join(out, "entry.ts");
writeFileSync(
  entry,
  `export * from ${JSON.stringify(join(web, "src/lib/mascot.ts"))};\n` +
    `export * as Cursor from ${JSON.stringify(join(web, "src/components/CursorAvatar.tsx"))};\n`,
);

const exposePrivate = {
  name: "expose-private",
  setup(build) {
    build.onLoad({ filter: /CursorAvatar\.tsx$/ }, (args) => ({
      contents: readFileSync(args.path, "utf8") + "\nexport { EXPR_CADENCE as __EXPR_CADENCE, BLINK as __BLINK, GAZE_X as __GAZE_X, GAZE_Y as __GAZE_Y, SPHERE_C as __SPHERE_C, SPHERE_R as __SPHERE_R };\n",
      loader: "tsx",
    }));
  },
};

await esbuild.build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile: bundle,
  plugins: [exposePrivate],
  alias: { "@": join(web, "src") },
  jsx: "automatic",
  logLevel: "error",
  nodePaths: [join(web, "node_modules")],
});
const M = await import(pathToFileURL(bundle).href);
rmSync(out, { recursive: true, force: true });
const C = M.Cursor;

// ---------------------------------------------------------------- helpers

const num = (n) => {
  const s = Number(n.toFixed(6)).toString();
  return s.includes(".") || s.includes("e") ? s : s;
};
const caseName = (state) => state.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
const swiftString = (s) => JSON.stringify(s);
const chunk = (values, per) => {
  const lines = [];
  for (let i = 0; i < values.length; i += per) lines.push("        " + values.slice(i, i + per).join(", ") + ",");
  return lines.join("\n");
};

/** "translate(a b) scale(k)" → affine [a b c d tx ty], applied right-to-left like SVG. */
function parseTransform(text) {
  let m = [1, 0, 0, 1, 0, 0];
  const mul = (p, q) => [
    p[0] * q[0] + p[2] * q[1],
    p[1] * q[0] + p[3] * q[1],
    p[0] * q[2] + p[2] * q[3],
    p[1] * q[2] + p[3] * q[3],
    p[0] * q[4] + p[2] * q[5] + p[4],
    p[1] * q[4] + p[3] * q[5] + p[5],
  ];
  for (const [, fn, args] of (text ?? "").matchAll(/(translate|scale)\(([^)]*)\)/g)) {
    const v = args.split(/[\s,]+/).filter(Boolean).map(Number);
    if (fn === "translate") m = mul(m, [1, 0, 0, 1, v[0], v[1] ?? 0]);
    else m = mul(m, [v[0], 0, 0, v[1] ?? v[0], 0, 0]);
  }
  return m;
}
const compose = (p, q) => [
  p[0] * q[0] + p[2] * q[1],
  p[1] * q[0] + p[3] * q[1],
  p[0] * q[2] + p[2] * q[3],
  p[1] * q[2] + p[3] * q[3],
  p[0] * q[4] + p[2] * q[5] + p[4],
  p[1] * q[4] + p[3] * q[5] + p[5],
];

// ---------------------------------------------------------------- data

const states = C.CURSOR_STATES;
const ids = M.MAUS_SILHOUETTE_IDS;
const silhouettes = ids.map((id) => {
  const s = M.MAUS_SILHOUETTES[id];
  const fit = parseTransform(s.fit);
  const paths = [...s.clip.matchAll(/<path\b([^>]*)\/?>/g)].map(([, attrs]) => {
    const d = attrs.match(/\bd="([^"]*)"/)[1].replace(/\s+/g, " ").trim();
    const t = attrs.match(/\btransform="([^"]*)"/)?.[1];
    return { d, transform: compose(fit, parseTransform(t?.replace(/,/g, " "))) };
  });
  if (!paths.length) throw new Error(`silhouette ${id}: no path`);
  return { id, paths, anchor: s.anchor };
});

const expressionsFlat = C.EXPRESSIONS.flatMap((ex) => ex.flatMap((ring) => ring.flatMap((p) => [num(p[0]), num(p[1])])));
const gazeFlat = C.GAZE.flatMap((g) => [num(g[0]), num(g[1])]);
const mouthsFlat = C.MOUTHS.flatMap((m) => m.map(num));

const pair = (v) => (v ? `(${num(v[0])}, ${num(v[1])})` : "nil");
const motion = (m) => {
  const parts = [];
  for (const k of ["bob", "sway", "pulse", "circle", "jitter"]) if (m[k]) parts.push(`${k}: ${pair(m[k])}`);
  if (m.tilt !== undefined) parts.push(`tilt: ${num(m.tilt)}`);
  if (m.squash !== undefined) parts.push(`squash: ${num(m.squash)}`);
  if (m.enter) parts.push(`enter: ${pair(m.enter)}`);
  if (m.settle !== undefined) parts.push(`settle: ${num(m.settle)}`);
  return `MausBodyMotion(${parts.join(", ")})`;
};
const effect = (e) => {
  const parts = [];
  if (e.confetti) {
    const c = e.confetti;
    parts.push(`confetti: MausConfettiSpec(count: ${c.count}, period: ${num(c.period)}, life: ${num(c.life)}, origin: ${num(c.origin)}, spread: ${num(c.spread)})`);
  }
  if (e.trails) {
    const t = e.trails;
    parts.push(`trails: MausTrailSpec(count: ${t.count}, period: ${num(t.period)}, radius: ${num(t.radius)})`);
  }
  if (e.glyph) {
    const g = e.glyph;
    const kind = g.markup.includes("stroke-width") ? ".query" : ".bang";
    parts.push(`glyph: MausGlyphSpec(kind: ${kind}, period: ${num(g.period)}, hold: ${num(g.hold)})`);
  }
  return `MausEffects(${parts.join(", ")})`;
};

// ---------------------------------------------------------------- emit

const lines = [];
const w = (s = "") => lines.push(s);
w("// GENERATED by scripts/gen-mascot-data.mjs from the React mascot modules");
w("// (src/lib/mascot.ts, src/components/CursorAvatar.tsx). Do not hand-edit:");
w("// re-run the script. Same numbers as the desktop, which is the whole point.");
w("import CoreGraphics");
w();
w("enum MausState: String, CaseIterable {");
for (const s of states) w(`    case ${caseName(s)} = ${swiftString(s)}`);
w("}");
w();
w("enum MausFaceData {");
w(`    static let faceBox: CGFloat = ${num(C.FACE_BOX)}`);
w(`    static let faceCentre = CGPoint(x: ${num(C.FACE_CENTRE[0])}, y: ${num(C.FACE_CENTRE[1])})`);
w(`    static let mouthStroke: CGFloat = ${num(C.MOUTH_STROKE)}`);
w(`    static let sphereCentre: CGFloat = ${num(C.__SPHERE_C)}`);
w(`    static let sphereRadius: CGFloat = ${num(C.__SPHERE_R)}`);
w(`    static let gazeTravel = CGPoint(x: ${num(C.__GAZE_X)}, y: ${num(C.__GAZE_Y)})`);
w(`    static let expressionCount = ${C.EXPRESSION_COUNT}`);
w(`    static let pointsPerRing = ${C.EXPRESSIONS[0][0].length}`);
w("    /// EXPRESSIONS (look-direction removed): expression → eye → point → (x, y), flattened.");
w("    static let expressionsFlat: [CGFloat] = [");
w(chunk(expressionsFlat, 12));
w("    ]");
w("    /// GAZE: each expression's own look-direction.");
w("    static let gazeFlat: [CGFloat] = [");
w(chunk(gazeFlat, 12));
w("    ]");
w("    /// MOUTHS: [halfWidth, curve, gap, skew] per expression.");
w("    static let mouthsFlat: [CGFloat] = [");
w(chunk(mouthsFlat, 16));
w("    ]");
w("    static let pools: [MausState: [Int]] = [");
for (const s of states) w(`        .${caseName(s)}: [${C.POOLS[s].join(", ")}],`);
w("    ]");
w("    static let expressionCadence: [MausState: (CGFloat, CGFloat)] = [");
for (const s of states) w(`        .${caseName(s)}: ${pair(C.__EXPR_CADENCE[s])},`);
w("    ]");
w("    static let blink: [MausState: (CGFloat, CGFloat)] = [");
for (const s of states) if (C.__BLINK[s]) w(`        .${caseName(s)}: ${pair(C.__BLINK[s])},`);
w("    ]");
w("    static let motion: [MausState: MausBodyMotion] = [");
for (const s of states) w(`        .${caseName(s)}: ${motion(C.MOTION[s] ?? {})},`);
w("    ]");
w("    static let effects: [MausState: MausEffects] = [");
for (const s of states) if (C.EFFECTS[s]) w(`        .${caseName(s)}: ${effect(C.EFFECTS[s])},`);
w("    ]");
w("    /// RESTING_FACES, for `restingFaceFor` (FNV-1a of the bot id).");
w(`    static let restingFaces: [MausState] = [${M.RESTING_FACES.map((s) => "." + caseName(s)).join(", ")}]`);
w("}");
w();
w("enum MausPaletteData {");
w("    /// MAUS_COLORS");
w("    static let hex: [String: String] = [");
for (const name of M.MAUS_COLOR_NAMES) w(`        ${swiftString(name)}: ${swiftString(M.MAUS_COLORS[name])},`);
w("    ]");
w(`    static let names: [String] = [${M.MAUS_COLOR_NAMES.map(swiftString).join(", ")}]`);
w("}");
w();
w("enum MausSilhouetteData {");
w(`    static let defaultId = ${swiftString(M.DEFAULT_SILHOUETTE_ID)}`);
w("    /// MAUS_SILHOUETTE_IDS order (the appearance picker's).");
w("    static let all: [MausSilhouetteSpec] = [");
for (const s of silhouettes) {
  w(`        MausSilhouetteSpec(`);
  w(`            id: ${swiftString(s.id)},`);
  w(`            paths: [`);
  for (const p of s.paths) {
    w(`                MausSilhouettePath(`);
    w(`                    d: ${swiftString(p.d)},`);
    w(`                    transform: CGAffineTransform(a: ${p.transform.map(num).join(", ").replace(/^([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+)$/, "$1, b: $2, c: $3, d: $4, tx: $5, ty: $6")})`);
  w(`                ),`);
  }
  w(`            ],`);
  w(`            anchor: (x: ${num(s.anchor.x)}, y: ${num(s.anchor.y)}, scale: ${num(s.anchor.scale)})`);
  w(`        ),`);
}
w("    ]");
w("}");
w();

const target = join(root, "Sources/SwarmeBot/Mascot/MausFaceData.swift");
writeFileSync(target, lines.join("\n"));
console.log(`wrote ${target}: ${states.length} states, ${silhouettes.length} silhouettes, ${C.EXPRESSION_COUNT} expressions`);
