// Split engines into Cloud (first-party catalog + Custom) and Local
// (no catalog — inject a model). A missing `access` is Cloud so older
// payloads stay in the top group. VibeCoder would join Local later.
import type { InstanceInfo } from "@/state/store";

/** Harnesses kept off the per-bot model picker BY DEFAULT. Existing bots
 * still run, and Settings -> Engines overrides this per instance: an
 * explicit choice there wins over this list. */
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

export function isPickerHarness(
  instance: { driverKind?: string; pickerVisible?: boolean } | undefined,
): boolean {
  const kind = instance?.driverKind;
  if (!kind) return false;
  // the user's per-engine choice beats the shipped default
  if (typeof instance?.pickerVisible === "boolean") return instance.pickerVisible;
  return !HIDDEN_PICKER_DRIVER_KINDS.has(kind);
}

/** The shipped default for this harness, ignoring any override — the settings
 * row uses it to label a toggle as "default" or "changed". */
export function isPickerDefault(instance: { driverKind?: string } | undefined): boolean {
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
