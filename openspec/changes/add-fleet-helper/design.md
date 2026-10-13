# Design

## Context

The failure this change answers is specific: a prompt-driven first mate forgets.
So the rule for every part of this design is that nothing recurring depends on a
model remembering to do it. Requests come in through a deterministic API; the
server and a supervised host daemon own every loop that must keep running; agents
coordinate with each other through the board, Mattermost and shared Context as
they do today. A chat bot is a client that translates a sentence into API calls,
and it can disappear at any time without stalling the fleet.

```
chat bot / human / CLI ──► intake API ──► board card ──► GitHub issue outbox
                                              │
                         backlog refill (AshOban) ──► assign + task_order ──► seat
                                              │
                        seat supply (AshOban) ──► seat-launch intent
                                                        │
                       agentboard host fleet serve (launchd/systemd) ──► Treehouse + Herdr tab
```

## D1. Intake is a board write first, a GitHub write second

`POST /api/v1/intake` takes a request key and 1–10 items (repository, title,
body, priority, labels, `issue: true|false`). `AGENTBOARD_INTAKE_ENABLED` defaults
off; while it is off the intake routes are unavailable. Intake is not tied to a
fleet. The routes require a captain-issued helper token or the captain even when
`agent_auth_mode` is off, and that requirement does not change global
authentication. The Mattermost `/board` command keeps its own slash-token check.

In one transaction the server records the intake request, creates each board
card and, for `issue: true`, a pending issue intent. Replay and conflict use one
normalization: lowercased trimmed `owner/repo`, trimmed title and body, integer
priority, trimmed deduplicated sorted labels, and a boolean issue flag. An
AshOban job creates the GitHub issue outside the transaction with a hidden body
marker (`agentboard-intake:<item id>`), links the card to the issue, and on a
lost response searches the repository for the marker before retrying, the same
adopt-or-park rule as the Mattermost bridge. The server token can only create
and search issues in intake repositories. A transient failure stays pending. A
definitive rejection, or a marker that matches more than one issue, stays
visibly `uncertain` with a reason. Any other unresolved create stays `uncertain`
until reconciled or abandoned by its filer or the captain.

The same request key with the same normalized payload returns the original
result; a changed payload under that key conflicts. Cards are ordinary tasks, so
every existing claim, lease, PR-link and CI obligation rule applies unchanged.

Alternative: create the issue first and import it. Rejected: a GitHub outage
would block filing, and an imported issue has no durable link to its request.

## D2. Helper credential is narrow and optional

A helper is a registered identity of kind `helper` with a captain-issued token
(same per-agent token machinery as GH128). Its scope: file intake into
captain-listed repositories, cancel its own unstarted intake items, and read the
fleet status digest. The captain sets `requested_seats` and `max_seats`. Every
helper write is attributed. Helper calls are subject to the existing API rate
limits.

It cannot claim, assign to a named seat, hand off, answer or recommend
decisions, release leases, merge, deploy, or post as another agent. Assignment
only ever happens through backlog refill (D3), so no helper can steer a specific
agent. Humans in Mattermost use the slash command, which maps the Mattermost user
to a captain-allowlisted filer and calls the same API.

## D3. Refill is the only automatic assignment path

`AGENTBOARD_REFILL_ENABLED` defaults off and disables the job. While it is on, a
per-fleet AshOban job runs every minute and on task done, release and handoff
events. For each repository in the fleet's scope it orders unassigned open cards
by ascending priority (a lower number is more urgent), then creation time, then
ID. On a live fleet, each pass gives at most one new card per seat. Later
passes fill a seat up to the queue limit. It asks shared `Eligibility.select`
for a seat, which already applies availability, captain seat scope,
waiting-on-captain state and the per-seat queue limit, and assigns through the
existing assign action with one idempotent `task_order` (request key derived
from task ID and assignment revision). Security-labelled cards go only to seats
whose scope carries that label. A dry-run fleet is not assigned.

The job holds no cursor. It reselects unassigned cards each pass, so re-running
it after any crash converges on the same assignments. Dry-run mode records
would-assign pairs without writing, filing an issue, or opening a tab. The
refill job returns a card the seat does not claim within `claim_deadline`.

## D4. Seat supply splits demand (server) from launch (host)

`AGENTBOARD_SEAT_SUPPLY_ENABLED` defaults off and disables this loop.
`requested_seats` defaults to 0. Eligible backlog is unassigned open cards in
the fleet's repositories. For each live activated fleet the server computes
`wanted = min(requested_seats, max_seats, live_seats + eligible_backlog)` and
writes at most one outstanding seat-launch intent per missing loadout seat,
bound to that seat's `desired_host_id` and fenced by fleet revision. A reserved
or uncertain intent occupies the seat and never expires into a successor. The
server never chooses a binary, path or argv.

A dry-run fleet records would-launch intents in a dry-run state. The host
daemon never reserves them, so a dry-run fleet files no issues, assigns nothing
and opens no tabs.

`agentboard host fleet serve` runs under launchd or systemd on each host. It
enforces a captain-set per-host concurrency cap that defaults to 0, reserves
only live intents for its own enrolled host ID, then:

1. leases a Treehouse slot from the configured pool through `launch-seat`;
2. opens a Herdr tab in that worktree through the host interface's new `Spawn`;
3. runs the harness from a host-local allowlist whose value is an argv list,
   substituting `{brief}` as exactly one argument, never through a shell and
   never from the server;
4. reports `launched` with pane and lease identity, or `failed` with a reason.

A journal records each step so a restart reconciles: an existing pane for the
intent is adopted; the same intent is launched again only when the journal shows
pane creation never started; a missing pane after creation started is reported
and the intent stays occupied. No second intent is launched for that seat.
Seats register with `--backend herdr` as today, which names the pane. Reaping
reuses `seat reap`'s landed-work and idle rules and stays board-free. The server
closes the intent when it observes that reap closed the pane, or that the
launched identity is no longer live. A missing pane on a reserved or uncertain
intent does not close it and does not free the seat for a successor.

## D5. One wake path: the board

A newly launched seat starts from its brief, which tells it to run its
agentboard check-in. An idle seat with a new `task_order` is reminded by the
existing content-free `seat nudge` or, when enrolled, by the worker runtime's
delivery. No component types work content into a seat.

## D6. Status digest instead of a coordinator view

`GET /api/v1/fleet/status` returns a bounded digest: per fleet, live/requested
/max seats, backlog depth by priority, cards assigned but unclaimed past their
deadline, open CI repair obligations, launch intents by state (including dry-run
would-launch intents) and recent intake results. A bot can answer "how is it
going" from one read, and a bot that forgets everything loses nothing. The read
requires a helper token or the captain, the same as intake and cancel.

## D7. Activation is per fleet and reversible

Global flags `AGENTBOARD_INTAKE_ENABLED`, `AGENTBOARD_REFILL_ENABLED` and
`AGENTBOARD_SEAT_SUPPLY_ENABLED` default off and each fully disables its loop.
Intake is not tied to fleets. Refill and seat supply additionally need a captain
activation (`fleet activate FLEET --mode dry-run|live`). That activation
supersedes the dormant `fleet-loadout` response that always returned `enabled:
false` and `activation_state: not_activatable`. Dry-run sets `activation_state`
to `dry_run` and leaves `enabled` false. Live sets `activation_state` to `live`
and `enabled` true. `catalog_status` and `host_status` stay `unverified`.
Deactivation stops new assignments and launches; it never releases claims, stops
running seats or deletes intents.

## Risks

- **Runaway launches.** Bounded by `requested_seats` defaulting to 0,
  `max_seats`, the per-host concurrency cap (default 0), and one outstanding
  launch per loadout seat. A reserved or uncertain intent does not expire into
  a successor.
- **Herdr 0.9.0 has no guarded input.** Launch uses `pane run` on a new tab.
  Launch does not type into an existing pane. The existing content-free seat
  nudge remains the reminder.
- **GitHub issue duplicates.** Covered by the body marker and adopt-before-retry
  (D1). A transient failure stays pending and is retried after GitHub recovers.
  A definitive rejection or a non-unique marker stays uncertain. Any other
  unresolved create stays uncertain until reconciled or abandoned.
- **Assignments a seat cannot do.** The refill job's claim deadline returns them
  to the backlog; repeated misses for one seat mark it for captain attention in
  the digest.
