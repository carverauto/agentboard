# Shared eligibility and repair admission v1

Captain task_order1824 assigns #169 the minimal shared evaluator, with #170 reusing it later. This server checkpoint builds on main 7db89ef and its captain-managed `SeatScope` contract. Native custody remains unsupported under decision fd4961ff; the installed native publication custody contract remains separately assigned.

## Shared functions

`Agentboard.Eligibility.admit(agent_id, task)` returns retained evaluation evidence. `select(task, excluded_ids)` returns the first rechecked eligible candidate or `nil`. Both run inside the caller's `Ops.transaction` before any task/order/worker lock. A selection reserves capacity through commit only when its caller atomically assigns the repair in that transaction. #169 uses `admit/2` for initial author assignment and `select/2` for replacement routing. #170 can reuse these functions and the same policy; refill scheduling is outside this change.

Evidence fields are `agent_id`, `eligible`, `reason`, `queue_count`, `queue_limit`, `last_assignment` (epoch seconds, zero for no retained assignment), and `scope_revision`. Reasons are `unregistered`, `not_seat`, `retired`, `stale`, `unavailable`, `waiting_on_captain`, `outside_managed_scope`, `queue_full`, and `eligible`. `repair_routed` task events retain the successful candidate evidence alongside before/after task records and the prior order ID/revision.

Automatic recipients must be registered nonretired seats, current under `Board.Reads.roster_threshold/0`, active under `Availability.effective/1`, without an open/unapplied captain decision, inside a captain-managed repository/label scope, and below the queue limit. Missing managed scope refuses automatic assignment. Self-reported capabilities and shared GitHub credentials establish no repository authority. The evaluated task is the actual repair, with its `rebase-repair` label. Captain scopes must cover those task attributes.

## Queue policy

`AGENTBOARD_QUEUE_LIMIT` defaults to 2 and accepts integers 1–100. It maps to the shared `:queue_limit` application policy. Count all assigned/in-progress/blocked/review cards across repositories, excluding archived/terminal cards and the repair currently being reevaluated. Registration `current_task_id` and heartbeat busy/idle status do not replace that count.

Choose shortest queue, then least recent retained assignment, then stable full agent ID. Assignment time is the latest retained assign/handoff/claim/reclaim/repair_routed event for that recipient; an identity with none sorts first. The fleet scan is bounded at 1000 seats; a larger fleet refuses automatic selection instead of evaluating an incomplete page as complete.

## Transaction and lock contract

Conflict consumers acquire sorted watched default/target identities, canonical PR and PollState first. Shared availability/scope policy admission follows, then a per-seat transaction advisory gate, compatible agent row lock, repair task and order. Manual assign/handoff/claim/reclaim and the existing CI/rebase producers acquire the same seat gate before their task locks. Decision request/promotion takes the requester's seat gate before its task lock, fencing new holds through admission commit. Policy/scope writers retain the existing exclusive policy gate.

Selection ranks a read snapshot and rechecks queue, scope, liveness and holds after taking a candidate's gate. A busy candidate is skipped using a try-lock, so competing selections do not wait on another candidate while holding their own gates. The scheduled persisted order remains available for reevaluation. Agent row locks are shared; they fence heartbeat/model/retirement updates through commit. Routing locks and rechecks the repair and exact observed order revision/current pointer before applying any assignment.

The source task is neither locked nor mutated by repair routing. Assignment changes only the repair, clears its previous claim, records the system actor and retains author attribution. Public linking cannot replace a rebase repair's original PR identity, avoiding attribution changes and a task→PR lock inversion.

## Deadline and retained findings

`AGENTBOARD_CONFLICT_DEADLINE_SECONDS` defaults to 2700 and accepts 60–86400. Each episode retains its earliest deadline across supersession. `ConflictDisposition` persists an immediate AshOban job for new orders and reevaluates open orders through bounded keyset pages every minute. This catches deadline expiry and changes in policy, scope, liveness, queue and captain holds without another provider poller.

An eligible author receives the initial repair. An ineligible recipient can be replaced before its deadline; an unresolved current recipient — author or reassigned seat — is replaced once at its retained earliest deadline, and a generation that already fired its deadline routing stays assigned across subsequent ticks. Candidate admission and the canonical base/order fence commit with repair handoff, supersession, new current pointer and the sole #122 source election. The old order's pending/admitted grants are revoked and retained captain findings are superseded. No branch grant is created by this workflow.

No eligible seat creates one durable captain decision for the current order/revision, plus `conflict_escalated` timeline evidence. Later ticks reevaluate eligibility without repeating that finding. A replacement creates a visible `native_custody_unsupported` decision until the separately owned native adapter supplies its verified contract. Clean/closed evidence cancels the order before a frozen timer can issue a replacement. The server retains unknown rebaser credit and does not complete the repair from notification or unverified clean evidence.

## Verification

The `conflict_routing_test` collector/API/AshOban fixture owns this contract: eligibility profiles, queue/assignment/ID ties, early unavailable/waiting/stale routing, deadline transfer of an existing repair lease, duplicate jobs, concurrent admission for one remaining slot, unchanged source claims and resolution before a queued timer. `conflict_order_sources_test` owns canonical source/current-base and connected dashboard proof. All actors, provider metadata and capabilities are invented fixtures. The deadline/staleness cases advance retained timestamps; they do not pre-create an order, assignment, source or admission decision.

All ten remote targets pass after the final runtime changes: https://carverauto.buildbuddy.io/invocation/db52c2f7-fb6f-4475-b87f-8ed681e0aa9a. The producer now defers generic fallback capture and retains a typed WakeIntents reference after the immutable relation, per inbox owner1828. Coordinator1837 confirms #156/#122 on main. Both actual frozen worker and typed inbox wake consumers now share the currentness prefix and closed reference documented in conflict-consumers.v1.md. The companion conflict-audit-and-capture.v1.md records the snapshot dry-run ledger and its limits. Native publication custody adapters, verified rebaser completion, disable-time cleanup and activation remain pending. No PR or live deployment is implied by this checkpoint.

## Quality review

The targeted review extracted task-admission/identity guards and routing evidence checks, eliminating new complexity regressions in existing mutation/repair creation functions. Ripwire still reports 12 gating candidates: advisory-lock/result/config boilerplate, the existing CI/rebase producer similarity, the established AshOban reconciliation pattern and growth in the conflict-order module. Four new-symbol findings include module/function size and a six-argument assignment helper. These are retained review findings; no blanket suppression or clean-quality claim is made.

The native retained-deadline/dedup fixes and corrected current-order regression now have intended product RED, byte-for-byte restoration and fresh remote GREEN. See [the recovery receipt](conflict-routing-recovery-receipt.md) for exact checkpoints, hashes, invocations and unfinished publication obligations.
