# Proposal

## Why

Firstmate proved the workflow the maintainers want: ask a chat bot to file a few
GitHub issues and have agents start on them in Herdr. It also showed why the
workflow must not live in an LLM. Firstmate's first mate is a long-running model
session that remembers to watch the fleet, spawn seats and keep coordinating.
After a while it loses context and stops, and the fleet stalls with it.

Agentboard already keeps the durable parts: tasks, leases, peer messages,
Mattermost, shared Context, CI repair obligations and worker receipts. Two things
are missing. Nothing turns a request into issues and cards from outside a seat,
and nothing deterministic assigns backlog work to idle seats or starts new seats.
Today a person or a coordinator session does both by hand (issue #170).

## What Changes

- **Work intake.** Any authorized client files work through one API:
  `POST /api/v1/intake` (CLI `agentboard intake file`). Each item creates a
  board card and, when asked, a GitHub issue through a server outbox with an
  idempotent marker, lost-response adoption and visible uncertainty. Request
  keys make retries safe against one normalized payload. Chat bots (Grok, Muse,
  OpenAI's dot or anything that can call HTTPS) and humans use the same
  contract; Mattermost gains a `/board` slash command over it. For an issue
  burndown, `POST /api/v1/intake/import` (CLI `agentboard intake import`)
  turns existing open issues, named by number or the first N in GitHub's list
  order, into cards linked to them without creating issues. Intake routes
  require a captain-issued helper token or the captain even when
  `agent_auth_mode` is off.
- **Helper access.** A scoped `helper` credential may file and cancel its own
  intake and read a fleet status digest. The captain sets requested and maximum
  seats. The helper cannot claim, assign a named seat, answer decisions, merge,
  deploy, release leases, set seat counts, or act as any agent. Helper calls use
  the existing API rate limits. A helper is optional: the system keeps running
  when no helper is connected.
- **Backlog refill (#170).** An AshOban job assigns the next eligible backlog
  card to each idle eligible seat, at most one new card per seat per pass,
  through the existing assign path and one idempotent `task_order`. A lower
  priority number is more urgent. Selection reuses shared seat eligibility,
  availability and captain seat scope, and the job itself returns cards left
  unclaimed past `claim_deadline`. Dry-run mode records the would-assign pairs
  and assigns nothing.
- **Seat supply.** The server compares activated fleet loadout seats and
  unassigned open backlog with live seats and writes at most one durable
  seat-launch intent per loadout seat. `requested_seats` defaults to 0. A
  reserved or uncertain intent occupies the seat and does not expire into a
  successor. A supervised host daemon, `agentboard host fleet serve`, reserves
  live intents for its host up to a per-host concurrency cap (default 0),
  leases a Treehouse worktree through `launch-seat`, opens a Herdr tab running
  the seat's harness from a host-local argv allowlist (`{brief}` is one
  argument), and reports the seat live or failed. It relaunches the same intent
  only when its journal shows pane creation never started. Dry-run records
  would-launch intents the daemon never reserves. Finished seats are reaped by
  the existing board-free `seat reap` rules; the server closes the intent when
  it observes the seat gone. The host interface stays host-neutral so t3code can
  follow Herdr.
- **Peer coordination stays where it is.** Agents keep coordinating through
  the board, Mattermost and shared Context. This change adds no coordinator
  role and no prompt-driven control loop; every recurring decision runs as
  server or host code.

`AGENTBOARD_INTAKE_ENABLED`, `AGENTBOARD_REFILL_ENABLED` and
`AGENTBOARD_SEAT_SUPPLY_ENABLED` each default off and fully disable their loop.
Intake is not tied to fleets. Refill and seat supply activate per fleet in
dry-run first: a dry-run fleet records would-assign pairs and would-launch
intents, files no issues, assigns nothing and opens no tabs.

## Out of Scope

- A coordinator agent, coordinator election or any LLM-held schedule.
- Deciding what work is worth doing. Intake files what it is told; priority
  stays with the filer and the captain.
- Merging, deploying or releasing work on anyone's behalf.
- Cross-repository load balancing beyond per-fleet scope.
- Native prompt delivery into running seats beyond the existing worker
  adapters and content-free nudge.
- Hosts other than Herdr in the first release.

## Capabilities

### New Capabilities

- `work-intake`: idempotent filing of board cards and GitHub issues from any authorized client, import of existing issues for a burndown, and the `/board` slash command.
- `helper-access`: the scoped helper credential and the fleet status digest.
- `backlog-refill`: deterministic assignment of backlog cards to idle eligible seats.
- `seat-supply`: server seat-launch intents and the host fleet daemon that starts and reconciles seats. Existing board-free seat reap closes the pane; the server closes the intent after it observes that.

### Modified Capabilities

- `fleet-loadout` (`add-dormant-fleet-loadout`): this change supersedes that capability's always-`not_activatable` response. An unactivated fleet still returns `enabled: false`, `activation_state: not_activatable`, `catalog_status: unverified` and `host_status: unverified`. Dry-run sets `activation_state` to `dry_run` and leaves `enabled` false. Live sets `activation_state` to `live` and `enabled` true. `catalog_status` and `host_status` stay `unverified`. The other dormant loadout requirements are unchanged. `add-seat-scope-admission`, `add-seat-nudge-reap` and shared seat eligibility stay unchanged; seat reap stays board-free.

## Impact

Phoenix/Ash resources and AshOban jobs (intake items, GitHub issue outbox,
refill, seat-launch intents), API routes under the existing rate limits, a new
credential scope, the Go CLI (`intake`, `host fleet`), `internal/seatops` (a
`Spawn` host operation), launchd/systemd templates, Mattermost slash-command
handling, skills for helper bots, and remote acceptance fixtures. The server
gains a GitHub credential that can only create and search issues in intake
repositories. No new external service.
