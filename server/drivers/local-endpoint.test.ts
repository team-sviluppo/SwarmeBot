import { describe, expect, it } from "vitest";

import { encodeInjectId, hostBaseUrl, localHost, normalizeGatewayBaseUrl } from "./local-inject.ts";
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

  it("talks to the endpoint the workspace configured, not the shipped one", async () => {
    const previous = process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    process.env.SWARMEBOT_PROBE_LOCAL_INJECT = "1";
    const originalFetch = globalThis.fetch;
    const seen: string[] = [];
    globalThis.fetch = (async (input) => {
      const url = String(input);
      seen.push(url);
      if (url === "https://llm.example.com/v1/models") {
        return new Response(JSON.stringify({ data: [{ id: "gpt-4o-mini" }] }), { status: 200 });
      }
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
    try {
      const instance = await LitellmDriver.create({
        instanceId: "litellm",
        displayName: "Litellm",
        enabled: true,
        environment: {
          LITELLMHEXTRA_AUTH_KEY: "hextra-secret",
          LITELLMHEXTRA_BASE_URL: "https://llm.example.com/v1",
        },
        config: {},
      });
      expect(instance.models.options.map((option) => option.id)).toEqual([
        encodeInjectId("litellm_hextra", "gpt-4o-mini"),
      ]);
      expect(seen.some((url) => url.includes("litellm.hextra.it"))).toBe(false);
    } finally {
      globalThis.fetch = originalFetch;
      if (previous === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previous;
    }
  });
});

describe("gateway endpoint overrides", () => {
  it("accepts what a user pastes and rejects what cannot be a gateway", () => {
    expect(normalizeGatewayBaseUrl("https://llm.example.com")).toBe("https://llm.example.com/v1");
    expect(normalizeGatewayBaseUrl(" https://llm.example.com/v1/ ")).toBe("https://llm.example.com/v1");
    expect(normalizeGatewayBaseUrl("http://127.0.0.1:4000/openai/v1")).toBe("http://127.0.0.1:4000/openai/v1");
    expect(normalizeGatewayBaseUrl("")).toBeNull();
    expect(normalizeGatewayBaseUrl("llm.example.com")).toBeNull();
    expect(normalizeGatewayBaseUrl("file:///etc/passwd")).toBeNull();
  });

  it("overrides only hosts that declare a baseUrlEnv", () => {
    const env = { LITELLMHEXTRA_BASE_URL: "https://llm.example.com" };
    expect(localHost("litellm_hextra", env)!.baseUrl).toBe("https://llm.example.com/v1");
    expect(localHost("ollama", env)!.baseUrl).toBe("http://127.0.0.1:11434/v1");
    // a junk setting falls back rather than breaking the harness
    expect(hostBaseUrl(localHost("litellm_hextra", {})!, { LITELLMHEXTRA_BASE_URL: "junk" })).toBe(
      "https://litellm.hextra.it/v1",
    );
  });
});
