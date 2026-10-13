# Tasks

Remote-only builds and tests use `./scripts/bazel` (injects `--config=remote`).
Each group lands as its own PR from freshly fetched main, with packaged
acceptance under `build/integration/`. `AGENTBOARD_INTAKE_ENABLED`,
`AGENTBOARD_REFILL_ENABLED` and `AGENTBOARD_SEAT_SUPPLY_ENABLED` each stay off
until group 6. Intake off means its routes are unavailable. Intake is not tied
to fleets.

## 1. Work intake

- [x] 1.1 Add intake request/item resources, request-key idempotency on the normalized payload (lowercased `owner/repo`, trimmed title and body, integer priority, sorted deduplicated labels, boolean issue flag) and the transactional card plus issue-intent write; verify same-key replay, changed-payload conflict, out-of-scope repository rejection and rollback remotely.
- [x] 1.2 Add the GitHub issue outbox job with body marker, card link, marker search before retry, a server token limited to issue creation and search in intake repositories, and visible uncertainty; verify transient outage stays pending, lost response adopts one match, definitive rejection and a non-unique marker stay uncertain, and abandon remotely against controlled provider fixtures.
- [x] 1.3 Add `POST /api/v1/intake`, `GET /api/v1/intake/:id` and `agentboard intake file|status|cancel`; require a captain-issued helper token or the captain even when `agent_auth_mode` is off, without changing global authentication; document the contract and error codes. Verify the routes are unavailable while `AGENTBOARD_INTAKE_ENABLED` is off.
- [ ] 1.4 Add the Mattermost `/board file|status` slash command with token check and filer allowlist; verify unmapped-user refusal, intake-flag-off refusal, and threaded replies remotely.

## 2. Helper access and status

- [ ] 2.1 Add the `helper` identity kind and captain-issued token scope on the per-agent token machinery; verify every refused write (claim, assign, handoff, decisions, lease release, posting as another agent, setting `requested_seats` or `max_seats`) remotely, including while `agent_auth_mode` is off.
- [ ] 2.2 Add `GET /api/v1/fleet/status` with bounded digest fields, including dry-run would-assign pairs and would-launch intents; verify no bodies or credentials, helper-token refusal while `agent_auth_mode` is off, and the existing API rate limits remotely. The captain sets requested and max seats.
- [ ] 2.3 Add a helper skill for chat bots (Grok, Muse, dot, any HTTPS client): file work, cancel its own unstarted intake, read status, never coordinate, never set seat counts.

## 3. Backlog refill (#170)

- [x] 3.1 Add the per-fleet refill job on shared `Eligibility.select` with ascending priority (lower number more urgent), at most one new card per seat per pass, security-label matching, the existing assign action and idempotent `task_order`; no cursor; verify ordering, the two-seat three-card pass, a later pass filling toward the queue limit, waiting/reserved seats, crash replay and no duplicate orders remotely. The job stays fully disabled while `AGENTBOARD_REFILL_ENABLED` is off.
- [x] 3.2 Add the claim deadline, performed by the refill job, with attributed return to backlog and per-seat miss counts; verify deadline, re-assignment and digest reporting remotely.
- [x] 3.3 Add dry-run mode recording would-assign pairs without assigning, filing an issue or opening a tab; verify the board is unchanged.

## 4. Seat supply

- [x] 4.1 Add fleet activation (`dry-run|live`) that supersedes the dormant `fleet-loadout` always-`not_activatable` response (`dry_run` leaves `enabled` false; `live` sets `enabled` true and `activation_state` `live`; catalog and host status stay unverified), `requested_seats` defaulting to 0, captain-set `max_seats` and `claim_deadline`, and one outstanding launch intent per loadout seat with revision fencing. A reserved or uncertain intent occupies the seat and never expires into a successor. Eligible backlog is unassigned open cards in the fleet's repositories. Verify demand, caps, deactivation and no successor remotely. The loop stays fully disabled while `AGENTBOARD_SEAT_SUPPLY_ENABLED` is off.
- [x] 4.2 Add a host-neutral `Spawn` to `internal/seatops` with the Herdr backend (`workspace`/`tab create --cwd --label`, `pane run` on a new tab). The allowlist value is an argv list and `{brief}` is one argument, never a shell string. Verify argv construction and refusal paths against a fake Herdr binary.
- [x] 4.3 Add `agentboard host fleet serve` with reservation of live intents for its own host, a per-host concurrency cap defaulting to 0, `launch-seat` leasing, the host-local harness allowlist, journaled steps and restart adoption; relaunch the same intent only when the journal shows pane creation never started; never reserve a dry-run intent. Verify no second intent, unknown harness, lease failure and restart remotely with fake Herdr and Treehouse.
- [x] 4.4 Keep `seat reap` board-free. The server closes an intent when it observes the seat gone (pane closed or identity no longer live). Add launchd/systemd templates and a setup guide; verify reap closes the pane and returns the lease without writing the board, and the server then closes the intent.

## 5. Docs and artifacts

- [ ] 5.1 Update README, API, setup and canonical/harness skills; deliver Archify architecture and the portable OpenSpec review per the PR documentation rule.

## 6. Live pilot

- [ ] 6.1 With the captain's approval, turn the three flags on and activate one fleet on farm01 in dry-run, then live with `max_seats` 2, `requested_seats` 2 and per-host cap 2: confirm dry-run files no issues, assigns nothing and opens no tabs; then a chat bot files three issues on a sandbox repository, two seats launch in Herdr, claim, open PRs, and are reaped after merge. Record the timeline, digest snapshots and any manual step.
