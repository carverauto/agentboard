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
body, priority, labels, `issue: true|false`). In one transaction it records the
intake request, creates each board card and, for `issue: true`, a pending issue
intent. An AshOban job creates the GitHub issue outside the transaction with a
hidden body marker (`agentboard-intake:<item id>`), links the card to the issue,
and on a lost response searches the repository for the marker before retrying,
the same adopt-or-park rule as the Mattermost bridge. An unresolved create stays
visibly `uncertain` until reconciled or abandoned by its filer or the captain.

The same request key with the same normalized payload returns the original
result; a changed payload under that key conflicts. Cards are ordinary tasks, so
every existing claim, lease, PR-link and CI obligation rule applies unchanged.

Alternative: create the issue first and import it. Rejected: a GitHub outage
would block filing, and an imported issue has no durable link to its request.

## D2. Helper credential is narrow and optional

A helper is a registered identity of kind `helper` with a captain-issued token
(same per-agent token machinery as GH128). Its scope: file intake into
captain-listed repositories, cancel its own unstarted intake items, read the
fleet status digest, and set a fleet's requested seat count within the captain's
`max_seats`. Every helper write is attributed and rate-limited.

It cannot claim, assign to a named seat, hand off, answer or recommend
decisions, release leases, merge, deploy, or post as another agent. Assignment
only ever happens through backlog refill (D3), so no helper can steer a specific
agent. Humans in Mattermost use the slash command, which maps the Mattermost user
to a captain-allowlisted filer and calls the same API.

## D3. Refill is the only automatic assignment path

A per-fleet AshOban job runs every minute and on task done, release and handoff
events. For each repository in the fleet's scope it orders unassigned open cards
by priority, then creation time, then ID. It asks shared `Eligibility.select`
for a seat, which already applies availability, captain seat scope, waiting-on
-captain state and the per-seat queue limit, and assigns through the existing
assign action with one idempotent `task_order` (request key derived from task ID
and assignment revision). Security-labelled cards go only to seats whose scope
carries that label.

The job holds no state of its own beyond a per-fleet cursor and dry-run log;
re-running it after any crash converges on the same assignments. Dry-run mode
records would-assign pairs without writing. A seat that does not claim its
ordered card within `claim_deadline` loses the assignment back to the backlog.
That deadline is a board rule, not a prompt.

## D4. Seat supply splits demand (server) from launch (host)

The server computes, per activated fleet, `wanted = min(requested_seats,
max_seats, live_seats + eligible_backlog)` and writes one seat-launch intent per
missing loadout seat, bound to that seat's `desired_host_id`. Intents are fenced
by fleet revision and expire. The server never chooses a binary, path or argv.

`agentboard host fleet serve` runs under launchd or systemd on each host. It
reserves only intents for its own enrolled host ID, then:

1. leases a Treehouse slot from the configured pool through `launch-seat`;
2. opens a Herdr tab in that worktree through the host interface's new `Spawn`;
3. runs the harness command from a host-local allowlist (`harness → argv`
   template with `{brief}`), never from the server;
4. reports `launched` with pane and lease identity, or `failed` with a reason.

A journal records each step so a restart reconciles: an existing pane for the
intent is adopted, a missing one is reported, and no intent is launched twice.
Seats register with `--backend herdr` as today, which names the pane. Reaping
reuses `seat reap`'s landed-work and idle rules and closes the intent.

## D5. One wake path: the board

A newly launched seat starts from its brief, which tells it to run its
agentboard check-in. An idle seat with a new `task_order` is reminded by the
existing content-free `seat nudge` or, when enrolled, by the worker runtime's
delivery. No component types work content into a seat.

## D6. Status digest instead of a coordinator view

`GET /api/v1/fleet/status` returns a bounded digest: per fleet, live/requested
/max seats, backlog depth by priority, cards assigned but unclaimed past their
deadline, open CI repair obligations, launch intents by state and recent intake
results. A bot can answer "how is it going" from one read, and a bot that
forgets everything loses nothing.

## D7. Activation is per fleet and reversible

Global flags `AGENTBOARD_INTAKE_ENABLED`, `AGENTBOARD_REFILL_ENABLED` and
`AGENTBOARD_SEAT_SUPPLY_ENABLED` default off. A fleet additionally needs a captain
activation (`fleet activate FLEET --mode dry-run|live`). Deactivation stops new
assignments and launches; it never releases claims, stops running seats or
deletes intents.

## Risks

- **Runaway launches.** Bounded by `max_seats`, per-host concurrency, intent
  expiry and the requirement that each launch maps to a loadout seat.
- **Herdr 0.9.0 has no guarded input.** Launch uses `pane run` on a new pane,
  which has no prior occupant. Nothing types into an existing pane.
- **GitHub issue duplicates.** Covered by the body marker and adopt-before-retry
  (D1); unresolved creates stay uncertain rather than retried blindly.
- **Assignments a seat cannot do.** The claim deadline returns them to the
  backlog; repeated misses for one seat mark it for captain attention in the
  digest.
