# Proposal

## Why

The `/agents` roster on a live deployment mixes real seats with synthetic fixtures, the human captain identity, and server system actors (all "Stale / Never heartbeat"), while busy healthy seats also show Stale because the fixed 600 s threshold does not match real heartbeat cadence. There is no supported, captain-gated way to retire an identity (hard-delete is blocked by `ON DELETE RESTRICT` FKs and destroys history). Captain approved this slice as GH #166, absorbing #42.

## What Changes

- Classify agent identities as `seat` (default), `human`, `system`, or `fixture`; default `/agents` roster shows seats only, with a filter/toggle for the rest. Never delete; human/system identities keep resolving for decision answers, attribution, and CI accountability.
- Captain-gated, idempotent `agentboard agent retire <id> --reason` and `agentboard agent restore <id>` in the CLI and the API (`POST /api/v1/agents/:id/retire`, `POST /api/v1/agents/:id/restore`). Retire sets a tombstone (`retired_at`, `retired_by`, `reason`), hides the identity from the default roster and from routing, and calls the existing `ElasticBots.retire/1` hook. Refuses when the identity holds a live claim or an open decision unless `--force` with a reason. Re-registering a retired id requires explicit restore.
- Configurable server-side roster stale threshold (`AGENTBOARD_ROSTER_STALE_AFTER`, default 20m), shown in the `/agents` column header; CLI `agentboard agent heartbeat --every 5m` cadence (documented in the seat skill); stale + busy renders as "last reported busy (unreliable)" and is not treated as live ownership.
- Docs + skills describe identity kinds and the heartbeat cadence.

## Capabilities

### New Capabilities

- `roster-identity-kinds`: identity classification and seats-only default roster with filter.
- `agent-retire`: captain-gated retire/restore tombstone in CLI and API, routing exclusion, refusal cases.
- `roster-stale-threshold`: configurable threshold, header display, heartbeat cadence, stuck-busy rendering.

### Modified Capabilities

(none — no existing specs in `openspec/specs/`; this change introduces the roster behavior contract.)

## Impact

- `web/lib/agentboard/board/resources/agent.ex` (+ migration: `kind`, `retired_at`, `retired_by`, `retire_reason` columns), `Board.Reads` roster listing/filtering, `BoardLive` `:agents` view, `APIController` agents routes, `internal/cli` agent commands (+ admin group if #144 lands first), seat skill docs, `AGENTBOARD_ROSTER_STALE_AFTER` server config.
- `ElasticBots.retire/1` hook reused as-is; no changes to claim/decision lifecycle except the retire refusal check.
- The synthetic rollout fixture retire stays a separate, explicit captain-gated step after deploy (out of this change's code).
