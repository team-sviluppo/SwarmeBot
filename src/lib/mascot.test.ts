import { describe, expect, it } from "vitest";

import {
  DEFAULT_SILHOUETTE_ID,
  MAUS_SILHOUETTES,
  MAUS_SILHOUETTE_IDS,
  normalizeSilhouette,
  silhouetteFor,
} from "./mascot";

describe("silhouettes", () => {
  it("offers every registered shape, default first", () => {
    expect(MAUS_SILHOUETTE_IDS[0]).toBe(DEFAULT_SILHOUETTE_ID);
    expect(MAUS_SILHOUETTE_IDS).toEqual(Object.keys(MAUS_SILHOUETTES));
  });

  it("falls back to the default for junk, absent and inherited names", () => {
    // A bot saved by a newer build, or seeded from an untrusted team file,
    // must still render rather than throwing on an id we do not have.
    for (const value of [null, undefined, "", "pentagon", "toString", "__proto__"]) {
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
