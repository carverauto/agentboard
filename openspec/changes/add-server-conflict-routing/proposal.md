# Proposal

## Why

PRs can open already conflicting or without a card link, and a busy or unavailable author can leave a repair unattended. Agentboard must retain publication identity and route timely conflict repairs without a coordinator process.

## What Changes

- Require a durable task/head-repository/branch binding before native publication. Check the freshly fetched repository default branch at final push and PR open/update; refuse a conflicting branch, warn and record a clean but behind branch, and retain unknown/unavailable checks as unresolved.
- Record the opened PR on its bound card automatically, with retryable receipts. Discover registered branches with missing links; auto-link only a unique, valid mapping and escalate ambiguous attribution without guessing an author.
- Extend the existing base-watch, observation and rebase-repair paths. Route a conflicting PR immediately at open/link and every relevant base advance, including advances caused by an unlinked merge.
- Maintain one current conflict order per canonical PR and current default-branch tip. Supersede older tips, retain provenance, and satisfy a repair only with a changed, currently mergeable head.
- Use #122's sole worker/inbox election: retain the existing Event/Delivery for a healthy worker, or one canonical Message for inbox fallback. Carry the same closed order reference through the selected source; suppress superseded delivery and never create a second prompt. Captain decision `aca78ca8-4587-438c-babd-f33065d0bb37` approved this amendment on 2026-10-09.
- Give the author a configurable deadline (proposed default 45 minutes). Reassign only the repair card when the deadline expires or the author is stale, waiting on a captain decision, or out of service. Use shared queue eligibility and preserve original task ownership and authorship.
- Fence repair publication against the observed head and base, cancel losing repairs, and require a verified native-custody handoff before another seat writes the same PR branch. Unsupported custody produces a captain escalation, never an impersonated push or second PR.
- Persist sweep, order, selection, deadline, cancellation and escalation evidence. Support dry-run planning without assignments, messages, wakes or provider writes. Preserve existing default-branch CI failure attribution.

## Capabilities

### New Capabilities

- `publication-admission`: Durable branch/card binding, fresh-base publication checks, opened-PR recording and recovery of missing links.
- `pr-conflict-routing`: Base-fenced conflict episodes, orders, deadline eligibility, repair-only reassignment, resolution and audit.

### Modified Capabilities

None. `openspec list --specs` reports no main capability inventory at the inspected baseline; existing change documents and delivery code are inputs, not duplicate main specs.

## Impact

Extend `scripts/publish-seat`, `scripts/publication-guard`, Go API client commands, Board link operations, `Delivery.Inventory`, `BaseMonitor`, `Polling`, `Rebase` and `RebaseFollowUp`. Add Ash/Postgres resources and AshOban work in the existing domains, with AshEvents and AshPaperTrail where mutable state needs history; no SQL-serializing GenServer and no CLI database access.

Use the existing provider budget, availability admission, decision lane and cooperation delivery. Integrate contracts from #156/#150 for host wakes and native custody, #170 for queue eligibility, and #153 for optional signed webhook hints; the poller remains sufficient for correctness. Reserve schema 32 / migration `20261008003200` for the additive state after rechecking the ledger at implementation. This PR proposes behavior only; enforcement and host cutover are later implementation work, requiring reviewed custody contracts.
