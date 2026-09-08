// Visible-chat Markdown: the text the user actually reads, not tool
// chips, screens, or cards. Shared by the download route and the
// safety copy written when a bot with pinned tasks is deleted.
import { mkdirSync } from "node:fs";
import { join } from "node:path";

import { writeFileAtomic } from "./atomic.ts";
import { DATA_DIR } from "./config.ts";
import type { Message } from "./store.ts";

export function sanitizeFsName(raw: string, fallback: string): string {
  const cleaned = raw
    .replace(/[^\w\- ]+/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
  return cleaned || fallback;
}

export function conversationMarkdown(
  title: string,
  messages: Message[],
  opts: { userName: string; botName: string },
): string {
  const lines: string[] = [`# ${title}`, ""];
  for (const msg of messages) {
    if (msg.kind !== "text" || !msg.text?.trim()) continue;
    const who = msg.role === "user" ? opts.userName : (msg.from?.name ?? opts.botName);
    lines.push(`**${who}:**`, "", msg.text, "");
  }
  return `${lines.join("\n").trimEnd()}\n`;
}

export function exportFilename(title: string): string {
  return `${sanitizeFsName(title, "conversation")}.md`;
}

/** Write each pinned task's visible transcript under
 * `~/.swarmebot/bots/<bot-name>/`. Called before the bot's threads are
 * deleted so the copy still has something to read. */
export function archivePinnedTasks(opts: {
  botName: string;
  userName: string;
  tasks: Array<{ title: string; pinned?: boolean; threadId: string }>;
  messagesFor: (threadId: string) => Message[];
}): string | null {
  const pinned = opts.tasks.filter((t) => t.pinned);
  if (!pinned.length) return null;
  const dir = join(DATA_DIR, "bots", sanitizeFsName(opts.botName, "bot"));
  mkdirSync(dir, { recursive: true });
  const used = new Set<string>();
  for (const task of pinned) {
    let name = exportFilename(task.title);
    if (used.has(name)) name = `${sanitizeFsName(task.title, "conversation")}-${task.threadId.slice(0, 8)}.md`;
    used.add(name);
    const md = conversationMarkdown(task.title, opts.messagesFor(task.threadId), {
      userName: opts.userName,
      botName: opts.botName,
    });
    writeFileAtomic(join(dir, name), md);
  }
  return dir;
}
