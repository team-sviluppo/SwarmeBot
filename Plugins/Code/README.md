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

`checkout` and `branch` answer 409 when a bot (or a routine) works in the same repository, and for a
conflict with local edits (git's own message).

## In the app

The chip of the branch opens a searchable picker (recent, local, remote; "Create branch" when the
search finds nothing); **Open terminal** opens a shell in the effective folder; **Open in…** opens
Finder (local only), an editor (VS Code, Cursor, Zed, Xcode; on a server only VS Code and Cursor,
through Remote - SSH) or the chat's session in a terminal. A remote engine needs an SSH identity
configured on this Mac for the terminal and the editors. The terminal is the one picked in
Settings › General.
