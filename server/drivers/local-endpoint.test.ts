import { afterEach, beforeEach, describe, expect, it } from "vitest";

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
      expect([...new Set(seen)].sort()).toEqual([
        "https://llm.example.com/v1/capabilities",
        "https://llm.example.com/v1/models",
      ]);
    } finally {
      globalThis.fetch = originalFetch;
      if (previous === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previous;
    }
  });
});

describe("Hermes Agent session continuity", () => {
  const BASE = "https://hermes.example.com/v1";
  const CAPABILITIES = {
    object: "hermes.api_server.capabilities",
    platform: "hermes-agent",
    auth: { type: "bearer", required: true },
    features: { session_continuity_header: "X-Hermes-Session-Id" },
  };

  /** Stand up a Hermes-shaped endpoint and record every chat/completions call.
   *
   * `capabilities` and `echo` move independently on purpose: /v1/capabilities
   * tells us what the endpoint claims to be, the echoed session header is what
   * the backend actually did, and a proxy in front can break either one without
   * touching the other. "proxied" echoes under LiteLLM's renamed header. */
  async function hermesInstance(
    capabilities: unknown = CAPABILITIES,
    echo: "direct" | "proxied" | "none" = "direct",
  ) {
    const calls: Array<{ messages: Array<{ role: string; content: string }>; session: string | null }> = [];
    // real Hermes echoes back the session that served the turn; an override
    // stands in for the rare case where it answers on a different one
    let replySession: string | null = null;
    // Hermes 403s a continuation when it has no API_SERVER_KEY — the header
    // is what it rejects, so the flag keys off the header, not a call count.
    let refuseContinuation = false;
    let probeBroken = false;
    globalThis.fetch = (async (input, init) => {
      const url = String(input);
      if (url === `${BASE}/models`) {
        return new Response(JSON.stringify({ data: [{ id: "hermes-4" }] }), { status: 200 });
      }
      if (url === `${BASE}/capabilities`) {
        if (probeBroken) throw new TypeError("fetch failed");
        return capabilities === null
          ? new Response("nope", { status: 404 })
          : new Response(JSON.stringify(capabilities), { status: 200 });
      }
      if (url === `${BASE}/chat/completions`) {
        const headers = new Headers(init?.headers as Record<string, string>);
        const session = headers.get("X-Hermes-Session-Id");
        calls.push({ messages: JSON.parse(String(init?.body)).messages, session });
        if (session && refuseContinuation) return new Response("Session continuation requires API key", { status: 403 });
        const frames = [
          `data: ${JSON.stringify({ choices: [{ delta: { content: "ok" } }] })}\n`,
          "data: [DONE]\n",
        ].join("");
        if (echo === "none") return new Response(frames, { status: 200 });
        const served = replySession ?? session ?? "api-derived";
        const name = echo === "proxied" ? "llm_provider-x-hermes-session-id" : "X-Hermes-Session-Id";
        return new Response(frames, { status: 200, headers: { [name]: served } });
      }
      return new Response("nope", { status: 404 });
    }) as typeof fetch;
    const instance = await LocalEndpointDriver.create({
      instanceId: "localEndpoint",
      displayName: "Local Endpoint",
      enabled: true,
      environment: { LOCAL_ENDPOINT_AUTH_KEY: "hextra-secret", LOCAL_ENDPOINT_BASE_URL: BASE },
      config: {},
    });
    return {
      instance,
      calls,
      setReplySession: (id: string) => (replySession = id),
      refuseContinuation: () => (refuseContinuation = true),
      breakProbe: () => (probeBroken = true),
    };
  }

  /** Drive one turn to completion — sendTurn returns before the stream ends. */
  function runTurn(instance: Awaited<ReturnType<typeof LocalEndpointDriver.create>>, turn: any) {
    const sessions: Array<string | null> = [];
    const done = new Promise<void>((resolve) => {
      const off = instance.adapter.onEvent((event) => {
        if (event.type === "session.started") sessions.push(event.sessionId);
        if (event.type === "turn.completed") {
          off();
          resolve();
        }
      });
    });
    return instance.adapter.sendTurn(turn).then(() => done).then(() => sessions);
  }

  let originalFetch: typeof fetch;
  let previousProbe: string | undefined;
  beforeEach(() => {
    originalFetch = globalThis.fetch;
    previousProbe = process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    process.env.SWARMEBOT_PROBE_LOCAL_INJECT = "1";
  });
  afterEach(() => {
    globalThis.fetch = originalFetch;
    if (previousProbe === undefined) delete process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
    else process.env.SWARMEBOT_PROBE_LOCAL_INJECT = previousProbe;
  });

  it("names a session of its own for a task that has no cursor yet", async () => {
    const { instance, calls } = await hermesInstance();
    const opened: string[] = [];
    for (const threadId of ["task-1", "task-2"]) {
      // both tasks open with the same persona and the same words — Hermes'
      // own sha256(system + first user) derivation would collide them
      const sessions = await runTurn(instance, { threadId, text: "ciao", system: "You are Bot" });
      const session = calls.at(-1)!.session!;
      expect(session).toMatch(/^swarme-/);
      // and it is announced up front, so the harness can store it as the cursor
      expect(sessions).toEqual([session]);
      opened.push(session);
    }
    expect(opened[0]).not.toBe(opened[1]);
  });

  it("sends only the latest message once it holds the session id", async () => {
    const { instance, calls } = await hermesInstance();
    const sessions = await runTurn(instance, {
      threadId: "task-1",
      text: "third question",
      system: "You are Bot",
      resumeCursor: "swarme-known",
      transcript: [{ role: "user", text: "first" }, { role: "assistant", text: "answer" }],
    });
    expect(calls[0]!.session).toBe("swarme-known");
    // history lives in Hermes' state.db — replaying it would be paid for twice
    expect(calls[0]!.messages.map((m) => m.content)).toEqual(["You are Bot", "third question"]);
    // no correction event: the server served the session we asked for
    expect(sessions).toEqual(["swarme-known"]);
  });

  it("refuses a session it did not name, however healthy the echo looks", async () => {
    // The real shape of a proxy that drops the request header: Hermes never
    // saw ours, so it derived `api-<sha256(system + first user)>` and stamped
    // that on the answer. Verified live against LiteLLM 2026-08-23.
    const { instance, calls, setReplySession } = await hermesInstance(null, "proxied");
    setReplySession("api-018e81eb9112136a");
    await runTurn(instance, { threadId: "task-1", text: "ciao", system: "You are Bot" });
    expect(calls[0]!.session).toMatch(/^swarme-/);

    // Believing that echo is ruinous: the driver would stop sending the
    // transcript, and each turn's body would start with a different first
    // user message — a brand-new empty session every time, memory silently
    // gone. So the mismatch has to settle the question the other way.
    await runTurn(instance, {
      threadId: "task-1",
      text: "second",
      system: "You are Bot",
      transcript: [{ role: "user", text: "ciao" }, { role: "assistant", text: "ok" }],
    });
    expect(calls[1]!.session).toBeNull();
    expect(calls[1]!.messages.map((m) => m.content)).toEqual(["You are Bot", "ciao", "ok", "second"]);
  });

  it("replays the thread instead of failing when continuation is refused", async () => {
    const { instance, calls, refuseContinuation } = await hermesInstance();
    refuseContinuation();
    const turn = {
      threadId: "task-1",
      text: "next",
      system: "You are Bot",
      resumeCursor: "swarme-known",
      transcript: [{ role: "user", text: "first" }],
    };
    // Hermes lost its API_SERVER_KEY: the header attempt 403s, and the retry
    // carries the whole branch with no header at all
    await runTurn(instance, turn);
    expect(calls.map((c) => c.session)).toEqual(["swarme-known", null]);
    expect(calls[1]!.messages.map((m) => m.content)).toEqual(["You are Bot", "first", "next"]);
    // and continuity is given up for good — the next turn replays too
    const after = await runTurn(instance, { ...turn, threadId: "task-2" });
    expect(calls[2]!.session).toBeNull();
    expect(calls[2]!.messages).toHaveLength(3);
    expect(after).toEqual([null]);
  });

  it("keeps the session alive when a refresh cannot reach the endpoint", async () => {
    const { instance, calls, breakProbe } = await hermesInstance();
    // a Local Endpoint is as often remote as on loopback: one blipped probe
    // must not silently drop every open task back to full-transcript replay
    breakProbe();
    await instance.refreshModels?.();
    await runTurn(instance, {
      threadId: "task-1",
      text: "next",
      resumeCursor: "swarme-known",
      transcript: [{ role: "user", text: "first" }],
    });
    expect(calls[0]!.session).toBe("swarme-known");
    expect(calls[0]!.messages.map((m) => m.content)).toEqual(["next"]);
  });

  it("stays stateless against an endpoint that says it is not a Hermes with a key", async () => {
    for (const capabilities of [{ platform: "litellm" }, { ...CAPABILITIES, auth: { required: false } }]) {
      // it said no, and its backend behaves accordingly: nothing echoed back
      const { instance, calls } = await hermesInstance(capabilities, "none");
      const sessions = await runTurn(instance, {
        threadId: "task-1",
        text: "next",
        resumeCursor: "swarme-known",
        transcript: [{ role: "user", text: "first" }],
      });
      // a cursor from a previous Hermes must not leak into a plain endpoint
      expect(calls[0]!.session).toBeNull();
      expect(calls[0]!.messages.map((m) => m.content)).toEqual(["first", "next"]);
      expect(sessions).toEqual([null]);
    }
  });

  it("finds the session through a proxy that hides /v1/capabilities", async () => {
    // LiteLLM in front of Hermes: it serves the OpenAI routes and 404s the
    // rest, so detection has to come off the first real turn instead
    const { instance, calls } = await hermesInstance(null, "proxied");
    const opening = await runTurn(instance, { threadId: "task-1", text: "first", system: "You are Bot" });
    // unproven, so the header goes out on spec and the body stays complete
    expect(calls[0]!.session).toMatch(/^swarme-/);
    expect(calls[0]!.messages.map((m) => m.content)).toEqual(["You are Bot", "first"]);
    // the echo came back under LiteLLM's renamed header — that is the proof
    expect(opening).toEqual([calls[0]!.session]);

    const next = await runTurn(instance, {
      threadId: "task-1",
      text: "second",
      system: "You are Bot",
      resumeCursor: calls[0]!.session,
      transcript: [{ role: "user", text: "first" }, { role: "assistant", text: "ok" }],
    });
    // now proven: the transcript stops going over the wire
    expect(calls[1]!.session).toBe(calls[0]!.session);
    expect(calls[1]!.messages.map((m) => m.content)).toEqual(["You are Bot", "second"]);
    expect(next).toEqual([calls[0]!.session]);
  });

  it("gives up on continuity when an unproven endpoint echoes nothing back", async () => {
    const { instance, calls } = await hermesInstance(null, "none");
    // a plain llama.cpp behind a proxy: no capabilities route AND no echo
    const opening = await runTurn(instance, { threadId: "task-1", text: "first" });
    expect(calls[0]!.session).toMatch(/^swarme-/);
    expect(opening).toEqual([calls[0]!.session]);

    await runTurn(instance, {
      threadId: "task-1",
      text: "second",
      transcript: [{ role: "user", text: "first" }, { role: "assistant", text: "ok" }],
    });
    // settled: no header, and the thread is replayed in full as before
    expect(calls[1]!.session).toBeNull();
    expect(calls[1]!.messages.map((m) => m.content)).toEqual(["first", "ok", "second"]);
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
