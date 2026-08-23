// Local Endpoint harness — OpenAI-compatible chat completions against
// whatever endpoint the user configured (LiteLLM, vLLM, llama.cpp, a hosted
// proxy). Catalog is that endpoint's /v1/models list, same inject ids Hermes
// uses; the URL and API key live in settings, not in a CLI login or the build.
//
// One endpoint is more than OpenAI-compatible: Hermes Agent's api_server keeps
// the conversation server-side and hands the caller a session id back. When we
// detect it (see probeHermesSession) the thread stops being replayed on every
// turn — see sendTurn.
import type {
  DriverCreateInput,
  ModelCatalog,
  ProviderDriver,
  ProviderInstance,
  ProviderSnapshot,
  RuntimeEvent,
  RuntimeEventListener,
  SendTurnInput,
} from "../contracts.ts";
import { newEventId, newId } from "../contracts.ts";
import { appendNative } from "./native.ts";
import {
  decodeInjectId,
  hostApiKey,
  LOCAL_ENDPOINT_API_KEY_ENV,
  localHost,
  mergeLocalInject,
} from "./local-inject.ts";

const DRIVER_KIND = "localEndpoint";
const HOST_ID = "local_endpoint";
const EMPTY: ModelCatalog = { default: "", options: [] };
const NO_ENDPOINT = "Set the Local Endpoint URL in Settings → Connections";
const NO_KEY = "Add a Local Endpoint API key in Settings → Connections";
/** Hermes' own header name. Read off /v1/capabilities rather than hardcoded at
 * the call site, so a rename upstream travels with the probe. */
const HERMES_SESSION_HEADER = "X-Hermes-Session-Id";
/** Generous next to the 1.2s the model probe allows itself, because that one
 * is aimed at loopback sidecars and this endpoint is routinely remote. It runs
 * alongside the model probe, so it costs the settings refresh nothing extra. */
const PROBE_TIMEOUT_MS = 5000;

/** An endpoint that answered, badly. The status is part of the contract, not
 * decoration: Hermes uses 403 to refuse a session continuation it cannot
 * honour, and sendTurn recovers from exactly that one. */
class EndpointError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/** What we know about this endpoint's ability to hold a conversation for us.
 *
 * "unknown" is the state that matters: a LiteLLM (or any other) proxy in front
 * of Hermes serves the OpenAI routes and 404s everything else, so a missing
 * /v1/capabilities is NOT evidence of a plain endpoint. Unknown resolves on the
 * first real turn instead — see sessionEcho. */
export type Continuity = { kind: "unknown" } | { kind: "session"; header: string } | { kind: "none" };

/** LiteLLM hands the upstream's own response headers back to the client under
 * this prefix, so Hermes' session id arrives as
 * `llm_provider-x-hermes-session-id` rather than under its own name. */
const PROXY_HEADER_PREFIX = "llm_provider-";

/** The session Hermes says served this turn, whether it answered us directly or
 * through a proxy that renamed its headers. Header lookup is case-insensitive,
 * so only the prefix has to be tried twice. */
function sessionEcho(headers: Headers, name: string): string | null {
  return headers.get(name) || headers.get(`${PROXY_HEADER_PREFIX}${name}`);
}

/** A session id Hermes will accept as a name for a conversation of ours.
 *
 * We always name it ourselves rather than let Hermes derive one, because its
 * derivation hashes only the system prompt plus the FIRST user message
 * (`_derive_chat_session_id`): two tasks on the same bot that open with the
 * same words would land in one session, and a rewound thread would keep
 * writing into the very branch it abandoned. Shaped to clear Hermes' own
 * guard — no separators, no `..`, no drive letter, far under its 256 chars. */
export const newHermesSessionId = () => `swarme-${newId()}`;

/** Ask /v1/capabilities what this endpoint is. The fast path: a Hermes we reach
 * directly settles the question before the first turn is ever sent.
 *
 * Everything that is not a clear yes stays "unknown" rather than becoming a
 * "no", because the two ways this route fails are indistinguishable from here —
 * a plain llama.cpp has no such route, and neither does a proxy that only
 * exposes /v1/chat/completions with a Hermes behind it. Only an endpoint that
 * answers and names itself something else is a verdict.
 *
 * `auth.required` has to be true: Hermes answers 403 to a continuation when it
 * has no API_SERVER_KEY of its own, and that is worth knowing before we rely on
 * one. A probe that gets no answer at all throws — a Local Endpoint is as often
 * across the internet as on loopback, and a blipped probe must not be read as a
 * verdict of any kind. */
export async function probeHermesSession(
  baseUrl: string,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Continuity> {
  const res = await fetchImpl(`${baseUrl.replace(/\/$/, "")}/capabilities`, {
    headers: { authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
  });
  if (!res.ok) return { kind: "unknown" };
  const json = (await res.json().catch(() => null)) as {
    platform?: unknown;
    auth?: { required?: unknown };
    features?: { session_continuity_header?: unknown };
  } | null;
  if (json === null) return { kind: "unknown" };
  if (json.platform !== "hermes-agent") return { kind: "none" };
  if (json.auth?.required !== true) return { kind: "none" };
  const header = json.features?.session_continuity_header;
  return { kind: "session", header: typeof header === "string" && header ? header : HERMES_SESSION_HEADER };
}

export const LocalEndpointDriver: ProviderDriver<Record<string, never>> = {
  driverKind: DRIVER_KIND,
  metadata: { displayName: "Local Endpoint", supportsMultipleInstances: true, access: "custom" },
  models: EMPTY,
  decodeConfig: () => ({}),
  defaultConfig: () => ({}),

  async create(input: DriverCreateInput<Record<string, never>>): Promise<ProviderInstance> {
    const { instanceId } = input;
    const env: Record<string, string | undefined> = { ...process.env, ...input.environment };
    // env first: the endpoint is a user setting the fleet injects here, so the
    // host must be resolved against THIS instance's env. It is undefined until
    // a URL is saved — create() must still succeed, or an unconfigured harness
    // would take the whole fleet down at startup instead of reporting itself
    // unavailable.
    const host = localHost(HOST_ID, env);
    const apiKey = host ? hostApiKey(host, env) : "";
    const hasKey = Boolean(env[LOCAL_ENDPOINT_API_KEY_ENV]);
    let models = EMPTY;
    // Unknown until the probe or the first turn settles it.
    let hermes: Continuity = { kind: "unknown" };
    const refreshModels = async () => {
      if (!host) return;
      // same guard mergeLocalInject uses: unit tests must not reach a network
      const vitest = env.VITEST ?? process.env.VITEST;
      const probe = env.SWARMEBOT_PROBE_LOCAL_INJECT ?? process.env.SWARMEBOT_PROBE_LOCAL_INJECT;
      const probing = vitest !== "true" || probe === "1";
      // side by side: this runs on every describe(), so the settings panel
      // waits for the slower of the two rather than for both in turn
      const [resolved, probed] = await Promise.all([
        mergeLocalInject(EMPTY, env, fetch, [HOST_ID]),
        probing ? probeHermesSession(host.baseUrl, apiKey, fetch).catch(() => undefined) : undefined,
      ]);
      if (resolved.options.length) models = resolved;
      // undefined is "the probe never got an answer" — keep what we know, so
      // one slow round trip does not cost every open task its session. An
      // inconclusive probe likewise must not undo what a real turn established.
      if (probed && (probed.kind !== "unknown" || hermes.kind === "unknown")) hermes = probed;
    };
    await refreshModels();

    const listeners = new Set<RuntimeEventListener>();
    const active = new Map<string, { abort: AbortController; turnId: string }>();

    const emit = (event: RuntimeEvent) => {
      for (const l of [...listeners]) l(event);
    };
    const base = (threadId: string, turnId: string) => ({
      eventId: newEventId(),
      provider: DRIVER_KIND,
      providerInstanceId: instanceId,
      threadId,
      turnId,
      createdAt: new Date().toISOString(),
    });

    const apiModel = (modelId: string | null | undefined) => decodeInjectId(modelId)?.model ?? modelId ?? "";

    const complete = async (
      messages: Array<{ role: string; content: string }>,
      model: string,
      opts: {
        stream: boolean;
        signal?: AbortSignal;
        onDelta?: (d: string) => void;
        /** Hermes only: continue this server-side conversation. */
        sessionId?: string | null;
      },
    ): Promise<{ text: string; usage: { input: number; output: number } | null; sessionId: string | null }> => {
      if (!host) throw new Error(NO_ENDPOINT);
      const headerName = hermes.kind === "session" ? hermes.header : HERMES_SESSION_HEADER;
      const headers = new Headers({ authorization: `Bearer ${apiKey}`, "content-type": "application/json" });
      if (opts.sessionId) headers.set(headerName, opts.sessionId);
      const res = await fetch(`${host.baseUrl}/chat/completions`, {
        method: "POST",
        headers,
        body: JSON.stringify({ model, messages, stream: opts.stream }),
        signal: opts.signal ?? AbortSignal.timeout(120_000),
      });
      // Hermes echoes the id of the session that served the turn — the proof
      // that our header survived whatever sits between us. It rides on the SSE
      // response too, so it is read off the headers before the body.
      const sessionId = sessionEcho(res.headers, headerName);
      if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new EndpointError(res.status, `Local Endpoint HTTP ${res.status}${body ? `: ${body.slice(0, 200)}` : ""}`);
      }
      if (!opts.stream) {
        const json: any = await res.json();
        return {
          text: json.choices?.[0]?.message?.content ?? "",
          usage: json.usage
            ? { input: json.usage.prompt_tokens ?? 0, output: json.usage.completion_tokens ?? 0 }
            : null,
          sessionId,
        };
      }
      let text = "";
      let usage: { input: number; output: number } | null = null;
      const reader = res.body!.getReader();
      const decoder = new TextDecoder();
      let buf = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let nl;
        while ((nl = buf.indexOf("\n")) !== -1) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (data === "[DONE]") continue;
          let chunk: any;
          try {
            chunk = JSON.parse(data);
          } catch {
            continue;
          }
          const delta = chunk.choices?.[0]?.delta?.content;
          if (delta) {
            text += delta;
            opts.onDelta?.(delta);
          }
          if (chunk.usage) {
            usage = { input: chunk.usage.prompt_tokens ?? 0, output: chunk.usage.completion_tokens ?? 0 };
          }
        }
      }
      return { text, usage, sessionId };
    };

    const sendTurn = async (turn: SendTurnInput) => {
      const { threadId } = turn;
      if (!host) throw new Error(NO_ENDPOINT);
      if (!hasKey) throw new Error(NO_KEY);
      if (active.has(threadId)) throw new Error("a turn is already running on this thread");
      const turnId = newId();
      const abort = new AbortController();
      active.set(threadId, { abort, turnId });
      const model = apiModel(turn.model) || apiModel(models.default);

      // The cursor the harness kept for THIS task — a new task starts with
      // none, so it opens a session of its own, and every later message in the
      // same chat rides that id.
      const cursor = typeof turn.resumeCursor === "string" && turn.resumeCursor ? turn.resumeCursor : null;
      // A "no" is the only state that sends nothing: while the answer is still
      // unknown the header goes out anyway, because it is the request itself
      // that settles the question and a header no one understands is ignored.
      const session = hermes.kind === "none" ? null : (cursor ?? newHermesSessionId());
      const replay = (turn.transcript ?? []).map((m) => ({
        role: m.role === "assistant" ? "assistant" : "user",
        content: m.text,
      }));
      const system = turn.system ? [{ role: "system", content: turn.system }] : [];
      const latest = { role: "user", content: turn.text };
      const full = [...system, ...replay, latest];
      // A confirmed Hermes keeps the transcript in its own state.db and discards
      // whatever the body carries, so replaying it would be paid for and thrown
      // away. The one case that needs history — a rewind or an engine switch,
      // which both open a fresh session — already arrives inlined in turn.text
      // by buildTurnContext, so nothing is lost by leaving the body bare.
      // While the endpoint is unproven the body stays full: it is wasted on a
      // Hermes, which drops it, and it is the whole conversation on anything
      // else, so full is the only choice that is right either way.
      const messages = hermes.kind === "session" ? [...system, latest] : full;
      appendNative(threadId, {
        dir: "out",
        source: "localEndpoint.chat.completions",
        msg: { model, session, messages },
      });

      emit({ ...base(threadId, turnId), type: "turn.started" });
      // The id is ours, so the harness can store it as this task's cursor
      // before the endpoint has said a word.
      emit({
        ...base(threadId, turnId),
        type: "session.started",
        sessionId: session,
        model: turn.model ?? models.default,
      });

      (async () => {
        try {
          const onDelta = (delta: string) =>
            emit({ ...base(threadId, turnId), type: "content.delta", streamKind: "assistant_text", delta });
          let result: Awaited<ReturnType<typeof complete>>;
          try {
            result = await complete(messages, model, {
              stream: true,
              signal: abort.signal,
              sessionId: session,
              onDelta,
            });
          } catch (e) {
            // Hermes refuses continuation with 403 once its API_SERVER_KEY goes
            // away after we probed. Stand the thread back up on this turn — a
            // full replay, no header — rather than fail the user's message, and
            // stop claiming continuity for this instance.
            if (session && e instanceof EndpointError && e.status === 403) {
              hermes = { kind: "none" };
              result = await complete(full, model, { stream: true, signal: abort.signal, onDelta });
            } else throw e;
          }
          const { text, usage } = result;
          // The proof is not that an id came back — it is that OUR id came
          // back. Hermes stamps a session id on every answer, and when it never
          // received a header it derives one from sha256(system + first user
          // message): a proxy that drops the header still returns a perfectly
          // healthy-looking `api-<hash>`. Trusting that echo is ruinous, and
          // silently so. We would store it, stop sending the transcript, and
          // hand Hermes a body whose first user message is now a different one
          // every turn — so it would derive a NEW empty session each time and
          // the bot would lose its memory completely, with nothing in the logs.
          // A mismatch therefore means exactly one thing: the header did not
          // survive the trip, and this thread has to keep replaying itself.
          const honoured = Boolean(result.sessionId) && result.sessionId === session;
          if (hermes.kind === "unknown") {
            hermes = honoured ? { kind: "session", header: HERMES_SESSION_HEADER } : { kind: "none" };
          } else if (hermes.kind === "session" && !honoured) {
            hermes = { kind: "none" };
          }
          appendNative(threadId, { dir: "in", source: "localEndpoint.chat.completions", msg: { text, usage } });
          if (text.trim()) {
            emit({ ...base(threadId, turnId), type: "item.completed", itemType: "assistant_text", text });
          }
          if (usage) {
            emit({ ...base(threadId, turnId), type: "thread.token-usage.updated", ...usage });
          }
          active.delete(threadId);
          emit({ ...base(threadId, turnId), type: "turn.completed", ok: true, stopReason: null, cost: null });
        } catch (e) {
          active.delete(threadId);
          const aborted = (e as Error).name === "AbortError";
          if (!aborted) {
            emit({ ...base(threadId, turnId), type: "runtime.error", message: (e as Error).message });
          }
          emit({
            ...base(threadId, turnId),
            type: "turn.completed",
            ok: false,
            stopReason: aborted ? "interrupted" : "error",
            cost: null,
          });
        }
      })();

      return { turnId };
    };

    const snapshot = async (): Promise<ProviderSnapshot> => {
      if (!host) return { state: "unavailable", reason: NO_ENDPOINT };
      if (!hasKey) return { state: "unavailable", reason: NO_KEY };
      return { state: "available", authenticated: true, version: null };
    };

    return {
      instanceId,
      driverKind: DRIVER_KIND,
      displayName: input.displayName,
      enabled: input.enabled,
      get models() {
        return models;
      },
      refreshModels,
      snapshot,
      adapter: {
        provider: DRIVER_KIND,
        capabilities: { sessionModelSwitch: "in-session" },
        sendTurn,
        interruptTurn: async (threadId) => active.get(threadId)?.abort.abort(),
        respondToRequest: async () => "unavailable" as const,
        hasSession: (threadId) => active.has(threadId),
        stopAll: async () => {
          for (const { abort } of active.values()) abort.abort();
        },
        onEvent: (listener) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
      },
      generateText: async (prompt: string) => {
        const model = apiModel(models.default) || apiModel(models.options[0]?.id);
        const { text } = await complete([{ role: "user", content: prompt }], model, { stream: false });
        return text;
      },
      dispose: async () => {
        for (const { abort } of active.values()) abort.abort();
        listeners.clear();
      },
    };
  },
};
