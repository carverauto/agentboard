# Implementation checkpoint

Orders1438/1449 bound this PR to disabled audited recovery resources, dry-run capture, and the lifecycle contract. Schema31 is reserved. No AshOban detector, operational reservation, host command, policy activation or notification is installed. The full approved design follows as the future integration contract. See `checkpoint.md` for actual implemented boundaries and blocked follow-ups.

# Design

## Context

See `proposal.md` for motivation. Observed baseline is `origin/main` at `5595a1369482bd04a3eb39c61d5c1d35853be54b`, inspected 2026-10-08. This document proposes additions; it is not deployed-recovery evidence.

| Repository evidence | Current contract |
| --- | --- |
| `web/lib/agentboard/board/operations.ex:heartbeat` | A registered seat reports busy/idle and current task; database time updates heartbeat. This does not renew its claim or establish host/session identity. |
| `web/lib/agentboard/decisions.ex:request/answer/ack` | Decisions block owned tasks; answers retain exact plaintext and audit history; ack requires the requester and a renewed live lease. |
| `decisions.ex:capture_wake/wake_mutate`, `decisions/wake.ex` | Answer routes are frozen; fallback reservation uncertainty prohibits automatic physical replay. Fallback mutation currently requires captain authority. |
| `board/resources/task.ex`, `delivery/reads.ex`, `components/decision_panel.ex` | Reads expose requester staleness separately from held claims and display a ten-minute stale threshold; there is no restart action here. |
| `cooperation/runtime.ex` | Worker bindings use epochs/generations, exact receipts, scoped enrollment and paused/revoked state; replacing a binding retains uncertain attempts. |
| `availability/policy.ex`, `housekeeping/policy.ex`, `application.ex` | Audited Ash resources plus minute-scheduled AshOban actions and effective availability admission already exist. |
| `scripts/launch-seat`, `internal/cli/seat.go` | Treehouse v3.1.2 isolation and a gated seat-return operation exist. The #141 ensure/check/env proposal is in PR167, not this baseline. |
| Active `add-decision-requests` and `align-agensh-worker-runtime` deltas | Staleness alone never authorizes reclaim, wake uncertainty never authorizes replay, and unsupported harness capability is not blanket parity. |

No archived main specs exist. The new `seat-recovery` capability supplements those active deltas without changing held-claim or frozen-wake guarantees. The task description and GH164 explicitly require proposal approval before implementation.

## Goals / Non-Goals

**Goals:** Recover an opted-in host-owned seat after its session disappears, preserve WIP/ownership and original decisions, prove a new session generation, and resume canonical responsibility/answer processing without coordinator orchestration.

**Non-Goals:** Generic process killing, UI prompt injection, claim takeover, automatic answer/supersede/withdraw, automatic task completion, garbage collection, production secret provisioning, or enabling unproven Herdr/fleet automation. Host install/activation remains explicit and captain-gated. A server resource cannot fence arbitrary filesystem writes by a rogue native process.

## Decisions

### D1. Approved policy defines eligibility and bounded attempts

Use the board-stored, captain-approved policy version from #154; recovery disabled and dry-run by default. No inline environment override or coordinator platform can bypass policy. Snapshot the active version on each episode; disabling policy immediately stops new reservations, while in-flight host effects must be reconciled before cancellation can be called complete.

Recommended policy values for captain approval: minimum stale age 600 seconds; declared heartbeat cadence at most 120 seconds; actual threshold `max(600, 3 * cadence)`; three attempts; retry delays 60 then 300 seconds; host completion/startup deadline 180 seconds; final failure action `escalate_preserve`. The explicit cadence prerequisite prevents a manually checked-in seat from being silently enrolled in automatic recovery. Heartbeat from a never-enrolled identity is not enough.

Candidates must be an approved real seat enrollment with explicit agent/repo/host mapping, declared cadence, effective active availability, unrevoked recovery capability, and at least one held claimed task or open/answered decision. Reserved/out-of-service, paused, intentionally detached or unknown-incarnation seats are excluded. A completed task or no remaining outstanding responsibility cancels eligibility. A busy/idle status alone proves neither liveness nor absence.

Alternative: periodic coordinator scripts or a global heartbeat-age reclaim rule. Both lose the durable policy/host/session boundary; the latter breaks held-decision ownership.

### D2. One episode with atomic state and append-only attempts

Propose audited RecoveryEpisode and RecoveryAttempt resources. Episode identity is `(agent_id, enrollment_revision, native_incarnation, last_heartbeat_at)` with a unique key; it retains policy version, triggering task/decision IDs, observed heartbeat and host/session fences. Attempts have `(episode_id, attempt_number)` uniqueness, their intent reservation/idempotency key, automatic reason code, timestamps and immutable outcome evidence. No secret, prompt transcript or complete environment belongs in either resource.

Lifecycle: `detected -> reserved -> restarting -> verifying -> recovered`, or `retry_due`, `uncertain`, `cancelled`, `exhausted`. A periodic AshOban action scans bounded keyset pages and queues only durable episode IDs. Re-read eligibility under the same short locks used at reservation; concurrent replicas must create one episode/attempt/intent. External host effects execute after commit. No database transaction, application-wide process, or per-agent SQL broker waits for a native session.

Use the existing task-before-decision-before-worker locking discipline; lock multiple tasks in sorted ID order and recheck episode identity on commit. Integrate heartbeat/recovery admission so a renewed heartbeat before reservation cancels the stale episode. A heartbeat after reservation does not silently prove cancellation of a possible already-started host effect; reconcile its exact attempt instead. Ordinary heartbeats never renew task leases.

### D3. #156 provides a restart intent, not a new answer route

Proposed intent type `seat.restart` references agent, enrolled host, repository allowlist, episode/attempt, expected enrollment revision/native generation, policy version, recorded seat/worktree reference and expiry. It contains no executable shell or caller-chosen path. Unique reason subject is `recovery:<episode>:<attempt>` inside #156's per-agent/reason/subject reservation contract. Reservation, result and expiry/reconciliation API must authenticate a host credential scoped to its enrolled seats and expected incarnation; an ordinary agent header/heartbeat cannot attest a restart.

The server's internal recovery actor is narrowly authorized to these transitions; it cannot answer captain decisions or run legacy captain-only wake reserve operations on behalf of a requester. Coordinator attribution is optional audit context, not an execution dependency. The host reads protected credential file paths locally and talks HTTPS, never PostgreSQL.

Dependency contract for #156: compare-and-set claim, bounded lease/expiry, exact receipt, idempotent host reconciliation, terminal rejection, paused/revoked admission, and explicit readiness per adapter/host. These interfaces are proposed here and must be agreed before implementation. Do not invent currently installed `host run` commands as evidence.

### D4. Host fences native effects and preserves custody

The host adapter verifies its local enrollment manifest and Treehouse lease ID/holder before touching the seat. It reconciles the expected session incarnation under a per-seat durable journal lock. If the old session is alive and responsive, do not stop it: report `still_alive`, cancel the stale observation and resume its normal heartbeat path. If alive but not responsive, an automatic stop is allowed only by an explicitly proven, policy-approved owned-session replacement capability that fences old writes; otherwise retain uncertainty and escalate after the bounded reconciliation budget. UI-attached and unproven sessions are not automatically killed or appended to.

Before a known-absent session restart, preserve tracked WIP/untracked task artifacts and all Git/No-mistakes custody references without resetting, rebasing, cleaning, pushing or committing unknown changes. Restore the same held Treehouse slot when its exact lease is valid. A foreign/missing lease cannot be stolen or erased: use #141's verified ensure contract to obtain a new owned slot only when all recoverable state is preserved; otherwise fail with an inspectable reason. Local configuration selects the native argv; the server supplies no shell text or secret values.

Start the native harness with the same stable repo-grounded agent ID, actual harness/model, URL, source/root/worktree and generated STOP brief. Re-run physical cwd, Git registration/common-dir and launcher checks before the native process can edit. Allocate a new native incarnation and worker binding epoch using the existing runtime fence; old receipts cannot satisfy this recovery.

The journal writes intent identity before spawn, then records the native child/session identity. A crash around spawn is reconciled against that exact marker and process identity. Repeating a request must return the prior disposition, not launch a second seat. If absence or successful spawn cannot be proved, mark `uncertain`; no blind duplicate launch or old delivery replay.

### D5. Startup verification precedes canonical catch-up

Successful native spawn is not recovery. Require host-authenticated proof of the new generation, validated isolated cwd and a fresh board heartbeat for that same enrollment, then a startup checkpoint proving canonical responsibility and pending-decision reads. Correlate these proofs with the reserved attempt; the existing unauthenticated agent heartbeat alone cannot close an episode. A genuinely newer verified heartbeat may cancel a not-yet-started stale episode without restarting anything.

Return task IDs/revisions, held-claim status and original decision IDs to the restarted seat. It explicitly renews retained held leases before applying/acking; ordinary expired claims must be renewed/reclaimed only by the existing owner and allowed lifecycle actions. No server-side extension silently manufactures ownership.

Answered-but-unapplied decisions stay the same Request, task/gate, exact answer, message and frozen Wake. Startup check-in retrieves them; it does not create a second decision answer event or reroute an uncertain worker/watcher wake. Reading answer references on a new startup generation is transport-independent catch-up, not permission to repeat its physical side effect. The seat inspects the referenced native gate/run and current work: apply only when the original gate remains applicable; ack only after an idempotent native result is proved. Mismatched/terminal gates remain unapplied with a durable diagnostic for captain review. Open decisions remain waiting; recovered liveness does not invent an answer.

Episode `recovered` means restart plus responsibility catch-up succeeded; it does not mean every answer was applied, every task completed, or uncertain worker delivery reconciled. Those statuses remain visible separately.

### D6. Bounded failure creates one escalation, preserving holds

A failed host attempt or bounded unresolved reconciliation increments its episode budget once; provider/HTTP retries do not each count as a fresh native attempt. Backoff is durable. Uncertainty consumes a bounded reconciliation window and prevents another native effect until exact absence is proved; exhaustion still retains the uncertain journal and all work.

After K failures, atomically mark exhausted and reserve one escalation keyed by episode ID for #155. Keep the failure visible in the dashboard even if notification transport is down; an idempotent delivery outbox can retry without a running coordinator. This version only implements `escalate_preserve`: claims and open/answered decisions remain held. Automatic release/supersede/reassignment needs a separately approved contract because the current supersede endpoint is captain-authorized and closes every outstanding decision on a task.

Manual authenticated Supersede stays available. Its concurrent closure/availability/policy changes cancel further recovery reservations and require reconciliation of any committed host effect. Server recovery must never re-open a superseded decision or transfer its old owner.

## Risks / Trade-offs

- False stale detection due to missed manual check-ins -> opt-in cadence plus host session probe; live sessions are preserved.
- Distributed crash cannot guarantee exactly-once native effects -> durable host journal, incarnation fence and retained uncertainty rather than replay.
- Native processes can write outside a fenced adapter -> reject automatic replacement until owned-process fencing is proven; preserve No-mistakes custody.
- #154/#156/#141/#155 are separate unshipped dependencies -> contract tests and per-host readiness gate activation; no blanket Herdr parity.
- Conservative exhaustion can leave a held task blocked -> one durable captain escalation, with existing manual supersede available.
- Audit overload -> transition-only bounded structured evidence, no heartbeat-body/transcript copying; retention must preserve referenced unsettled episodes.

## Migration Plan

1. Captain approves this proposal and later an implementation/policy version; reserve a schema version without colliding with concurrent work.
2. Add resources/migration/read-only surfaces with recovery disabled. Preserve higher `board_schema` stamps, existing decision holds, worker uncertainty and audit history.
3. Implement server/host protocol behind opt-in capability gates; prove #156/#141 integration using packaged Phoenix/Postgres and a disposable fresh native session.
4. Compare dry-run candidates with existing stale flags, including long check-in cadences and reserved agents. Do not disable the existing local nudger yet.
5. Captain enables one allowlisted proven seat/host and watches kill-session + retained-answer recovery, independent of coordinator process. Expand per-worker readiness only after proof.
6. Rollback by disabling new reservations. Reconcile already reserved/spawned effects; retain episode/attempt/journal/decision/claim records. No destructive down migration, auto-release, hook or secret activation in this planning change.
