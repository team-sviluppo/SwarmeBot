import { describe, expect, it } from "vitest";

import * as collection from "@dicebear/collection";
import {
  DICEBEAR_STYLE_IDS,
  importDicebearAvatar,
  dicebearSvg,
  dicebearUrl,
  loadDicebear,
  namespaceSvgIds,
  parseDicebearAvatar,
} from "./dicebear";

const declaredIds = (svg: string) => [...svg.matchAll(/(?<![\w:-])id="([^"]+)"/g)].map((m) => m[1]!);
const referencedIds = (svg: string) => [
  ...[...svg.matchAll(/url\(#([^)]+)\)/g)].map((m) => m[1]!),
  ...[...svg.matchAll(/(?<![\w-])(?:xlink:)?href="#([^"]+)"/g)].map((m) => m[1]!),
];

describe("dicebear avatars", () => {
  it("lists exactly the styles the collection ships", () => {
    expect([...DICEBEAR_STYLE_IDS]).toEqual(Object.keys(collection));
  });

  it("reads a URL copied from dicebear.com, options and all", () => {
    const spec = parseDicebearAvatar(
      "https://api.dicebear.com/9.x/pixel-art/svg?seed=Mira&hair=short01,short02&flip=true&size=96",
    );
    expect(spec).toEqual({
      style: "pixelArt",
      seed: "Mira",
      // `size` is transport, not appearance; the seed is stored on its own.
      options: "flip=true&hair=short01%2Cshort02",
    });
  });

  it("accepts a bare style, in either spelling", () => {
    expect(parseDicebearAvatar("bottts")?.style).toBe("bottts");
    expect(parseDicebearAvatar("pixel-art")?.style).toBe("pixelArt");
    expect(parseDicebearAvatar("https://www.dicebear.com/styles/big-ears/")?.style).toBe("bigEars");
  });

  it("refuses anything it cannot render", () => {
    for (const value of [null, undefined, "", "   ", "not a url", "https://example.com/nope"]) {
      expect(parseDicebearAvatar(value)).toBeNull();
    }
  });

  it("round-trips through the URL it stores", () => {
    const url = dicebearUrl("notionists", "Ada", "backgroundColor=b6e3f4");
    expect(parseDicebearAvatar(url)).toEqual({
      style: "notionists",
      seed: "Ada",
      options: "backgroundColor=b6e3f4",
    });
  });

  it("tells a missing style apart from a URL that is not DiceBear's", () => {
    // DiceBear 10 added styles that were never published as packages, so a
    // perfectly good URL can name one this build cannot render.
    expect(importDicebearAvatar("https://api.dicebear.com/10.x/disco/svg?seed=Felix")).toEqual({
      ok: false,
      reason: "style-unavailable",
      style: "disco",
    });
    expect(importDicebearAvatar("https://www.dicebear.com/styles/disco/")).toEqual({
      ok: false,
      reason: "style-unavailable",
      style: "disco",
    });
    expect(importDicebearAvatar("https://example.com/felix.svg")).toEqual({
      ok: false,
      reason: "not-dicebear",
    });
    // A version we do not write ourselves still imports when we have the style.
    const imported = importDicebearAvatar("https://api.dicebear.com/10.x/bottts/svg?seed=Felix");
    expect(imported).toMatchObject({ ok: true, spec: { style: "bottts", seed: "Felix" } });
  });

  it("renders locally once the collection is loaded", async () => {
    expect(dicebearSvg("bottts", "Mira")).toBeNull();
    await loadDicebear();

    const svg = dicebearSvg("bottts", "Mira");
    expect(svg).toContain("<svg");
    // Same seed, same picture — and the bot's name only seeds a URL without one.
    expect(dicebearSvg(dicebearUrl("bottts", "Mira"))).toBe(svg);
    expect(dicebearSvg("bottts", "Ada")).not.toBe(svg);
  });

  it("gives each avatar its own ids so one page can hold many", async () => {
    await loadDicebear();
    // Every style names its mask `viewboxMask` and sizes it in its own viewBox
    // units, so sharing that id across a page crops or blanks every avatar
    // after the first.
    const raw = dicebearSvg("bottts", "Mira")!;
    expect(declaredIds(raw)).toContain("viewboxMask");

    const mine = namespaceSvgIds(raw, "dbA");
    const theirs = namespaceSvgIds(dicebearSvg("pixelArt", "Mira")!, "dbB");

    for (const svg of [mine, theirs]) {
      const declared = declaredIds(svg);
      expect(declared.length).toBeGreaterThan(0);
      // Nothing points at an id the document does not declare here.
      expect(new Set(referencedIds(svg))).toEqual(new Set(declared));
    }
    expect(declaredIds(mine).some((id) => declaredIds(theirs).includes(id))).toBe(false);
    // The RDF attribution block must survive the rewrite untouched.
    expect(mine).toContain('xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"');
  });

  it("keeps an avatar whose options do not fit its style", async () => {
    await loadDicebear();
    // A style change carries no options over, but a hand-edited URL can still
    // name an option the style rejects: it must render on the seed alone.
    const svg = dicebearSvg("https://api.dicebear.com/9.x/identicon/svg?seed=Mira&mouth=nonsense");
    expect(svg).toContain("<svg");
  });
});
