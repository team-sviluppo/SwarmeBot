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

### Projects (engine plugin 1.2.0 and later)

A project is a name, a ClickUp list id and the folders of a piece of work with a role each (`backend`,
`backoffice`, `app`, `bruno`), kept in `<data>/plugins/code/projects.json` on the engine, because the folders are on
its machine. A bot or a channel belongs to at most one and says which folder it **works on**; the others are linked
**read-only**, for context. In a channel the channel's project counts, not its members'.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET | `/api/projects` | — | `{projects:[{id, name, clickupListId?, repos:[{role, path, scripts?:[{name, command}]}], createdAt}]}` |
| POST | `/api/projects` | `{name, clickupListId?, repos?}` | 201 `{project}`. 400 for a blank name, an unknown or repeated role, a path that is not an absolute folder **that exists on the engine's machine** |
| PATCH | `/api/projects/:id` | any of the fields above (`repos` replaces the list) | `{project}`; a bot or channel working on a folder that moved follows it |
| DELETE | `/api/projects/:id` | — | `{ok}`; whoever belonged to it belongs to none |
| GET | `/api/fs/dirs` | `?path=&hidden=1` (default: home) | `{path, parent?, home, dirs:[name], truncated}`: the engine machine's folders, for picking where the Mac's open panel cannot |

The data of a bot or channel is `plugins.code = {projectId, role}`, set with `PATCH /api/bots/:id` or
`/api/groups/:id` and `{"plugins": {"code": {…}}}` (merged shallowly, `null` removes a key; the part of another
plugin and a field this version does not know are kept). Choosing a folder to work on also sets the chat's default
folder (`cwd`) to it; a channel whose folder is already fixed keeps it.

Before each turn the plugin tells the agent about the project, puts `SWARME_PROJECT_JSON` (the path of
`<data>/plugins/code/projects/<id>.json`: id, name, ClickUp list, folders with roles) in its environment, and links
the other folders read-only: Claude gets `--add-dir` and a rule against editing there; every engine that asks for a
permission before writing is refused for a write under them (the engine's permission broker, `ReadOnlyGuard`); Codex
already writes only in its working folder. Not enforced: a shell command that writes without asking, and an engine
run with every permission open.

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

### Projects in the app (engine plugin 1.2.0 and later)

- **Settings › Plugins › Projects**: the engine's projects, *New project…* / *Edit…*. A project has a name, a ClickUp
  list id and up to four folders (Backend, Backoffice, App, Bruno collection). *Choose…* opens the Mac's open panel for a
  local engine, and a browser of the **server's** folders for a remote one (`GET /api/fs/dirs`). The ClickUp list's name
  is not shown next to the id: that needs ClickUp access the engine does not have yet.
- **A bot's settings** (the Code card) and **a channel's settings**: *Project* and *Works on*. Choosing the folder also
  makes it the chat's default folder; a chat can still change folder from the composer. In a channel, its project
  counts, not its members'.
