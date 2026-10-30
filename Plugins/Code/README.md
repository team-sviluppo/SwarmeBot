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

### Code channels, chat history and scripts (engine plugin 1.4.0)

Code mode can be enabled on a channel with a shared folder. Every local member uses that folder;
branches, diff, commit and file references use the channel's thread. Mixed channels cannot enable Code,
and Code channels cannot take guests. Repository mutations wait while a bot, channel or routine works there.
The changed-file badge names the member who replied. With no global commit model, a channel uses its default
member's model (or its first local member when the responder policy has no selected member).

Code bots get a collapsible **Chat** column (⌘⇧L, remembered per bot and engine), with date groups, title/branch
filtering, working/unread filters and a branch filter. Enter searches the bot's message history and shows snippets.
The context menu renames, pins, archives, opens a terminal/editor, copies the path or deletes a chat; archived chats
stay in a collapsed group. Read/archive markers live on the engine. ⌘K includes Code chats and branch/script actions.
The branch and diff counts in the column describe the **current shared working folder**, rather than a separate
worktree per chat. Line counts cover tracked text changes; the tooltip identifies untracked files excluded from them.
The pull request's state and CI are in the last section.

A project's folder can define up to 20 named shell commands in its editor. **Scripts** under the composer starts
one on the engine in that folder; its output is shown below the transcript. Stop terminates the process group.
A failed command offers **Send the error to the bot**, with the command, folder, exit status and last 60 lines.
A chat whose working folder was overridden outside the project's repo has no scripts. One command per chat runs
at a time; output is bounded in memory, retained for at most 50 chats, and disappears after an engine restart.
Disabling Code or shutting down the engine stops its scripts.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET | `/api/code/chats/recent` | — | `{chats:[{botId,name,threadId,title,updatedAt}]}`, the 20 most recently active Code chats, excluding archived chats |
| GET | `/api/bots/:bid/code/chats` | — | `{chats:[{threadId,title,createdAt,updatedAt,pinned,archived,unread,status,git?}]}`; `status`: `working`, `waiting`, `unread`, `done`, `error` |
| GET | `/api/bots/:bid/code/chats/search` | `?q=` | `{hits:[SearchHit]}`, up to 50 messages from this bot's tasks; scope applied before the result limit |
| PATCH | `/api/threads/:tid/code/chat` | `{archived?:bool,read?:bool}` | chat metadata; `read:true` records the newest reply seen |
| GET | `/api/threads/:tid/code/scripts` | — | `{scripts:[{name,command}],run:null\|{id,name,command,folder,output,truncated,running,stopped,exitCode}}` |
| POST | `/api/threads/:tid/code/scripts` | `{index}` | 202 `{run}`; runs only a configured script, 400 for an invalid index and 409 while one runs |
| POST | `/api/threads/:tid/code/scripts/stop` | `{}` | `{run}`; stops the current script |

`GET /api/threads/:tid/git` additionally returns optional `additions`, `deletions` and `summaryPartial`.

### Plan mode, review by another bot, pull request and CI (engine plugin 1.5.0)

An engine whose plugin is older than 1.5.0 has none of this, and the app shows none of it.

**Plan / Execute.** The mode belongs to the chat (a bot's task, or a channel), is kept in `<data>/plugins/code/modes.json`
and read before each turn. In Plan the agent is told to explore and propose a plan and to change nothing, and the chat's
own folder is linked read-only (the guard of the project's linked folders: `--add-dir` and a rule for Claude, a refused
permission for the engines that ask before writing). It is **not a sandbox**: a command that writes without asking is what
it cannot stop. The app's chip switches the mode; under the newest reply of a chat in Plan it offers *Approve and execute*,
which switches to Execute and tells the agent to go ahead (writing a correction instead asks for a new plan).

**Review by another bot.** *Ask for a review from…* (in the Diff tab and under a reply's badge) sends the diff to a second
bot, ideally on a different model. It runs as a task of its own on that bot (its main chat stays as it was), at a peer's
depth (no tool to contact other bots), with the repository linked to it read-only so that it can read the code around the
change. With no uncommitted changes (after a push, say) the diff is the branch against its base. The reply lands in the chat
that was reviewed as a message from the reviewer, with `review:{applied:false}` (`docs/contract/http-sse.md`); *Apply* sends
it to the first bot (in a channel, to the channel) and marks it.

**Pull request and CI.** The engine asks GitHub with `gh`, in the repository, so it also works for a chat on a server;
nothing here writes to GitHub. The answer is kept for 15 s per repository and branch. The app asks again every 30 s while
checks run, 2 min otherwise, and whenever a turn ends.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET, PUT | `/api/threads/:tid/code/mode` | `{mode: "plan" \| "execute"}` | `{mode}`; 400 for another value |
| GET | `/api/threads/:tid/code/review` | — | `{review: null \| {id, reviewerId, reviewerName, reviewerThread, status, branch?, error?, messageId?, startedAt, finishedAt?}}`; `status`: `running`, `done`, `failed`, `cancelled`; the running one, or the last to end until the engine restarts |
| POST | `/api/threads/:tid/code/review` | `{botId}` | 202 `{review: {…, scope}}`, `scope` `changes` or `branch`. 400 for no changes and nothing beyond the base, for a bot reviewing its own chat or a folder that is not a repo; 404 no such bot; 409 the reviewer is working, or a review of this chat already runs |
| DELETE | `/api/threads/:tid/code/review` | — | `{cancelled: bool}`: interrupts the reviewer's turn, nothing lands in the chat |
| POST | `/api/threads/:tid/code/review/applied` | `{messageId}` | `{ok}`; 404 when the message is not a review |
| GET | `/api/threads/:tid/code/pr` | `?refresh=1` skips the kept answer | `{available, reason?, pr: null \| {number, url, title, state, draft, base, head, checks:{state, total, passed, failed, pending, items:[{name, state, workflow?, url?}]}, comments, merge?, mergeable?, reviewDecision?, author?}}`. `available:false` with a `reason` when `gh` is missing or not signed in; `pr:null` for a branch with none. `state`: `open`, `closed`, `merged`; check `state`: `success`, `failure`, `pending`, `skipped`; `checks.state` folds them (`none`, `success`, `failure`, `pending`) |
| GET | `/api/threads/:tid/code/pr/ci-failures` | — | `{message, checks}`: the text to send the agent, with the end of the failed jobs' logs (`gh run view --log-failed`, one fetch per run, 120 lines each, 24 KB in all). 404 when no check failed or there is no pull request |
| GET | `/api/threads/:tid/code/pr/comments` | — | `{message, count}`: reviews with something to say, the **unresolved** conversations on the code, and the discussion. 404 when there is nothing |

Not done: the comments of a conversation are as GitHub's GraphQL gives them (first 100 threads, 20 comments each); a
status from an external CI with no log gives its link only.

### Ahead, behind, fetch, pull and push (engine plugin 1.6.0)

`GET /api/threads/:tid/git` also answers `upstream`, `ahead` and `behind` for a branch that follows another: the commits a push would
send and a pull would bring, **as of the last fetch** (git is not asked to go to the network for a state that is read often). A branch
that follows none, a detached HEAD, or an older engine has none of the three.

| Method | Path | Request | Answer |
|---|---|---|---|
| POST | `/api/threads/:tid/git/fetch` | `{}` | the git state, after `git fetch --prune`. It moves only the remote-tracking refs, so it is allowed while a bot works. 400 not a repo, 409 no remote or git's own refusal, 504 after 120 s |
| POST | `/api/threads/:tid/git/pull` | `{}` | the git state, after `git pull --ff-only`: fast-forward only, never a merge or a rebase (that is for a terminal). 409 while a bot works, or with git's text when it would need a merge or local edits are in the way; 400 for a detached HEAD or a branch that follows nothing |
| POST | `/api/threads/:tid/git/push` | `{}` | the git state, after `git push` (`-u <remote> <branch>` for a branch with no upstream yet). Allowed while a bot works: what goes is what is committed. 409 with git's text when the remote refuses |

In the app, a chip after the branch shows `↑n ↓m` (a check when in step) and opens *Check*, *Pull*, *Push* and *Sync* (check the remote,
pull when behind, push when ahead; the first step that fails stops the rest, with git's message under the buttons). The app's
requests to a route that waits on git (these, and a commit that pushes or opens a pull request) allow four minutes instead of twenty seconds.

**A git that does not answer** is not a folder that is not a repository: git gets 30 seconds (it was 8) to say what a folder is, and past
that `GET /api/threads/:tid/git` answers `{repo:false, folder, unavailable}` (a client keeps what it last knew) while the routes that need the
repository answer **504** `git did not answer…`. A folder that is really not a repository still answers 400 `not a git repository`.

