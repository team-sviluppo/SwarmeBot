import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";

let home: string;

afterEach(() => {
  vi.unstubAllEnvs();
  if (home) rmSync(home, { recursive: true, force: true });
});

describe("conversation Markdown", () => {
  it("keeps only visible text, dropping tools and cards", async () => {
    home = mkdtempSync(join(tmpdir(), "omb-md-"));
    vi.stubEnv("HOME", home);
    vi.stubEnv("USERPROFILE", home);
    vi.resetModules();
    const { conversationMarkdown } = await import("./transcript-export.ts");
    const md = conversationMarkdown(
      "Payroll",
      [
        { id: "1", role: "user", kind: "text", text: "Look at payroll", at: 1 },
        { id: "2", role: "bot", kind: "activity", tool: { name: "Bash" }, at: 2 },
        { id: "3", role: "bot", kind: "text", text: "Looks fine.", at: 3 },
        { id: "4", role: "bot", kind: "options", card: { title: "Pick", subtitle: "", options: ["a"] }, at: 4 },
      ],
      { userName: "Cris", botName: "Mira" },
    );
    expect(md).toContain("# Payroll");
    expect(md).toContain("**Cris:**");
    expect(md).toContain("Look at payroll");
    expect(md).toContain("**Mira:**");
    expect(md).toContain("Looks fine.");
    expect(md).not.toContain("Bash");
    expect(md).not.toContain("Pick");
  });

  it("writes pinned tasks under ~/.swarmebot/bots/<name>/", async () => {
    home = mkdtempSync(join(tmpdir(), "omb-md-"));
    vi.stubEnv("HOME", home);
    vi.stubEnv("USERPROFILE", home);
    vi.resetModules();
    const { archivePinnedTasks } = await import("./transcript-export.ts");
    const { DATA_DIR } = await import("./config.ts");
    mkdirSync(DATA_DIR, { recursive: true });
    const dir = archivePinnedTasks({
      botName: "Mira!",
      userName: "User",
      tasks: [
        { title: "Keep me", pinned: true, threadId: "aaaa1111bbbb" },
        { title: "Skip", threadId: "cccc" },
      ],
      messagesFor: (id) =>
        id === "aaaa1111bbbb"
          ? [{ id: "m", role: "user", kind: "text", text: "saved", at: 1 }]
          : [],
    });
    expect(dir).toBe(join(DATA_DIR, "bots", "Mira"));
    const file = join(dir!, "Keep me.md");
    expect(existsSync(file)).toBe(true);
    expect(readFileSync(file, "utf8")).toContain("saved");
  });
});
