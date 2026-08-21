// Config + data dirs. One file, ~/.swarmebot/config.json, env fallbacks:
//   { "xai": {"key":"xai-…"}, "composio": {"apiKey":"ak_…"}, "box": {"token":"…"},
//     "instances": { "<instanceId>": {"driver":"grok", …} } }
import { readFileSync, mkdirSync, existsSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { z } from "zod";

import { writeFileAtomic } from "./atomic.ts";
import type { InstanceConfigMap } from "./contracts.ts";
import {
  LITELLM_BASE_URL_ENV,
  LITELLM_DEFAULT_BASE_URL,
  normalizeGatewayBaseUrl,
} from "./drivers/local-inject.ts";
import { parseJson, schemaIssue, type JsonObject, type JsonValue } from "./schema.ts";

const optionalText = z.string().optional();
const SSH_ALIAS = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;

export const DEFAULT_ROOM_TURN_TIMEOUT_MINUTES = 5;
export const MIN_ROOM_TURN_TIMEOUT_MINUTES = 1;
export const MAX_ROOM_TURN_TIMEOUT_MINUTES = 1_440;

export function isValidSshAlias(value: unknown): value is string {
  return typeof value === "string" && SSH_ALIAS.test(value);
}

/** Keep the persisted VPS shape deliberately smaller than an SSH connection. */
export function normalizeVpsConfig(raw: unknown): { sshAlias?: string } {
  if (raw === undefined || raw === null) return {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("vps must be an object containing an SSH config alias");
  }
  const alias = (raw as Record<string, unknown>).sshAlias;
  if (alias === undefined || alias === "") return {};
  if (!isValidSshAlias(alias)) {
    throw new Error("vps.sshAlias must be a simple SSH config alias (letters, numbers, dot, dash, or underscore)");
  }
  return { sshAlias: alias };
}

const vpsConfigSchema = z.object({
  sshAlias: z.string().refine((value) => value === "" || isValidSshAlias(value), {
    message: "must be a simple SSH config alias",
  }).optional(),
});
const roomConfigSchema = z.object({
  turnTimeoutMinutes: z
    .number()
    .int()
    .min(MIN_ROOM_TURN_TIMEOUT_MINUTES)
    .max(MAX_ROOM_TURN_TIMEOUT_MINUTES),
});
const instanceConfigSchema = z.object({
  driver: z.string().min(1),
  displayName: optionalText,
  accentColor: optionalText,
  environment: z.record(z.string(), z.string()).optional(),
  enabled: z.boolean().optional(),
  config: z.json().optional(),
});
const instanceConfigMapSchema = z.record(z.string(), instanceConfigSchema);
/** Per-engine model-picker overrides, keyed by instanceId. Only explicit
 * user choices live here — a missing id means "use the shipped default for
 * that harness", which the picker itself decides. */
const pickerVisibilitySchema = z.record(z.string(), z.boolean());
const appConfigSchema = z.object({
  xai: z.object({ key: optionalText, url: optionalText }).optional(),
  /** Project key used for Sessions, catalog and agent tools. userId/sessionId
   * are non-secret local identifiers used to reuse one Composio Session. */
  composio: z.object({ apiKey: optionalText, userId: optionalText, sessionId: optionalText }).optional(),
  box: z.object({ token: optionalText }).optional(),
  vps: vpsConfigSchema.optional(),
  /** OpenCode Go key; persisted write-only and passed only to its child. */
  opencodeGo: z.object({ apiKey: optionalText }).optional(),
  /** LiteLLM gateway: the key, plus the endpoint it authenticates against —
   * every user runs their own proxy, so the URL is a setting, not a build
   * constant. Empty means "use the shipped default". */
  litellmHextra: z
    .object({
      apiKey: optionalText,
      baseUrl: z.string().refine((value) => value === "" || normalizeGatewayBaseUrl(value) !== null, {
        message: "must be an http(s) URL",
      }).optional(),
    })
    .optional(),
  /** Voice credentials and the selected voice id. */
  tts: z.object({ key: optionalText, voice: optionalText }).optional(),
  /** Non-secret profile details shown in the sidebar. */
  profile: z.object({ name: optionalText, email: optionalText }).optional(),
  rooms: roomConfigSchema.optional(),
  instances: instanceConfigMapSchema.optional(),
  pickerVisibility: pickerVisibilitySchema.optional(),
});
const appConfigPatchSchema = appConfigSchema.omit({ instances: true, pickerVisibility: true });
const jsonObjectSchema = z.record(z.string(), z.json());

export interface AppConfig {
  xai?: { key?: string; url?: string };
  composio?: { apiKey?: string; userId?: string; sessionId?: string };
  box?: { token?: string };
  /** A named host from the user's SSH config. Authentication stays with SSH. */
  vps?: { sshAlias?: string };
  opencodeGo?: { apiKey?: string };
  litellmHextra?: { apiKey?: string; baseUrl?: string };
  tts?: { key?: string; voice?: string };
  profile?: { name?: string; email?: string };
  rooms?: { turnTimeoutMinutes: number };
  instances?: InstanceConfigMap;
  /** instanceId → show this engine in the per-bot model picker. Explicit
   * overrides only; absent ids fall back to the picker's own default. */
  pickerVisibility?: Record<string, boolean>;
}
export type ConfigPatch = z.output<typeof appConfigPatchSchema>;

export function parseStoredConfig(value: JsonValue): AppConfig {
  const parsed = appConfigSchema.safeParse(value);
  if (!parsed.success) throw new Error(schemaIssue(parsed.error, "Invalid stored configuration"));
  return parsed.data;
}

export function parseConfigPatch(value: JsonValue): ConfigPatch {
  const parsed = appConfigPatchSchema.safeParse(value);
  if (!parsed.success) {
    throw Object.assign(new Error(schemaIssue(parsed.error, "Invalid configuration")), { status: 400 });
  }
  return parsed.data;
}

export function vpsSshAlias(cfg: AppConfig): string | null {
  return isValidSshAlias(cfg.vps?.sshAlias) ? cfg.vps.sshAlias : null;
}

/** The LiteLLM endpoint this workspace talks to: the user's setting when it
 * parses, the shipped gateway otherwise. */
export function litellmBaseUrl(cfg: AppConfig): string {
  return normalizeGatewayBaseUrl(cfg.litellmHextra?.baseUrl) ?? LITELLM_DEFAULT_BASE_URL;
}

/** Non-secret endpoints the config owns but code outside the fleet reads off
 * the environment: every driver's Custom list probes the LiteLLM gateway
 * through process.env, not through its own instance env, so a saved URL has
 * to reach process.env as well — the mirror image of syncCredentialEnv. */
export function syncEndpointEnv(cfg: AppConfig): void {
  const baseUrl = normalizeGatewayBaseUrl(cfg.litellmHextra?.baseUrl);
  if (baseUrl) process.env[LITELLM_BASE_URL_ENV] = baseUrl;
  else delete process.env[LITELLM_BASE_URL_ENV];
}

export function roomTurnTimeoutMinutes(cfg: AppConfig): number {
  return cfg.rooms?.turnTimeoutMinutes ?? DEFAULT_ROOM_TURN_TIMEOUT_MINUTES;
}

// OMB_DATA_DIR isolates test/soak rigs from the user's real fleet.
export const DATA_DIR = process.env.OMB_DATA_DIR ?? join(homedir(), ".swarmebot");
const LEGACY_DATA_DIRS = [join(homedir(), ".openmausbot"), join(homedir(), ".opengrokbot")];
export const EVENTS_DIR = join(DATA_DIR, "events");
export const NATIVE_DIR = join(DATA_DIR, "native");

export function ensureDirs() {
  // one-time migration from the pre-rename data dir — bots, transcripts,
  // config and keys all carry over
  if (!existsSync(DATA_DIR)) {
    for (const legacy of LEGACY_DATA_DIRS) {
      if (!existsSync(legacy)) continue;
      try {
        renameSync(legacy, DATA_DIR);
        break;
      } catch {
        /* cross-device or busy — fall through to a fresh dir */
      }
    }
  }
  for (const dir of [DATA_DIR, EVENTS_DIR, NATIVE_DIR]) mkdirSync(dir, { recursive: true });
}

export function loadConfig(): AppConfig {
  let cfg: AppConfig = {};
  try {
    cfg = parseStoredConfig(parseJson(readFileSync(join(DATA_DIR, "config.json"), "utf8")));
  } catch {
    /* first run — env fallbacks below */
  }
  // Env wins over the file for every credential. The desktop shell keeps
  // these secrets OS-encrypted and hands them to this process as env at
  // spawn, leaving config.json without the plaintext field — so the file
  // value is the dev-mode (no desktop shell) fallback, not the primary.
  // Anything that saves a credential mid-session must keep process.env in
  // step (syncCredentialEnv below), or the value injected at boot would
  // shadow the save until the next launch.
  cfg.xai = { ...cfg.xai };
  if (process.env.XAI_API_KEY !== undefined) cfg.xai.key = process.env.XAI_API_KEY;
  cfg.composio = { ...cfg.composio };
  if (process.env.COMPOSIO_API_KEY !== undefined) cfg.composio.apiKey = process.env.COMPOSIO_API_KEY;
  cfg.box = { ...cfg.box };
  if (process.env.BOX_TOKEN !== undefined) cfg.box.token = process.env.BOX_TOKEN;
  cfg.opencodeGo = { ...cfg.opencodeGo };
  if (process.env.OPENCODE_API_KEY !== undefined) cfg.opencodeGo.apiKey = process.env.OPENCODE_API_KEY;
  cfg.litellmHextra = { ...cfg.litellmHextra };
  if (process.env.LITELLMHEXTRA_AUTH_KEY !== undefined) cfg.litellmHextra.apiKey = process.env.LITELLMHEXTRA_AUTH_KEY;
  cfg.tts = { ...cfg.tts };
  if (process.env.OMB_TTS_KEY !== undefined) cfg.tts.key = process.env.OMB_TTS_KEY;
  return cfg;
}

/** After saveConfig() writes a credential, the running process's env must
 * follow the newest value — loadConfig() prefers env, so the secret injected
 * at boot would otherwise shadow the save until relaunch: the UI would show
 * "saved" while every turn still used the old key. An empty string means the
 * user cleared the credential, so the var is dropped and the (now empty)
 * file value is authoritative again. Fields absent from the patch are
 * untouched. */
export function syncCredentialEnv(patch: Partial<AppConfig>): void {
  const secrets: Array<[value: string | undefined, name: string]> = [
    [patch.xai?.key, "XAI_API_KEY"],
    [patch.composio?.apiKey, "COMPOSIO_API_KEY"],
    [patch.box?.token, "BOX_TOKEN"],
    [patch.opencodeGo?.apiKey, "OPENCODE_API_KEY"],
    [patch.litellmHextra?.apiKey, "LITELLMHEXTRA_AUTH_KEY"],
    [patch.tts?.key, "OMB_TTS_KEY"],
  ];
  for (const [value, name] of secrets) {
    if (value === undefined) continue;
    if (value) process.env[name] = value;
    else delete process.env[name];
  }
}

/** Env names of every workspace credential this process may be holding —
 * injected at boot by the desktop shell or exported by a developer. Spawned
 * engine CLIs must never inherit them: the one driver that consumes a given
 * secret receives it through instanceConfigs() narrowing, and to every other
 * child these are someone else's keys riding along in `...process.env`. */
export const WORKSPACE_CREDENTIAL_ENV = [
  "XAI_API_KEY",
  "BOX_TOKEN",
  "OPENCODE_API_KEY",
  "LITELLMHEXTRA_AUTH_KEY",
  "OMB_TTS_KEY",
  "COMPOSIO_API_KEY",
  "OMB_COMPOSIO_BROKER_TOKEN",
] as const;

/** Drop every workspace credential from a child-process env (in place). */
export function stripWorkspaceCredentialEnv(env: Record<string, string | undefined>): void {
  for (const key of WORKSPACE_CREDENTIAL_ENV) delete env[key];
}

/** Env names a provider CLI might read as its own billing identity. A spawned
 * engine keeps only what its driver explicitly allows: a foreign key riding
 * along in `...process.env` must not flip a subscription CLI onto
 * pay-as-you-go billing the user never granted. */
export const PROVIDER_CREDENTIAL_ENV = [
  "ANTHROPIC_API_KEY",
  "FACTORY_API_KEY",
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "KIMI_API_KEY",
  "MOONSHOT_API_KEY",
  "OPENAI_API_KEY",
  "OPENCODE_API_KEY",
  "XAI_API_KEY",
  "CURSOR_API_KEY",
  "CURSOR_AUTH_TOKEN",
] as const;

/** Sections/fields the desktop shell keeps OS-encrypted, as `[section,
 * field]` pairs saveConfig() can be asked to REMOVE from config.json.
 *
 * Removal, not a "" tombstone: the shell reads a plaintext "" at the next
 * boot as "the user cleared this credential" and drops the encrypted copy
 * (electron/workspace-credentials.mjs), which would delete the very key the
 * user just saved. Absent means "already migrated — keep the stored one". */
export const EXTERNAL_SECRET_FIELDS = [
  ["xai", "key"],
  ["composio", "apiKey"],
  ["box", "token"],
  ["opencodeGo", "apiKey"],
  ["litellmHextra", "apiKey"],
  ["tts", "key"],
] as const;

/** Merge a partial config into ~/.swarmebot/config.json (secrets never
 * echoed back — callers report configured-or-not booleans only).
 *
 * `remove` deletes fields after the merge — the only way to take a plaintext
 * credential OUT of the file, since a merge can add or overwrite but never
 * unset. */
export function saveConfig(
  patch: Partial<AppConfig>,
  remove: ReadonlyArray<readonly [string, string]> = [],
): void {
  const p = join(DATA_DIR, "config.json");
  let disk: JsonObject = {};
  try {
    const parsed = jsonObjectSchema.safeParse(parseJson(readFileSync(p, "utf8")));
    if (parsed.success) disk = parsed.data;
  } catch {
    /* first write */
  }
  const checkedPatch = appConfigSchema.partial().parse(patch);
  for (const key of ["xai", "composio", "box", "opencodeGo", "litellmHextra", "tts", "profile", "rooms"] as const) {
    const section = checkedPatch[key];
    if (!section) continue;
    const current = jsonObjectSchema.safeParse(disk[key]);
    const merged: JsonObject = current.success ? { ...current.data } : {};
    Object.assign(merged, section);
    disk[key] = merged;
  }
  if (checkedPatch.vps !== undefined) disk.vps = normalizeVpsConfig(checkedPatch.vps);
  if (checkedPatch.instances) {
    const currentInstances = jsonObjectSchema.safeParse(disk.instances);
    const diskInstances: JsonObject = currentInstances.success ? currentInstances.data : {};
    for (const [instanceId, entry] of Object.entries(checkedPatch.instances)) {
      const current = jsonObjectSchema.safeParse(diskInstances[instanceId]);
      const merged: JsonObject = current.success ? { ...current.data } : {};
      Object.assign(merged, entry);
      diskInstances[instanceId] = merged;
    }
    disk.instances = diskInstances;
  }
  // Whole-map replace, not a merge: withInstancePickerVisibility() hands back
  // the resolved map, so a merge could not express "clear this override".
  if (checkedPatch.pickerVisibility !== undefined) {
    disk.pickerVisibility = { ...checkedPatch.pickerVisibility };
  }
  for (const [section, field] of remove) {
    const current = jsonObjectSchema.safeParse(disk[section]);
    if (!current.success || !Object.hasOwn(current.data, field)) continue;
    const rest = { ...current.data };
    delete rest[field];
    disk[section] = rest;
  }
  mkdirSync(DATA_DIR, { recursive: true });
  writeFileAtomic(p, JSON.stringify(disk, null, 2), { mode: 0o600 });
}

/** Set one instance's `config.cli` ("" clears the override back to the
 * driver default). Creating the instance entry is fine — a config-less
 * entry rides driver.defaultConfig(). Returns false for unknown instances
 * when the fleet is explicitly configured. The returned map must stay
 * PERSISTABLE: instanceConfigs() injects credential env into consuming
 * drivers' entries for the live fleet, so those injected keys are stripped
 * back out before the map is returned — otherwise saving an override would
 * copy xai/box/opencodeGo secrets into the instances section of
 * config.json. */
export function withInstanceCli(
  cfg: AppConfig,
  instanceId: string,
  cli: string,
): InstanceCliUpdate {
  const next: AppConfig = structuredClone(cfg);
  const map = instanceConfigs(next);
  // hasOwn, not truthiness: map is a plain object literal, so
  // map["__proto__"] resolves to Object.prototype — truthy — and the
  // assignment below would poison EVERY object in the process (instanceId
  // comes off the URL, where `__proto__` passes the route's [\w.-]+ regex)
  if (!Object.hasOwn(map, instanceId)) return { ok: false, config: cfg };
  const entry = map[instanceId];
  const cliKey = cli.trim();
  const currentConfig = jsonObjectSchema.safeParse(entry.config);
  if (cliKey) {
    const nextConfig: JsonObject = currentConfig.success ? { ...currentConfig.data } : {};
    nextConfig.cli = cliKey;
    entry.config = nextConfig;
  } else if (currentConfig.success && Object.hasOwn(currentConfig.data, "cli")) {
    const rest = { ...currentConfig.data };
    delete rest.cli;
    entry.config = Object.keys(rest).length ? rest : undefined;
  }
  for (const e of Object.values(map)) {
    if (!e.environment) continue;
    const injected = injectedEnvironment(next, e.driver);
    for (const [k, v] of Object.entries(e.environment)) {
      if (injected.get(k) === v) delete e.environment[k];
    }
    if (!Object.keys(e.environment).length) delete e.environment;
  }
  next.instances = map;
  return { ok: true, config: next };
}

interface InstanceCliUpdate {
  ok: boolean;
  config: AppConfig;
}

/** The user's explicit model-picker choices, one per instanceId. Values that
 * are not booleans are dropped rather than trusted. */
export function pickerVisibility(cfg: AppConfig): Record<string, boolean> {
  const out: Record<string, boolean> = Object.create(null);
  for (const [instanceId, visible] of Object.entries(cfg.pickerVisibility ?? {})) {
    if (typeof visible === "boolean") out[instanceId] = visible;
  }
  return out;
}

/** Show or hide one engine in the per-bot model picker; `null` drops the
 * override so the shipped default applies again. Unknown instances are
 * rejected the same way withInstanceCli() rejects them — and the hasOwn
 * check is also what keeps an instanceId of `__proto__` (the route regex
 * accepts it) from reaching the assignment below. */
export function withInstancePickerVisibility(
  cfg: AppConfig,
  instanceId: string,
  visible: boolean | null,
): InstanceCliUpdate {
  if (!Object.hasOwn(instanceConfigs(cfg), instanceId)) return { ok: false, config: cfg };
  const map = pickerVisibility(cfg);
  if (visible === null) delete map[instanceId];
  else map[instanceId] = visible;
  return { ok: true, config: { ...cfg, pickerVisibility: { ...map } } };
}

/** The credential env instanceConfigs() injects for one driver — shared with
 * withInstanceCli() so the inject rule and the strip rule cannot drift apart.
 * Each secret goes only to the driver that actually reads it: the API-key
 * Grok driver reads XAI_API_KEY, the Computer driver reads BOX_TOKEN, and
 * OpenCode Go reads OPENCODE_API_KEY. Every other engine brings its own
 * login, so handing it a key it never uses would only put that key in the
 * environment of an unrelated child process. */
function injectedEnvironment(cfg: AppConfig, driver: string): Map<string, string> {
  const environment = new Map<string, string>();
  if (driver === "grok" && cfg.xai?.key) environment.set("XAI_API_KEY", cfg.xai.key);
  if (driver === "boxAgent" && cfg.box?.token) environment.set("BOX_TOKEN", cfg.box.token);
  if (driver === "opencodeGo" && cfg.opencodeGo?.apiKey) environment.set("OPENCODE_API_KEY", cfg.opencodeGo.apiKey);
  if (driver === "litellm" && cfg.litellmHextra?.apiKey) {
    environment.set("LITELLMHEXTRA_AUTH_KEY", cfg.litellmHextra.apiKey);
  }
  if (driver === "litellm") {
    const baseUrl = litellmBaseUrl(cfg);
    if (baseUrl !== LITELLM_DEFAULT_BASE_URL) environment.set(LITELLM_BASE_URL_ENV, baseUrl);
  }
  return environment;
}

// Default fleet: one instance per built-in driver (upstream
// defaultInstanceIdForDriver — instanceId defaults to the driver kind).
// Config-file keys are injected as per-instance environment so drivers
// see them without needing real process env vars — but only into the
// driver that consumes each key (injectedEnvironment above).
export function instanceConfigs(cfg: AppConfig): InstanceConfigMap {
  // The default `grok` instance rides the `grokAgent` driver, not the API-key
  // one: like claude and codex it needs no credential from us, just the CLI
  // installed and logged in (it shows up unavailable otherwise). The API-key
  // `grok` driver stays registered but out of the default fleet — that key is
  // a credential Milind doesn't want to manage; an `instances` entry brings
  // it back anytime.
  //
  // Google rides `antigravityAgent` (the `agy` CLI), not `geminiAgent`:
  // Google retired Gemini CLI for the free/Pro/Ultra tiers on 2026-06-18
  // (developers.googleblog.com, "transitioning Gemini CLI to Antigravity
  // CLI"), so a default `gemini` instance could only ever show unavailable.
  // The driver stays registered for enterprise licences, which keep Gemini
  // CLI — `{"instances": {"gemini": {"driver": "geminiAgent"}}}` restores it.
  const DEFAULT_FLEET: InstanceConfigMap = {
    grok: { driver: "grokAgent" },
    kimi: { driver: "kimiAgent" },
    droid: { driver: "droidAgent" },
    cursor: { driver: "cursorAgent" },
    claude: { driver: "claudeAgent" },
    codex: { driver: "codex" },
    antigravity: { driver: "antigravityAgent" },
    opencodeGo: { driver: "opencodeGo" },
    computer: { driver: "boxAgent" },
    qwen: { driver: "qwenAgent" },
    hermes: { driver: "hermesAgent" },
    pi: { driver: "piAgent" },
    litellm: { driver: "litellm" },
  };
  const CUSTOM_ONLY = {
    qwen: { driver: "qwenAgent" },
    hermes: { driver: "hermesAgent" },
    pi: { driver: "piAgent" },
    litellm: { driver: "litellm" },
  } as const;
  // New default-fleet engines that existing product configs would otherwise
  // never see. Custom-only engines stay in CUSTOM_ONLY so a one-off test map
  // is not expanded, matching the claude/grok/codex product-fleet probe.
  const PRODUCT_FLEET_ADDITIONS = {
    cursor: { driver: "cursorAgent" },
    ...CUSTOM_ONLY,
  } as const;
  const configured = cfg.instances && Object.keys(cfg.instances).length ? cfg.instances : null;
  const map: InstanceConfigMap = configured ? { ...configured } : { ...DEFAULT_FLEET };
  // Product fleets pick up newly shipped engines. A one-off test/shadow map
  // (no claude/grok/codex) is left exactly as written.
  if (
    configured &&
    (Object.hasOwn(configured, "claude") || Object.hasOwn(configured, "grok") || Object.hasOwn(configured, "codex"))
  ) {
    for (const [id, entry] of Object.entries(PRODUCT_FLEET_ADDITIONS)) {
      if (!Object.hasOwn(map, id)) map[id] = { ...entry };
    }
  }
  for (const entry of Object.values(map)) {
    const environment = { ...entry.environment };
    for (const [key, value] of injectedEnvironment(cfg, entry.driver)) environment[key] = value;
    entry.environment = environment;
  }
  return map;
}
