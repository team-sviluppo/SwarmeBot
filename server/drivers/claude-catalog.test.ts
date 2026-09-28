import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { ClaudeDriver, readClaudeModelCatalog, readLatestClaudeModelsFromBinary, STATIC_CLAUDE_MODELS } from "./claude.ts";

const scratchDirs: string[] = [];

afterEach(() => {
  for (const dir of scratchDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("readClaudeModelCatalog", () => {
  it("returns the official four when settings are missing", () => {
    expect(readClaudeModelCatalog({ HOME: join(tmpdir(), "omb-claude-missing-home") })).toEqual(STATIC_CLAUDE_MODELS);
  });

  it("tags extra settings models as custom and leaves official rows untagged", () => {
    const home = mkdtempSync(join(tmpdir(), "omb-claude-catalog-"));
    scratchDirs.push(home);
    const dir = join(home, ".claude");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "settings.json"),
      JSON.stringify({
        model: "claude-sonnet-5",
        availableModels: [{ id: "my-local-opus", name: "Local Opus" }],
        env: { ANTHROPIC_MODEL: "hosted-qwen" },
      }),
    );

    expect(readClaudeModelCatalog({ HOME: home })).toEqual({
      default: "claude-sonnet-5",
      options: [
        ...STATIC_CLAUDE_MODELS.options,
        { id: "my-local-opus", label: "Local Opus", custom: true },
        { id: "hosted-qwen", label: "hosted-qwen", custom: true },
      ],
    });
  });

  it("preserves exact effort levels from configured extra models", () => {
    const home = mkdtempSync(join(tmpdir(), "omb-claude-effort-catalog-"));
    scratchDirs.push(home);
    const dir = join(home, ".claude");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "settings.json"),
      JSON.stringify({
        availableModels: [{ id: "claude-exact-low", label: "Claude exact low", effortLevels: ["low"] }],
      }),
    );

    expect(readClaudeModelCatalog({ HOME: home }).options).toContainEqual({
      id: "claude-exact-low",
      label: "Claude exact low",
      custom: true,
      effortLevels: ["low"],
    });
  });
});

describe("readLatestClaudeModelsFromBinary", () => {
  it("keeps only the newest id of each family from the CLI catalog block", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-claude-bin-"));
    scratchDirs.push(dir);
    const binary = join(dir, "claude");
    writeFileSync(
      binary,
      'noise FABLE_ID:"claude-fable-5-1",FABLE_NAME:"Claude Fable 5.1",PREV_FABLE_ID:"claude-fable-5",PREV_FABLE_NAME:"Claude Fable 5",OPUS_ID:"claude-opus-5",OPUS_NAME:"Claude Opus 5",OPUS_NEXT_ID:"claude-opus-5-5",OPUS_NEXT_NAME:"Claude Opus 5.5",PREV_OPUS_ID:"claude-opus-4-8",PREV_OPUS_NAME:"Claude Opus 4.8",SONNET_ID:"claude-sonnet-5",SONNET_NAME:"Claude Sonnet 5",SONNET_NEXT_ID:"claude-sonnet-5",SONNET_NEXT_NAME:"Claude Sonnet 5",HAIKU_ID:"claude-haiku-4-5",HAIKU_NAME:"Claude Haiku 4.5",PREV_SONNET_ID:"claude-sonnet-4-6"',
    );
    expect(readLatestClaudeModelsFromBinary(binary)).toEqual([
      { id: "claude-fable-5-1", label: "Claude Fable 5.1" },
      { id: "claude-opus-5-5", label: "Claude Opus 5.5" },
      { id: "claude-sonnet-5", label: "Claude Sonnet 5" },
      { id: "claude-haiku-4-5", label: "Claude Haiku 4.5" },
    ]);
  });
});

describe("ClaudeDriver catalog", () => {
  it("loads extras when the instance is created", async () => {
    const home = mkdtempSync(join(tmpdir(), "omb-claude-instance-"));
    scratchDirs.push(home);
    const dir = join(home, ".claude");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ customModels: ["local-glm"] }));
    const instance = await ClaudeDriver.create({
      instanceId: "claude-catalog",
      displayName: "Claude",
      environment: { HOME: home },
      enabled: true,
      config: ClaudeDriver.defaultConfig(),
    });
    try {
      expect(instance.models.options.some((option) => option.id === "local-glm" && option.custom)).toBe(true);
      expect(instance.refreshModels).toEqual(expect.any(Function));
    } finally {
      await instance.dispose();
    }
  });
});
