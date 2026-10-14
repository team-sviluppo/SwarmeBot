// Reference answers of the Node engine for the Swift validators' tests.
//   node Tests/Fixtures/team-avatar.mts <SwarmeBot repo> > Tests/Fixtures/team-avatar.json
// Inputs over 5000 characters are left out (the size limits have their own tests).
const server = `${process.argv[2] ?? "../SwarmeBot"}/server`;
const { parseTeamManifest } = await import(`${server}/team-manifest.ts`);
const { validateAvatarSvg } = await import(`${server}/avatar-svg.ts`);
const { githubManifestUrls, parseTeamCatalog } = await import(`${server}/team-library.ts`);
const m = (o: any) => ({ key: "a", name: "A", appearance: { color: "red" }, ...o });
const t = (members: any, extra: any = {}) => ({ format: "swarme.team", version: 2, team: { name: "T", members, ...extra } });
const room = (r: any) => ({ format: "swarme.team", version: 1, team: { name: "T", members: [{ key: " a ", name: "A", appearance: { color: "red" } }], room: { name: "R", ...r } } });
const many = (bad: boolean) => { const a = Array.from({ length: 201 }, (_, i) => m({ key: "k" + i })); if (bad) a[0] = m({ key: "BAD" }); return a; };
const manifests: any[] = [
  "hello", null, [], {}, true, 3, { format: "swarme.team" }, { format: "x", version: 2, team: {} }, { format: "x", version: 9 },
  { format: "swarme.team", version: "2" }, { format: "swarme.team", version: null }, { format: "swarme.team", version: 2 },
  { format: "swarme.team", version: 2, team: "x" }, { format: "swarme.team", version: 2, team: null }, { format: "swarme.team", version: 2, team: {} },
  { format: "swarme.team", version: 2, team: { name: 5, members: [m({})] } }, { format: "swarme.team", version: 2, team: { name: "  ﻿ ", members: [m({})] } },
  { format: "swarme.team", version: 2, team: { name: "x".repeat(101), members: "no" } }, { format: 1, version: 2, team: {} }, { format: "y", version: 1 },
  { format: "swarme.team", version: 2, team: { description: 5, members: 5, name: 1 } },
  t({}), t([]), t(["x"]), t([null]), t(many(false)), t(many(true)),
  t([m({ key: "A" })]), t([m({ key: "" })]), t([m({ key: 1 })]), t([m({ key: "a".repeat(65) })]), t([m({ key: "A".repeat(65) })]), t([m({ key: " ok_key-1 " })]),
  t([m({ name: undefined })]), t([m({ name: "😀".repeat(51) })]), t([m({ name: "😀".repeat(50) })]), t([m({ name: " " + "n".repeat(100) + " " })]),
  t([m({ title: 3 })]), t([m({ title: null })]), t([m({ title: "  " })]), t([m({ description: "x".repeat(8001) })]),
  t([m({ appearance: undefined })]), t([m({ appearance: [] })]), t([m({ appearance: { color: "black" } })]), t([m({ appearance: {} })]),
  t([m({ appearance: { color: null } })]), t([m({ appearance: { color: "red", mascotExpression: 1 } })]),
  t([m({ appearance: { color: "white", mascotExpression: " focused ", mascotSilhouette: "hexagon", mascotAvatarSvg: "  <?xml version='1.0'?><svg></svg>  " } })]),
  t([m({ appearance: { color: "red", mascotAvatarSvg: "<svg onload=x></svg>" } })]), t([m({ appearance: { color: "red", mascotSilhouette: "s".repeat(41) } })]),
  t([m({ name: "" }), m({ key: "B" })]), t([m({})], { description: "y".repeat(2001) }), t([m({})], { description: " Una squadra " }), t([m({}), m({})]),
  { format: "swarme.team", version: 1, team: { name: "T", members: [m({})] } },
  room({ defaultResponder: { kind: "x" } }), room({}), room({ defaultResponder: { kind: "member" } }), room({ defaultResponder: {} }),
  room({ defaultResponder: { kind: 5 } }), room({ defaultResponder: "x" }), room({ defaultResponder: null }),
  room({ defaultResponder: { kind: "member", member: " " } }), room({ defaultResponder: { kind: "member", member: "zz" } }),
  room({ defaultResponder: { kind: "member", member: " a " }, bulletin: null }), room({ defaultResponder: { kind: "everyone", member: "q" }, bulletin: " hi " }),
  room({ defaultResponder: { kind: "mentions" }, name: "" }),
  { format: "swarme.team", version: 1, team: { name: "T", members: [], room: "x" } },
  { format: "openmaus.team", version: 2, team: { name: "T", members: [m({ title: "  " })] } }, ["openmaus.team"],
  { format: "swarme.team", version: 2, team: { name: "Trap", members: [{ key: "mole", name: "Mole", appearance: { color: "red", extra: 1 }, id: "bot-1", autoApprove: true, alwaysAllow: ["Bash"], chiefOfStaff: true, composio: true, cwd: "/", modelSelection: { instanceId: "ghost" } }], room: { name: "x" } } },
];
const svgBase = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 135 135" fill="none">
<metadata xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:RDF /></metadata>
<mask id="viewboxMask"><rect width="135" height="135" fill="#fff" /></mask>
<g mask="url(#viewboxMask)"><use xlink:href="#part" /><path id="part" d="M0 0h1v1H0z" /></g>
</svg>`;
const svgs: string[] = [
  svgBase, `<?xml version="1.0"?>\n${svgBase}`, `<?XML version="1.0"?>${svgBase}`, `﻿ ${svgBase}\n `, `\u0085${svgBase}`,
  svgBase.replace("<mask", '<script>fetch("//x")</script><mask'), svgBase.replace("<svg ", '<svg onload="alert(1)" '),
  svgBase.replace("<svg ", '<svg\u000bonload="alert(1)" '), svgBase.replace("<svg ", '<svg ONLOAD = "x" '),
  svgBase.replace("<mask", "<foreignObject><b>hi</b></foreignObject><mask"), svgBase.replace("<mask", "< ForeignObject/><mask"),
  svgBase.replace('xlink:href="#part"', 'xlink:href="https://evil.com/x.svg"'), svgBase.replace('xlink:href="#part"', "HREF = 'data:x'"),
  svgBase.replace("url(#viewboxMask)", "url(https://evil.com/x.svg)"), svgBase.replace("url(#viewboxMask)", "URL( '#ok')"),
  svgBase.replace("url(#viewboxMask)", "url( \"x\")"), svgBase.replace("<metadata", '<image src="https://evil.com/x.png" /><metadata'),
  svgBase.replace("<metadata", '<image datasrc="x" /><metadata'), svgBase.replace("<metadata", '<image data-src="x" /><metadata'),
  svgBase.replace("<metadata", '<image ésrc="x" /><metadata'),
  `<!DOCTYPE svg [<!ENTITY x "y">]>${svgBase}`, svgBase.replace("<mask", "<!entity x><mask"), "<html><body>nope</body></html>", "", "   ", svgBase.slice(0, 200),
  svgBase.replace("<mask", "<scripté/><mask"), svgBase.replace("<mask", "<ſcript/><mask"), svgBase.replace("<mask", "<scripts/><mask"),
  svgBase.replace("<mask", "<script_x/><mask"), svgBase.replace("<mask", "<SCRIPT/><mask"), svgBase.replace("<mask", "< iframe/><mask"),
  svgBase.replace("<mask", "<style>@IMPORT 'x';</style><mask"), svgBase.replace("<mask", '<a href="javascript :x"/><mask'),
  svgBase.replace("<mask", '<a title="vbscript:"/><mask'), svgBase.replace("<mask", "<handlers/><mask"), svgBase.replace("<mask", "<metadata2/><mask"),
  svgBase.replace("</svg>", "</SVG>"), svgBase + "\n\t ", svgBase + "x", "<SVG></svg>", "<svg></svg>", `<?xml?>  <svg></svg>`,
  `<svg>${"x".repeat(64000)}</svg>`, ` <svg>${"x".repeat(63989)}</svg> `, `<svg>${"é".repeat(63989)}</svg>`,
  svgBase.replace("<svg ", "<svg on=\"x\" "), svgBase.replace("<svg ", "<svg xon=1 "), svgBase.replace("<svg ", "<svg\nonclick\n=\n1 "),
];
const urls = [
  "https://github.com/acme/team", " https://github.com/acme/team ", "https://www.github.com/acme/team/", "https://GitHub.com/acme/team",
  "HTTPS://github.com/acme/team", "https://github.com:443/acme/team", "https://github.com:8443/acme/team", "https://u@github.com/acme/team",
  "https://u:p@github.com/acme/team", "http://github.com/acme/team", "http://example.com/team.json", "nope", "", "github.com/acme/team",
  "https://github.com/acme/team/blob/main/presets/seo.mausteam.json", "https://github.com/acme/team/raw/v1/a/b.json",
  "https://github.com/acme/team/blob/main/run.sh", "https://github.com/acme/team/tree/main/x.json", "https://github.com/acme",
  "https://raw.githubusercontent.com/acme/team/main/team.mausteam.json", "https://raw.githubusercontent.com/acme/team/main",
  "https://raw.githubusercontent.com/acme/team/main/x.txt", "https://gitlab.com/acme/team", "https://github.com/acme/../team/x",
  "https://github.com/a%2F../b", "https://github.com/a%20b/c", "https://github.com/a b/c", "https://github.com/acme/team?x=1#y",
  "https://github.com/acme/te@m", "https://github.com/acme/team.git", "https://github.com/./acme/team", "https://github.com/acme/%2e%2e/team/x",
  "ftp://github.com/a/b", "https://github.com//acme//team",
];
const cat = { format: "swarme.catalog", version: 1, teams: [{ slug: "engineering", name: " Engineering Team ", summary: "Plan.", category: "Eng", manifest: "teams/engineering/team.mausteam.json", readme: "teams/engineering/README.md", members: 1, skills: ["teams/engineering/skills/release/SKILL.md"], requires: { apps: ["GitHub"] }, extra: true }] };
const e = (o: any) => ({ ...cat, teams: [{ ...cat.teams[0], ...o }] });
const catalogs: any[] = [cat, null, [], { ...cat, format: "openmaus.catalog" }, { ...cat, version: 2 }, { ...cat, teams: {} }, { ...cat, teams: Array(101).fill(0) },
  { ...cat, teams: [5] }, e({ slug: "Eng" }), e({ slug: "" }), { ...cat, teams: [cat.teams[0], cat.teams[0]] }, e({ manifest: "../private.json" }),
  e({ manifest: "teams/engineering//x.mausteam.json" }), e({ manifest: "teams/other/team.mausteam.json" }), e({ readme: "teams/engineering/readme.md" }),
  e({ members: 0 }), e({ members: 1.5 }), e({ members: 201 }), e({ members: "1" }), e({ skills: null }), e({ skills: ["teams/engineering/SKILL.md"] }),
  e({ requires: null }), e({ requires: { apps: null } }), e({ requires: { apps: "x" } }), e({ requires: { apps: [" "] } }), e({ name: "n".repeat(101) }),
  e({ summary: 5 }), e({ category: "" }), e({ manifest: "teams/engineering/a\\b.mausteam.json" })];
const run = (f: () => any) => { try { return { ok: JSON.stringify(f()) }; } catch (err: any) { return { error: err.message }; } };
const out = {
  manifests: manifests.map((v) => ({ input: JSON.stringify(v), ...run(() => parseTeamManifest(v)) })),
  svgs: svgs.filter((s) => s.length < 5000).map((s) => { const v = validateAvatarSvg(s); return { input: s, ...(v.ok ? { ok: v.svg } : { error: v.error }) }; }),
  urls: urls.map((u) => ({ input: u, ...run(() => githubManifestUrls(u)) })),
  catalogs: catalogs.map((v) => ({ input: JSON.stringify(v), ...run(() => parseTeamCatalog(v)) })),
};
console.log(JSON.stringify(out, null, 1));
