import { describe, expect, it } from "vitest";

import { parseSession, sha256 } from "./index";

describe("connected-apps broker boundaries", () => {
  it("accepts only HTTPS Composio MCP endpoints", () => {
    expect(parseSession({
      session_id: "session-1",
      mcp: { url: "https://mcp.composio.dev/session", headers: { "x-session": "one", host: "bad" } },
    })).toEqual({
      sessionId: "session-1",
      url: "https://mcp.composio.dev/session",
      headers: { "x-session": "one" },
    });
    expect(() => parseSession({ session_id: "session-1", mcp: { url: "https://attacker.example/mcp" } })).toThrow(/untrusted/i);
    expect(() => parseSession({ session_id: "session-1", mcp: { url: "http://mcp.composio.dev/session" } })).toThrow(/untrusted/i);
  });

  it("hashes installation tokens before storage", async () => {
    await expect(sha256("swarmebot")).resolves.toBe("01f7eb6f3d1cf55340eacde9d1f777d12244b494ad7fa12e73b03e846a1198c0");
  });
});
