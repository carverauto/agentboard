# Conflict source resolver v1

This supplements the captain-approved delivery-source contract v2 and the unchanged closed `conflict-order-ref.v1.schema.json`. It records executable server and notification-host consumer integration, not deployment or native publication support.

## Implementation boundary

`Agentboard.Delivery.ConflictOrders.with_current_source(kind, id, version, recipient, consumer)` owns the database transaction. It returns `{:ok, consumer_result}` or `{:error, code, message}`. The callback receives the closed order reference only after canonical currentness passes. It must reserve the selected effect in that same transaction, and perform provider/native I/O afterward.

| Selected source | kind | id | version |
| --- | --- | --- | --- |
| Existing worker Event/Delivery | `event` | immutable Event UUID | exact Event `source_key` |
| Canonical inbox Message | `board_message` | positive integer Message ID | exact `DateTime.to_iso8601(Message.created_at)` |

The immutable `delivery_conflict_sources` row relates Event ID, order ID/revision, source key, selected disposition, and optional Message ID/version. The resolver reads that row; it accepts no caller-supplied order reference, summary, hash or prose authority. Inbox selection cannot also authorize the corresponding Event as a worker effect.

Lock order is sorted watched default/target identities, canonical PR, PollState, shared availability admission, recipient agent, repair task, and current order. Callers must hold no worker/source/intent lock before entering. A callback may then take the consumer's existing worker/intent locks. Do not nest this single-source wrapper for a batch. `ConflictCurrentness.lock/2` collects all immutable source relations and locks every distinct watch, then every PR, then every PollState in globally sorted order before policy, repair or worker custody. Both actual consumers use this prefix through `ConflictConsumer`.

The resolver verifies the current order pointer, open/unresolved state, revision, selected mode, nonretired recipient, repair assignment and nonterminal task, PR URL, exact retained Event/Message identity and version, current PR lifecycle/head, and both watched default-tip and actual-target identities. Unknown relation or disabled routing/cooperation returns `unsupported`; invalid source input returns `invalid_input`; obsolete source/recipient/evidence returns `stale_order`. The callback is never invoked on refusal.

## Read-only API

`POST /api/v1/conflicts/resolve-source` accepts exactly `source_kind`, `source_id`, and `source_version`. The registered Board actor is the recipient; a foreign actor cannot resolve another seat's selected order. Its response contains `order_ref` and `native_publication: unsupported`. A response proves currentness at read time only and cannot authorize a later dispatch or branch write.

## Producer behavior and remaining acceptance

The existing fenced collector selects the new path only in apply mode with cooperation enabled. It reuses the repair creator, preserves source-card ownership, retains the earliest unresolved deadline, reuses a current order on repeated or still-dirty heads, and supersedes default/target/recipient changes with one new selected source. `Runtime.fallback/4` remains #122's sole selector. No pre-election owner DM is emitted by this path. Enrollment reads the existing immutable source without re-election or base/order locks, and an inbox-selected occurrence never re-elects its original `pr_conflict` Event into a worker delivery. The existing #156 `wake.nudge` transport may adopt that canonical Message and retain its closed reference in its own bounded frozen batch.

The policy defaults disabled. Snapshot and retained-order deadline dry-run append attributable audit evidence without repair effects; disable-time cleanup remains pending. Default deadline is 2700 seconds; `conflict_deadline_seconds` accepts 60–86400 seconds with invalid values falling back to the default. No native publication/custody grant is issued.

Coordinator message1837 confirms #156/#122 are shipped on main and directs #169 to implement against their actual contracts. The worker reserve/dispatch and canonical inbox wake consumers now share the currentness map; `conflict-consumers.v1.md` documents the portable contract and remote proof. No retired owner agreement is pending. Full 3.2/3.3 acceptance remains open for verified rebaser attribution and remaining admission/cancellation races; terminal same-head episodes are now implemented at the server boundary. Shared eligibility and repair-only deadline routing are implemented in the companion shared-eligibility.v1 contract. Clean evidence invalidates obsolete instructions without invented credit; it does not complete a repair whose rebaser is unproven.

Captain decision `fd4961ff-f367-42ad-9c72-153161c73d23` assigns the upstream PR-admission/custody adapter to a separate seat after the quota reset (2026-10-13 22:28 CT). #169 remains server-only and cannot declare native grants/cutover ready before that contract and executable proof.

## Verification ownership

`conflict_order_sources_test` owns collector-produced source relations, independent closed-reference/API assertions, current-tip idempotency, changed-dirty-head reuse, default/target supersession, earliest-deadline preservation, wrong version/recipient refusal, selected worker versus inbox effects, late-enrollment reuse, atomic audit rollback, and a concurrent base advance serialized behind the consumer transaction. It uses invented provider metadata; production creates every order, pointer and selected source. Existing `pr_conflicts_test` owns legacy per-head delivery; `conflict_default_watch_test` owns default-watch fanout/replay; `release_schema_test` owns migration preservation/idempotency.

Ripwire review identified cross-domain Ash query/controller boilerplate as clone candidates and the moved existing repair creator as a clone of the pre-existing CI episode creator. The latter is an unchanged extraction reused by both conflict paths, not a second copied repair implementation. The new producer's branch complexity was reduced by making retained episode/deadline semantics explicit. The report is not clean; these boilerplate/extraction tradeoffs require review rather than a blanket suppression or unrelated refactor.

## Read-only dashboard checkpoint

The existing PR index/detail and source/repair task detail views now show the latest retained order, deadline, issued recipient, current repair owner, author, default/actual-target identities, selected source disposition and verified rebaser (or Not verified). They share one read-only component and do not change the Kanban, source task or claim. Order evidence is labeled last observed; it authorizes no effect. Unknown rebaser credit remains unknown.

The public PR projection and connected task/PR renders passed through the actual Phoenix WebSocket transport and pinned Rendered consumer: https://carverauto.buildbuddy.io/invocation/577a3414-1698-42dc-a55f-5219c52ae3db. The legacy conflict suite passed against the same production tree in https://carverauto.buildbuddy.io/invocation/217dffc8-f991-4f0e-8f5d-b95ba43a9e63; the new suite failed its initial fixture there, then passed separately after comparing UTC instants and exercising connected task loading. Keyboard/narrow behavior in the deployed product: UNTESTED-live. The complete admission/escalation ledger and full task5.2 remain pending.

#122 owner agreement is retained in board message1810 for Context324/document187. The shipped main fallback/bootstrap suite passes with the integrated consumers; the canonical source suite also exercises late enrollment and typed Message adoption without another original Event delivery. Captain task_order1824 answers message1811: #169 defines the minimal shared evaluator and #170 reuses it later. The shared-eligibility.v1 contract reuses main's captain-managed SeatScope, with automatic routing failing closed for unmanaged seats.

## Terminal repair reconciliation checkpoint

Manual done/cancelled status cannot prove a dirty PR resolved. A later dirty observation at an already signaled head creates a fresh repair while retaining the historical follow-up and terminal task. A conflict after provider clearance starts a fresh episode/deadline. If the current episode's repair becomes terminal while the PR remains dirty, the collector resolves the old follow-up relation, creates a replacement through the existing author admission path, and supersedes the order while preserving its episode ID and earliest deadline. Repeated observations reuse that replacement. Source card ownership/claim and original author attribution remain unchanged; notification or manual completion supplies no rebaser credit.

The reserved, undeployed schema32 migration adds current_base=false to existing legacy follow-ups. The old once-per-head uniqueness remains for legacy records; current-base follow-ups retain distinct repair history with at most one unresolved current-base follow-up per PR. Existing historical rows receive no live deadline/order. Readiness also requires the new column. Current main schema36, triage and fleet migrations remain preserved; readiness requires the complete main table set plus the additive conflict/binding/grant tables.

The active-terminal regression failed at https://carverauto.buildbuddy.io/invocation/8d9492cd-4371-49ab-922d-74674a032ac3 on retaining the same terminal repair/order. The corrected exact historical-head fixture failed at https://carverauto.buildbuddy.io/invocation/c8110b85-1d3f-4676-b7e1-c83cab67eb8c on refusing a new episode. All four owner/sibling tests then ran freshly and passed at https://carverauto.buildbuddy.io/invocation/c595a37f-e235-4ef2-96c2-a20e9df02f78: conflict_order_sources_test, conflict_routing_test, pr_conflicts_test and release_schema_test. These exercise real provider collection, public cancellation, retained producer history, exact deadline preservation, source claim equality and legacy upgrade idempotency.

The incremental quality delta retains one clone finding for the shared Ash filter/sort/limit/read-one query shape against an unrelated workflow-health reader, plus three minor size findings. This is a deliberate small query API for both legacy and current-base owners; no cross-resource abstraction or blanket suppression is added to hide the review finding. Native publication/rebaser proof, registered-branch recovery and policy disable cleanup remain unfinished.
