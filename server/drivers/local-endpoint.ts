// Local Endpoint harness — OpenAI-compatible chat completions against
// whatever endpoint the user configured (LiteLLM, vLLM, llama.cpp, a hosted
// proxy). Catalog is that endpoint's /v1/models list, same inject ids Hermes
// uses; the URL and API key live in settings, not in a CLI login or the build.
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
    const refreshModels = async () => {
      if (!host) return;
      const resolved = await mergeLocalInject(EMPTY, env, fetch, [HOST_ID]);
      if (resolved.options.length) models = resolved;
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
      opts: { stream: boolean; signal?: AbortSignal; onDelta?: (d: string) => void },
    ): Promise<{ text: string; usage: { input: number; output: number } | null }> => {
      if (!host) throw new Error(NO_ENDPOINT);
      const res = await fetch(`${host.baseUrl}/chat/completions`, {
        method: "POST",
        headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ model, messages, stream: opts.stream }),
        signal: opts.signal ?? AbortSignal.timeout(120_000),
      });
      if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new Error(`Local Endpoint HTTP ${res.status}${body ? `: ${body.slice(0, 200)}` : ""}`);
      }
      if (!opts.stream) {
        const json: any = await res.json();
        return {
          text: json.choices?.[0]?.message?.content ?? "",
          usage: json.usage
            ? { input: json.usage.prompt_tokens ?? 0, output: json.usage.completion_tokens ?? 0 }
            : null,
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
      return { text, usage };
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

      const messages = [
        ...(turn.system ? [{ role: "system", content: turn.system }] : []),
        ...(turn.transcript ?? []).map((m) => ({
          role: m.role === "assistant" ? "assistant" : "user",
          content: m.text,
        })),
        { role: "user", content: turn.text },
      ];
      appendNative(threadId, { dir: "out", source: "localEndpoint.chat.completions", msg: { model, messages } });

      emit({ ...base(threadId, turnId), type: "turn.started" });
      emit({ ...base(threadId, turnId), type: "session.started", sessionId: null, model: turn.model ?? models.default });

      (async () => {
        try {
          const { text, usage } = await complete(messages, model, {
            stream: true,
            signal: abort.signal,
            onDelta: (delta) =>
              emit({ ...base(threadId, turnId), type: "content.delta", streamKind: "assistant_text", delta }),
          });
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
