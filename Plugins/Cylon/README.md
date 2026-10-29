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
| GET | `/groups/:gid/cylon` | — | `{follow, busy, projectId, pipeline: null \| {ticketId, tag, specTicketId?, title?, slug?, prUrl?, startedAt, finished}, phases:[{key, skill, bot: null \| {botId, name, member, skillOnEngine, skillOnBot}, state?, current?, canRun?, canSkip?, canMarkDone?, command?, note?, startedAt?, finishedAt?}], source?:{id, name, ok, installed, missing}}`; `state`: `pending`, `running`, `done`, `skipped`, `failed`. `command` is what a click sends, when it can be known (the task's folder is not before the plan) |
| POST | `/groups/:gid/cylon/start` | `{ticket, tag?: "cylon-plan", title?, replace?}`; `ticket`: its id or ClickUp address | the status. 409 if the channel does not follow the flow, is working, or is in the middle of another ticket |
| DELETE | `/groups/:gid/cylon` | — | the status, with no pipeline |
| POST | `/groups/:gid/cylon/phases/:phase/run` | `{slug?}` (the task's folder name, when it cannot be found) | 202 and the status. 409 for an earlier phase not over, a working channel, no project, no bot for the phase, a bot that is not a member, a skill missing on the engine or the bot, Plan mode, or an unknown folder |
| POST | `/groups/:gid/cylon/phases/:phase/skip` | — | the status; only a waiting or failed phase whose earlier ones are over |
| POST | `/groups/:gid/cylon/phases/:phase/done` | — | the status; a running, failed or waiting phase |
| GET | `/cylon/roles` | — | `{roles: {<projectId>: {<phase>: botId}}}` |
| PUT | `/cylon/roles/:project` | `{<phase>: botId \| null}` | `{roles}`; 400 for an unknown phase or bot. Also hands the Cylon source to the bots that have a part |
| GET, PUT | `/cylon/settings` | `{sourceId: string \| null}` | the skill source the plugin uses; 400 for one that does not exist |

Kept in `<data>/plugins/cylon/`: `roles.json`, `settings.json`, `pipelines.json`.

## In the app

(see below once the app half is in)
