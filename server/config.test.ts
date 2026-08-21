import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  DATA_DIR,
  instanceConfigs,
  isValidSshAlias,
  loadConfig,
  parseConfigPatch,
  parseStoredConfig,
  roomTurnTimeoutMinutes,
  litellmBaseUrl,
  saveConfig,
  stripWorkspaceCredentialEnv,
  syncCredentialEnv,
  syncEndpointEnv,
  vpsSshAlias,
  withInstanceCli,
  WORKSPACE_CREDENTIAL_ENV,
  type AppConfig,
} from "./config.ts";

describe("configuration boundaries", () => {
  it("keeps supported stored settings and drops unrelated top-level data", () => {
    expect(
      parseStoredConfig({
        profile: { name: "Ada", email: "ada@example.com" },
        instances: { claude: { driver: "claudeAgent", config: { cli: "/opt/claude" } } },
        unrelated: { secret: "not part of the config contract" },
      }),
    ).toEqual({
      profile: { name: "Ada", email: "ada@example.com" },
      instances: { claude: { driver: "claudeAgent", config: { cli: "/opt/claude" } } },
    });
  });

  it("rejects malformed stored instances and API patches", () => {
    expect(() => parseStoredConfig({ instances: { claude: { driver: 42 } } })).toThrow("instances.claude.driver");
    expect(() => parseConfigPatch({ opencodeGo: { apiKey: 42 } })).toThrow("opencodeGo.apiKey");
    expect(() => parseConfigPatch({ litellmHextra: { apiKey: 42 } })).toThrow("litellmHextra.apiKey");
    expect(() => parseConfigPatch({ profile: [] })).toThrow("profile");
  });

  it("accepts only a simple VPS SSH config alias and exposes no credentials", () => {
    expect(isValidSshAlias("production-vps")).toBe(true);
    expect(isValidSshAlias("prod; reboot")).toBe(false);
    expect(() => parseConfigPatch({ vps: { sshAlias: "prod; reboot" } })).toThrow("vps.sshAlias");
    expect(parseConfigPatch({ vps: { sshAlias: "production-vps" } })).toEqual({
      vps: { sshAlias: "production-vps" },
    });
    expect(vpsSshAlias({ vps: { sshAlias: "production-vps" } })).toBe("production-vps");
    expect(vpsSshAlias({ vps: { sshAlias: "-bad" } })).toBeNull();
  });

  it("accepts a persisted global room turn timeout and supplies the legacy default", () => {
    expect(parseStoredConfig({ rooms: { turnTimeoutMinutes: 20 } })).toEqual({
      rooms: { turnTimeoutMinutes: 20 },
    });
    expect(roomTurnTimeoutMinutes({ rooms: { turnTimeoutMinutes: 20 } })).toBe(20);
    expect(roomTurnTimeoutMinutes({})).toBe(5);
  });

  it.each([0, 1.5, 1441, "20", null])(
    "rejects an invalid room turn timeout: %j",
    (turnTimeoutMinutes) => {
      expect(() => parseConfigPatch({ rooms: { turnTimeoutMinutes } })).toThrow(
        "rooms.turnTimeoutMinutes",
      );
    },
  );
});

describe("default fleet", () => {
  it("ships Qwen and Hermes as custom-only engines", () => {
    const map = instanceConfigs({});
    expect(map.qwen).toEqual({ driver: "qwenAgent", environment: {} });
    expect(map.hermes).toEqual({ driver: "hermesAgent", environment: {} });
    expect(map.litellm).toEqual({ driver: "litellm", environment: {} });
  });

  it("ships Cursor as a default-fleet subscription engine", () => {
    const map = instanceConfigs({});
    expect(map.cursor).toEqual({ driver: "cursorAgent", environment: {} });
  });

  it("adds missing custom-only engines onto an existing product fleet", () => {
    const map = instanceConfigs({ instances: { claude: { driver: "claudeAgent" } } });
    expect(map.claude.driver).toBe("claudeAgent");
    expect(map.qwen?.driver).toBe("qwenAgent");
    expect(map.hermes?.driver).toBe("hermesAgent");
    expect(map.litellm?.driver).toBe("litellm");
    expect(map.cursor?.driver).toBe("cursorAgent");
  });

  it("does not expand a one-off shadow fleet", () => {
    const map = instanceConfigs({ instances: { ghost: { driver: "not-a-real-driver" } } });
    expect(Object.keys(map)).toEqual(["ghost"]);
  });
});

describe("Instance CLI override", () => {
  it("sets, replaces, and clears config.cli on a default-fleet instance", () => {
    const cfg: AppConfig = {};
    const set = withInstanceCli(cfg, "claude", "/opt/claude-2.1/bin/claude");
    expect(set.ok).toBe(true);
    expect(set.config.instances!.claude.config).toEqual({ cli: "/opt/claude-2.1/bin/claude" });

    const replaced = withInstanceCli(set.config, "claude", "~/bin/claude");
    expect(replaced.config.instances!.claude.config).toEqual({ cli: "~/bin/claude" });

    const cleared = withInstanceCli(replaced.config, "claude", "");
    expect(cleared.config.instances!.claude.config).toBeUndefined();
  });

  it("preserves sibling config keys when clearing only cli", () => {
    const cfg: AppConfig = {
      instances: { claude: { driver: "claudeAgent", config: { cli: "/x/claude", permissionMode: "bypassPermissions" } } },
    };
    const cleared = withInstanceCli(cfg, "claude", "");
    expect(cleared.config.instances!.claude.config).toEqual({ permissionMode: "bypassPermissions" });
  });

  it("leaves the original config untouched and rejects unknown instances", () => {
    const cfg: AppConfig = { instances: { codex: { driver: "codex" } } };
    const result = withInstanceCli(cfg, "codex", "/new/codex");
    expect(result.config.instances!.codex.config).toEqual({ cli: "/new/codex" });
    expect(cfg.instances!.codex.config).toBeUndefined();

    expect(withInstanceCli(cfg, "nope", "/x").ok).toBe(false);
  });

  it("never persists the credential env instanceConfigs injects", () => {
    // instanceConfigs() copies each credential into its consuming driver's
    // environment for the live fleet; withInstanceCli must strip those pairs
    // back out, or saving a CLI override would copy secrets into the
    // instances section of config.json.
    const cfg: AppConfig = {
      xai: { key: "SECRET-XAI" },
      box: { token: "SECRET-BOX" },
      opencodeGo: { apiKey: "SECRET-OCG" },
      litellmHextra: { apiKey: "SECRET-HEXTRA" },
      instances: {
        claude: { driver: "claudeAgent" },
        grokApi: { driver: "grok" },
        computer: { driver: "boxAgent" },
        opencode: { driver: "opencodeGo" },
        litellm: { driver: "litellm" },
      },
    };
    const set = withInstanceCli(cfg, "claude", "/opt/claude");
    expect(set.ok).toBe(true);
    for (const entry of Object.values(set.config.instances!)) {
      expect(entry.environment ?? {}).toEqual({});
    }
    // user-authored env survives
    const custom = { instances: { claude: { driver: "claudeAgent", environment: { MY_FLAG: "1" } } } };
    const kept = withInstanceCli(custom, "claude", "/x");
    expect(kept.config.instances!.claude.environment).toEqual({ MY_FLAG: "1" });
  });
});

describe("LiteLLM Hextra configuration", () => {
  it("injects the key only into Litellm instances", () => {
    const cfg: AppConfig = {
      litellmHextra: { apiKey: "hextra-secret" },
      instances: {
        litellm: { driver: "litellm" },
        grok: { driver: "grokAgent" },
      },
    };
    const instances = instanceConfigs(cfg);
    expect(instances.litellm.environment).toEqual({ LITELLMHEXTRA_AUTH_KEY: "hextra-secret" });
    expect(instances.grok.environment).toEqual({});
  });

  it("falls back to the shipped gateway and normalizes a user endpoint", () => {
    expect(litellmBaseUrl({})).toBe("https://litellm.hextra.it/v1");
    expect(litellmBaseUrl({ litellmHextra: { baseUrl: "" } })).toBe("https://litellm.hextra.it/v1");
    expect(litellmBaseUrl({ litellmHextra: { baseUrl: "https://llm.example.com" } })).toBe(
      "https://llm.example.com/v1",
    );
    // a broken setting must not point the fleet at nothing
    expect(litellmBaseUrl({ litellmHextra: { baseUrl: "nonsense" } })).toBe("https://litellm.hextra.it/v1");
  });

  it("injects a custom endpoint into Litellm instances, and nothing when it is the default", () => {
    const custom = instanceConfigs({
      litellmHextra: { baseUrl: "https://llm.example.com/v1" },
      instances: { litellm: { driver: "litellm" }, grok: { driver: "grokAgent" } },
    });
    expect(custom.litellm.environment).toEqual({ LITELLMHEXTRA_BASE_URL: "https://llm.example.com/v1" });
    expect(custom.grok.environment).toEqual({});

    const shipped = instanceConfigs({ instances: { litellm: { driver: "litellm" } } });
    expect(shipped.litellm.environment).toEqual({});
  });

  it("mirrors the endpoint into process.env for the fleet-wide Custom probes", () => {
    syncEndpointEnv({ litellmHextra: { baseUrl: "https://llm.example.com" } });
    expect(process.env.LITELLMHEXTRA_BASE_URL).toBe("https://llm.example.com/v1");
    syncEndpointEnv({});
    expect(process.env.LITELLMHEXTRA_BASE_URL).toBeUndefined();
  });
});

describe("externally stored secrets", () => {
  it("removes a plaintext credential field instead of tombstoning it", () => {
    // A "" left in config.json is read at the next desktop boot as "the user
    // cleared this key" and deletes the encrypted copy — the field has to go.
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(
      join(DATA_DIR, "config.json"),
      JSON.stringify({ litellmHextra: { apiKey: "old-plaintext" }, profile: { name: "Ada" } }),
    );
    saveConfig({ litellmHextra: {}, profile: { name: "Grace" } }, [["litellmHextra", "apiKey"]]);
    const disk = JSON.parse(readFileSync(join(DATA_DIR, "config.json"), "utf8"));
    expect(disk.litellmHextra).toEqual({});
    expect(disk.profile).toEqual({ name: "Grace" });
  });
});

describe("credential env narrowing", () => {
  it("injects each credential only into the driver that consumes it", () => {
    const cfg: AppConfig = {
      xai: { key: "SECRET-XAI" },
      box: { token: "SECRET-BOX" },
      opencodeGo: { apiKey: "SECRET-OCG" },
      litellmHextra: { apiKey: "SECRET-HEXTRA" },
      instances: {
        grokApi: { driver: "grok" },
        computer: { driver: "boxAgent" },
        opencode: { driver: "opencodeGo" },
        litellm: { driver: "litellm" },
        claude: { driver: "claudeAgent" },
        codex: { driver: "codex" },
      },
    };
    const instances = instanceConfigs(cfg);
    expect(instances.grokApi.environment).toEqual({ XAI_API_KEY: "SECRET-XAI" });
    expect(instances.computer.environment).toEqual({ BOX_TOKEN: "SECRET-BOX" });
    expect(instances.opencode.environment).toEqual({ OPENCODE_API_KEY: "SECRET-OCG" });
    expect(instances.litellm.environment).toEqual({ LITELLMHEXTRA_AUTH_KEY: "SECRET-HEXTRA" });
    // engines that bring their own login receive NO workspace credential
    expect(instances.claude.environment).toEqual({});
    expect(instances.codex.environment).toEqual({});
  });

  it("hands no credential to any default-fleet CLI engine except the Computer", () => {
    // the default `grok` instance is the CLI-login grokAgent, not the
    // API-key driver, so a configured xai key reaches nobody by default
    const cfg: AppConfig = { xai: { key: "SECRET-XAI" }, box: { token: "SECRET-BOX" } };
    const instances = instanceConfigs(cfg);
    for (const [id, entry] of Object.entries(instances)) {
      if (id === "computer") expect(entry.environment).toEqual({ BOX_TOKEN: "SECRET-BOX" });
      else expect(entry.environment).toEqual({});
    }
  });

  it("keeps a per-instance environment while layering the credential on top", () => {
    const cfg: AppConfig = {
      box: { token: "SECRET-BOX" },
      instances: { computer: { driver: "boxAgent", environment: { MY_FLAG: "1" } } },
    };
    expect(instanceConfigs(cfg).computer.environment).toEqual({ MY_FLAG: "1", BOX_TOKEN: "SECRET-BOX" });
  });
});

describe("credential env preference", () => {
  const VARS = ["XAI_API_KEY", "BOX_TOKEN", "OPENCODE_API_KEY", "LITELLMHEXTRA_AUTH_KEY", "OMB_TTS_KEY", "COMPOSIO_API_KEY"] as const;
  let saved: Record<string, string | undefined>;

  beforeEach(() => {
    saved = Object.fromEntries(VARS.map((name) => [name, process.env[name]]));
    for (const name of VARS) delete process.env[name];
    mkdirSync(DATA_DIR, { recursive: true });
    rmSync(join(DATA_DIR, "config.json"), { force: true });
  });
  afterEach(() => {
    for (const name of VARS) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
    rmSync(join(DATA_DIR, "config.json"), { force: true });
  });

  it("prefers env over the config file for every credential", () => {
    // the desktop shell hands secrets to this process as env (from its
    // OS-encrypted store) and leaves the file without them — env must win
    // even over a leftover plaintext value
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(
      join(DATA_DIR, "config.json"),
      JSON.stringify({
        xai: { key: "file-xai", url: "https://api.example.test/v1" },
        box: { token: "file-box" },
        opencodeGo: { apiKey: "file-ocg" },
        litellmHextra: { apiKey: "file-hextra" },
        tts: { key: "file-tts", voice: "narrator" },
      }),
    );
    process.env.XAI_API_KEY = "env-xai";
    process.env.BOX_TOKEN = "env-box";
    process.env.OPENCODE_API_KEY = "env-ocg";
    process.env.LITELLMHEXTRA_AUTH_KEY = "env-hextra";
    process.env.OMB_TTS_KEY = "env-tts";
    const cfg = loadConfig();
    expect(cfg.xai).toEqual({ key: "env-xai", url: "https://api.example.test/v1" });
    expect(cfg.box).toEqual({ token: "env-box" });
    expect(cfg.opencodeGo).toEqual({ apiKey: "env-ocg" });
    expect(cfg.litellmHextra).toEqual({ apiKey: "env-hextra" });
    expect(cfg.tts).toEqual({ key: "env-tts", voice: "narrator" });
  });

  it("falls back to the config file when the env var is unset (dev mode)", () => {
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(
      join(DATA_DIR, "config.json"),
      JSON.stringify({ xai: { key: "file-xai" }, tts: { key: "file-tts" } }),
    );
    const cfg = loadConfig();
    expect(cfg.xai?.key).toBe("file-xai");
    expect(cfg.tts?.key).toBe("file-tts");
  });

  it("treats a blanked file field as absent when env supplies the secret", () => {
    // after migration the desktop shell may leave "" behind (a cleared key
    // that was saved mid-session); the env-injected value must still win
    writeFileSync(join(DATA_DIR, "config.json"), JSON.stringify({ xai: { key: "" } }));
    process.env.XAI_API_KEY = "env-xai";
    expect(loadConfig().xai?.key).toBe("env-xai");
  });

  it("syncCredentialEnv keeps process.env in step with a credential save", () => {
    process.env.XAI_API_KEY = "boot-injected";
    process.env.BOX_TOKEN = "boot-injected";
    process.env.COMPOSIO_API_KEY = "boot-injected";
    syncCredentialEnv({
      xai: { key: "just-saved" },
      composio: { apiKey: "ak_just_saved" },
      box: { token: "" },
      profile: { name: "Ada" },
    });
    // a saved value replaces the boot-time one; a cleared value drops it;
    // untouched sections change nothing
    expect(process.env.XAI_API_KEY).toBe("just-saved");
    expect(process.env.COMPOSIO_API_KEY).toBe("ak_just_saved");
    expect(process.env.BOX_TOKEN).toBeUndefined();
    expect(process.env.OMB_TTS_KEY).toBeUndefined();
  });
});

describe("workspace credential env strip", () => {
  it("removes every workspace credential from a child env in place", () => {
    const env = {
      PATH: "/usr/bin",
      MY_FLAG: "1",
      ...Object.fromEntries(WORKSPACE_CREDENTIAL_ENV.map((name) => [name, "secret"])),
    };
    stripWorkspaceCredentialEnv(env);
    expect(env).toEqual({ PATH: "/usr/bin", MY_FLAG: "1" });
  });

  it("covers the box token and voice key, which no engine CLI may inherit", () => {
    // these two have no per-driver ACP allowlist entry anywhere — they are
    // consumed in-process (Computer driver / voice module), never by a CLI
    expect(WORKSPACE_CREDENTIAL_ENV).toContain("BOX_TOKEN");
    expect(WORKSPACE_CREDENTIAL_ENV).toContain("OMB_TTS_KEY");
    expect(WORKSPACE_CREDENTIAL_ENV).toContain("LITELLMHEXTRA_AUTH_KEY");
  });
});
