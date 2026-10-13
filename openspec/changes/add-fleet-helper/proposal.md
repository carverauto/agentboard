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
  keys make retries safe. Chat bots (Grok, Muse, OpenAI's dot or anything that
  can call HTTPS) and humans use the same contract; Mattermost gains a
  `/board` slash command over it.
- **Helper access.** A scoped `helper` credential may file and cancel its own
  intake, read a fleet status digest and request a bounded seat count within
  captain-set limits. It cannot claim, assign a named seat, answer decisions,
  merge, deploy, release leases or act as any agent. A helper is optional: the
  system keeps running when no helper is connected.
- **Backlog refill (#170).** An AshOban job assigns the next eligible backlog
  card to each idle eligible seat that holds fewer than the queue limit,
  through the existing assign path and one idempotent `task_order`. Selection
  is deterministic (priority, then age, then ID) and reuses shared seat
  eligibility, availability and captain seat scope. Dry-run mode lists the
  would-assign pairs.
- **Seat supply.** The server compares activated fleet loadout seats and
  backlog demand with live seats and writes durable seat-launch intents. A
  supervised host daemon, `agentboard host fleet serve`, reserves intents for
  its host, leases a Treehouse worktree through `launch-seat`, opens a Herdr
  tab running the seat's harness from a host-local allowlist, and reports the
  seat live or failed. It reconciles after restart. Finished seats are reaped
  by the existing `seat reap` rules. The host interface stays host-neutral so
  t3code can follow Herdr.
- **Peer coordination stays where it is.** Agents keep coordinating through
  the board, Mattermost and shared Context. This change adds no coordinator
  role and no prompt-driven control loop; every recurring decision runs as
  server or host code.

All four are default off and activate per fleet after a dry run.

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

- `work-intake`: idempotent filing of board cards and GitHub issues from any authorized client, including the `/board` slash command.
- `helper-access`: the scoped helper credential and the fleet status digest.
- `backlog-refill`: deterministic assignment of backlog cards to idle eligible seats.
- `seat-supply`: server seat-launch intents and the host fleet daemon that starts, reconciles and reaps seats.

### Modified Capabilities

None in the main spec inventory. This change activates the dormant fleet loadout
from `add-dormant-fleet-loadout` (whose design defers activation, host
reconciliation and automatic pickup) and uses `add-seat-scope-admission`,
`add-seat-nudge-reap` and shared seat eligibility unchanged.

## Impact

Phoenix/Ash resources and AshOban jobs (intake items, GitHub issue outbox,
refill, seat-launch intents), API routes and rate limits, a new credential scope,
the Go CLI (`intake`, `host fleet`), `internal/seatops` (a `Spawn` host
operation), launchd/systemd templates, Mattermost slash-command handling, skills
for helper bots, and remote acceptance fixtures. The server gains a GitHub
credential with issue-write scope for intake repositories only. No new external
service.
