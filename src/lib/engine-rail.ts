// Split engines into Cloud (first-party catalog + Custom) and Local
// (no catalog — inject a model). A missing `access` is Cloud so older
// payloads stay in the top group. VibeCoder would join Local later.
import type { InstanceInfo } from "@/state/store";

/** Harnesses kept off the desktop model-picker rail. Existing bots still run. */
const HIDDEN_PICKER_DRIVER_KINDS = new Set([
  "grok",
  "grokAgent",
  "kimiAgent",
  "droidAgent",
  "antigravityAgent",
  "opencodeGo",
  "qwenAgent",
  "hermesAgent",
  "piAgent",
]);

export function isPickerHarness(instance: { driverKind?: string } | undefined): boolean {
  const kind = instance?.driverKind;
  if (!kind) return false;
  return !HIDDEN_PICKER_DRIVER_KINDS.has(kind);
}

export function isCustomOnly(instance: { access?: InstanceInfo["access"] } | undefined): boolean {
  return instance?.access === "custom";
}

export function splitEngineRail<T>(instances: readonly T[]): {
  subscription: T[];
  custom: T[];
} {
  const subscription: T[] = [];
  const custom: T[] = [];
  for (const instance of instances) {
    if (isCustomOnly(instance as { access?: InstanceInfo["access"] })) custom.push(instance);
    else subscription.push(instance);
  }
  return { subscription, custom };
}
