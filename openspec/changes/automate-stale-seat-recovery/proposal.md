# Proposal

## Current delivery scope

Coordinator task orders 1438/1449 authorize a disabled resources and episode-machine checkpoint, with schema31. Full detector, policy-store, host restart, escalation transport and end-to-end retained-answer proof remain explicit follow-ups blocked on #154/#155/#156. The full approved target below is retained; this PR does not claim it is operational. See `approval.md` and `checkpoint.md`.


## Why

A stopped seat can retain claimed work and unanswered or answered-but-unapplied captain decisions indefinitely. Recovery currently depends on a human or coordinator noticing the stale requester, restarting its session, and delivering the retained answer; the server should run this bounded recovery process regardless of coordinator platform.

## What Changes

- Add a policy-controlled AshOban stale-seat detector and one durable recovery episode per registered seat incarnation and stale-heartbeat episode.
- Reserve generation-fenced `seat.restart` intents through the #156 host delivery contract; hosts relaunch only their verified owned sessions in preserved Treehouse leases with the #141 identity/environment contract.
- Persist an automatic reason and outcome for detection, reservation, host reconciliation, restart, startup verification, responsibility catch-up, and final escalation.
- Recover answered-but-unapplied decisions through canonical startup/check-in reads, retaining their original task/gate, answer, route and delivery uncertainty; applying an answer remains distinct from transport acknowledgement.
- Snapshot a captain-approved #154 policy version. Recommend a ten-minute minimum stale threshold, declared heartbeat cadence, three bounded attempts, and final escalation that preserves claims and decisions.
- Keep manual Supersede available. No automatic release, supersede or reassignment in this version. This intentionally retains the existing held-claim contract.
- Keep activation disabled until #156/#141 integration and per-host restart capability have been proved, and a captain approves the policy and rollout.

## Capabilities

### New Capabilities

- `seat-recovery`: Policy-controlled stale-seat detection, generation-fenced restart, immutable audit evidence, canonical decision catch-up, and bounded failure escalation.

### Modified Capabilities

None in the main spec inventory (currently empty). This change extends the active `add-decision-requests` contract by adding automatic session recovery while preserving its explicit held-claim recovery and frozen/uncertain wake semantics. It does not release holds automatically.

## Impact

- Server: `web/lib/agentboard/decisions.ex`, Board operations/resources/audit, cooperation bindings/runtime, availability admission, AshOban application scheduling, and new recovery resources/actions.
- Proposed external contracts: #154 policy activation/versioning, #156 authenticated host intent reservations and receipts, #141 isolated seat ensure/check/env, #155 escalation delivery. Those issues remain dependencies, not deployed features.
- Host: a narrowly scoped recovery adapter behind #156; HTTPS only, protected credential-file references, no database access, no server-supplied shell commands or site-specific seat IDs.
- CLI/API/UI: bounded recovery inspection and captain overrides, accurate `requester_stale` plus recovery progress, no automatic decision acknowledgement or native gate bypass.
- Schema31 is reserved through coordinator order1449. This disabled checkpoint requires remote reducer/storage/schema proof, current Archify/OpenSpec documentation, native No-mistakes and green CI. Fresh-session restart and retained-answer application remain blocked-on integration work, not proof furnished by this PR.
