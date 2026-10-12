import { describe, expect, it } from "vitest";
import { namespaceSvgIds } from "./SvgAvatar";

const declaredIds = (svg: string) => [...svg.matchAll(/(?<![\w:-])id="([^"]+)"/g)].map((m) => m[1]!);
const referencedIds = (svg: string) => [
  ...[...svg.matchAll(/url\(#([^)]+)\)/g)].map((m) => m[1]!),
  ...[...svg.matchAll(/(?<![\w-])(?:xlink:)?href="#([^"]+)"/g)].map((m) => m[1]!),
];

const SVG = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" viewBox="0 0 16 16">
<mask id="viewboxMask"><rect width="16" height="16" fill="#fff" /></mask>
<g mask="url(#viewboxMask)"><use xlink:href="#part" /><path id="part" d="M0 0h1v1H0z" /></g>
</svg>`;

describe("svg avatars", () => {
  it("namespaces ids so two avatars on one page cannot capture each other's", () => {
    const mine = namespaceSvgIds(SVG, "svA");
    const theirs = namespaceSvgIds(SVG, "svB");
    for (const svg of [mine, theirs]) {
      const declared = declaredIds(svg);
      expect(declared.length).toBeGreaterThan(0);
      // Nothing points at an id the document does not declare here.
      expect(new Set(referencedIds(svg))).toEqual(new Set(declared));
    }
    expect(declaredIds(mine).some((id) => declaredIds(theirs).includes(id))).toBe(false);
    // Namespace declarations are attributes, not ids, and survive untouched.
    expect(mine).toContain('xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"');
  });
});
