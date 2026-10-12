import { describe, expect, it } from "vitest";

import {
  DEFAULT_SILHOUETTE_ID,
  MAUS_SILHOUETTES,
  MAUS_SILHOUETTE_IDS,
  MAUS_COLOR_NAMES,
  MAUS_COLORS,
  PICKABLE_STATES,
  RESTING_FACES,
  eyeInkFor,
  normalizeSilhouette,
  restingFaceFor,
  silhouetteFor,
  stateForBot,
} from "./mascot";

describe("silhouettes", () => {
  it("offers every registered shape exactly once, the default first", () => {
    expect(MAUS_SILHOUETTE_IDS[0]).toBe(DEFAULT_SILHOUETTE_ID);
    expect(new Set(MAUS_SILHOUETTE_IDS).size).toBe(MAUS_SILHOUETTE_IDS.length);
    expect([...MAUS_SILHOUETTE_IDS].sort()).toEqual(Object.keys(MAUS_SILHOUETTES).sort());
  });

  it("offers the designed shapes", () => {
    for (const id of [
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
    ]) {
      expect(MAUS_SILHOUETTE_IDS).toContain(id);
    }
  });

  it("generates closed paths with finite coordinates", () => {
    for (const id of MAUS_SILHOUETTE_IDS) {
      const { clip } = MAUS_SILHOUETTES[id];
      expect(clip, id).not.toMatch(/NaN|Infinity/);
      expect(clip, id).toMatch(/Z\s*"/);
    }
  });

  it("falls back to the default for junk, absent and inherited names", () => {
    // A bot saved by a newer build, or seeded from an untrusted team file,
    // must still render rather than throwing on an id we do not have.
    for (const value of [null, undefined, "", "dodecagon", "toString", "__proto__"]) {
      expect(normalizeSilhouette(value)).toBe(DEFAULT_SILHOUETTE_ID);
      expect(silhouetteFor(value)).toBe(MAUS_SILHOUETTES[DEFAULT_SILHOUETTE_ID]);
    }
  });

  it("paints every shape with the instance gradient, not a fixed fill", () => {
    for (const id of MAUS_SILHOUETTE_IDS) {
      const silhouette = MAUS_SILHOUETTES[id];
      expect(silhouette.body, id).toContain("{{GRADIENT}}");
      expect(silhouette.body, id).not.toMatch(/fill="#/);
      expect(silhouette.clip, id).not.toContain("{{GRADIENT}}");
    }
  });
});

describe("resting faces", () => {
  it("only offers faces the picker can also show", () => {
    for (const face of RESTING_FACES) expect(PICKABLE_STATES).toContain(face);
  });

  it("leaves out the faces that would read as broken or as a warning", () => {
    // A bot that has told us nothing about itself has nothing to warn about,
    // and must not look like an engine that failed to start.
    for (const face of ["sleeping", "drowsy", "suspicious"]) {
      expect(RESTING_FACES).not.toContain(face);
    }
  });

  it("gives one bot the same face forever", () => {
    expect(restingFaceFor("bot-7")).toBe(restingFaceFor("bot-7"));
  });

  it("spreads a roster across the faces instead of repeating one", () => {
    const roster = Array.from({ length: 60 }, (_, i) => `bot-${i}`);
    const faces = new Set(roster.map(restingFaceFor));
    // The old fallback returned "idle" for all of them, which is the bug this
    // guards: a sidebar that looked like one bot repeated.
    expect(faces.size).toBe(RESTING_FACES.length);
  });
});

describe("stateForBot", () => {
  const plain = { id: "plain-1", name: "Bot" };

  it("varies the face across bots whose profile says nothing", () => {
    const faces = new Set(
      Array.from({ length: 40 }, (_, i) => stateForBot({ id: `blank-${i}`, name: "Bot" })),
    );
    expect(faces.size).toBeGreaterThan(1);
  });

  it("keys the fallback on the id, so a rename does not repaint the face", () => {
    expect(stateForBot({ id: "same", name: "Ada" })).toBe(stateForBot({ id: "same", name: "Grace" }));
  });

  it("falls back to the name when there is no id yet", () => {
    expect(stateForBot({ name: "Ada" })).toBe(restingFaceFor("Ada"));
  });

  it("lets a pinned face win over everything, live state included", () => {
    expect(stateForBot({ ...plain, mascotExpression: "proud", busy: true })).toBe("proud");
    // legacy vocabulary still resolves rather than falling through
    expect(stateForBot({ ...plain, mascotExpression: "focused" })).toBe("working");
  });

  it("puts live state ahead of the profile and the fallback", () => {
    expect(stateForBot({ ...plain, busy: true })).toBe("working");
    expect(stateForBot({ ...plain, unread: true })).toBe("notifying");
    expect(stateForBot({
      ...plain,
      messages: [{ kind: "activity", tool: { ok: false } }],
    })).toBe("alerting");
    expect(stateForBot({ ...plain, messages: [{ kind: "options" }] })).toBe("curious");
  });

  it("still reads the profile keywords", () => {
    expect(stateForBot({ ...plain, title: "Security Engineer" })).toBe("working");
    expect(stateForBot({ ...plain, title: "Compliance" })).toBe("scared");
    expect(stateForBot({ ...plain, description: "watches uptime and incidents" })).toBe("radar");
  });
});

describe("colors", () => {
  it("gives every offered color a fill", () => {
    for (const name of MAUS_COLOR_NAMES) expect(MAUS_COLORS[name]).toMatch(/^#[0-9A-Fa-f]{6}$/);
  });

  it("inks the face dark on a light body and white on the rest", () => {
    // White eyes on a white body is a blob with no face.
    expect(eyeInkFor("white")).toBe("#2A2A30");
    for (const name of MAUS_COLOR_NAMES.filter((c) => c !== "white")) {
      expect(eyeInkFor(name), name).toBe("#ffffff");
    }
  });
});
