# Design

## Context

`scripts/launch-seat` already verifies physical Git roots, common Git identity, registration, pinned Treehouse version, pool boundaries and durable lease holder. It injects seat variables into a new child only; protected `agent.env` omits them. `agentboard seat return` reads paginated task events and applies a landed gate. Codex, Muse and Herdr skills currently escalate even recoverable missing environment. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:** Recover from an owned task without resetting a worktree, silently replacing credentials, weakening isolation, or requiring a repository clone of Agentboard. Give launchers and existing sessions one validated environment contract.

**Non-Goals:** Mutate a parent process environment, automate Herdr composers/workspace configuration, migrate legacy worktrees, bootstrap credentials, install Treehouse silently, claim/reclaim tasks implicitly, or change the API/schema. Recovery does not resume work held for a captain decision.

## Decisions

### Shared packaged isolation engine

Embed the existing Python launcher in the Go workflow bundle and invoke its local resolution modes through Python 3. The Go command reads the board through the existing authenticated client, verifies an owned live task claim, follows all event pages and passes only selected task-seat metadata to the engine. This avoids independently duplicating the security-sensitive Git/Treehouse checks. A Go-only rewrite would add divergent guards; requiring a source-side script would prevent no-clone CLI use. Python 3, Git and the checksum-pinned Treehouse v3.1.2 remain explicit prerequisites.

### Task-bound durable reuse

`ensure TASK --repo SOURCE --root POOL` can run from the primary checkout for recovery only. Source defaults to the explicit seat source or the repository's registered primary checkout. Pool must be explicit, or recoverable from an existing task record; conflicting explicit pool/source is refused. Each task/actor/source has a private registry under the pool with a cross-process advisory lock. A durable binding records task, holder, physical source/root/worktree, pinned version and current lease ID. Persist a pending acquisition marker before invoking Treehouse; if interrupted before the complete binding is saved, retries refuse blind reacquisition and require inspecting the retained pool/task evidence. Persist it before board recording so a failed/ambiguous API write cannot allocate another slot on retry. Existing board records can be adopted only after all physical and holder checks; old records lacking source/lease ID are upgraded from the verified lease. Contradictory, missing, foreign or expired lease evidence is refused rather than discarded.

The engine keeps `.agentboard-seat/seat.json` in the verified slot. Unknown/recycled metadata conflicts fail closed; an existing task binding for another lease or task is never overwritten. Metadata is private, bounded and rejects symlinks. The file lock serializes same-task acquisition on one host; it is not a distributed host lock or OS sandbox. A task may have only one authoritative local recorded seat; a record referring to another host is a recovery blocker, not permission to allocate elsewhere.

### Environment handoff and native attachment

`ensure` acquires if necessary; `env` reads/verifies an existing binding without acquisition; `check` additionally requires actual cwd and expected environment to match. Default ensure/env output is POSIX shell-quoted `export` lines plus `cd -- ...`, containing only seat paths and caller-declared non-secret identity/URL. `--json` emits the same selected environment plus binding metadata. No token, token-file path, captain env file or arbitrary inherited environment appears in either format. Nothing is executed via a shell internally. `check` prints a selected JSON receipt or verified path.

Task-aware fresh launches and `--attach` use packaged `seat ensure --json`, recheck physical lease before child start, and require delivered brief argv. Reattachment verifies and reuses an existing private brief; another task or changed brief is refused instead of overwriting it. `agent.env` is created exclusively on fresh launch, now including seat variables; an existing protected file is preserved and validated for safe reuse. Existing sessions consume printed exports explicitly, change cwd, and run `seat check TASK`. This is how Herdr sessions recover now; we cannot silently inject environment into a running harness.

### Skill recovery

Canonical workflow gives the three-command recovery procedure. Codex/Muse/Herdr variants and generated briefs link it and distinguish STOP editing from permitted explicit recovery. A missing environment alone does not require a captain question; task ownership, decision holds, genuine Git/lease mismatch, full pool or legacy/out-of-pool work still require appropriate blocking/escalation. Skills ship in the existing embedded installer; no new update daemon or #57 implementation is added.

## Risks / Trade-offs

- [Python dependency in CLI recovery] → Document it; fail clearly before acquisition if missing; existing launcher already needs it.
- [Lost response after allocation/recording] → Persist local binding under the lock first; replay identical task record after comparing current events; no worktree reset or automatic release.
- [Lease changes after check] → Verify current lease ID/holder immediately before reuse and child execution. This is a boundary check, not transactional fencing of Git/Treehouse or malicious filesystem actors.
- [Old credential/brief metadata in recycled slots] → Refuse conflicts and preserve work; no credential relocation or wholesale cleanup.
- [Another host's task record] → Refuse a missing/foreign local path; explicit coordinated recovery remains necessary.
- [Board outage or ownership change] → No new allocation without successful owned-task read; final task-record mutation uses the ordinary owner API, with failure retaining the local lease for retry.

## Migration Plan

Ship the CLI and updated skills together through existing release packaging. Existing launcher-only calls without a task stay supported; task-aware attach requires the updated CLI. No server migration or rollout. Keep all old leases and credentials in place. Rollback leaves durable bindings/worktrees intact; older tooling can still inspect and explicitly return landed slots, but does not provide the new recovery commands.
