# Tasks

## 1. Migration and domain

- [ ] 1.1 Reserve migration number with coordinator, add `kind` (default `seat`), `retired_at`, `retired_by`, `retire_reason` to agents with backfill of derived kinds. Verify: `mix ash_postgres.migrate` plan shows the reserved number; rollback removes only these columns.
- [ ] 1.2 Failing-first tests for roster filtering (seats-only default, kind filter reveals rest, retired excluded) and kind derivation for legacy rows. Verify: new `ex_unit_test` target fails before, passes after via Bazel `--config=remote`.
- [ ] 1.3 Shared `visible_roster` scope used by both listing and routing. Verify: routing test asserts a retired identity is unroutable.

## 2. Retire / restore

- [ ] 2.1 Captain-gated `POST /api/v1/agents/:id/retire` + `/restore` with tombstone write, history record, and `ElasticBots.retire/1` call. Verify: API tests for gate refusal, idempotent repeat, and restore round-trip.
- [ ] 2.2 Live-claim / open-decision refusal unless `--force` with reason; forced retire recorded as forced. Verify: tests for refusal, forced success, and missing-reason rejection.
- [ ] 2.3 CLI `agentboard agent retire <id> --reason [--force]` and `agentboard agent restore <id>` (+ admin group if #144 lands first). Verify: `cli_test` cases incl. idempotency and no secret output.

## 3. Threshold and rendering

- [ ] 3.1 `AGENTBOARD_ROSTER_STALE_AFTER` server config (default 20m) plumbed to the roster read; header shows active threshold. Verify: config test + LiveView header assertion.
- [ ] 3.2 CLI `agentboard agent heartbeat --every 5m` ticker reusing the heartbeat call; seat skill documents the cadence. Verify: CLI test for ticker invocation; docs updated.
- [ ] 3.3 Stale + busy renders "last reported busy (unreliable)"; no ownership clearing from staleness. Verify: LiveView coverage for `/agents` rows in each state.

## 4. Ship

- [ ] 4.1 Docs + skills describe identity kinds and cadence. Verify: docs reference the new commands and threshold var.
- [ ] 4.2 Push via no-mistakes without --yes, link PR to card, record CI, never merge. Verify: PR linked on `agentboard-roster-identity-retire`, `gh-axi pr checks` green recorded.
