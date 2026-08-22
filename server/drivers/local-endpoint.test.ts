import { describe, expect, it } from "vitest";

import { encodeInjectId, hostBaseUrl, LOCAL_HOSTS, localHost, normalizeGatewayBaseUrl } from "./local-inject.ts";
import { LocalEndpointDriver } from "./local-endpoint.ts";

describe("LocalEndpointDriver", () => {
  it("is a custom-only Local Endpoint harness", () => {
    expect(LocalEndpointDriver.driverKind).toBe("localEndpoint");
    expect(LocalEndpointDriver.metadata).toMatchObject({ displayName: "Local Endpoint", access: "custom" });
  });

  it("creates without throwing and asks for a URL when none is configured", async () => {
    // an unconfigured harness must report itself, not take the fleet down
    const instance = await LocalEndpointDriver.create({
      instanceId: "localEndpoint",
      displayName: "Local Endpoint",
      enabled: true,
      environment: { LOCAL_ENDPOINT_AUTH_KEY: "hextra-secret" },
      config: {},
    });
    expect(await instance.snapshot()).toMatchObject({
      state: "unavailable",
      reason: expect.stringMatching(/URL in Settings/),
    });
    expect(instance.models.options).toEqual([]);
  });

  it("stays unavailable until a settings key is injected", async () => {
    const instance = await LocalEndpointDriver.create({
      instanceId: "localEndpoint",
      displayName: "Local Endpoint",
      enabled: true,
      environment: { LOCAL_ENDPOINT_BASE_URL: "https://llm.example.com/v1" },
      config: {},
    });
    expect(await instance.snapshot()).toMatchObject({
      state: "unavailable",
      reason: expect.stringMatching(/key in Settings/),
    });
  });

  it("lists only local_endpoint inject models", async () => {
    const previous = process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    process.env.SWARMEBOT_PROBE_LOCAL_INJECT = "1";
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input) => {
      const url = String(input);
      if (url === "https://llm.example.com/v1/models") {
        return new Response(JSON.stringify({ data: [{ id: "gpt-4o-mini" }, { id: "claude-sonnet" }] }), {
          status: 200,
        });
      }
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
    try {
      const instance = await LocalEndpointDriver.create({
        instanceId: "localEndpoint",
        displayName: "Local Endpoint",
        enabled: true,
        environment: {
          LOCAL_ENDPOINT_AUTH_KEY: "hextra-secret",
          LOCAL_ENDPOINT_BASE_URL: "https://llm.example.com/v1",
        },
        config: {},
      });
      expect(await instance.snapshot()).toMatchObject({ state: "available", authenticated: true });
      expect(instance.models.options.map((option) => option.id).sort()).toEqual([
        encodeInjectId("local_endpoint", "claude-sonnet"),
        encodeInjectId("local_endpoint", "gpt-4o-mini"),
      ]);
      expect(instance.models.options.every((option) => option.custom)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
      if (previous === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previous;
    }
  });

  it("probes nothing at all while the endpoint is unset", async () => {
    const previous = process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    process.env.SWARMEBOT_PROBE_LOCAL_INJECT = "1";
    const originalFetch = globalThis.fetch;
    const seen: string[] = [];
    globalThis.fetch = (async (input) => {
      seen.push(String(input));
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
    try {
      const instance = await LocalEndpointDriver.create({
        instanceId: "localEndpoint",
        displayName: "Local Endpoint",
        enabled: true,
        environment: { LOCAL_ENDPOINT_AUTH_KEY: "hextra-secret" },
        config: {},
      });
      expect(instance.models.options).toEqual([]);
      expect(seen).toEqual([]);
    } finally {
      globalThis.fetch = originalFetch;
      if (previous === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previous;
    }
  });

  it("talks to the endpoint the workspace configured", async () => {
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
      const instance = await LocalEndpointDriver.create({
        instanceId: "localEndpoint",
        displayName: "Local Endpoint",
        enabled: true,
        environment: {
          LOCAL_ENDPOINT_AUTH_KEY: "hextra-secret",
          LOCAL_ENDPOINT_BASE_URL: "https://llm.example.com/v1",
        },
        config: {},
      });
      expect(instance.models.options.map((option) => option.id)).toEqual([
        encodeInjectId("local_endpoint", "gpt-4o-mini"),
      ]);
      // the configured endpoint is the only host contacted — nothing else
      expect(seen).toEqual(["https://llm.example.com/v1/models"]);
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
    const env = { LOCAL_ENDPOINT_BASE_URL: "https://llm.example.com" };
    expect(localHost("local_endpoint", env)!.baseUrl).toBe("https://llm.example.com/v1");
    expect(localHost("ollama", env)!.baseUrl).toBe("http://127.0.0.1:11434/v1");
    // a junk setting reads as unconfigured rather than as a URL
    const host = LOCAL_HOSTS.find((row) => row.id === "local_endpoint")!;
    expect(hostBaseUrl(host, { LOCAL_ENDPOINT_BASE_URL: "junk" })).toBe("");
    expect(hostBaseUrl(host, {})).toBe("");
  });
});
