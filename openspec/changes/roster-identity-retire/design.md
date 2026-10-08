# Design

## Context

See proposal.md (Why). Current state: `Agentboard.Board.Resources.Agent` has no kind or tombstone fields; `Board.Reads` lists agents with a fixed `stale_after=600` default for the web roster; `/agents` is the `BoardLive :agents` table; the API has list/show/register/heartbeat only; `ElasticBots.retire/1` already idempotently retires a bot row; the agent CLI lives in `internal/cli` (Go) beside the new `admin` group (#144).

## Goals / Non-Goals

**Goals:** kind + tombstone columns behind a reserved migration number (coordinator-reserved); captain-gated retire/restore in CLI + API reusing the token/capability conventions from #128/#138; threshold config plumbed to the roster read; LiveView filter + stuck-busy rendering.

**Non-Goals:** automatic reclamation or takeover from staleness (#164 owns recovery); production worker enrollment; the post-deploy fixture retire (separate explicit captain step).

## Decisions

- **Tombstone columns on agents, not a side table** (`kind` default `seat`; `retired_at`, `retired_by`, `retire_reason` nullable): keeps roster filtering a single-query predicate and history joins unchanged. Alternative (side table) rejected — extra join on every roster read.
- **Kind derived at read time for legacy rows**: rows predating the migration with `model=system`/`harness=ash` read as `system`, captain id as `human`, unless an explicit kind was set. Backfill writes the derived value once in the migration so the rule is inspectable, not magic.
- **Retire refusal checks claim + open decisions inside the same transaction** as the tombstone write: avoids retire racing a fresh claim. `--force` + reason bypasses, recorded as forced.
- **Threshold default 20m, CLI cadence 5m**: 4x headroom so a missed beat never flips a working seat to Stale. `--every` implemented as a client-side ticker reusing the existing heartbeat call (no new server surface).
- **Routing exclusion via the same predicate as the roster** (seats-only, non-retired): one `visible_roster` scope shared by listing and routing so they cannot disagree.

## Risks / Trade-offs

- [Risk] Migration number collision with parallel changes → Mitigation: reserve the number with the coordinator before writing it (task order step 2).
- [Risk] `--every` ticker drift on sleeping laptops → Mitigation: 4x headroom absorbs it; staleness degrades to the honest "unreliable" label, never to takeover.
- [Risk] Legacy `system`/`human` derivation misclassifies a real seat → Mitigation: explicit kind at register wins; derivation only fills nulls; kind editable by captain.

## Migration Plan

Deploy: migration adds nullable columns + backfill (online-safe); server reads honor kind/tombstone/threshold immediately; CLI ships retire/restore/--every; docs + seat skill updated. Rollback: new columns ignored by old code paths; retire is reversible via restore.

## Open Questions

- Exact `/agents` filter control shape (query-param toggle vs dropdown) — UI detail, settled at implementation within the spec's filter requirement.
