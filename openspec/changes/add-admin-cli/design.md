# Design

## Context

See proposal.md (Why). Current state: worker identity provisioning is a hand-run curl against captain-gated `POST /api/v1/workers/provision` (`WorkerController.provision`) plus revoke (`WorkerController.revoke`); `agentboard worker bind/install/doctor` exist as separate manual steps with no create-or-reuse logic (`internal/cli/worker.go`); `AGENTBOARD_COORDINATOR_ID` and `AGENTBOARD_CI_POLICIES` are hand-edited env vars (#100/#125, #124); rollouts follow the prose runbook in `docs/deploy/reference-farm01.md` with hand-written evidence JSON shaped like `docs/verification/farm01-1bf92ae-rollout.json`; per-agent tokens are being built in #128 (Agent A — reuse, do not duplicate); release/installer ships the same CLI in #127.

## Goals / Non-Goals

Goals: one CLI group covering the full operator path; every mutation idempotent and dry-runnable; secrets never observable; rollouts verify and self-rollback; generic backends (kustomize + compose). Non-goals: a new binary; changing `worker bind/install/doctor`, `agent register`, or `task link` semantics (wrapped, not rewritten); the #128 token commands; the #57 compose bootstrap itself (line up with it, not a prerequisite); actual backup/restore engine work (#98 owns CNPG backups — `admin` only invokes).

## Decisions

- **Extend `internal/cli` with `admin*.go` under the existing root command** over any new tool: the captain's explicit ask; inherits config, flags, client, and captain capability for free.
- **Diff-then-apply inside every subcommand** over check-then-act flags: uniform `--dry-run`/`--plan` with shared exit codes (0/2/1 dry, 0/1/3 apply); `apply -f` reuses the same code paths so declarative and imperative converge identically.
- **Tokens only to `0600` files, referenced by fingerprint/prefix** over any display-or-return: matches the worker `bind` receipt discipline (epoch receipt saved, never printed) and the #128 convention; existing files require `--rotate`; group/world-writable parents refused.
- **Digest-only pins; tags rejected at the gate** over resolving tags: rollouts and migration Jobs must agree on one immutable digest; resolution would reintroduce drift.
- **CNPG on-demand `Backup` first, logical dump fallback** over mandating CNPG: uses #98 where configured, still works where it is not; the backup record precedes the migration Job unconditionally.
- **Migration-order parity with #97 CI checks**: migrate-then-roll ordering is the same rule CI enforces; `admin rollout` is the operator-side twin.
- **farm01 as docs example only** over code defaults: `k8s/overlays/example` + sample config carry every input explicitly; no hostname, namespace, or Secret name baked in.
- **Captain capability for all board mutations; agent tokens rejected for `admin`** over scope negotiation: agents keep agent-scoped tokens (#128); operator power stays behind the existing captain gate.

## Risks / Trade-offs

- [`apply -f` schema becomes a compatibility surface] → Settle the schema in this proposal; version the file with an explicit `apiVersion`-style field from day one.
- [Rollback of a partially applied rollout] → Exit `1` reports exactly what changed vs what did not; rollback restores the previous pin, not intermediate state; the record distinguishes both.
- [Compose target drift vs #57] → Line up compose field names with #57's bootstrap now; note divergences as open questions for the captain rather than inventing a second dialect.
- [Doctor false drift on eventually-consistent reads] → Doctor reports observed-vs-desired with the observation timestamp; transient mismatches are labeled, not asserted.

## Migration Plan

Additive: new `admin` command group; no existing command changes behavior; new docs page plus runbook rewrite; example overlay additive. Rollback: remove the group wiring. No schema changes, no migrations.

## Open Questions

- `apply -f` schema version field name and the exact `--json` diff envelope field names — settled in this proposal, captain confirms naming in Lavish.
- Soak-window default duration for rollout verification — proposed default in spec review, captain decides.
- Cosign/attestation verification inside `admin rollout` (optional in #127) — in or out for v1 of this group.
