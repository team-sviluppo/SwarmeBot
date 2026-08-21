import { describe, expect, it } from "vitest";

import { encodeInjectId } from "./local-inject.ts";
import { LitellmDriver } from "./litellm.ts";

describe("LitellmDriver", () => {
  it("is a custom-only Litellm harness", () => {
    expect(LitellmDriver.driverKind).toBe("litellm");
    expect(LitellmDriver.metadata).toMatchObject({ displayName: "Litellm", access: "custom" });
  });

  it("stays unavailable until a settings key is injected", async () => {
    const instance = await LitellmDriver.create({
      instanceId: "litellm",
      displayName: "Litellm",
      enabled: true,
      environment: {},
      config: {},
    });
    expect(await instance.snapshot()).toMatchObject({
      state: "unavailable",
      reason: expect.stringMatching(/Settings/),
    });
  });

  it("lists only litellm_hextra inject models", async () => {
    const previous = process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    process.env.SWARMEBOT_PROBE_LOCAL_INJECT = "1";
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input) => {
      const url = String(input);
      if (url.includes("litellm.hextra.it") && url.endsWith("/models")) {
        return new Response(JSON.stringify({ data: [{ id: "gpt-4o-mini" }, { id: "claude-sonnet" }] }), {
          status: 200,
        });
      }
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
    try {
      const instance = await LitellmDriver.create({
        instanceId: "litellm",
        displayName: "Litellm",
        enabled: true,
        environment: { LITELLMHEXTRA_AUTH_KEY: "hextra-secret" },
        config: {},
      });
      expect(await instance.snapshot()).toMatchObject({ state: "available", authenticated: true });
      expect(instance.models.options.map((option) => option.id).sort()).toEqual([
        encodeInjectId("litellm_hextra", "claude-sonnet"),
        encodeInjectId("litellm_hextra", "gpt-4o-mini"),
      ]);
      expect(instance.models.options.every((option) => option.custom)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
      if (previous === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previous;
    }
  });
});
