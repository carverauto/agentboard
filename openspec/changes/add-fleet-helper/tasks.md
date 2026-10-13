# Tasks

Remote-only builds and tests use `./scripts/bazel` (injects `--config=remote`).
Each group lands as its own PR from freshly fetched main, with packaged
acceptance under `build/integration/`. Every flag stays off until group 6.

## 1. Work intake

- [ ] 1.1 Add intake request/item resources, request-key idempotency and the transactional card plus issue-intent write; verify same-key replay, changed-payload conflict, out-of-scope repository rejection and rollback remotely.
- [ ] 1.2 Add the GitHub issue outbox job with body marker, card link, marker search before retry and visible uncertainty; verify outage, lost response, duplicate marker and abandon remotely against controlled provider fixtures.
- [ ] 1.3 Add `POST /api/v1/intake`, `GET /api/v1/intake/:id` and `agentboard intake file|status|cancel`; document the contract and error codes.
- [ ] 1.4 Add the Mattermost `/board file|status` slash command with token check and filer allowlist; verify unmapped-user refusal and threaded replies remotely.

## 2. Helper access and status

- [ ] 2.1 Add the `helper` identity kind and captain-issued token scope on the per-agent token machinery; verify every refused write (claim, assign, handoff, decisions, lease release, posting as another agent) remotely.
- [ ] 2.2 Add `GET /api/v1/fleet/status` with bounded digest fields and the helper seat-count request within `max_seats`; verify bounds, no bodies or credentials, and cap refusal remotely.
- [ ] 2.3 Add a helper skill for chat bots (Grok, Muse, dot, any HTTPS client): file work, read status, request seats, never coordinate.

## 3. Backlog refill (#170)

- [ ] 3.1 Add the per-fleet refill job on shared `Eligibility.select` with deterministic ordering, security-label matching, the existing assign action and idempotent `task_order`; verify ordering, waiting/reserved seats, queue limit, crash replay and no duplicate orders remotely.
- [ ] 3.2 Add the claim deadline with attributed return to backlog and per-seat miss counts; verify deadline, re-assignment and digest reporting remotely.
- [ ] 3.3 Add dry-run mode recording would-assign pairs; verify the board is unchanged.

## 4. Seat supply

- [ ] 4.1 Add fleet activation (`dry-run|live`), `requested_seats`/`max_seats`/`claim_deadline` on the fleet loadout, and launch-intent resources with revision fencing and expiry; verify demand computation, caps, deactivation and expiry remotely.
- [ ] 4.2 Add a host-neutral `Spawn` to `internal/seatops` with the Herdr backend (`workspace`/`tab create --cwd --label`, `pane run`), ported from Firstmate's Herdr backend; verify argv construction and refusal paths against a fake Herdr binary.
- [ ] 4.3 Add `agentboard host fleet serve` with intent reservation for its own host, `launch-seat` leasing, the host-local harness allowlist, journaled steps and restart adoption; verify no double launch, unknown harness, lease failure and restart remotely with fake Herdr and Treehouse.
- [ ] 4.4 Close intents from `seat reap` and add launchd/systemd templates and a setup guide; verify reap closes the pane, lease and intent.

## 5. Docs and artifacts

- [ ] 5.1 Update README, API, setup and canonical/harness skills; deliver Archify architecture and the portable OpenSpec review per the PR documentation rule.

## 6. Live pilot

- [ ] 6.1 With the captain's approval, activate one fleet on farm01 in dry-run, then live with `max_seats` 2: a chat bot files three issues on a sandbox repository, two seats launch in Herdr, claim, open PRs, and are reaped after merge. Record the timeline, digest snapshots and any manual step.
