import { track } from "@/lib/analytics";
import { Fragment, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  Archive,
  ArrowDownToLine,
  BellDot,
  Bot as BotIcon,
  CalendarDays,
  Check,
  ChevronRight,
  ClipboardCopy,
  Copy,
  Crown,
  FolderMinus,
  FolderPlus,
  Library,
  Loader2,
  ArrowDown,
  ArrowUp,
  GripVertical,
  MoreHorizontal,
  Pencil,
  Pin,
  PinOff,
  Plus,
  RefreshCw,
  Search,
  Settings,
  Puzzle,
  Trash2,
  Users,
  X,
} from "lucide-react";
import { api, useStore, formatTime, visibleMessages, type Bot, type Group } from "@/state/store";

import { MausAvatar, InitialsAvatar } from "./Avatar";
import { stateForBot } from "@/lib/mascot";
import { useUpdaterState } from "@/lib/updater";
import { cn } from "@/lib/cn";
import { moveSection, nudgeSection, orderSections, renameInOrder } from "@/lib/section-order";
import { downloadAllBots } from "@/lib/team-files";
import { useDesktopCapabilities } from "./DesktopCapabilities";
import { MIN_QUERY, SearchResults } from "./SearchResults";
import { TeamLibraryPanel, type TeamImportResult } from "./TeamLibraryPanel";
import { RenameTitle } from "./RenameTitle";

/** "Milind Soni" → "MS", "milind" → "M", "you@x.dev" → "Y", unset → "?" */
function profileInitials(profile?: { name?: string; email?: string }): string {
  const name = profile?.name?.trim();
  if (name) {
    const words = name.split(/\s+/);
    return words
      .slice(0, 2)
      .map((w) => w[0]!.toUpperCase())
      .join("");
  }
  const email = profile?.email?.trim();
  return email ? email[0]!.toUpperCase() : "?";
}

/** Manual update check, next to the settings gear. Packaged app only (no
 * bridge in dev/browser). One button, state-dependent: check → download →
 * restart, with a brief "up to date" tick when a check finds nothing so a
 * click is never silent. The bottom-left popup handles the loud cases. */
function UpdateButton() {
  const s = useUpdaterState();
  const [checkedAt, setCheckedAt] = useState(0);
  const updater = window.ogb?.updater;
  const status = s?.status ?? "idle";
  // download and install both round-trip through main before the status
  // changes — spin on the click itself, and let the new status clear it
  const [pending, setPending] = useState(false);
  useEffect(() => setPending(false), [status]);
  // a check that found nothing lands back on idle — acknowledge it for 3s
  const upToDate = Boolean(checkedAt) && (!s || s.status === "idle") && Date.now() - checkedAt < 3000;
  useEffect(() => {
    if (!upToDate) return;
    const timer = setTimeout(() => setCheckedAt(0), 3000);
    return () => clearTimeout(timer);
  }, [upToDate]);
  if (!updater) return null;

  const working =
    pending || status === "checking" || status === "downloading" || status === "installing";
  const label =
    status === "available"
      ? `Version ${s?.version ?? ""} available — download`
      : status === "downloading"
        ? s?.percent == null
          ? "Starting download…"
          : `Downloading… ${Math.round(s.percent)}%`
        : status === "downloaded"
          ? `Version ${s?.version ?? ""} ready — restart to update`
          : status === "installing"
            ? "Restarting to update…"
            : status === "checking"
              ? "Checking for updates…"
              : upToDate
                ? "You're up to date"
                : "Check for updates";

  return (
    <button
      onClick={() => {
        if (status === "downloaded") {
          setPending(true);
          return void updater.install();
        }
        if (status === "available") {
          setPending(true);
          return void updater.download();
        }
        setCheckedAt(Date.now());
        void updater.check();
      }}
      disabled={working}
      title={label}
      aria-label={label}
      className="relative rounded-md p-2 text-accent hover:bg-raised disabled:opacity-60"
    >
      {working ? (
        <Loader2 size={18} className="animate-spin" />
      ) : upToDate ? (
        <Check size={18} />
      ) : status === "available" ? (
        <ArrowDownToLine size={18} />
      ) : (
        <RefreshCw size={18} />
      )}
      {status === "downloaded" && (
        <span className="absolute right-1.5 top-1.5 size-2 rounded-full bg-accent" />
      )}
    </button>
  );
}

function preview(bot: Bot): string {
  if (bot.activity === "waiting-on-you") return "Waiting for you…";
  if (bot.busy) return "Working…";
  // the visible branch's tail — bot.messages holds every fork, so its last
  // entry can belong to a version the user switched away from
  const last = visibleMessages(bot).at(-1);
  if (!last) return "";
  if (last.kind === "options" && last.card) return last.card.title;
  if (last.kind === "activity" && last.tool) return last.tool.name;
  if (last.kind === "screen") return "Screen frame";
  return last.text ?? "";
}

interface MenuState {
  botId: string;
  x: number;
  y: number;
}

function groupPreview(group: Group, bots: Bot[]): string {
  if (group.busyBotId) {
    return `${bots.find((b) => b.id === group.busyBotId)?.name ?? "A bot"} is working…`;
  }
  const last = group.messages.at(-1);
  if (!last) return "No messages yet";
  const text = last.kind === "activity" && last.tool ? last.tool.name : (last.text ?? "");
  if (last.role === "user") return `You: ${text}`;
  return last.from ? `${last.from.name}: ${text}` : text;
}

/** Room avatar: 2–3 overlapping mauses in the same 56px slot a bot gets. */
function StackedMauses({ members }: { members: Bot[] }) {
  if (members.length <= 1) {
    const b = members[0];
    return (
      <div className="flex size-14 shrink-0 items-center justify-center">
        {b ? <MausAvatar color={b.color} look={b} state="happy" size={56} /> : <Users size={24} className="text-ink-secondary" />}
      </div>
    );
  }
  const shown = members.slice(0, 3);
  const extra = members.length - shown.length;
  return (
    <div className="flex size-14 shrink-0 items-center justify-center">
      <div className="flex items-center -space-x-3">
        {shown.map((b) => (
          <MausAvatar key={b.id} color={b.color} look={b} state="happy" size={30} />
        ))}
        {extra > 0 && (
          <span className="z-10 flex size-[22px] items-center justify-center rounded-full border border-hairline/40 bg-raised text-[10px] font-medium text-ink-secondary">
            +{extra}
          </span>
        )}
      </div>
    </div>
  );
}

function GroupListItem({ group, onMenu }: { group: Group; onMenu: (menu: { groupId: string; x: number; y: number }) => void }) {
  const { state, dispatch } = useStore();
  const selected = state.activeView === "chat" && state.selectedId === group.id;
  const members = group.memberIds
    .map((id) => state.bots.find((b) => b.id === id))
    .filter((b): b is Bot => Boolean(b));
  const last = group.messages.at(-1);
  return (
    <button
      onClick={() => dispatch({ type: "select", id: group.id })}
      onContextMenu={(e) => {
        e.preventDefault();
        onMenu({ groupId: group.id, x: e.clientX, y: e.clientY });
      }}
      className={cn(
        "flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left",
        selected ? "bg-raised" : "hover:bg-raised/50",
      )}
    >
      <StackedMauses members={members} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate text-[15px] font-semibold text-ink">{group.name}</span>
          {selected && last && <span className="shrink-0 text-xs text-ink-secondary">{formatTime(last.at)}</span>}
        </div>
        <div className="flex items-center justify-between gap-2">
          <span className="truncate text-[13px] text-ink-secondary">{groupPreview(group, state.bots)}</span>
          {group.unread && <span className="size-2 shrink-0 rounded-full bg-accent" />}
        </div>
      </div>
    </button>
  );
}

function RoomContextMenu({
  menu,
  onClose,
}: {
  menu: { groupId: string; x: number; y: number };
  onClose: () => void;
}) {
  const { state, dispatch } = useStore();
  const group = state.groups.find((g) => g.id === menu.groupId);

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest("[data-room-menu]")) onClose();
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);

  if (!group) return null;
  const top = Math.min(menu.y, window.innerHeight - 164);
  const left = Math.min(menu.x, window.innerWidth - 240);
  return createPortal(
    <div
      data-room-menu
      style={{ top, left }}
      className="fixed z-40 w-[228px] overflow-hidden rounded-xl border border-hairline/50 bg-card py-1.5 shadow-2xl shadow-black/60"
    >
      <button
        onClick={() => {
          void navigator.clipboard?.writeText(group.threadId);
          onClose();
        }}
        className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
      >
        <ClipboardCopy size={16} className="text-ink-secondary" />
        Copy conversation ID
      </button>
      <button
        onClick={() => {
          dispatch({ type: "deleteGroup", groupId: group.id });
          onClose();
        }}
        className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-danger hover:bg-raised/70"
      >
        <Trash2 size={16} />
        Delete Room
      </button>
    </div>,
    document.body,
  );
}

/** Pick members → Create. The room name is optional; the server defaults it. */
function NewRoomPanel({ onClose }: { onClose: () => void }) {
  const { state, dispatch } = useStore();
  const [name, setName] = useState("");
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const bots = state.bots.filter((b) => !b.hidden);
  const toggle = (id: string) =>
    setPicked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const create = () => {
    if (!picked.size) return;
    dispatch({ type: "createGroup", memberIds: [...picked], name: name.trim() || undefined });
    track("room_created", { members: picked.size });
    onClose();
  };
  return (
    <div
      className="fixed inset-0 z-40 flex items-center justify-center bg-black/40"
      onMouseDown={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="w-[340px] rounded-2xl border border-hairline/50 bg-card p-4 shadow-2xl">
        <div className="mb-3 text-[15px] font-semibold text-ink">New Room</div>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") create();
            if (e.key === "Escape") onClose();
          }}
          placeholder="Room name (optional)"
          className="mb-3 w-full rounded-lg bg-raised/70 px-3 py-2 text-[14px] text-ink placeholder:text-ink-secondary focus:outline-none"
        />
        <div className="flex max-h-64 flex-col gap-0.5 overflow-y-auto">
          {bots.length === 0 && (
            <div className="px-2 py-4 text-center text-[13px] text-ink-secondary">Create a bot first — rooms are made of bots.</div>
          )}
          {bots.map((b) => (
            <button
              key={b.id}
              onClick={() => toggle(b.id)}
              className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 text-left hover:bg-raised/50"
            >
              <MausAvatar color={b.color} look={b} state="happy" size={28} />
              <span className="min-w-0 flex-1 truncate text-[14px] text-ink">{b.name}</span>
              <span
                className={cn(
                  "flex size-[18px] shrink-0 items-center justify-center rounded-full border",
                  picked.has(b.id) ? "border-accent bg-accent text-white" : "border-hairline/60",
                )}
              >
                {picked.has(b.id) && <Check size={12} />}
              </span>
            </button>
          ))}
        </div>
        <button
          onClick={create}
          disabled={!picked.size}
          className="mt-3 w-full rounded-lg bg-accent py-2 text-[14px] font-medium text-white hover:brightness-110 disabled:opacity-40"
        >
          Create Room{picked.size ? ` · ${picked.size} ${picked.size === 1 ? "bot" : "bots"}` : ""}
        </button>
      </div>
    </div>
  );
}

// Two bits of sidebar arrangement outlive a reload: which sections are folded
// away, and what order they sit in. Both are furniture rather than facts about
// the bots — a section is only a label each bot carries, so there is no section
// record on the server to hang either off (see src/lib/section-order.ts).
// Reaching for localStorage is itself a failure point (blocked storage throws
// on access), so every touch is guarded and a failure just means the sidebar
// starts in its default arrangement.
//
// The cost of storing the order here is that it is per-machine. If it should
// follow the account, it wants a real field on the server, not this key.
const COLLAPSED_KEY = "swarmebot.collapsedSections";
const ORDER_KEY = "swarmebot.sectionOrder";

function readStoredNames(key: string): string[] {
  try {
    const raw = typeof localStorage === "undefined" ? null : localStorage.getItem(key);
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    return Array.isArray(parsed) ? parsed.filter((name): name is string => typeof name === "string") : [];
  } catch {
    return [];
  }
}

function writeStoredNames(key: string, names: string[]) {
  try {
    if (typeof localStorage !== "undefined") localStorage.setItem(key, JSON.stringify(names));
  } catch {
    // storage unavailable — the arrangement still holds for this session
  }
}

/** Labeled divider between sidebar sections. Same typographic register as
 * EngineGroupLabel so the sidebar reads as one system. Right-click or the
 * hover affordance opens the rename/delete menu. */
function SectionDivider({
  name,
  count,
  collapsed,
  onToggle,
  onMenu,
  dragging,
  dropAbove,
  dropBelow,
  onDragStart,
  onDragEnter,
  onDrop,
  onDragEnd,
}: {
  name: string;
  count: number;
  collapsed: boolean;
  onToggle: () => void;
  onMenu: (name: string, x: number, y: number) => void;
  dragging: boolean;
  dropAbove: boolean;
  dropBelow: boolean;
  onDragStart: () => void;
  onDragEnter: () => void;
  onDrop: () => void;
  onDragEnd: () => void;
}) {
  return (
    <div
      // The header is the handle for the whole section: its bots follow it,
      // because the list is rendered straight from the order this reorders.
      draggable
      onDragStart={(e) => {
        // Firefox ignores a drag whose dataTransfer was never written to, and
        // the payload is the section name so an external drop reads sensibly.
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", name);
        onDragStart();
      }}
      onDragEnter={onDragEnter}
      onDragOver={(e) => {
        // the default action is "reject the drop" — without this there is no
        // drop event at all
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
      }}
      onDrop={(e) => {
        e.preventDefault();
        onDrop();
      }}
      onDragEnd={onDragEnd}
      className={cn(
        "group/section relative flex items-center gap-2 px-3 pb-1 pt-3 first:pt-0",
        dragging && "opacity-40",
        // the line sits on the edge the section will land against, so the
        // preview matches where the release actually puts it
        dropAbove && "before:absolute before:inset-x-3 before:top-1.5 before:h-0.5 before:rounded-full before:bg-accent",
        dropBelow && "after:absolute after:inset-x-3 after:bottom-0 after:h-0.5 after:rounded-full after:bg-accent",
      )}
      data-section={name}
      onContextMenu={(e) => {
        e.preventDefault();
        onMenu(name, e.clientX, e.clientY);
      }}
    >
      <GripVertical
        size={11}
        aria-hidden
        className="pointer-events-none shrink-0 text-ink-secondary opacity-0 transition-opacity group-hover/section:opacity-60"
      />
      <button
        onClick={onToggle}
        aria-expanded={!collapsed}
        aria-label={`${collapsed ? "Expand" : "Collapse"} section ${name}`}
        className="flex min-w-0 items-center gap-1 rounded-md text-ink-secondary hover:text-ink"
      >
        <ChevronRight
          size={11}
          className={cn("shrink-0 transition-transform", !collapsed && "rotate-90")}
        />
        <span className="truncate text-[10px] font-medium uppercase tracking-[0.08em]">{name}</span>
        {collapsed && <span className="shrink-0 text-[10px] tabular-nums">{count}</span>}
      </button>
      <span className="h-px flex-1 bg-hairline/40" />
      <button
        aria-label={`Section options for ${name}`}
        onClick={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          onMenu(name, r.right, r.bottom);
        }}
        className="shrink-0 rounded-md p-0.5 text-ink-secondary opacity-0 hover:text-ink focus-visible:opacity-100 group-hover/section:opacity-100"
      >
        <MoreHorizontal size={13} />
      </button>
    </div>
  );
}

/** Section header menu. A section is only a per-bot label, so renaming and
 * deleting are batch patches over the bots that carry it — hidden ones
 * included, or an archived bot would keep resurrecting the old name. */
function SectionMenu({
  section,
  anchor,
  onClose,
  onNudge,
  onRenamed,
  canMoveUp,
  canMoveDown,
}: {
  section: string;
  anchor: { x: number; y: number };
  onClose: () => void;
  /** Reordering without a mouse. Dragging is the fast path, not the only one. */
  onNudge: (delta: -1 | 1) => void;
  onRenamed: (from: string, to: string) => void;
  canMoveUp: boolean;
  canMoveDown: boolean;
}) {
  const { state, dispatch } = useStore();
  const [renaming, setRenaming] = useState(false);
  const [name, setName] = useState(section);
  const trimmed = name.trim();
  const members = state.bots.filter((b) => b.section === section);

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest("[data-section-menu]")) onClose();
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);

  // "" clears the label server-side (the section stops existing once its
  // last bot leaves); a new name renames it for the whole group at once
  const applyToAll = (value: string) => {
    for (const bot of members) dispatch({ type: "updateBot", botId: bot.id, patch: { section: value } });
    // a rename is the same section under a new label, so it keeps its slot
    // instead of surfacing at the bottom as if it had just been created
    if (value) onRenamed(section, value);
    onClose();
  };

  const top = Math.max(8, Math.min(anchor.y, window.innerHeight - 200));
  const left = Math.min(anchor.x, window.innerWidth - 260);

  return (
    <div
      data-section-menu
      style={{ top, left }}
      className="fixed z-40 w-[236px] overflow-hidden rounded-xl border border-hairline/50 bg-card py-2 shadow-2xl shadow-black/60"
    >
      <div className="px-3.5 pb-1 text-[10px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
        {section}
      </div>
      {renaming ? (
        <form
          className="flex items-center gap-1.5 px-2.5 py-1"
          onSubmit={(e) => {
            e.preventDefault();
            if (!trimmed || trimmed.length > 60) return;
            if (trimmed === section) return onClose();
            applyToAll(trimmed);
          }}
        >
          <input
            autoFocus
            maxLength={60}
            value={name}
            onChange={(e) => setName(e.target.value)}
            aria-label="Section name"
            className="w-full rounded-lg bg-raised/70 px-2.5 py-1.5 text-[13px] text-ink placeholder:text-ink-secondary focus:outline-none"
          />
          <button
            type="submit"
            disabled={!trimmed || trimmed.length > 60}
            className={cn(
              "shrink-0 rounded-lg px-2.5 py-1.5 text-[12px] font-medium",
              trimmed ? "bg-accent text-panel" : "bg-raised/70 text-ink-secondary",
            )}
          >
            Save
          </button>
        </form>
      ) : (
        <button
          onClick={() => setRenaming(true)}
          className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[13px] text-ink hover:bg-raised/70"
        >
          <Pencil size={15} className="text-ink-secondary" />
          Rename section
        </button>
      )}
      <div className="mx-2 my-1 border-t border-hairline/40" />
      <button
        onClick={() => {
          onNudge(-1);
          onClose();
        }}
        disabled={!canMoveUp}
        className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[13px] text-ink hover:bg-raised/70 disabled:opacity-40 disabled:hover:bg-transparent"
      >
        <ArrowUp size={15} className="text-ink-secondary" />
        Move section up
      </button>
      <button
        onClick={() => {
          onNudge(1);
          onClose();
        }}
        disabled={!canMoveDown}
        className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[13px] text-ink hover:bg-raised/70 disabled:opacity-40 disabled:hover:bg-transparent"
      >
        <ArrowDown size={15} className="text-ink-secondary" />
        Move section down
      </button>
      <div className="mx-2 my-1 border-t border-hairline/40" />
      <button
        onClick={() => applyToAll("")}
        className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[13px] text-danger hover:bg-raised/70"
      >
        <FolderMinus size={15} />
        Delete section
      </button>
      <div className="px-3.5 pt-1 text-[11px] text-ink-secondary">
        {members.length === 1 ? "1 bot stays" : `${members.length} bots stay`}, ungrouped.
      </div>
    </div>
  );
}

/** Move-to-section popover: existing sections as chips (checkmark on the
 * bot's current one), a create field, and a remove action. Mirrors the
 * context menu's fixed positioning + dismiss-on-outside-click contract. */
function SectionPicker({
  botId,
  anchor,
  onClose,
}: {
  botId: string;
  anchor: MenuState;
  onClose: () => void;
}) {
  const { state, dispatch } = useStore();
  const [name, setName] = useState("");
  const bot = state.bots.find((b) => b.id === botId);
  const trimmed = name.trim();

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest("[data-section-picker]")) onClose();
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);

  if (!bot) return null;
  // hidden bots can carry a stale assignment; don't offer it as a section
  const sections = [...new Set(state.bots.filter((b) => !b.hidden && b.section).map((b) => b.section!))];

  const assign = (section: string) => {
    dispatch({ type: "updateBot", botId, patch: { section } });
    onClose();
  };

  const top = Math.max(8, Math.min(anchor.y, window.innerHeight - 300));
  const left = Math.min(anchor.x, window.innerWidth - 260);

  return (
    <div
      data-section-picker
      style={{ top, left }}
      className="fixed z-40 w-[236px] overflow-hidden rounded-xl border border-hairline/50 bg-card py-2 shadow-2xl shadow-black/60"
    >
      <div className="px-3.5 pb-1 text-[10px] font-medium uppercase tracking-[0.08em] text-ink-secondary">
        Move to section
      </div>
      {sections.length > 0 && (
        <div className="flex flex-col gap-0.5 px-1.5 py-1">
          {sections.map((section) => (
            <button
              key={section}
              onClick={() => assign(section)}
              className={cn(
                "flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-1.5 text-left text-[13px]",
                section === bot.section ? "bg-raised text-ink" : "text-ink hover:bg-raised/70",
              )}
            >
              <span className="truncate">{section}</span>
              {section === bot.section && <Check size={14} className="shrink-0 text-accent" />}
            </button>
          ))}
        </div>
      )}
      <form
        className="flex items-center gap-1.5 px-2.5 py-1"
        onSubmit={(e) => {
          e.preventDefault();
          if (!trimmed || trimmed.length > 60) return;
          assign(trimmed);
        }}
      >
        <input
          autoFocus
          maxLength={60}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="New section…"
          aria-label="New section name"
          className="w-full rounded-lg bg-raised/70 px-2.5 py-1.5 text-[13px] text-ink placeholder:text-ink-secondary focus:outline-none"
        />
        <button
          type="submit"
          disabled={!trimmed || trimmed.length > 60}
          className={cn(
            "shrink-0 rounded-lg px-2.5 py-1.5 text-[12px] font-medium",
            trimmed ? "bg-accent text-panel" : "bg-raised/70 text-ink-secondary",
          )}
        >
          Add
        </button>
      </form>
      {bot.section && (
        <>
          <div className="mx-2 my-1 border-t border-hairline/40" />
          <button
            onClick={() => {
              dispatch({ type: "updateBot", botId, patch: { section: "" } });
              onClose();
            }}
            className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[13px] text-danger hover:bg-raised/70"
          >
            <FolderMinus size={15} />
            Remove from section
          </button>
        </>
      )}
    </div>
  );
}

function BotContextMenu({
  menu,
  onClose,
  onArchive,
  onMoveToSection,
}: {
  menu: MenuState;
  onClose: () => void;
  onArchive: (bot: Bot) => void;
  onMoveToSection: (botId: string) => void;
}) {
  const { state, dispatch } = useStore();
  const bot = state.bots.find((b) => b.id === menu.botId);

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest("[data-bot-menu]")) onClose();
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);

  if (!bot) return null;
  const engine = state.instances.find((instance) => instance.instanceId === bot.modelSelection.instanceId);
  const canCoordinate = engine?.capabilities?.agentsMcp === true;
  const visibleBotCount = state.bots.filter((candidate) => !candidate.hidden).length;
  const archiveBlocked = Boolean(bot.chiefOfStaff) || visibleBotCount <= 1;
  const archiveHint = bot.chiefOfStaff
    ? "Choose another Chief of Staff first"
    : visibleBotCount <= 1
      ? "Keep at least one active bot"
      : undefined;
  // keep the menu on-screen near the click
  const top = Math.max(8, Math.min(menu.y, window.innerHeight - 380));
  const left = Math.min(menu.x, window.innerWidth - 240);

  const item = (
    icon: React.ReactNode,
    label: string,
    onClick?: () => void,
    opts?: { danger?: boolean; disabled?: boolean; hint?: string },
  ) => (
    <button
      key={label}
      disabled={opts?.disabled}
      onClick={() => {
        onClick?.();
        onClose();
      }}
      title={opts?.hint}
      className={cn(
        "flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px]",
        opts?.danger ? "text-danger" : "text-ink",
        opts?.disabled ? "cursor-default opacity-40" : "hover:bg-raised/70",
      )}
    >
      {icon}
      {label}
    </button>
  );
  const divider = (key: string) => <div key={key} className="mx-2 my-1 border-t border-hairline/40" />;

  return (
    <div
      data-bot-menu
      style={{ top, left }}
      className="fixed z-40 w-[228px] overflow-hidden rounded-xl border border-hairline/50 bg-card py-1.5 shadow-2xl shadow-black/60"
    >
      {[
        item(
          bot.pinned ? <PinOff size={16} className="text-ink-secondary" /> : <Pin size={16} className="text-ink-secondary" />,
          bot.pinned ? "Unpin" : "Pin",
          () => dispatch({ type: "updateBot", botId: bot.id, patch: { pinned: !bot.pinned } }),
        ),
        item(
          <Crown size={16} className={bot.chiefOfStaff ? "text-accent" : "text-ink-secondary"} />,
          bot.chiefOfStaff ? "Remove Chief of Staff" : "Make Chief of Staff",
          () => dispatch({ type: "updateBot", botId: bot.id, patch: { chiefOfStaff: !bot.chiefOfStaff } }),
          {
            disabled: !bot.chiefOfStaff && !canCoordinate,
            hint: !bot.chiefOfStaff && !canCoordinate ? "Choose a Claude or ACP engine first" : undefined,
          },
        ),
        item(<FolderPlus size={16} className="text-ink-secondary" />, "Move to section", () => {
          onClose();
          onMoveToSection(bot.id);
        }),
        item(<BellDot size={16} className="text-ink-secondary" />, "Mark as Unread", () =>
          dispatch({ type: "markUnread", botId: bot.id }),
        ),
        divider("d1"),
        item(<Pencil size={16} className="text-ink-secondary" />, "Edit Profile", () => {
          dispatch({ type: "select", id: bot.id });
          dispatch({ type: "toggleSettings", open: true });
        }),
        item(<Copy size={16} className="text-ink-secondary" />, "Duplicate", () =>
          dispatch({ type: "duplicateBot", botId: bot.id }),
        ),
        divider("d2"),
        item(<ClipboardCopy size={16} className="text-ink-secondary" />, "Copy conversation ID", () => {
          void navigator.clipboard?.writeText(bot.threadId);
        }),
        divider("d3"),
        item(
          <Archive size={16} className="text-ink-secondary" />,
          "Archive",
          () => onArchive(bot),
          {
            disabled: archiveBlocked,
            hint: archiveHint,
          },
        ),
        item(<Trash2 size={16} />, "Delete", () => dispatch({ type: "deleteBot", botId: bot.id }), {
          danger: true,
        }),
      ]}
    </div>
  );
}

function BotListItem({
  bot,
  onMenu,
  onArchive,
  archiveDisabled,
}: {
  bot: Bot;
  onMenu: (menu: MenuState) => void;
  onArchive: (bot: Bot) => void;
  archiveDisabled: boolean;
}) {
  const { state, dispatch } = useStore();
  const [renaming, setRenaming] = useState(false);
  const selected = state.activeView === "chat" && state.selectedId === bot.id;
  const mascotMotion = selected && state.mascotMotion?.botId === bot.id ? state.mascotMotion : null;
  // the visible branch, so a version switch changes the row with the chat
  const visible = visibleMessages(bot);
  const last = visible.at(-1);
  const rowClass = cn(
    "flex w-full items-center gap-3 rounded-xl border px-3 py-2.5 pr-10 text-left",
    bot.chiefOfStaff
      ? selected
        ? "border-accent/40 bg-accent/15"
        : "border-accent/25 bg-accent/5 hover:bg-accent/10"
      : selected
        ? "border-transparent bg-raised"
        : "border-transparent hover:bg-raised/50",
  );
  const body = (
    <>
      <MausAvatar
        color={bot.color} look={bot}
        state={stateForBot({ ...bot, messages: visible })}
        size={56}
        motion={mascotMotion?.kind ?? "none"}
        motionKey={mascotMotion?.nonce ?? 0}
        // The list is as long as the bot roster and every animated mascot
        // runs the morph engine on every frame. The ones worth the frames are
        // the row you are in, the ones actually doing something, and whoever
        // has a motion beat playing; the rest hold their resting face.
        animated={selected || bot.busy === true || mascotMotion != null}
      />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="flex min-w-0 items-center gap-1.5 truncate text-[15px] font-semibold text-ink">
            {bot.pinned && <Pin size={12} className="shrink-0 text-ink-secondary" />}
            <RenameTitle
              value={bot.name}
              onCommit={(name) => dispatch({ type: "updateBot", botId: bot.id, patch: { name } })}
              onEditingChange={setRenaming}
              className="truncate"
              inputClassName="w-full rounded bg-inset px-1 py-0.5 text-[15px] font-semibold"
            />
          </span>
          {selected && last && !renaming && (
            <span className="shrink-0 text-xs text-ink-secondary transition-opacity group-hover:opacity-0 group-focus-within:opacity-0">
              {formatTime(last.at)}
            </span>
          )}
        </div>
        <div className="flex items-center justify-between gap-2">
          <span className="flex min-w-0 items-center gap-1.5 truncate text-[13px] text-ink-secondary">
            {bot.chiefOfStaff && (
              <span className="flex shrink-0 items-center gap-1 text-[11.5px] font-medium text-accent">
                <Crown size={11} /> Chief of Staff
              </span>
            )}
            {bot.chiefOfStaff && preview(bot) && <span className="shrink-0 text-ink-secondary/60">·</span>}
            <span className="truncate">{preview(bot)}</span>
          </span>
          {bot.unread && (
            <span className="size-2 shrink-0 rounded-full bg-accent" />
          )}
        </div>
      </div>
    </>
  );
  const onContextMenu = (event: React.MouseEvent) => {
    event.preventDefault();
    onMenu({ botId: bot.id, x: event.clientX, y: event.clientY });
  };

  // Keep the rename <input> out of role="button" — a button's descendants
  // are presentational, which hides the field from assistive tech.
  if (renaming) {
    return (
      <div className={rowClass} onContextMenu={onContextMenu}>
        {body}
      </div>
    );
  }

  return (
    <div className="group relative">
      <div
        role="button"
        tabIndex={0}
        onClick={() => dispatch({ type: "select", id: bot.id })}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            dispatch({ type: "select", id: bot.id });
          }
        }}
        onContextMenu={onContextMenu}
        className={rowClass}
      >
        {body}
      </div>
      <button
        type="button"
        disabled={archiveDisabled}
        onClick={() => onArchive(bot)}
        aria-label={`Archive ${bot.name}`}
        title={
          bot.chiefOfStaff
            ? "Choose another Chief of Staff first"
            : archiveDisabled
              ? "Keep at least one active bot"
              : `Archive ${bot.name}`
        }
        className="absolute right-2 top-2.5 flex size-7 items-center justify-center rounded-lg bg-card/90 text-ink-secondary opacity-0 shadow-sm transition hover:bg-raised hover:text-ink focus:opacity-100 disabled:cursor-default disabled:opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 max-md:opacity-100"
      >
        <Archive size={14} />
      </button>
    </div>
  );
}

function ArchivedBotsPanel({
  bots,
  onClose,
  onRestored,
}: {
  bots: Bot[];
  onClose: () => void;
  onRestored: (message: string) => void;
}) {
  const { dispatch } = useStore();
  const dialogRef = useRef<HTMLDivElement>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [restoringAll, setRestoringAll] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    dialogRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busyId && !restoringAll) onClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [busyId, onClose, restoringAll]);

  const restore = async (bot: Bot) => {
    setBusyId(bot.id);
    setError("");
    try {
      const response = await api(`/api/bots/${bot.id}`, {
        method: "PATCH",
        body: JSON.stringify({ hidden: false }),
      });
      dispatch({ type: "botPatched", bot: response.bot });
      dispatch({ type: "select", id: bot.id });
      onRestored(`${bot.name} restored`);
      if (bots.length === 1) onClose();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusyId(null);
    }
  };

  const restoreAll = async () => {
    setRestoringAll(true);
    setError("");
    try {
      const responses = await Promise.all(
        bots.map((bot) =>
          api(`/api/bots/${bot.id}`, {
            method: "PATCH",
            body: JSON.stringify({ hidden: false }),
          }),
        ),
      );
      for (const response of responses) dispatch({ type: "botPatched", bot: response.bot });
      const first = bots[0];
      if (first) dispatch({ type: "select", id: first.id });
      onRestored(`${bots.length} ${bots.length === 1 ? "bot" : "bots"} restored`);
      onClose();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setRestoringAll(false);
    }
  };

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/55 p-4 backdrop-blur-[2px] sm:p-6"
      onMouseDown={(event) => event.target === event.currentTarget && !busyId && !restoringAll && onClose()}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="archived-bots-title"
        tabIndex={-1}
        className="animate-pop-in flex max-h-[min(680px,calc(100dvh-2rem))] w-full max-w-[760px] flex-col overflow-hidden rounded-[24px] border border-hairline/50 bg-panel shadow-2xl shadow-black/50 outline-none"
      >
        <header className="flex items-start justify-between gap-4 px-6 pb-4 pt-6 sm:px-8 sm:pt-7">
          <div>
            <h2 id="archived-bots-title" className="text-[22px] font-semibold tracking-[-0.01em] text-ink">Archived bots</h2>
            <p className="mt-1 text-[13px] text-ink-secondary">Conversations are kept until you choose to delete a bot.</p>
          </div>
          <div className="flex items-center gap-1">
            {bots.length > 1 && (
              <button
                onClick={() => void restoreAll()}
                disabled={restoringAll || Boolean(busyId)}
                className="flex items-center gap-1.5 rounded-full bg-raised px-3.5 py-2 text-[12.5px] text-ink hover:bg-raised-hover disabled:opacity-40"
              >
                {restoringAll && <Loader2 size={13} className="animate-spin" />}
                Restore all
              </button>
            )}
            <button
              onClick={onClose}
              disabled={restoringAll || Boolean(busyId)}
              className="rounded-lg p-2 text-ink-secondary hover:bg-raised hover:text-ink disabled:opacity-40"
              aria-label="Close archived bots"
            >
              <X size={21} />
            </button>
          </div>
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-7 pt-3 sm:px-8">
          <div className="mb-3 text-[12px] font-medium text-ink-secondary">{bots.length} archived</div>
          <div className="grid grid-cols-1 gap-x-8 md:grid-cols-2">
            {bots.map((bot) => (
              <div key={bot.id} className="flex min-h-[82px] items-center gap-3 border-b border-hairline/35 px-1 py-3">
                <MausAvatar color={bot.color} look={bot} state="happy" size={42} />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[14px] font-medium text-ink">{bot.name}</div>
                  <div className="mt-0.5 truncate text-[12.5px] text-ink-secondary">{bot.title || "Bot"}</div>
                </div>
                <button
                  onClick={() => void restore(bot)}
                  disabled={restoringAll || Boolean(busyId)}
                  className="flex min-w-[78px] items-center justify-center gap-1.5 rounded-full bg-raised px-3.5 py-2 text-[12.5px] text-ink hover:bg-raised-hover disabled:opacity-40"
                >
                  {busyId === bot.id && <Loader2 size={13} className="animate-spin" />}
                  Restore
                </button>
              </div>
            ))}
          </div>
          {error && <div role="alert" className="mt-4 rounded-lg bg-danger/10 px-3 py-2 text-[12.5px] text-danger">{error}</div>}
        </div>
      </div>
    </div>,
    document.body,
  );
}

export function Sidebar({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { state, dispatch } = useStore();
  const { capabilities } = useDesktopCapabilities();
  const importReturnRef = useRef<HTMLButtonElement>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [sectionPicker, setSectionPicker] = useState<MenuState | null>(null);
  const [sectionMenu, setSectionMenu] = useState<{ section: string; x: number; y: number } | null>(null);
  const [roomMenu, setRoomMenu] = useState<{ groupId: string; x: number; y: number } | null>(null);
  const [plusOpen, setPlusOpen] = useState(false);
  const [newRoom, setNewRoom] = useState(false);
  const [teamLibraryOpen, setTeamLibraryOpen] = useState(false);
  const [archivedBotsOpen, setArchivedBotsOpen] = useState(false);
  const [exportingTeam, setExportingTeam] = useState(false);
  const [teamFeedback, setTeamFeedback] = useState<{
    error: boolean;
    text: string;
    undo?: TeamImportResult;
    restoreBot?: { id: string; name: string };
  } | null>(null);
  const [query, setQuery] = useState("");
  const [collapsedSections, setCollapsedSections] = useState<string[]>(() => readStoredNames(COLLAPSED_KEY));

  const toggleSection = (name: string) => {
    setCollapsedSections((current) => {
      const next = current.includes(name) ? current.filter((s) => s !== name) : [...current, name];
      writeStoredNames(COLLAPSED_KEY, next);
      return next;
    });
  };

  // The saved preference, not the rendered list — see orderSections. `dragging`
  // is the section under the pointer's grip; `dropTarget` is the one it is
  // hovering, and drawing the line on the target is what tells the user where
  // the release will land.
  const [sectionOrder, setSectionOrder] = useState<string[]>(() => readStoredNames(ORDER_KEY));
  const [dragging, setDragging] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<string | null>(null);

  // Reordering has to be stated against what is ON SCREEN, then folded back
  // into the preference: the visible list is the only thing the user can see
  // to aim at, while the preference may still remember sections a search has
  // filtered away.
  const reorderSections = (visible: string[], apply: (order: string[]) => string[]) => {
    const next = apply(orderSections(visible, sectionOrder));
    // names outside this render keep their relative place at the back rather
    // than being dropped, so a filtered-out section survives a drag
    const merged = [...next, ...sectionOrder.filter((name) => !next.includes(name))];
    setSectionOrder(merged);
    writeStoredNames(ORDER_KEY, merged);
  };


  // Esc closes the drawer, mirroring ApiKeys.tsx:75-85. Bound only while the
  // drawer is open — on mobile, exactly when a bot/room context menu or the
  // New Room panel can be open on top of it, so the same Escape press closes
  // them together. Fine, since both directions are "get me out of here."
  useEffect(() => {
    if (!open) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => document.removeEventListener("keydown", closeOnEscape);
  }, [open, onClose]);

  useEffect(() => {
    if (!teamFeedback) return;
    const timer = window.setTimeout(() => setTeamFeedback(null), 5000);
    return () => window.clearTimeout(timer);
  }, [teamFeedback]);

  const exportAllBots = async () => {
    setExportingTeam(true);
    setTeamFeedback(null);
    try {
      const exported = await downloadAllBots();
      track("team_exported", { members: exported.members, scope: "all_visible" });
      setTeamFeedback({ error: false, text: `${exported.members} bots exported` });
    } catch (cause) {
      setTeamFeedback({
        error: true,
        text: cause instanceof Error ? cause.message : String(cause),
      });
    } finally {
      setExportingTeam(false);
    }
  };

  const undoTeamLoad = async (result: TeamImportResult) => {
    setTeamFeedback(null);
    try {
      const archiveNew = await Promise.all(
        result.importedBotIds.map((botId) =>
          api(`/api/bots/${botId}`, {
            method: "PATCH",
            body: JSON.stringify({ hidden: true, chiefOfStaff: false }),
          }),
        ),
      );
      for (const response of archiveNew) dispatch({ type: "botPatched", bot: response.bot });

      const previousChief = result.archived.find((bot) => bot.chiefOfStaff);
      const restoreOthers = await Promise.all(
        result.archived
          .filter((bot) => !bot.chiefOfStaff)
          .map((bot) =>
            api(`/api/bots/${bot.id}`, {
              method: "PATCH",
              body: JSON.stringify({ hidden: false }),
            }),
          ),
      );
      for (const response of restoreOthers) dispatch({ type: "botPatched", bot: response.bot });
      if (previousChief) {
        const response = await api(`/api/bots/${previousChief.id}`, {
          method: "PATCH",
          body: JSON.stringify({ hidden: false, chiefOfStaff: true }),
        });
        dispatch({ type: "botPatched", bot: response.bot });
      }
      const first = result.archived[0];
      if (first) dispatch({ type: "select", id: first.id });
      setTeamFeedback({ error: false, text: "Previous team restored" });
    } catch (cause) {
      setTeamFeedback({ error: true, text: cause instanceof Error ? cause.message : String(cause) });
    }
  };

  const archiveBot = async (bot: Bot) => {
    const activeBots = state.bots.filter((candidate) => !candidate.hidden);
    if (bot.chiefOfStaff || activeBots.length <= 1) return;
    setTeamFeedback(null);
    try {
      const response = await api(`/api/bots/${bot.id}`, {
        method: "PATCH",
        body: JSON.stringify({ hidden: true }),
      });
      dispatch({ type: "botPatched", bot: response.bot });
      if (state.selectedId === bot.id) {
        const next = activeBots.find((candidate) => candidate.id !== bot.id);
        if (next) dispatch({ type: "select", id: next.id });
      }
      setTeamFeedback({
        error: false,
        text: `${bot.name} archived`,
        restoreBot: { id: bot.id, name: bot.name },
      });
    } catch (cause) {
      setTeamFeedback({ error: true, text: cause instanceof Error ? cause.message : String(cause) });
    }
  };

  const undoBotArchive = async (bot: { id: string; name: string }) => {
    setTeamFeedback(null);
    try {
      const response = await api(`/api/bots/${bot.id}`, {
        method: "PATCH",
        body: JSON.stringify({ hidden: false }),
      });
      dispatch({ type: "botPatched", bot: response.bot });
      dispatch({ type: "select", id: bot.id });
      setTeamFeedback({ error: false, text: `${bot.name} restored` });
    } catch (cause) {
      setTeamFeedback({ error: true, text: cause instanceof Error ? cause.message : String(cause) });
    }
  };

  const macInset = capabilities.windowChrome === "mac-inset";
  const browser = capabilities.host.label === "Browser";

  const q = query.trim().toLowerCase();

  // Message search rides the same box as the name filter: names match
  // instantly from local state; transcript hits are the SearchResults
  // section below the list (debounced, lands on the message).

  const matchingBots = state.bots
    .filter((b) => !b.hidden)
    .filter(
      (b) =>
        !q ||
        b.name.toLowerCase().includes(q) ||
        (b.title ?? "").toLowerCase().includes(q) ||
        preview(b).toLowerCase().includes(q),
    );
  const chiefBot = matchingBots.find((bot) => bot.chiefOfStaff);
  const sectionedBots = matchingBots
    .filter((bot) => !bot.chiefOfStaff && bot.section)
    .sort((a, b) => Number(b.pinned ?? false) - Number(a.pinned ?? false));
  const visibleBots = matchingBots
    .filter((bot) => !bot.chiefOfStaff && !bot.section)
    .sort((a, b) => Number(b.pinned ?? false) - Number(a.pinned ?? false));
  // sections keep first-appearance order within the current list; a section
  // whose bots all moved away (or fell out of the filter) simply vanishes
  const discovered: string[] = [];
  for (const bot of sectionedBots) {
    if (!discovered.includes(bot.section!)) discovered.push(bot.section!);
  }
  // first appearance is only the fallback now: anything the user has dragged
  // outranks it
  const sectionNames = orderSections(discovered, sectionOrder);
  const visibleGroups = state.groups.filter((g) => !q || g.name.toLowerCase().includes(q));
  const activeBotCount = state.bots.filter((bot) => !bot.hidden).length;
  const archivedBots = state.bots.filter((bot) => bot.hidden);
  const pendingTeamUndo = teamFeedback?.undo;
  const pendingBotUndo = teamFeedback?.restoreBot;

  return (
    <aside
      className={cn(
        "flex h-full w-[320px] shrink-0 flex-col border-r border-hairline/40 bg-panel",
        // Below md only: the sidebar leaves the flow and slides in over the chat.
        // Scoped with max-md: rather than cancelled with md: on purpose — Tailwind
        // v4 emits the native `translate` property, and any value other than
        // `none` turns this element into a containing block for its `fixed`
        // descendants. Cancelling it with an `md:` prefix still emits a value, which
        // silently reparents NewRoomPanel's overlay and the "+" menu backdrop on
        // desktop.
        "max-md:absolute max-md:inset-y-0 max-md:left-0 max-md:z-40",
        "max-md:transition-transform max-md:duration-200",
        open ? "max-md:translate-x-0" : "max-md:-translate-x-full",
      )}
    >
      {/* macOS owns inset traffic lights; Linux/Windows use native chrome. */}
      <div
        className="flex items-center justify-between px-4 pt-3.5 pb-1"
        style={macInset ? ({ WebkitAppRegion: "drag" } as React.CSSProperties) : undefined}
      >
        {macInset ? (
          <div className="w-14" />
        ) : browser ? (
          <div className="flex items-center gap-2">
            <span className="size-3 rounded-full bg-[#ff5f57]" />
            <span className="size-3 rounded-full bg-[#febc2e]" />
            <span className="size-3 rounded-full bg-[#28c840]" />
          </div>
        ) : <div />}
        <div
          className="relative"
          style={macInset ? ({ WebkitAppRegion: "no-drag" } as React.CSSProperties) : undefined}
        >
          <button
            ref={importReturnRef}
            onClick={() => setPlusOpen((o) => !o)}
            className="rounded-md p-1 text-ink-secondary hover:bg-raised hover:text-ink"
            title="New or share"
          >
            <Plus size={20} strokeWidth={2} />
          </button>
          {plusOpen && (
            <>
              <div className="fixed inset-0 z-30" onMouseDown={() => setPlusOpen(false)} />
              <div className="absolute right-0 top-full z-40 mt-1 w-44 overflow-hidden rounded-xl border border-hairline/50 bg-card py-1.5 shadow-2xl shadow-black/60">
                <button
                  onClick={() => {
                    setPlusOpen(false);
                    track("bot_created");
                    dispatch({ type: "newBot" });
                  }}
                  className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
                >
                  <BotIcon size={16} className="text-ink-secondary" />
                  New Bot
                </button>
                <button
                  onClick={() => {
                    setPlusOpen(false);
                    setNewRoom(true);
                  }}
                  className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
                >
                  <Users size={16} className="text-ink-secondary" />
                  New Room
                </button>
                <button
                  onClick={() => {
                    setPlusOpen(false);
                    void exportAllBots();
                  }}
                  disabled={exportingTeam}
                  className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
                >
                  {exportingTeam ? <Loader2 size={16} className="animate-spin text-ink-secondary" /> : <ArrowDownToLine size={16} className="text-ink-secondary" />}
                  {exportingTeam ? "Exporting…" : "Export all bots"}
                </button>
                <button
                  onClick={() => {
                    setPlusOpen(false);
                    setTeamLibraryOpen(true);
                  }}
                  className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
                >
                  <Library size={16} className="text-ink-secondary" />
                  Teams
                </button>
                {archivedBots.length > 0 && (
                  <button
                    onClick={() => {
                      setPlusOpen(false);
                      setArchivedBotsOpen(true);
                    }}
                    className="flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] text-ink hover:bg-raised/70"
                  >
                    <Archive size={16} className="text-ink-secondary" />
                    <span className="flex-1">Archived bots</span>
                    <span className="text-[11.5px] text-ink-secondary">{archivedBots.length}</span>
                  </button>
                )}
              </div>
            </>
          )}
        </div>
      </div>

      {/* Search */}
      <div className="px-3 pt-2 pb-3">
        <div className="flex items-center gap-2 rounded-lg bg-raised/70 px-3 py-2">
          <Search size={16} className="text-ink-secondary" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && setQuery("")}
            placeholder="Search"
            aria-label="Search bots and messages"
            className="w-full bg-transparent text-[14px] text-ink placeholder:text-ink-secondary focus:outline-none"
          />
        </div>
      </div>

      {/* Bot list */}
      <div className="flex-1 overflow-y-auto px-2">
        <div className="flex flex-col gap-0.5">
          {!chiefBot && visibleBots.length === 0 && sectionedBots.length === 0 && visibleGroups.length === 0 && q && q.length < MIN_QUERY && (
            <div className="px-3 py-6 text-center text-[13px] text-ink-secondary">Nothing matches “{query}”</div>
          )}
          {chiefBot && (
            <div className="mb-1.5">
              <BotListItem
                bot={chiefBot}
                onMenu={setMenu}
                onArchive={(bot) => void archiveBot(bot)}
                archiveDisabled
              />
            </div>
          )}
          {visibleGroups.map((g) => (
            <GroupListItem key={g.id} group={g} onMenu={setRoomMenu} />
          ))}
          {visibleBots.map((b) => (
            <BotListItem
              key={b.id}
              bot={b}
              onMenu={setMenu}
              onArchive={(bot) => void archiveBot(bot)}
              archiveDisabled={activeBotCount <= 1}
            />
          ))}
          {sectionNames.map((name, i) => {
            const members = sectionedBots.filter((b) => b.section === name);
            // a filter is a search: hiding matches behind a folded section
            // would read as "no results", so collapse only applies at rest
            const collapsed = !q && collapsedSections.includes(name);
            return (
              <Fragment key={name}>
                <SectionDivider
                  name={name}
                  count={members.length}
                  collapsed={collapsed}
                  onToggle={() => toggleSection(name)}
                  onMenu={(section, x, y) => setSectionMenu({ section, x, y })}
                  dragging={dragging === name}
                  dropBelow={dropTarget === name && dragging !== null && sectionNames.indexOf(dragging) < i}
                  dropAbove={dropTarget === name && dragging !== null && sectionNames.indexOf(dragging) > i}
                  onDragStart={() => setDragging(name)}
                  onDragEnter={() => dragging && dragging !== name && setDropTarget(name)}
                  onDrop={() => {
                    if (dragging && dragging !== name) {
                      reorderSections(sectionNames, (order) => moveSection(order, dragging, name));
                    }
                    setDragging(null);
                    setDropTarget(null);
                  }}
                  onDragEnd={() => {
                    setDragging(null);
                    setDropTarget(null);
                  }}
                />
                {!collapsed &&
                  members.map((b) => (
                    <BotListItem
                      key={b.id}
                      bot={b}
                      onMenu={setMenu}
                      onArchive={(bot) => void archiveBot(bot)}
                      archiveDisabled={activeBotCount <= 1}
                    />
                  ))}
              </Fragment>
            );
          })}
          <SearchResults query={query} onLanded={() => setQuery("")} />
        </div>
      </div>

      {/* Footer */}
      <div className="px-3 pb-3 pt-2">
        <button
          onClick={() => dispatch({ type: "showRoutines" })}
          className={cn(
            "flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left transition-colors",
            state.activeView === "routines" ? "bg-raised text-ink" : "text-ink hover:bg-raised/50",
          )}
        >
          <CalendarDays size={20} className={state.activeView === "routines" ? "text-accent" : "text-ink-secondary"} />
          <span className="flex-1 text-[14px]">Automations</span>
          {state.routineRuns.some((run) => ["failed", "missed"].includes(run.status) && !run.seenAt) && (
            <span className="size-2 rounded-full bg-danger" />
          )}
        </button>
        <button
          onClick={() => dispatch({ type: "togglePlugins", open: true })}
          className="flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left hover:bg-raised/50"
        >
          <Puzzle size={20} className="text-ink-secondary" />
          <span className="text-[14px] text-ink">Connected apps</span>
        </button>
        <div className="flex items-center">
          <button
            onClick={() => dispatch({ type: "toggleAppSettings" })}
            className="flex min-w-0 flex-1 items-center gap-3 rounded-xl px-3 py-2 text-left hover:bg-raised/50"
          >
            <InitialsAvatar initials={profileInitials(state.config?.profile)} size={28} />
            <span className="truncate text-[14px] text-ink">
              {state.config?.profile?.name?.trim() || state.config?.profile?.email?.trim() || "You"}
            </span>
          </button>
          <UpdateButton />
          <button
            onClick={() => dispatch({ type: "toggleAppSettings" })}
            className="rounded-md p-2 text-ink-secondary hover:bg-raised hover:text-ink"
            title="App settings"
          >
            <Settings size={18} />
          </button>
        </div>
      </div>

      {menu && (
        <BotContextMenu
          menu={menu}
          onClose={() => setMenu(null)}
          onArchive={(bot) => void archiveBot(bot)}
          onMoveToSection={(botId) => setSectionPicker({ botId, x: menu.x, y: menu.y })}
        />
      )}
      {sectionPicker && (
        <SectionPicker botId={sectionPicker.botId} anchor={sectionPicker} onClose={() => setSectionPicker(null)} />
      )}
      {sectionMenu && (
        <SectionMenu
          section={sectionMenu.section}
          anchor={sectionMenu}
          onClose={() => setSectionMenu(null)}
          canMoveUp={sectionNames.indexOf(sectionMenu.section) > 0}
          canMoveDown={sectionNames.indexOf(sectionMenu.section) < sectionNames.length - 1}
          onNudge={(delta) =>
            reorderSections(sectionNames, (order) => nudgeSection(order, sectionMenu.section, delta))
          }
          onRenamed={(from, to) => {
            const merged = renameInOrder(sectionOrder, from, to);
            setSectionOrder(merged);
            writeStoredNames(ORDER_KEY, merged);
          }}
        />
      )}
      {roomMenu && (
        <RoomContextMenu
          menu={roomMenu}
          onClose={() => setRoomMenu(null)}
        />
      )}
      {newRoom && <NewRoomPanel onClose={() => setNewRoom(false)} />}
      {archivedBotsOpen && (
        <ArchivedBotsPanel
          bots={archivedBots}
          onClose={() => setArchivedBotsOpen(false)}
          onRestored={(message) => setTeamFeedback({ error: false, text: message })}
        />
      )}
      {teamLibraryOpen && (
        <TeamLibraryPanel
          returnFocusRef={importReturnRef}
          onClose={() => setTeamLibraryOpen(false)}
          onImported={(result) => {
            setTeamLibraryOpen(false);
            setTeamFeedback(
              result.archived.length > 0
                ? {
                    error: false,
                    text: `${result.name} loaded · ${result.members} ${result.members === 1 ? "bot" : "bots"}`,
                    undo: result,
                  }
                : {
                    error: false,
                    text: `${result.name} loaded · ${result.members} ${result.members === 1 ? "bot" : "bots"}`,
                  },
            );
          }}
        />
      )}
      {teamFeedback &&
        createPortal(
          <div
            role="status"
            className={cn(
              "fixed bottom-4 left-4 z-[60] max-w-[300px] rounded-xl border px-3.5 py-2.5 text-[13px] shadow-xl",
              teamFeedback.error
                ? "border-danger/30 bg-card text-danger"
                : "border-hairline/50 bg-card text-ink",
            )}
          >
            <div className="flex items-center gap-3">
              <span>{teamFeedback.text}</span>
              {pendingTeamUndo && (
                <button
                  onClick={() => void undoTeamLoad(pendingTeamUndo)}
                  className="rounded-md px-1.5 py-0.5 font-medium text-accent hover:bg-raised"
                >
                  Undo
                </button>
              )}
              {pendingBotUndo && (
                <button
                  onClick={() => void undoBotArchive(pendingBotUndo)}
                  className="rounded-md px-1.5 py-0.5 font-medium text-accent hover:bg-raised"
                >
                  Undo
                </button>
              )}
            </div>
          </div>,
          document.body,
        )}
    </aside>
  );
}
