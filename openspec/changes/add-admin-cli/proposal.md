# Proposal

## Why

Setting up and operating an agentboard deployment is still a hand-run sequence of curl calls, overlay edits, `kubectl` steps, and ad-hoc scripts. Every step was done by hand for the reference farm01 deployment on 10/7–10/8; a second team would have to reverse-engineer all of it (GH #138). The captain's ask: package it so other people can use it, everything idempotent, by extending the existing `agentboard` CLI — no new binary, no separate tool.

## What Changes

- A new `agentboard admin` command group in the existing CLI (`cmd/agentboard`, `internal/cli`), reusing its config, flags, client, and captain capability:
  - `admin worker create <worker-id> --token-file PATH` — create-or-reuse identity via captain-gated `POST /api/v1/workers/provision`; token goes only to a `0600` file, never stdout.
  - `admin worker enroll <worker-id> [--config PATH]` — converge-only bind + install supervision + doctor, built on the existing `worker bind/install/doctor` steps.
  - `admin worker revoke <worker-id>` — via `DELETE /workers/:id/revoke` semantics.
  - `admin agent register <agent-id> --harness H --model M` — wraps `agent register`; reports bot/availability state (#82/#118, #81).
  - `admin config get|set coordinator-id <agent-id>` and `config get|set ci-policies --file policies.json` — replacing hand-edits of `AGENTBOARD_COORDINATOR_ID` (#100/#125) and `AGENTBOARD_CI_POLICIES` (#124).
  - `admin rollout <image@sha256:...>` — pre-migration backup (CNPG on-demand `Backup` per #98, else logical dump to an operator path) → migration Job on the same digest → roll Deployment → verify (rollout status, readiness, `agentboard meta` schema/protocol, smoke read, soak window) → auto-rollback to the previous pin on failure. Writes a machine-readable rollout record shaped like today's `docs/verification/*-rollout.json`, with no secret values. Tags rejected; immutable digests only.
  - `admin doctor` — read-only drift report across all of the above.
  - `admin apply -f agentboard-admin.yaml` (optional) — converge a declarative file by calling the same subcommands.
- Every mutating subcommand supports `--dry-run` (alias `--plan`): no writes, prints the current-vs-desired diff. Exit codes — dry-run: `0` none, `2` pending, `1` error; apply: `0` converged, `1` error (nothing or partial change reported), `3` rolled back. `--json` emits the structured diff and result.
- Generic targets, not farm01-specific: pluggable Kubernetes/kustomize (overlay `images:`/env edit for GitOps, or direct apply) and docker compose (lined up with #57) backends. Cluster, namespace, context, overlay path, hostnames, and Secret names are all inputs; `k8s/overlays/example` gets a sample config; farm01 stays a worked example in docs, not a code path.
- Board-side mutations use the existing captain capability only; agents' per-agent tokens (#128) stay agent-scoped and cannot run `admin`. Per-agent token issue/rotate conventions (fingerprint/prefix output) are reused from #128, not duplicated.
- Docs: new `docs/setup/admin.md`; `docs/deploy/reference-farm01.md` manual rollout steps become `agentboard admin` invocations with an example config. The #127 installer ships this CLI unchanged (no extra binary); `agentboard admin --help` works after a one-line install.
- No implementation until the captain approves this proposal in Lavish.

## Capabilities

### New Capabilities

- `admin-conventions`: idempotency/diff-converge contract, `--dry-run`/`--plan` with documented exit codes, no-secret-output rule, `--json` diff/result shape — shared by every `admin` subcommand.
- `admin-worker-lifecycle`: idempotent worker identity create-or-reuse, token-to-0600-file, converge-only enroll, revoke.
- `admin-agent-config`: wrapped agent registration with bot/availability report; coordinator-id and ci-policies get/set.
- `admin-rollout`: digest-pinned backup → migrate → roll → verify → auto-rollback with a machine-readable rollout record.
- `admin-doctor-apply`: read-only drift report; declarative `apply -f` converging through the same subcommands.

### Modified Capabilities

None. Existing `worker bind/install/doctor`, `agent register`, and `task link --pr` behaviors are reused unchanged inside the scopes defined above; no current spec requirements change.

## Impact

- New `internal/cli/admin*.go` + Bazel targets; `root.go` wires the `admin` group; no new binary (`cmd/agentboard` unchanged in shape).
- `k8s/overlays/example` gains a sample admin config; farm01 overlay untouched except via operator-run `admin` invocations.
- New `docs/setup/admin.md`; `docs/deploy/reference-farm01.md` rewritten around `admin` invocations.
- Tests: idempotency (second run is a no-op), dry-run diffs on clean/drifted/partial states, no-secret-output capture across stdout/stderr/`--json`/logs, rollback-on-failed-verification with exit `3`, backup-before-migration ordering — all through CI Bazel targets (`--config=remote`), no raw BEP in evidence (#132).
