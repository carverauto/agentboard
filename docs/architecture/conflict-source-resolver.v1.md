# Conflict source resolver v1

This supplements the captain-approved delivery-source contract v2 and the unchanged closed `conflict-order-ref.v1.schema.json`. It records a local server checkpoint, not deployed consumer integration or native publication support.

## Implementation boundary

`Agentboard.Delivery.ConflictOrders.with_current_source(kind, id, version, recipient, consumer)` owns the database transaction. It returns `{:ok, consumer_result}` or `{:error, code, message}`. The callback receives the closed order reference only after canonical currentness passes. It must reserve the selected effect in that same transaction, and perform provider/native I/O afterward.

| Selected source | kind | id | version |
| --- | --- | --- | --- |
| Existing worker Event/Delivery | `event` | immutable Event UUID | exact Event `source_key` |
| Canonical inbox Message | `board_message` | positive integer Message ID | exact `DateTime.to_iso8601(Message.created_at)` |

The immutable `delivery_conflict_sources` row relates Event ID, order ID/revision, source key, selected disposition, and optional Message ID/version. The resolver reads that row; it accepts no caller-supplied order reference, summary, hash or prose authority. Inbox selection cannot also authorize the corresponding Event as a worker effect.

Lock order is sorted watched default/target identities, canonical PR, PollState, shared availability admission, recipient agent, repair task, and current order. Callers must hold no worker/source/intent lock before entering. A callback may then take the consumer's existing worker/intent locks. Do not nest this single-source wrapper for a batch: a multi-source consumer needs one agreed globally sorted base/PR prefix before any repair or worker locks.

The resolver verifies the current order pointer, open/unresolved state, revision, selected mode, nonretired recipient, repair assignment and nonterminal task, PR URL, exact retained Event/Message identity and version, current PR lifecycle/head, and both watched default-tip and actual-target identities. Unknown relation or disabled routing/cooperation returns `unsupported`; invalid source input returns `invalid_input`; obsolete source/recipient/evidence returns `stale_order`. The callback is never invoked on refusal.

## Read-only API

`POST /api/v1/conflicts/resolve-source` accepts exactly `source_kind`, `source_id`, and `source_version`. The registered Board actor is the recipient; a foreign actor cannot resolve another seat's selected order. Its response contains `order_ref` and `native_publication: unsupported`. A response proves currentness at read time only and cannot authorize a later dispatch or branch write.

## Producer behavior and remaining acceptance

The existing fenced collector selects the new path only in apply mode with cooperation enabled. It reuses the repair creator, preserves source-card ownership, retains the earliest unresolved deadline, reuses a current order on repeated or still-dirty heads, and supersedes default/target/recipient changes with one new selected source. `Runtime.fallback/4` remains #122's sole selector. No pre-election owner DM is emitted by this path. Enrollment reads the existing immutable source without re-election or base/order locks, and an inbox-selected occurrence does not become a worker frame.

The policy defaults disabled. Dry-run currently suppresses repair effects; the complete dry-run audit ledger is still pending. Default deadline is 2700 seconds; `conflict_deadline_seconds` accepts 60–86400 seconds with invalid values falling back to the default. No native publication/custody grant is issued.

Task 1.1 and the full 3.2/3.3 acceptance remain open. #156 must agree and implement the actual existing-frame projection plus frozen reservation/dispatch integration, including batch lock order and exact prior receipts. This single-source callback proof is not a claim that worker dispatch already invokes it. #122 election is reused unchanged; complete worker-health and concurrent fallback/bootstrap acceptance must be jointly verified. Shared eligibility and repair-only deadline routing are implemented in the companion shared-eligibility.v1 contract; terminal same-head episode reconciliation and verified rebaser attribution remain pending. Clean changed-head evidence cancels obsolete instructions without invented credit; it does not complete a repair whose actual rebaser is unproven.

Captain decision `fd4961ff-f367-42ad-9c72-153161c73d23` assigns the upstream PR-admission/custody adapter to a separate seat after the quota reset (2026-10-13 22:28 CT). #169 remains server-only and cannot declare native grants/cutover ready before that contract and executable proof.

## Verification ownership

`conflict_order_sources_test` owns collector-produced source relations, independent closed-reference/API assertions, current-tip idempotency, changed-dirty-head reuse, default/target supersession, earliest-deadline preservation, wrong version/recipient refusal, selected worker versus inbox effects, late-enrollment reuse, atomic audit rollback, and a concurrent base advance serialized behind the consumer transaction. It uses invented provider metadata; production creates every order, pointer and selected source. Existing `pr_conflicts_test` owns legacy per-head delivery; `conflict_default_watch_test` owns default-watch fanout/replay; `release_schema_test` owns migration preservation/idempotency.

Ripwire review identified cross-domain Ash query/controller boilerplate as clone candidates and the moved existing repair creator as a clone of the pre-existing CI episode creator. The latter is an unchanged extraction reused by both conflict paths, not a second copied repair implementation. The new producer's branch complexity was reduced by making retained episode/deadline semantics explicit. The report is not clean; these boilerplate/extraction tradeoffs require review rather than a blanket suppression or unrelated refactor.

## Read-only dashboard checkpoint

The existing PR index/detail and source/repair task detail views now show the latest retained order, deadline, issued recipient, current repair owner, author, default/actual-target identities, selected source disposition and verified rebaser (or Not verified). They share one read-only component and do not change the Kanban, source task or claim. Order evidence is labeled last observed; it authorizes no effect. Unknown rebaser credit remains unknown.

The public PR projection and connected task/PR renders passed through the actual Phoenix WebSocket transport and pinned Rendered consumer: https://carverauto.buildbuddy.io/invocation/577a3414-1698-42dc-a55f-5219c52ae3db. The legacy conflict suite passed against the same production tree in https://carverauto.buildbuddy.io/invocation/217dffc8-f991-4f0e-8f5d-b95ba43a9e63; the new suite failed its initial fixture there, then passed separately after comparing UTC instants and exercising connected task loading. Keyboard/narrow behavior in the deployed product: UNTESTED-live. The complete admission/escalation ledger and full task5.2 remain pending.

#122 owner agreement is retained in board message1810 for Context324/document187. Full concurrent fallback/bootstrap proof remains scheduled after #156/#164 land. Captain task_order1824 answers message1811: #169 defines the minimal shared evaluator and #170 reuses it later. The shared-eligibility.v1 contract reuses main's captain-managed SeatScope, with automatic routing failing closed for unmanaged seats.
