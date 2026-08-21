import { describe, expect, it } from "vitest";

import { isPickerHarness, splitEngineRail } from "./engine-rail";

describe("splitEngineRail", () => {
  it("keeps Cloud engines above Local engines", () => {
    const { subscription, custom } = splitEngineRail([
      { access: "subscription", instanceId: "claude" },
      { access: "custom", instanceId: "hermes" },
      { instanceId: "grok" },
      { access: "custom", instanceId: "qwen" },
    ]);
    expect(subscription.map((row) => row.instanceId)).toEqual(["claude", "grok"]);
    expect(custom.map((row) => row.instanceId)).toEqual(["hermes", "qwen"]);
  });

  it("hides the second group when nothing is custom-only", () => {
    const rows = [{ instanceId: "claude" }];
    expect(splitEngineRail(rows).custom).toEqual([]);
  });

  it("keeps Claude/Codex/Gemini off the hidden picker set", () => {
    expect(isPickerHarness({ driverKind: "claude" })).toBe(true);
    expect(isPickerHarness({ driverKind: "codex" })).toBe(true);
    expect(isPickerHarness({ driverKind: "geminiAgent" })).toBe(true);
    expect(isPickerHarness({ driverKind: "cursorAgent" })).toBe(true);
    expect(isPickerHarness({ driverKind: "litellm" })).toBe(true);
  });

  it("hides Grok, Kimi, Droid, Antigravity, OpenCode Go, Qwen, Hermes, and Pi from the picker rail", () => {
    for (const driverKind of [
      "grok",
      "grokAgent",
      "kimiAgent",
      "droidAgent",
      "antigravityAgent",
      "opencodeGo",
      "qwenAgent",
      "hermesAgent",
      "piAgent",
    ]) {
      expect(isPickerHarness({ driverKind })).toBe(false);
    }
  });
});
