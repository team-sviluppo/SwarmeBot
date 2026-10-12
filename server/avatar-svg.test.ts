import { describe, expect, it } from "vitest";

import { validateAvatarSvg } from "./avatar-svg.ts";

/** Shaped like the real thing: metadata, a mask, a fragment reference. */
const AVATAR_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 135 135" fill="none">
<metadata xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:RDF /></metadata>
<mask id="viewboxMask"><rect width="135" height="135" fill="#fff" /></mask>
<g mask="url(#viewboxMask)"><use xlink:href="#part" /><path id="part" d="M0 0h1v1H0z" /></g>
</svg>`;

describe("avatar svg", () => {
  it("accepts a plain self-contained SVG", () => {
    const verdict = validateAvatarSvg(`<?xml version="1.0"?>\n${AVATAR_SVG}`);
    expect(verdict.ok).toBe(true);
    // The XML declaration is dropped; the document itself is kept verbatim.
    expect(verdict.ok && verdict.svg.startsWith("<svg")).toBe(true);
  });

  it("refuses markup it would not put in a page", () => {
    const hostile = [
      AVATAR_SVG.replace("<mask", '<script>fetch("//x")</script><mask'),
      AVATAR_SVG.replace("<svg ", '<svg onload="alert(1)" '),
      AVATAR_SVG.replace("<mask", "<foreignObject><b>hi</b></foreignObject><mask"),
      AVATAR_SVG.replace('xlink:href="#part"', 'xlink:href="https://evil.com/x.svg"'),
      AVATAR_SVG.replace("url(#viewboxMask)", "url(https://evil.com/x.svg)"),
      AVATAR_SVG.replace("<metadata", '<image src="https://evil.com/x.png" /><metadata'),
      `<!DOCTYPE svg [<!ENTITY x "y">]>${AVATAR_SVG}`,
      "<html><body>nope</body></html>",
      "",
      `${AVATAR_SVG.slice(0, 200)}`,
    ];
    for (const svg of hostile) {
      expect(validateAvatarSvg(svg).ok, svg.slice(0, 60)).toBe(false);
    }
  });
});
