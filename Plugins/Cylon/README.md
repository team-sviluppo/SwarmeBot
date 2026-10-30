# Cylon plugin

The phases of a Cylon task in a channel (`docs/plans/2026-10-28-code-mode-t3.md` §10). Two targets, linked at build
time like the Code plugin's: `Engine/` → `CylonPluginEngine` (runs wherever the engine runs, **also on Linux**) and
`App/` → `CylonPluginApp` (the Mac app's half). It needs the Code plugin (`requires: ["code"]`): the channels are
Code channels with a project, and the roles are the project's.

## The flow

```
Spec (/cylon-spec) → Plan (/cylon-plan) → Run (/cylon-run) → Review (/cylon-review) → Pull request (/cylon-pull)
```

The engine imposes it, not a bot. A channel that **follows the flow** (`plugins.cylon.follow`, set with
`PATCH /api/groups/:id`) has a pipeline for its ticket. Each phase is sent as its skill, as a message to the channel
addressed to the one bot that plays that role for the channel's project (`@Name /cylon-run cylon-features/<slug>`), and
the next one is blocked until the one before is **done or skipped**. A phase can always be skipped or marked done by hand.

- **Where it starts** is the ticket's tag, chosen when it is started: `cylon-spec` starts at Spec, `cylon-plan` at Plan
  (Spec is skipped). A `cylon-investigate` ticket is outside the flow (400). The engine cannot read ClickUp itself.
- **One bot per role**, set per project (`PUT /api/cylon/roles/:project`): providers cannot continue one another's
  session, and state between phases is on disk (`cylon-features/<slug>/`), so each phase starts clean.
- **Clean session per ticket**: starting another ticket opens a new session in the channel (history kept, divider
  added), refused while someone is working or while the ticket in hand is not finished (`replace: true` overrides).
- **How a phase ends** is what its skill says, not that a turn ended (an interview ends a turn at every question):
  Spec — its closing `/cylon-plan <id>`, which also **replaces the ticket** (the spec makes a new one; the seed is kept
  as `specTicketId`); Plan — `plan.md` of the folder whose `.data.json` names the ticket has `status: approved`
  (else its closing `/cylon-run cylon-features/<slug>`); Run — its closing `/cylon-pull cylon-features/<slug>`; Review —
  the last line `REVIEW PASSED` (done) or `REVIEW FAILED` (failed: run it again after the fix); Pull request — a
  `github.com/…/pull/N` address. A turn that fails or is stopped leaves the phase `failed`, to be sent again. These markers
  are the skills' own closing lines: if a skill changes them, "mark as done" is the way out.
- **Skills** come from a GitHub source (`PUT /api/cylon/settings {sourceId}`; Settings › Skills makes the source): the
  bots with a part get the source's skills, and a phase whose skill the bot lacks says so instead of going out.
  Skills reach a channel member's turn since the engine passes them to rooms (`docs/contract/http-sse.md`).
- A phase that writes (everything but Spec) is refused while the channel is in the Code plugin's **Plan mode**.

## Engine routes

All under `/api/`, mutations need `content-type: application/json`. Phases: `spec`, `plan`, `run`, `review`, `pull`.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET | `/groups/:gid/cylon` | — | `{follow, busy, projectId, pipeline: null \| {ticketId, tag, specTicketId?, title?, slug?, prUrl?, startedAt, finished}, phases:[{key, skill, bot: null \| {botId, name, member, skillOnEngine, skillOnBot, busy}, state?, current?, canRun?, canSkip?, canMarkDone?, command?, note?, startedAt?, finishedAt?}], source?:{id, name, ok, installed, missing}}`; `state`: `pending`, `running`, `done`, `skipped`, `failed`. `command` is what a click sends, when it can be known (the task's folder is not before the plan) |
| POST | `/groups/:gid/cylon/start` | `{ticket, tag?: "cylon-plan", title?, replace?}`; `ticket`: its id or ClickUp address | the status. 409 if the channel does not follow the flow, is working, or is in the middle of another ticket |
| DELETE | `/groups/:gid/cylon` | — | the status, with no pipeline |
| POST | `/groups/:gid/cylon/phases/:phase/run` | `{slug?}` (the task's folder name, when it cannot be found) | 202 and the status. 409 for an earlier phase not over, a working channel, no project, no bot for the phase, a bot that is not a member, a skill missing on the engine or the bot, a bot whose model is gone or that is **working in another conversation** (the room would wait for it only a few minutes and then skip it, leaving the phase running with no turn behind it), Plan mode, or an unknown folder |
| POST | `/groups/:gid/cylon/phases/:phase/skip` | — | the status; only a waiting or failed phase whose earlier ones are over |
| POST | `/groups/:gid/cylon/phases/:phase/done` | — | the status; a running, failed or waiting phase |
| GET | `/cylon/roles` | — | `{roles: {<projectId>: {<phase>: botId}}}` |
| PUT | `/cylon/roles/:project` | `{<phase>: botId \| null}` | `{roles}`; 400 for an unknown phase or bot. Also hands the Cylon source to the bots that have a part |
| GET, PUT | `/cylon/settings` | `{sourceId: string \| null}` | the skill source the plugin uses; 400 for one that does not exist |

### Boards (plugin 1.1.0)

A job that touches several repositories is split **by a person**, on ClickUp, into independent tickets, one per repository, linked
there. A **board** lists them in order of priority and starts each in the channel of its repository. SwarmeBot does not split,
create or link tickets, and a priority is only an order: it blocks nothing, the channels work independently.

- A board belongs to a project (`projectId`); a project may have several. Its `items` are `{id, role, groupId, ticketId, tag, title?}`:
  the repository's role, the channel that works on it (found from the channel's `plugins.code = {projectId, role}` and its Cylon switch;
  `groupId` in the request when several qualify), the ticket and the tag it has on ClickUp. **The order of the array is the priority.**
- **State is read, never stored**, from the channel's pipeline: `not-started`, `ready` (a phase can go out), `running` (a bot is working),
  `waiting` (the phase is open and the channel idle: the bot asked something), `failed`, `done`, `other-ticket` (the channel works on a
  different ticket), `channel-missing`. A `cylon-spec` ticket changes id after its spec, so an item matches the pipeline's `ticketId` or its
  `specTicketId`. Removing an item or the board stops nothing.
- **Start** is the channel's own *Start a ticket…* (`begin`): a clean session, 409 for a working channel or one in the middle of another
  ticket (`replace: true` overrides), 409 for a channel that does not follow the flow. **Start next** starts the first item, in order, that is
  `not-started`, and stops at its error instead of skipping to another.
- `busyBots` names the bots of the project's roles that are working, and where: the engine refuses a phase for a bot busy elsewhere.

| Method | Path | Request | Answer |
|---|---|---|---|
| GET | `/cylon/boards?projectId=` | — | `{boards: [board]}` |
| POST | `/cylon/boards` | `{projectId, title, parentUrl?}`; `parentUrl` is an http(s) link to the mother ticket, to show | 201 `{board}`; 400 for a missing project or title (up to 120 characters) or a `parentUrl` that is not http(s); 409 past 100 boards |
| GET, PATCH, DELETE | `/cylon/boards/:id` | PATCH `{title?, parentUrl?: string \| null, order?: [itemId]}`; `order` must name every item once (400) | `{board}`; DELETE `{ok}`; 404 |
| POST | `/cylon/boards/:id/items` | `{role, ticket, tag?: "cylon-plan", title?, groupId?}` | 201 `{board}`; 400 for a bad role, ticket or tag, `cylon-investigate`, a `groupId` that does not work on the role, or several channels that do and no `groupId`; 409 for a ticket already there, no channel working on the role, a channel that does not follow the flow, or a board with 30 tickets |
| DELETE | `/cylon/boards/:id/items/:item` | — | `{board}` |
| POST | `/cylon/boards/:id/items/:item/start`, `/cylon/boards/:id/start-next` | `{replace?}` | `{board, started: itemId}` after `begin`; 409 as above, for a ticket its channel already follows, or when nothing is left to start |

`board` is `{id, projectId, title, createdAt, parentUrl?, items: [item + {state, channel: null \| {name, follows}, flow, prUrl?}], summary:
{total, done, prOpen, running, notStarted, problems}, busyBots: [{botId, name, channel}]}`, where `flow` is what `GET /groups/:gid/cylon`
answers for the item's channel.

Kept in `<data>/plugins/cylon/`: `roles.json`, `settings.json`, `pipelines.json`, `boards.json`.

## In the app

- **The bar** above the composer of a channel that follows the flow: the five phases with their state (done, being
  worked on, failed, skipped, waiting), the ticket and the task's folder, the pull request once there is one, and under the
  chips what comes next, who does it, and its button (*Spec*, *Plan it*, *Run*, *Review it*, *Open the PR*; *Retry* after a
  failure). *Skip* goes on without a phase. While a phase is running and the channel is idle the bar says it is waiting for you
  (the bot asked something) and offers *Mark as done*. A click on a chip says which skill and which bot, what it will send, and
  what is missing (no project, no bot for the phase, a bot that is not a member, a skill that is not there).
- **Start a ticket…**: the ticket's id or address, and the tag it has on ClickUp (`cylon-spec` or `cylon-plan`); the channel starts a
  clean session. The menu of the bar starts another ticket or closes the flow. For a phase that needs the task's folder before the
  plan has made it, the popover asks for the folder's name.
- **The Board tab** in the right column of a channel that follows the flow (and ⌘K › *Project board*): the project's boards (a picker, *New
  board* with a name and the link of the mother ticket), their tickets in order, dragged to change the priority. Each row: the repository,
  the ticket, its channel (a click goes there), the phases as small icons, what it is doing in words, what keeps the next phase from going
  out (the same warnings as the bar) and *Start* for a ticket nobody has started (*Start…* asks before replacing the ticket a channel is on).
  The footer says how many have a PR open, which bots are busy and where, and has *Start the next one* and *Add ticket…* (repository, ticket,
  tag, name; the channel when more than one works on it).
- **A channel's settings** (the Cylon card): *Follow the Cylon flow*, which needs a project for the channel (Code card).
- **Settings › Plugins › Cylon**: the skill source (made in Settings › Skills) and, per project, the bot of each phase.
- The app polls the engine every 2 s while something runs and every 15 s otherwise; the engine follows the turns itself.

Not done: the engine cannot read ClickUp, so the tag is chosen by the person; a phase's end is read from the skills' own closing
lines and files (`CylonDetect`), which break if a skill changes them; the five skills are not installed by the plugin, they come from
the source.
