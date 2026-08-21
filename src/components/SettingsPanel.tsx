import { ChevronDown, ChevronLeft, Crown, FolderOpen, ImagePlus, X } from "lucide-react";
import { useEffect, useState } from "react";
import { api, useStore, type Bot } from "@/state/store";
import { MausAvatar, wearsPicture } from "./Avatar";
import { DicebearAvatar, useDicebearReady } from "./DicebearAvatar";
import {
  DICEBEAR_STYLE_IDS,
  dicebearMeta,
  dicebearStyleSlug,
  dicebearUrl,
  importDicebearAvatar,
  parseDicebearAvatar,
  randomSeed,
} from "@/lib/dicebear";
import {
  PICKABLE_STATES,
  stateForBot,
  MAUS_COLORS,
  MAUS_COLOR_NAMES,
  MAUS_SILHOUETTE_IDS,
  normalizeSilhouette,
} from "@/lib/mascot";
import { useDesktopCapabilities } from "./DesktopCapabilities";
import { ModelPicker } from "./ModelPicker";
import { cn } from "@/lib/cn";
import { requestNotificationPermission } from "@/lib/notify";
import { botUsage, costCaption, formatTokens, formatUsd } from "@/lib/usage";
import { shortPath } from "@/lib/short-path";
import { SHEET_ROWS, clampSheetRow, downscaleSheetFile } from "@/lib/sprite-sheet";
import { SpriteSheetAvatar } from "./SpriteSheetAvatar";

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <div className="mb-1.5 text-[13px] text-ink-secondary">{label}</div>
      {children}
    </label>
  );
}

/** What this bot has spent across its tasks. Cost is captioned by how the
 * engine is billed — on a subscription the figure is an equivalent. */
function BotUsageCard({ bot }: { bot: Bot }) {
  const { state, dispatch } = useStore();
  const usage = botUsage(bot);
  const instance = state.instances.find((i) => i.instanceId === bot.modelSelection.instanceId);
  if (usage.turns === 0) return null;
  return (
    <div className="rounded-xl bg-card p-4">
      <div className="flex items-baseline justify-between">
        <div className="text-[15px] font-medium text-ink">Usage</div>
        <button
          onClick={() => dispatch({ type: "toggleAppSettings", open: true, section: "usage" })}
          className="text-[12px] text-ink-secondary hover:text-ink"
        >
          All bots →
        </button>
      </div>
      <div className="mt-3 grid grid-cols-3 gap-3 text-[13px]">
        <div>
          <div className="text-[11.5px] uppercase tracking-wide text-ink-secondary">Turns</div>
          <div className="mt-0.5 tabular-nums text-ink">{usage.turns}</div>
        </div>
        <div>
          <div className="text-[11.5px] uppercase tracking-wide text-ink-secondary">Tokens</div>
          <div className="mt-0.5 tabular-nums text-ink" title={`${formatTokens(usage.input)} in · ${formatTokens(usage.output)} out`}>
            {formatTokens(usage.input + usage.output)}
          </div>
        </div>
        <div>
          <div className="text-[11.5px] uppercase tracking-wide text-ink-secondary">Cost</div>
          <div className="mt-0.5 tabular-nums text-ink">{usage.costUsd === null ? "—" : formatUsd(usage.costUsd)}</div>
        </div>
      </div>
      <div className="mt-2 text-[12px] text-ink-secondary">
        {usage.costUsd === null ? "This engine doesn't report a price; tokens are counted." : `Cost ${costCaption(instance?.snapshot.billing)}.`}
      </div>
    </div>
  );
}

const inputCls =
  "w-full rounded-lg border border-hairline/40 bg-inset px-3 py-2.5 text-[15px] text-ink placeholder:text-ink-secondary focus:outline-none focus:border-hairline";

/** Where a bot's shell tools run. Set per bot; each task pins its own copy
 * on its first turn (the server does the pinning — Claude keeps sessions
 * per project folder, so a folder must not move under a live task). The
 * PATCH is made directly rather than through updateBot: the server
 * validates the path and a rejected folder must not stick in local state. */
function WorkingFolder({ bot }: { bot: Bot }) {
  const { capabilities } = useDesktopCapabilities();
  const home = capabilities.host.homeDir;
  const [draft, setDraft] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const canPick = Boolean(window.ogb?.pickFolder);
  const task = bot.tasks?.find((t) => t.threadId === bot.threadId);
  const pinned = task?.cwd; // undefined = not yet, null = legacy home, string = folder
  const pinnedElsewhere = pinned !== undefined && (pinned ?? undefined) !== bot.cwd;

  const save = async (cwd: string | null) => {
    setSaving(true);
    setError(null);
    try {
      await api(`/api/bots/${bot.id}`, { method: "PATCH", body: JSON.stringify({ cwd }) });
      setDraft(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  };
  const pick = async () => {
    const chosen = await window.ogb?.pickFolder?.(bot.cwd);
    if (chosen) void save(chosen);
  };

  return (
    <div className="rounded-xl bg-card p-4">
      <div className="text-[15px] font-medium text-ink">Working folder</div>
      <div className="mt-0.5 text-[13px] text-ink-secondary">Where this bot runs its shell and file tools.</div>
      {canPick ? (
        <div className="mt-3 flex items-center gap-2">
          <div className="min-w-0 flex-1 truncate rounded-lg border border-hairline/40 bg-inset px-3 py-2 font-mono text-[12.5px] text-ink" title={bot.cwd}>
            {bot.cwd ? shortPath(bot.cwd, home) : <span className="text-ink-secondary">Private bot workspace</span>}
          </div>
          <button onClick={() => void pick()} disabled={saving} className="flex shrink-0 items-center gap-1.5 rounded-lg bg-raised px-3 py-2 text-[13px] text-ink hover:bg-raised-hover disabled:opacity-50">
            <FolderOpen size={14} /> Choose…
          </button>
          {bot.cwd && (
            <button onClick={() => void save(null)} disabled={saving} className="shrink-0 rounded-lg px-2 py-2 text-[13px] text-ink-secondary hover:text-ink disabled:opacity-50">
              Clear
            </button>
          )}
        </div>
      ) : (
        <form
          className="mt-3 flex items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            // an emptied field clears the folder — the server wants null
            void save((draft ?? bot.cwd ?? "").trim() || null);
          }}
        >
          <input
            className={cn(inputCls, "font-mono text-[12.5px]")}
            placeholder="Private bot workspace — or an absolute path"
            value={draft ?? bot.cwd ?? ""}
            onChange={(e) => setDraft(e.target.value)}
          />
          <button type="submit" disabled={saving || draft === null} className="shrink-0 rounded-lg bg-raised px-3 py-2 text-[13px] text-ink hover:bg-raised-hover disabled:opacity-50">
            Save
          </button>
        </form>
      )}
      {error && <div className="mt-2 text-[12px] text-danger">{error}</div>}
      {pinnedElsewhere && (
        <div className="mt-2 text-[12px] text-ink-secondary">
          New tasks start here. This task is pinned to {pinned ? <span className="font-mono">{shortPath(pinned, home)}</span> : "the home folder"} — start a new task to use the new folder.
        </div>
      )}
    </div>
  );
}

interface MemoryTopic {
  name: string;
  bytes: number;
}

const formatBytes = (bytes: number) => (bytes < 1024 ? `${bytes} B` : `${Math.round(bytes / 102.4) / 10} KB`);

/** MEMORY.md + memory/ topic files, surfaced so the user can read and fix
 * what the bot believes. Fetched on expand, not on mount: settings opens for
 * every bot and most visits never look at memory — and an expand also
 * re-reads, so notes the bot wrote mid-session show up on the next open. */
function MemoryCard({ bot }: { bot: Bot }) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [dirty, setDirty] = useState(false);
  const [truncated, setTruncated] = useState(false);
  const [topics, setTopics] = useState<MemoryTopic[]>([]);
  const [saving, setSaving] = useState(false);
  const [topic, setTopic] = useState<{ name: string; text: string } | null>(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    setTopic(null);
    try {
      const result: { text: string; truncated: boolean; topics: MemoryTopic[] } = await api(
        `/api/bots/${bot.id}/memory`,
      );
      setText(result.text);
      setTruncated(result.truncated);
      setTopics(result.topics);
      setDirty(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const result: { truncated: boolean } = await api(`/api/bots/${bot.id}/memory`, {
        method: "PUT",
        body: JSON.stringify({ text }),
      });
      setTruncated(result.truncated);
      setDirty(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  };

  const openTopic = async (name: string) => {
    setError(null);
    try {
      setTopic(await api(`/api/bots/${bot.id}/memory/topics/${encodeURIComponent(name)}`));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="rounded-xl bg-card p-4">
      <button
        className="flex w-full items-center justify-between gap-4 text-left"
        aria-expanded={open}
        onClick={() => {
          const next = !open;
          setOpen(next);
          if (next) void load();
        }}
      >
        <div>
          <div className="text-[15px] font-medium text-ink">Memory</div>
          <div className="mt-0.5 text-[13px] text-ink-secondary">
            Notes this bot keeps between tasks — plain files you can edit.
          </div>
        </div>
        <ChevronDown size={16} className={cn("shrink-0 text-ink-secondary transition-transform", open && "rotate-180")} />
      </button>

      {open && loading && <div className="mt-3 text-[13px] text-ink-secondary">Loading…</div>}

      {open && !loading && topic && (
        <div className="mt-3">
          <div className="flex items-center justify-between gap-2">
            <span className="truncate font-mono text-[12.5px] text-ink">memory/{topic.name}</span>
            <button
              onClick={() => setTopic(null)}
              className="shrink-0 rounded-md px-2 py-1 text-[13px] text-ink-secondary hover:bg-raised hover:text-ink"
            >
              Back
            </button>
          </div>
          <pre className="mt-2 max-h-[240px] overflow-auto whitespace-pre-wrap rounded-lg border border-hairline/40 bg-inset p-3 font-mono text-[12.5px] leading-relaxed text-ink">
            {topic.text}
          </pre>
        </div>
      )}

      {open && !loading && !topic && (
        <div className="mt-3">
          <textarea
            className={cn(inputCls, "min-h-[160px] resize-y font-mono text-[12.5px] leading-relaxed")}
            value={text}
            placeholder="Nothing remembered yet. The bot writes durable notes here — or add your own."
            aria-label="Bot memory"
            onChange={(e) => {
              setText(e.target.value);
              setDirty(true);
            }}
          />
          <div className="mt-2 flex items-center gap-3">
            <button
              onClick={() => void save()}
              disabled={saving || !dirty}
              className="rounded-lg bg-raised px-3 py-1.5 text-[13px] text-ink hover:bg-raised-hover disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save"}
            </button>
            {truncated && (
              <span className="text-[11.5px] text-ink-secondary">
                Over the budget — only the top of this file loads each turn.
              </span>
            )}
          </div>
          {topics.length > 0 && (
            <div className="mt-3">
              <div className="mb-1.5 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
                Topic files
              </div>
              <div className="overflow-hidden rounded-lg border border-hairline/40">
                {topics.map((entry) => (
                  <button
                    key={entry.name}
                    onClick={() => void openTopic(entry.name)}
                    className="flex w-full items-center justify-between gap-2 border-b border-hairline/40 px-3 py-2 text-left last:border-b-0 hover:bg-raised/60"
                  >
                    <span className="truncate font-mono text-[12.5px] text-ink">{entry.name}</span>
                    <span className="shrink-0 text-[11.5px] text-ink-secondary">{formatBytes(entry.bytes)}</span>
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {error && <div className="mt-2 text-[12px] text-danger">{error}</div>}
    </div>
  );
}

/** The seed a stored URL carries, for a picture we cannot parse as a style. */
function seedOf(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url, "https://api.dicebear.com").searchParams.get("seed");
  } catch {
    return null;
  }
}

/** The same URL with another seed, leaving its other options alone. */
function withSeed(url: string | null | undefined, seed: string): string {
  const next = new URL(url ?? "https://api.dicebear.com/9.x/bottts/svg", "https://api.dicebear.com");
  next.searchParams.set("seed", seed);
  return next.toString();
}

/**
 * A seed field. For a locally drawn style every keystroke is free, so it types
 * live; for a fetched one each change costs a request, so it commits on Enter
 * or on leaving the field.
 */
function SeedInput({
  seed,
  commitOnBlur,
  onCommit,
}: {
  seed: string;
  commitOnBlur: boolean;
  onCommit: (seed: string) => void;
}) {
  const [draft, setDraft] = useState(seed);
  useEffect(() => setDraft(seed), [seed]);
  return (
    <input
      className={inputCls}
      value={commitOnBlur ? draft : seed}
      onChange={(e) => (commitOnBlur ? setDraft(e.target.value) : onCommit(e.target.value))}
      onBlur={() => commitOnBlur && draft !== seed && onCommit(draft)}
      onKeyDown={(e) => e.key === "Enter" && commitOnBlur && onCommit(draft)}
    />
  );
}

/**
 * DiceBear picture avatars. A picture replaces the mascot, so this is a mode
 * switch rather than another appearance knob: while one is set, shape,
 * expression and color describe a mascot nobody is looking at.
 *
 * What we store is the DiceBear URL itself — paste one from dicebear.com and
 * the style, the seed and every option chosen there come with it. Nothing is
 * fetched; the SVG is generated locally from the bundled styles.
 */
function PictureSection({
  bot,
  patch,
}: {
  bot: Bot;
  patch: (p: {
    mascotAvatar?: string | null;
    mascotAvatarSvg?: string | null;
    mascotAvatarImage?: string | null;
    mascotAvatarSheetRow?: number | null;
  }) => void;
}) {
  const ready = useDicebearReady();
  const picture = parseDicebearAvatar(bot.mascotAvatar);
  // A style we cannot draw was fetched once and stored as markup; its seed
  // lives in the URL beside it, and changing it means fetching again.
  const fetched = Boolean(bot.mascotAvatarSvg);
  const seed = picture?.seed ?? seedOf(bot.mascotAvatar) ?? bot.name;
  const [pasted, setPasted] = useState("");
  const [pasteError, setPasteError] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const meta = ready && picture ? dicebearMeta(picture.style) : null;

  /** Fetches a style this build cannot draw. The bot frame arrives over SSE. */
  const importRemote = async (url: string) => {
    setImporting(true);
    try {
      await api(`/api/bots/${bot.id}/avatar`, { method: "POST", body: JSON.stringify({ url }) });
      setPasteError(null);
      setPasted("");
    } catch (error) {
      setPasteError(error instanceof Error ? error.message : "Could not import that avatar");
    } finally {
      setImporting(false);
    }
  };

  /** Your own file. The bot frame comes back with whichever field it landed in. */
  const uploadPicture = async (rawFile: File) => {
    setImporting(true);
    try {
      // An oversized sheet is resampled here, before it is stored: sheets are
      // authored at sizes the browser then rescales on every single paint.
      // Anything that is not one is uploaded exactly as it was picked.
      const file = await downscaleSheetFile(rawFile);
      const response = await fetch(`/api/bots/${bot.id}/avatar/upload`, {
        method: "POST",
        headers: { "content-type": file.type || "application/octet-stream" },
        body: file,
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error ?? `${response.status} ${response.statusText}`);
      setPasteError(null);
    } catch (error) {
      setPasteError(error instanceof Error ? error.message : "Could not use that file");
    } finally {
      setImporting(false);
    }
  };

  const importPasted = () => {
    const result = importDicebearAvatar(pasted);
    if (result.ok) {
      setPasteError(null);
      setPasted("");
      const { spec } = result;
      patch({
        mascotAvatar: dicebearUrl(spec.style, spec.seed ?? seed, spec.options),
        mascotAvatarSvg: null,
        mascotAvatarImage: null,
        mascotAvatarSheetRow: null,
      });
      return;
    }
    if (result.reason === "not-dicebear") {
      setPasteError("That is not a DiceBear style or avatar URL.");
      return;
    }
    // A real DiceBear style we have no package for: fetch it once.
    void importRemote(pasted.trim());
  };

  /** Where a new seed goes: into the URL, or back to dicebear.com for it. */
  const applySeed = (next: string) => {
    if (fetched) {
      void importRemote(withSeed(bot.mascotAvatar, next));
      return;
    }
    if (!picture) return;
    patch({
      mascotAvatar: dicebearUrl(picture.style, next, picture.options),
      mascotAvatarSvg: null,
      mascotAvatarImage: null,
      mascotAvatarSheetRow: null,
    });
  };

  return (
    <div className="overflow-hidden rounded-xl border border-hairline/40 bg-card">
      <div className="flex items-center justify-between border-b border-hairline/40 px-3 py-2.5">
        <span className="rounded-lg bg-raised px-3 py-1.5 text-[14px] font-medium text-ink">
          Picture
        </span>
        {(picture || fetched || bot.mascotAvatarImage) && (
          <button
            onClick={() =>
              patch({ mascotAvatar: null, mascotAvatarSvg: null, mascotAvatarImage: null, mascotAvatarSheetRow: null })
            }
            className="rounded-md px-2 py-1.5 text-[13px] text-ink-secondary hover:bg-raised hover:text-ink"
          >
            Use the mascot
          </button>
        )}
      </div>

      <div className="p-3">
        <div className="mb-2 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
          Your own image
        </div>
        <label
          onDragOver={(e) => e.preventDefault()}
          onDrop={(e) => {
            e.preventDefault();
            const file = e.dataTransfer.files[0];
            if (file) void uploadPicture(file);
          }}
          className={cn(
            "flex cursor-pointer items-center gap-3 rounded-xl border border-dashed border-hairline/70 bg-inset px-3 py-2.5 text-[13px] text-ink-secondary transition-colors hover:bg-raised",
            importing && "opacity-60",
          )}
        >
          <input
            type="file"
            className="hidden"
            accept="image/png,image/jpeg,image/gif,image/webp,image/svg+xml"
            onChange={(e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (file) void uploadPicture(file);
            }}
          />
          {bot.mascotAvatarImage ? (
            <MausAvatar color={bot.color} look={bot} size={38} />
          ) : (
            <span className="flex size-[38px] shrink-0 items-center justify-center rounded-full bg-raised">
              <ImagePlus size={17} />
            </span>
          )}
          <span className="min-w-0 flex-1">
            {bot.mascotAvatarImage
              ? "Drop another image, or click to pick one"
              : "Drop a PNG, JPG, GIF, WebP or SVG here, or click to pick one"}
          </span>
        </label>
        {bot.mascotAvatarImage && (
          <div className="mt-3">
            <div className="text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
              How to use it
            </div>
            <p className="mt-1 text-[12px] text-ink-secondary">
              A still picture, or a 9 rows × 8 frames spritesheet animated one row at a time.
              Uploading picks whichever the image's own shape says it is.
            </p>
            <div className="mt-2 flex gap-2">
              {[
                { label: "Still image", sheet: false },
                { label: "Spritesheet", sheet: true },
              ].map((mode) => {
                const on = (clampSheetRow(bot.mascotAvatarSheetRow) != null) === mode.sheet;
                return (
                  <button
                    key={mode.label}
                    type="button"
                    onClick={() => patch({ mascotAvatarSheetRow: mode.sheet ? 0 : null })}
                    aria-pressed={on}
                    className={cn(
                      "rounded-lg px-3 py-1.5 text-[13px] font-medium",
                      on ? "bg-raised text-ink ring-2 ring-accent-border" : "bg-inset text-ink-secondary hover:bg-raised hover:text-ink",
                    )}
                  >
                    {mode.label}
                  </button>
                );
              })}
            </div>
            {clampSheetRow(bot.mascotAvatarSheetRow) != null && (
              <>
                <div className="mt-3 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
                  Spritesheet row
                </div>
                <div className="mt-2 grid grid-cols-3 gap-2">
                  {Array.from({ length: SHEET_ROWS }, (_, row) => {
                    const selected = clampSheetRow(bot.mascotAvatarSheetRow) === row;
                    return (
                      <button
                        key={row}
                        type="button"
                        onClick={() => patch({ mascotAvatarSheetRow: row })}
                        className={cn(
                          "flex flex-col items-center gap-1 rounded-xl bg-inset px-2 py-2 hover:bg-raised",
                          selected && "ring-2 ring-accent-border",
                        )}
                        aria-pressed={selected}
                        aria-label={`Animate sheet row ${row + 1}`}
                      >
                        <SpriteSheetAvatar
                          src={`/api/attachments/${encodeURIComponent(bot.mascotAvatarImage!)}`}
                          row={row}
                          size={44}
                        />
                        <span className="text-[11px] text-ink-secondary">{row + 1}</span>
                      </button>
                    );
                  })}
                </div>
              </>
            )}
          </div>
        )}

        <div className="mb-2 mt-4 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
          Import from dicebear.com
        </div>
        <div className="flex gap-2">
          <input
            className={inputCls}
            placeholder="https://api.dicebear.com/9.x/bottts/svg?seed=Mira"
            value={pasted}
            onChange={(e) => {
              setPasted(e.target.value);
              setPasteError(null);
            }}
            onKeyDown={(e) => e.key === "Enter" && importPasted()}
          />
          <button
            onClick={importPasted}
            disabled={!pasted.trim() || importing}
            className="shrink-0 rounded-lg bg-raised px-3 text-[13px] font-medium text-ink hover:bg-inset disabled:opacity-40"
          >
            {importing ? "Importing…" : "Import"}
          </button>
        </div>
        {pasteError ? (
          <p className="mt-1.5 text-[12px] text-danger">{pasteError}</p>
        ) : (
          <p className="mt-1.5 text-[12px] text-ink-secondary">
            Build one on dicebear.com and paste its URL — the options you picked come with it.
          </p>
        )}

        {(picture || fetched) && (
          <>
            <div className="mb-2 mt-4 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
              Seed
            </div>
            <div className="flex gap-2">
              <SeedInput seed={seed} commitOnBlur={fetched} onCommit={applySeed} />
              <button
                onClick={() => applySeed(randomSeed())}
                disabled={importing}
                className="shrink-0 rounded-lg bg-raised px-3 text-[13px] font-medium text-ink hover:bg-inset disabled:opacity-40"
              >
                Randomize
              </button>
            </div>
          </>
        )}

        <div className="mb-2 mt-4 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
          Style
        </div>
        <div className="grid grid-cols-5 gap-2">
          {DICEBEAR_STYLE_IDS.map((style) => (
            <button
              key={style}
              // The options belong to the style that was showing when they were
              // picked, so a style change keeps only the seed.
              onClick={() =>
                patch({
                  mascotAvatar: dicebearUrl(style, seed),
                  mascotAvatarSvg: null,
                  mascotAvatarImage: null,
                  mascotAvatarSheetRow: null,
                })
              }
              className={cn(
                "flex h-[58px] items-center justify-center rounded-xl bg-inset transition-colors hover:bg-raised",
                picture?.style === style && "ring-2 ring-accent-border",
              )}
              title={style}
              aria-label={`Use the ${style} picture style`}
            >
              <DicebearAvatar avatar={dicebearUrl(style, seed)} size={42} />
            </button>
          ))}
        </div>
        {fetched && (
          <p className="mt-2.5 text-[12px] text-ink-secondary">
            Wearing the {dicebearStyleSlug(bot.mascotAvatar) ?? "imported"} style, fetched from
            dicebear.com once and stored with this bot. Picking one above swaps to a style drawn
            here.
          </p>
        )}
        {meta && (
          <p className="mt-2.5 text-[12px] text-ink-secondary">
            {meta.title}
            {meta.creator ? ` by ${meta.creator}` : ""}
            {meta.license && (
              <>
                {" — "}
                <a
                  className="underline hover:text-ink"
                  href={meta.license.url}
                  target="_blank"
                  rel="noreferrer"
                >
                  {meta.license.name}
                </a>
              </>
            )}
          </p>
        )}
      </div>
    </div>
  );
}

/**
 * False on the first render, true from the next frame. The appearance
 * galleries below are twenty mascots and nine sheet previews — mounting them
 * in the same commit as the panel is what makes opening it feel slow, so the
 * panel paints first and they arrive a frame later into placeholders of the
 * same size.
 */
function useAfterFirstPaint(): boolean {
  const [painted, setPainted] = useState(false);
  useEffect(() => {
    const frame = requestAnimationFrame(() => setPainted(true));
    return () => cancelAnimationFrame(frame);
  }, []);
  return painted;
}

/** Same footprint as a gallery, none of its cost, for that one frame. */
function GalleryPlaceholder({ count }: { count: number }) {
  return (
    <div className="grid grid-cols-5 gap-2" aria-hidden>
      {Array.from({ length: count }, (_, cell) => (
        <div key={cell} className="h-[58px] rounded-xl bg-inset" />
      ))}
    </div>
  );
}

export function SettingsPanel({ bot }: { bot: Bot }) {
  const painted = useAfterFirstPaint();
  const { state, dispatch } = useStore();
  const [voices, setVoices] = useState<Array<{ id: string; label: string; description?: string }>>([]);
  const [voicesLoading, setVoicesLoading] = useState(false);
  const patch = (
    p: Partial<
      Pick<
        Bot,
        | "name"
        | "title"
        | "description"
        | "notifications"
        | "computer"
        | "cloudBackend"
        | "color"
        | "mascotExpression"
        | "mascotSilhouette"
        | "mascotAvatar"
        | "mascotAvatarSvg"
        | "mascotAvatarImage"
        | "mascotAvatarSheetRow"
        | "autoApprove"
        | "speakReplies"
        | "voice"
        | "chiefOfStaff"
        | "approvePeerComms"
        | "composio"
        | "modelSelection"
      >
    >,
  ) => dispatch({ type: "updateBot", botId: bot.id, patch: p });
  const activeState = stateForBot(bot);
  const activeSilhouette = normalizeSilhouette(bot.mascotSilhouette);
  const hasPicture = wearsPicture(bot);
  const mascotMotion = state.mascotMotion?.botId === bot.id ? state.mascotMotion : null;
  const engine = state.instances.find((instance) => instance.instanceId === bot.modelSelection.instanceId);
  const canCoordinate = engine?.capabilities?.agentsMcp === true;
  const canUseConnectedApps = engine?.capabilities?.composioMcp === true;
  const connectedAppsConfigured = state.config?.composio?.configured === true;
  const connectedAppsEnabled = bot.composio !== false;
  const currentChief = state.bots.find((candidate) => candidate.chiefOfStaff);

  useEffect(() => {
    if (!state.config?.tts?.configured) {
      setVoices([]);
      return;
    }
    let alive = true;
    setVoicesLoading(true);
    api("/api/tts/voices")
      .then((result: { voices?: typeof voices }) => alive && setVoices(result.voices ?? []))
      .catch(() => alive && setVoices([]))
      .finally(() => alive && setVoicesLoading(false));
    return () => {
      alive = false;
    };
  }, [state.config?.tts?.configured]);

  return (
    <aside className="animate-panel-in flex h-full w-[400px] shrink-0 flex-col border-l border-hairline/40 bg-panel">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3">
        <button
          onClick={() => dispatch({ type: "toggleSettings", open: false })}
          className="rounded-md p-1 text-ink-secondary hover:bg-raised hover:text-ink"
        >
          <ChevronLeft size={18} />
        </button>
        <span className="text-[15px] font-semibold text-ink">Settings</span>
        <button
          onClick={() => dispatch({ type: "toggleSettings", open: false })}
          className="rounded-md p-1 text-ink-secondary hover:bg-raised hover:text-ink"
        >
          <X size={18} />
        </button>
      </div>

      <div className="flex-1 overflow-y-auto px-5 pb-5">
        <div className="flex justify-center py-5">
          <MausAvatar
            color={bot.color} look={bot}
            state={activeState}
            size={112}
            motion={mascotMotion?.kind ?? "none"}
            motionKey={mascotMotion?.nonce ?? 0}
          />
        </div>

        <div className="flex flex-col gap-4">
          <div className="overflow-hidden rounded-xl border border-hairline/40 bg-card">
            <div className="flex items-center justify-between border-b border-hairline/40 px-3 py-2.5">
              <span className="rounded-lg bg-raised px-3 py-1.5 text-[14px] font-medium text-ink">
                Bot
              </span>
              <button
                onClick={() =>
                  patch({
                    color: "green",
                    mascotExpression: null,
                    mascotSilhouette: null,
                    mascotAvatar: null,
                    mascotAvatarSvg: null,
                    mascotAvatarImage: null,
                    mascotAvatarSheetRow: null,
                  })
                }
                className="rounded-md px-2 py-1.5 text-[13px] text-ink-secondary hover:bg-raised hover:text-ink"
              >
                Reset
              </button>
            </div>

            <div className={cn("p-3", hasPicture && "opacity-50")}>
              {hasPicture && (
                <p className="mb-3 text-[12px] text-ink-secondary">
                  This bot wears a picture. Shape, expression and color describe its mascot,
                  which comes back as soon as you clear the picture.
                </p>
              )}
              <div className="mb-2 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
                Shape
              </div>
              {!painted ? (
                <GalleryPlaceholder count={MAUS_SILHOUETTE_IDS.length} />
              ) : (
              <div className="grid grid-cols-5 gap-2">
                {MAUS_SILHOUETTE_IDS.map((silhouette) => (
                  <button
                    key={silhouette}
                    onClick={() => patch({ mascotSilhouette: silhouette })}
                    className={cn(
                      "flex h-[58px] items-center justify-center rounded-xl bg-inset transition-colors hover:bg-raised",
                      activeSilhouette === silhouette && "ring-2 ring-accent-border",
                    )}
                    title={silhouette}
                    aria-label={`Use the ${silhouette} shape`}
                  >
                    <MausAvatar
                      color={bot.color}
                      silhouette={silhouette}
                      state={activeState}
                      size={42}
                      animated={false}
                    />
                  </button>
                ))}
              </div>
              )}

              <div className="mb-2 mt-4 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
                Expression
              </div>
              {!painted ? (
                <GalleryPlaceholder count={PICKABLE_STATES.length} />
              ) : (
              <div className="grid grid-cols-5 gap-2">
                {PICKABLE_STATES.map((expression) => (
                  <button
                    key={expression}
                    onClick={() => patch({ mascotExpression: expression })}
                    className={cn(
                      "flex h-[58px] items-center justify-center rounded-xl bg-inset transition-colors hover:bg-raised",
                      activeState === expression && "ring-2 ring-accent-border",
                    )}
                    title={expression}
                    aria-label={`Use ${expression} expression`}
                  >
                    <MausAvatar
                      color={bot.color}
                      silhouette={activeSilhouette}
                      state={expression}
                      size={42}
                      animated={false}
                    />
                  </button>
                ))}
              </div>
              )}

              <div className="mb-2 mt-4 text-[12px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
                Color
              </div>
              <div className="flex flex-wrap gap-2.5">
                {MAUS_COLOR_NAMES.map((color) => (
                  <button
                    key={color}
                    onClick={() => patch({ color })}
                    className={cn(
                      "size-8 rounded-full border-2 border-transparent transition-transform hover:scale-110",
                      bot.color === color && "ring-2 ring-accent-border ring-offset-2 ring-offset-card",
                    )}
                    style={{ backgroundColor: MAUS_COLORS[color] }}
                    title={color}
                    aria-label={`Use ${color} mascot color`}
                  />
                ))}
              </div>
            </div>
          </div>

          <PictureSection bot={bot} patch={patch} />

          <Field label="Name">
            <input
              className={inputCls}
              value={bot.name}
              onChange={(e) => patch({ name: e.target.value })}
            />
          </Field>
          <Field label="Title">
            <input
              className={inputCls}
              placeholder="Describe what your agent does"
              value={bot.title}
              onChange={(e) => patch({ title: e.target.value })}
            />
          </Field>
          <Field label="Description">
            <textarea
              className={cn(inputCls, "min-h-[96px] resize-none")}
              placeholder="What this agent is for"
              value={bot.description}
              onChange={(e) => patch({ description: e.target.value })}
            />
          </Field>

          <div className={cn(
            "rounded-xl border p-4",
            bot.chiefOfStaff ? "border-accent/40 bg-accent/10" : "border-hairline/40 bg-card",
          )}>
            <div className="flex items-center gap-3">
              <span className={cn(
                "flex size-8 shrink-0 items-center justify-center rounded-lg",
                bot.chiefOfStaff ? "bg-accent text-white" : "bg-raised text-ink-secondary",
              )}>
                <Crown size={17} />
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-[15px] font-medium text-ink">Chief of Staff</div>
                <div className="text-[11.5px] text-ink-secondary">One per workspace</div>
              </div>
              <button
                role="switch"
                aria-checked={Boolean(bot.chiefOfStaff)}
                aria-label="Chief of Staff"
                disabled={!bot.chiefOfStaff && !canCoordinate}
                onClick={() => patch({ chiefOfStaff: !bot.chiefOfStaff })}
                title={!bot.chiefOfStaff && !canCoordinate ? "This engine cannot contact other bots" : undefined}
                className={cn(
                  "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-40",
                  bot.chiefOfStaff ? "bg-accent" : "bg-raised",
                )}
              >
                <span
                  className={cn(
                    "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                    bot.chiefOfStaff ? "left-[21px]" : "left-[3px]",
                  )}
                />
              </button>
            </div>
            <div className="mt-3 text-[13px] leading-relaxed text-ink-secondary">
              {bot.chiefOfStaff && !canCoordinate
                ? "This bot still holds the role, but its current engine cannot contact teammates. Choose a Claude or ACP engine to restore coordination."
                : bot.chiefOfStaff
                  ? "This is your primary contact. It can coordinate the other bots and combine their work into one answer."
                : !canCoordinate
                  ? "Choose a Claude or ACP engine to let this bot coordinate teammates."
                  : currentChief
                    ? `Make this bot your primary contact and hand the role over from ${currentChief.name}.`
                    : "Make this bot your primary contact for work that may involve several bots."}
            </div>
          </div>

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">
                Ask me before contacting other bots
              </div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                {bot.approvePeerComms
                  ? "This bot will stop and ask before it reaches out to another bot."
                  : "Let this bot talk to teammates on its own, without a confirmation step."}
              </div>
            </div>
            <button
              role="switch"
              aria-checked={Boolean(bot.approvePeerComms)}
              aria-label="Ask me before contacting other bots"
              disabled={!bot.approvePeerComms && !canCoordinate}
              onClick={() => patch({ approvePeerComms: !bot.approvePeerComms })}
              title={!bot.approvePeerComms && !canCoordinate ? "This engine cannot contact other bots" : undefined}
              className={cn(
                "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-40",
                bot.approvePeerComms ? "bg-accent" : "bg-raised",
              )}
            >
              <span
                className={cn(
                  "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                  bot.approvePeerComms ? "left-[21px]" : "left-[3px]",
                )}
              />
            </button>
          </div>

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">Connected apps</div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                {!connectedAppsConfigured
                  ? "Connect apps in App Settings before giving this bot access."
                  : !canUseConnectedApps
                    ? "This bot's current engine cannot use connected apps."
                    : connectedAppsEnabled
                      ? "Let this bot use your connected Gmail, Calendar, Slack, and other apps."
                      : "Keep your connected apps unavailable to this bot."}
              </div>
            </div>
            <button
              role="switch"
              aria-checked={connectedAppsEnabled}
              aria-label="Allow this bot to use connected apps"
              disabled={
                !connectedAppsEnabled && (!connectedAppsConfigured || !canUseConnectedApps)
              }
              onClick={() => patch({ composio: !connectedAppsEnabled })}
              title={
                !connectedAppsEnabled && !connectedAppsConfigured
                  ? "Connect apps in App Settings first"
                  : !connectedAppsEnabled && !canUseConnectedApps
                    ? "This engine cannot use connected apps"
                    : undefined
              }
              className={cn(
                "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-40",
                connectedAppsEnabled ? "bg-accent" : "bg-raised",
              )}
            >
              <span
                className={cn(
                  "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                  connectedAppsEnabled ? "left-[21px]" : "left-[3px]",
                )}
              />
            </button>
          </div>

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">Model</div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                Which provider and model this bot runs on
              </div>
            </div>
            <ModelPicker bot={bot} />
          </div>

          {!!engine?.capabilities?.effortLevels?.length && (
            <div className="rounded-xl bg-card p-4">
              <div className="text-[15px] font-medium text-ink">Effort</div>
              {/* Says what the app does, not what the engine ends up at:
                  Codex applies a level to the whole thread and has no way to
                  take one back, so "currently: engine default" was a promise
                  we could not keep for a thread that had already been sent
                  one. Sending nothing is true on every engine. */}
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                How hard this bot thinks{bot.modelSelection.effort ? "" : " (Default: no level is sent)"}
              </div>
              <div className="mt-3 flex overflow-hidden rounded-lg border border-hairline/40">
                {([undefined, ...engine.capabilities.effortLevels] as const).map((level, i) => (
                  <button
                    key={level ?? "default"}
                    aria-pressed={bot.modelSelection.effort === level}
                    onClick={() => patch({ modelSelection: { ...bot.modelSelection, effort: level } })}
                    className={cn(
                      "flex-1 py-1.5 text-[13px] capitalize",
                      i > 0 && "border-l border-hairline/40",
                      bot.modelSelection.effort === level
                        ? "bg-raised text-ink"
                        : "text-ink-secondary hover:bg-raised/60 hover:text-ink",
                    )}
                  >
                    {/* the others capitalize cleanly; "xhigh" would read "Xhigh" */}
                    {level === "xhigh" ? "X-High" : (level ?? "Default")}
                  </button>
                ))}
              </div>
            </div>
          )}

          <div className="rounded-xl bg-card p-4">
            <div className="text-[15px] font-medium text-ink">Computer</div>
            <div className="mt-0.5 text-[13px] text-ink-secondary">
              Local VM or off. Host desktop control is disabled.
            </div>
            <div className="mt-3 flex overflow-hidden rounded-lg border border-hairline/40">
              {([
                ["vm", "Local VM"],
                ["off", "Off"],
              ] as const).map(([mode, label], i) => (
                <button
                  key={mode}
                  onClick={() => patch({ computer: mode })}
                  className={cn(
                    "flex-1 py-1.5 text-[13px] capitalize",
                    i > 0 && "border-l border-hairline/40",
                    (bot.computer === mode || (mode === "off" && bot.computer !== "vm"))
                      ? "bg-raised text-ink"
                      : "text-ink-secondary hover:bg-raised/60 hover:text-ink",
                  )}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>

          <BotUsageCard bot={bot} />
          <WorkingFolder bot={bot} />

          {/* keyed so switching bots never shows one bot's notes under another's name */}
          <MemoryCard key={bot.id} bot={bot} />

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">Auto mode</div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                {bot.autoApprove
                  ? bot.computer === "local"
                    ? "Keeps going on its own — you'll still be asked about anything destructive, questions it asks you, and every action on this computer."
                    : "Keeps going on its own — you'll still be asked about anything destructive, and about questions it asks you."
                  : bot.computer === "local"
                    ? "Approve each action yourself. Turn on to let this bot keep working without stopping to ask — clicks and typing on this computer still need your approval."
                    : "Approve each action yourself. Turn on to let this bot keep working without stopping to ask."}
              </div>
            </div>
            <button
              role="switch"
              aria-checked={Boolean(bot.autoApprove)}
              aria-label="Auto mode"
              onClick={() => patch({ autoApprove: !bot.autoApprove })}
              className={cn(
                "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors",
                bot.autoApprove ? "bg-accent" : "bg-raised",
              )}
            >
              <span
                className={cn(
                  "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                  bot.autoApprove ? "left-[21px]" : "left-[3px]",
                )}
              />
            </button>
          </div>

          {state.config?.tts?.configured && (
            <div className="rounded-xl bg-card p-4">
              <div className="text-[15px] font-medium text-ink">Bot voice</div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                Use a distinct voice for calls and spoken replies, or inherit the app default
              </div>
              <select
                value={bot.voice ?? ""}
                onChange={(e) => patch({ voice: e.target.value })}
                aria-label={`${bot.name}'s voice`}
                className="mt-3 w-full rounded-lg border border-hairline/40 bg-inset px-3 py-2 text-[13px] text-ink focus:border-hairline focus:outline-none"
              >
                <option value="">App default</option>
                {bot.voice && !voices.some((voice) => voice.id === bot.voice) && (
                  <option value={bot.voice}>Current bot voice</option>
                )}
                {voices.map((voice) => (
                  <option key={voice.id} value={voice.id}>
                    {voice.label}{voice.description ? ` — ${voice.description}` : ""}
                  </option>
                ))}
              </select>
              {voicesLoading && <div className="mt-1.5 text-[11.5px] text-ink-secondary">Loading voices…</div>}
            </div>
          )}

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">Read replies aloud</div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                Speak this bot's answers as they arrive, even when you're in another chat
              </div>
            </div>
            <button
              role="switch"
              aria-checked={Boolean(bot.speakReplies)}
              aria-label="Read this bot's replies aloud"
              onClick={() => patch({ speakReplies: !bot.speakReplies })}
              className={cn(
                "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors",
                bot.speakReplies ? "bg-accent" : "bg-raised",
              )}
            >
              <span
                className={cn(
                  "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                  bot.speakReplies ? "left-[21px]" : "left-[3px]",
                )}
              />
            </button>
          </div>

          <div className="flex items-center justify-between gap-4 rounded-xl bg-card p-4">
            <div>
              <div className="text-[15px] font-medium text-ink">
                Notifications
              </div>
              <div className="mt-0.5 text-[13px] text-ink-secondary">
                Get notified when this agent finishes or needs input
              </div>
            </div>
            <button
              role="switch"
              aria-checked={bot.notifications}
              onClick={() => {
                const enabled = !bot.notifications;
                if (enabled) void requestNotificationPermission();
                patch({ notifications: enabled });
              }}
              className={cn(
                "relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors",
                bot.notifications ? "bg-accent" : "bg-raised",
              )}
            >
              <span
                className={cn(
                  "absolute top-[3px] size-5 rounded-full bg-white transition-all",
                  bot.notifications ? "left-[21px]" : "left-[3px]",
                )}
              />
            </button>
          </div>
        </div>
      </div>
    </aside>
  );
}
