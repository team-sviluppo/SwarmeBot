// "Show in model picker" — the one switch that decides whether an engine is
// offered in the per-bot picker. Shared by the CLI engine rows and by the
// engines that configure themselves through their own card (DeepSeek Harness),
// so an engine can never ship with a settings card that forgot the toggle.
//
// Deliberately takes no store context: the DeepSeek Harness card is rendered
// as a pure view in tests, and a hook that throws outside a provider would
// make the toggle untestable there. `api` is a plain function; the caller
// hands over its own refresh through onSaved.
import { useState } from "react";

import { api, type InstanceInfo } from "@/state/store";
import { isPickerDefault, isPickerHarness } from "@/lib/engine-rail";
import { cn } from "@/lib/cn";

export function ModelPickerToggle({ instance, onSaved }: {
  instance: InstanceInfo;
  onSaved?: () => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const visible = isPickerHarness(instance);
  const isDefault = isPickerDefault(instance);

  // null instead of the boolean when the choice matches the shipped default:
  // config.json then carries overrides only, so a later change to the default
  // list still reaches engines the user never touched.
  const setVisible = (next: boolean) => {
    if (saving) return;
    setSaving(true);
    setError(null);
    api(`/api/instances/${encodeURIComponent(instance.instanceId)}`, {
      method: "PATCH",
      body: JSON.stringify({ pickerVisible: next === isDefault ? null : next }),
    })
      // The override already took once PATCH returns 200. A follow-up list
      // refresh failure should not tell the user the toggle itself failed.
      .then(() => Promise.resolve(onSaved?.()).catch(() => {}))
      .catch((e) => setError(e.message))
      .finally(() => setSaving(false));
  };

  return (
    <>
      <div className="flex items-center gap-2 text-[12px]">
        <span className="text-ink-secondary">Show in model picker</span>
        {visible !== isDefault && (
          <button
            onClick={() => setVisible(isDefault)}
            disabled={saving}
            className="text-[11px] text-ink-secondary underline decoration-dotted hover:text-ink disabled:opacity-50"
          >
            reset to default
          </button>
        )}
        <span className="flex-1" />
        <button
          role="switch"
          aria-checked={visible}
          aria-label={`Show ${instance.displayName} in the model picker`}
          disabled={saving}
          onClick={() => setVisible(!visible)}
          className={cn(
            "relative h-5 w-9 shrink-0 rounded-full transition-colors disabled:opacity-50",
            visible ? "bg-accent" : "bg-raised-hover",
          )}
        >
          <span
            className={cn(
              "absolute top-0.5 size-4 rounded-full bg-white transition-all",
              visible ? "left-[18px]" : "left-0.5",
            )}
          />
        </button>
      </div>
      {error && <div role="alert" className="mt-1 text-[12px] text-danger">{error}</div>}
    </>
  );
}
