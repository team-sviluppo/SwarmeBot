// A bot's tasks: separate contexts on the same bot.
//
// One endless thread per bot means every job contaminates the next, and
// the only clean slate is a second bot. A task is a real boundary — its
// own transcript and its own provider session — so sensitive work, a
// long job and a quick question can sit side by side under one agent.
import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Pin, Plus, Trash2 } from "lucide-react";
import { useStore, formatTime, type Bot, type Task } from "@/state/store";
import { cn } from "@/lib/cn";
import { formatTokens } from "@/lib/format-tokens";

/** Quiet per-task token tally — input+output combined, because one honest
 * total reads faster than a split; the split lives in the hover title. */
function TaskUsage({ usage }: { usage: Task["usage"] }) {
  if (!usage) return null;
  const label = formatTokens(usage.input + usage.output);
  if (!label) return null;
  return (
    <span title={`${usage.input.toLocaleString()} in · ${usage.output.toLocaleString()} out`}>
      {" · "}
      {label}
    </span>
  );
}

export function TaskPicker({ bot }: { bot: Bot }) {
  const { dispatch } = useStore();
  const [open, setOpen] = useState(false);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [pinnedOnly, setPinnedOnly] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const tasks = bot.tasks ?? [];
  const current = tasks.find((t) => t.threadId === bot.threadId);
  const listed = (pinnedOnly ? tasks.filter((t) => t.pinned) : tasks).slice().sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned));

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      // SAFETY: a mousedown target inside a document is always a DOM Node
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // a bot that has only ever done one thing doesn't need a switcher yet —
  // just the button that gives it a second context
  if (tasks.length <= 1) {
    return (
      <button
        onClick={() => dispatch({ type: "newTask", botId: bot.id })}
        disabled={bot.busy}
        title={bot.busy ? "Let this turn finish first" : "New task — a fresh context on this bot"}
        className="flex items-center gap-1 rounded-full border border-hairline/40 px-2.5 py-1 text-[12.5px] text-ink-secondary hover:bg-raised hover:text-ink disabled:opacity-40"
      >
        <Plus size={12} /> Task
      </button>
    );
  }

  const commitRename = (threadId: string) => {
    const title = draft.trim();
    setRenaming(null);
    if (title) dispatch({ type: "renameTask", botId: bot.id, threadId, title });
  };

  // the picker button stays as-is — a token count next to a truncated title
  // and count would crowd it; the open task's tally rides the hover title
  const u = current?.usage;
  const currentLabel = u ? formatTokens(u.input + u.output) : null;
  const switchTitle =
    u && currentLabel
      ? `Switch task · ${currentLabel} (${u.input.toLocaleString()} in · ${u.output.toLocaleString()} out)`
      : "Switch task";

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen((o) => !o)}
        title={switchTitle}
        className="flex max-w-[220px] items-center gap-1.5 rounded-full border border-hairline/40 px-2.5 py-1 text-[12.5px] text-ink-secondary hover:bg-raised hover:text-ink"
      >
        <span className="truncate">{current?.title ?? "Task"}</span>
        <span className="shrink-0 tabular-nums opacity-60">{tasks.length}</span>
        {current?.pinned && <Pin size={11} className="shrink-0 text-accent" />}
        <ChevronDown size={12} className="shrink-0" />
      </button>

      {open && (
        <div className="absolute right-0 top-full z-40 mt-1 w-[300px] overflow-hidden rounded-xl border border-hairline/50 bg-card py-1 shadow-2xl shadow-black/50">
          <button
            onClick={() => setPinnedOnly((v) => !v)}
            className={cn(
              "mx-1 mb-1 flex w-[calc(100%-8px)] items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[12px]",
              pinnedOnly ? "bg-accent/12 text-accent" : "text-ink-secondary hover:bg-raised/50 hover:text-ink",
            )}
          >
            <Pin size={12} />
            {pinnedOnly ? "Showing pinned only" : "Show pinned only"}
          </button>
          <div className="max-h-[320px] overflow-y-auto">
            {listed.length === 0 && (
              <div className="px-3 py-4 text-center text-[12px] text-ink-secondary">No pinned conversations</div>
            )}
            {listed.map((task) => {
              const active = task.threadId === bot.threadId;
              return (
                <div
                  key={task.threadId}
                  className={cn("group flex items-center gap-2 px-2.5 py-2", active ? "bg-raised/60" : "hover:bg-raised/40")}
                >
                  <Check size={13} className={cn("shrink-0", active ? "text-accent" : "opacity-0")} />
                  {renaming === task.threadId ? (
                    <input
                      autoFocus
                      value={draft}
                      onChange={(e) => setDraft(e.target.value)}
                      onBlur={() => commitRename(task.threadId)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") commitRename(task.threadId);
                        if (e.key === "Escape") setRenaming(null);
                      }}
                      className="min-w-0 flex-1 rounded bg-inset px-1.5 py-0.5 text-[13px] text-ink focus:outline-none"
                    />
                  ) : (
                    <button
                      onClick={() => {
                        if (!active) dispatch({ type: "switchTask", botId: bot.id, threadId: task.threadId });
                        setOpen(false);
                      }}
                      onDoubleClick={() => {
                        setDraft(task.title);
                        setRenaming(task.threadId);
                      }}
                      className="min-w-0 flex-1 text-left"
                      title="Click to switch · double-click to rename"
                    >
                      <div className="flex items-center gap-1 truncate text-[13px] text-ink">
                        {task.pinned && <Pin size={11} className="shrink-0 text-accent" />}
                        <span className="truncate">{task.title}</span>
                      </div>
                      <div className="text-[11px] text-ink-secondary">
                        {formatTime(task.createdAt)}
                        <TaskUsage usage={task.usage} />
                      </div>
                    </button>
                  )}
                  <button
                    onClick={() =>
                      dispatch({ type: "pinTask", botId: bot.id, threadId: task.threadId, pinned: !task.pinned })
                    }
                    aria-label={task.pinned ? "Unpin conversation" : "Pin conversation"}
                    title={task.pinned ? "Unpin" : "Pin this conversation"}
                    className={cn(
                      "rounded p-1 hover:bg-raised",
                      task.pinned ? "text-accent" : "text-ink-secondary opacity-0 group-hover:opacity-100",
                    )}
                  >
                    <Pin size={13} />
                  </button>
                  <button
                    onClick={() => {
                      if (task.pinned) return;
                      dispatch({ type: "deleteTask", botId: bot.id, threadId: task.threadId });
                    }}
                    disabled={task.pinned || (bot.busy && active)}
                    aria-label="Delete task"
                    title={task.pinned ? "Unpin this conversation before deleting" : "Delete this task and its conversation"}
                    className="rounded p-1 text-ink-secondary opacity-0 hover:bg-raised hover:text-danger group-hover:opacity-100 disabled:opacity-20"
                  >
                    <Trash2 size={13} />
                  </button>
                </div>
              );
            })}
          </div>
          <button
            onClick={() => {
              dispatch({ type: "newTask", botId: bot.id });
              setOpen(false);
            }}
            disabled={bot.busy}
            className="mt-1 flex w-full items-center gap-2 border-t border-hairline/40 px-3 py-2 text-left text-[13px] text-ink hover:bg-raised/50 disabled:opacity-40"
          >
            <Plus size={13} className="text-ink-secondary" /> New task
          </button>
        </div>
      )}
    </div>
  );
}
