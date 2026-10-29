# Code plugin

Code mode of a bot: the git state of the chat's folder under the composer, the files a turn
changed, branches, a terminal, an editor. Two targets, linked at build time into the app and the
engine; the core never imports them (`docs/plans/2026-10-28-code-mode-t3.md` §12).

- `Engine/` → `CodePluginEngine`: routes and git, runs wherever the engine runs, **also on Linux**.
- `App/` → `CodePluginApp`: the Mac app's half. The iOS app has none of it.
- Tests: `Tests/CodePluginEngineTests`, `Tests/CodePluginAppTests`.

The engine declares it in `GET /api/plugins` as `code`; the app shows its interface only for an
engine that carries it and has it on. A bot opts in with the `codeMode` flag (`PATCH /api/bots/:id`),
which the plugin adds to the flags the engine accepts.

## Engine routes

All answer 404 `no such thread` for an unknown thread. `:tid` is a bot's or a channel's thread.
Mutations need `content-type: application/json`.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET | `/api/threads/:tid/git` | — | `{repo, folder?, root?, branch?, detached?, changes:[{path,name,status,bytes}]}`. `folder` is the task's effective folder even outside a repository |
| GET | `/api/threads/:tid/git/branches` | — | `{branches:[{ref,name,remote,date?}]}`, newest commit first; local branches and remote refs already fetched, without symbolic aliases such as `origin/HEAD`. `date` is the last commit's time in seconds |
| POST | `/api/threads/:tid/git/checkout` | `{ref}`, a full ref from the list | the updated git state. A remote branch reuses a local branch that tracks it or creates one with tracking. No force, reset or stash |
| POST | `/api/threads/:tid/git/branch` | `{name}` | the updated git state, on the new branch made from HEAD (uncommitted edits come along). 400 for an invalid name or a folder that is not a repo, 409 if the name exists |
| GET | `/api/threads/:tid/resume-command` | — | `{supported:true, tool, folder, command}` or `{supported:false, reason}`. `command` is a shell line that continues the chat's session in the agent's own CLI (`claude --resume`, `codex resume`) in the chat's folder |

| GET | `/api/threads/:tid/git/diff` | `?path=` (absolute, or relative to the repo's root; optional) | `{path?, diff, truncated, binary}`: the file's changes against HEAD (staged and unstaged read as one; a new file is all added lines), or every change when no path. 400 for a path outside the repository; the diff is cut at 400 KB on a line |
| POST | `/api/threads/:tid/git/commit-message` | `{}` | `{message}`: written from the diff by a model in a call of its own (not a turn of the chat), which runs in an empty folder and is told to use no tool (a permission request is denied). The model is the one in `/api/code/settings`, else the bot's own. 400 when there is nothing to commit, 409 with no model, 502/504 when the model fails or takes over 90 s |
| POST | `/api/threads/:tid/git/commit` | `{message, files?, mode?, branch?, prTitle?, prBody?}` | `{ok, commit, branch, pushed, prUrl?, git}`. `files`: paths to take (default: every change; deletions included). `mode`: `commit` (default), `push` (`-u origin <branch>` when there is no upstream), `push-new-branch` (needs `branch`: made first, from HEAD), `pr` (push, then `gh pr create`: title is `prTitle` or the message's subject, body `prBody` or the rest). Run by the engine as processes, no agent. A failing hook answers 409 with its output; a failed push or PR answers 409 saying what was already done (`committed abc123, but …`). 400 for nothing to commit, no message, a path outside the repository, `gh` missing |
| GET | `/api/threads/:tid/files` | `?q=&limit=` (default 50, max 200) | `{files:[{path, relative, name}]}`: what `git ls-files` lists (tracked, and untracked that `.gitignore` does not hide), best fuzzy match first; outside a repository, a walk that leaves out the usual heavy folders. With no `q`, changed files first. (The core's `POST` on the same path resolves references of a reply.) |
| GET, PUT | `/api/code/settings` | `{commitModel: {instanceId, model} \| null}` | the plugin's settings on this engine, kept in `<data>/plugins/code/settings.json`: the model that writes every bot's commit messages. 400 for an engine this server does not have |

`checkout`, `branch` and `commit` answer 409 when a bot (or a routine) works in the same repository, and
`checkout` and `branch` also for a conflict with local edits (git's own message).

## In the app

The chip of the branch opens a searchable picker (recent, local, remote; "Create branch" when the
search finds nothing); **Open terminal** opens a shell in the effective folder; **Open in…** opens
Finder (local only), an editor (VS Code, Cursor, Zed, Xcode; on a server only VS Code and Cursor,
through Remote - SSH) or the chat's session in a terminal. A remote engine needs an SSH identity
configured on this Mac for the terminal and the editors. The terminal is the one picked in
Settings › General.

### Diff, commit and file references (engine plugin 1.1.0 and later)

An engine whose plugin is older than 1.1.0 keeps the first version: the branch, the terminal, Open in…
and a "Commit & push" that asks the agent to do it.

- **Diff tab** (⌘⇧D) in the right column, 660 pt wide: the changed files by folder on the left, the
  diff of the chosen one on the right. A click on a line opens a comment; **Send review** sends every
  comment to the agent as one message, with file and line. Each file has *Add to chat* (also a drag
  to the composer, on this Mac).
- **Commit…** (from the diff tab, or the badge under a reply): the message is written by the model set in
  Settings › Plugins (else the bot's own) and can be edited; checkboxes pick the files; then commit,
  commit and push, push to a new branch, or push and open a pull request with `gh`. The engine runs
  it; a failing hook's output is shown as it is.
- **⌘P / the File chip** searches the repository's files (`.gitignore` respected) and adds the file as a
  chip above the field. It is a path, not an upload: the message carries `Files I am referring to…` and
  the agent reads the file itself, so it also works with an engine on a server. A file dragged in from
  Finder that lies inside the chat's folder becomes a reference too (this Mac only); images stay attachments.
