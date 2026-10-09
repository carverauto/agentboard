# Conflict audit and typed capture v1

This supplements the shared eligibility v1 checkpoint and captain-approved source contract. Captain message1824 assigns the minimal shared evaluator to #169; #170 reuses it. Inbox owner message1828 confirms the deferred-notice producer contract. Neither agreement supplies native custody or authorizes deployment.

## Typed inbox capture

Runtime.fallback/4 remains the sole Event/Delivery versus canonical Message election. Its optional capture_notice?: false defers MessageNotice and WakeIntents capture; existing callers retain the default behavior.

The conflict producer requests deferred capture, records the immutable ConflictSource relation, and captures MessageNotice plus the typed WakeIntents occurrence inside the collector's existing transaction. Message ID and exact creation-time version remain the occurrence identity. The closed order_ref remains unchanged and is evidence for a future consumer fence, not branch-write authority. The producer emits no second task order or selector.

If a source/audit/typed-wake write fails, the collector transaction rolls back its snapshot, new order, repair, selected Event/Message, source relation and wake together. Its separately committed poll reservation survives for crash recovery. The next ordinary collection attempt retries the sole election. No generic orphan is committed from the failed typed path.

An unassigned repair has no authorized order recipient. Its captain triage Message therefore retains a generic notice/wake rather than inventing an assigned-order reference. Resolving that Message as an assigned conflict order fails closed.

The actual generic wake consumer currently classifies a typed conflict occurrence as unsupported. Worker reserve, frozen dispatch and globally sorted batch admission still need the joint currentness integration. Capturing the reference does not establish that those consumers invoke the resolver.

## Snapshot dry-run ledger

Rebase.observe calls ConflictDryRun.observe only in dry-run mode. The caller owns the collector's sorted base/PR/poll fence and the existing AshEvents transaction.

ConflictEvaluation uses Ash's Simple data layer for its transient evaluation value. Its create action persists an append-only record in the existing board_action_events log through AshEvents. It has no mutable table, repair identity, source effect or additional migration. The supplied database observation time is the event timestamp.

The retained event contains canonical PR/snapshot identity, phase snapshot, mode, lifecycle/mergeability, observed head, actual default/target names and tips, immutable submission attribution, shared author-eligibility evidence, queue/deadline policy and prior current-order identity/revision. Native custody remains unsupported.

Plans include create, retain or supersede an order; clear without rebaser credit; cancel closed order; no conflict/open order; unsupported base identity; unknown mergeability; and cooperation disabled. Observation classification is shared with legacy repairs and apply-mode current orders. Submission attribution also shares the exact repair-excluding TaskLink query with apply mode.

Dry-run commits ordinary provider snapshots and polling/watch evidence. It never creates an assignment, repair card, claim, inbox Message, cooperation Event/Delivery, wake, captain decision or publication grant. Audit failure rolls back the provider snapshot rather than leaving observation evidence without its attributable plan.

This is snapshot planning, not full deadline-selection parity or a promise of successful future admission. Existing terminal same-head repair reconciliation, complete dry-run deadline/escalation evidence and disable-time grant cleanup remain pending. OpenSpec task5.1 therefore remains unchecked.

## Verification ownership and limits

conflict_order_sources_test owns the packaged provider-to-source boundary. It independently asserts the closed typed reference, exactly one wake, failure/retry atomicity, dry-run audit identities and author eligibility, create/retain/supersede/clear plans, and unchanged effect counts and source claims. Its audit failures are invented PostgreSQL triggers at the real commit boundary; there is no test-only production export.

The pre-fix typed-capture regression failed on an empty source_ref (BuildBuddy a11bbce7-f096-47bd-b84e-6dd6b8982bd7). The pre-fix dry-run regression failed on the missing evaluation record (BuildBuddy 33f3bd7e-ea04-41c3-84ed-3c0356ad1256). Four remote owner/sibling targets passed at the first audit/capture checkpoint: https://carverauto.buildbuddy.io/invocation/6da4c89e-6fc4-4c36-a0a9-77f9afc237aa. All eleven combined remote targets pass after the shared observation-classification cleanup and expanded dry-run transition assertions: https://carverauto.buildbuddy.io/invocation/7b315629-ee23-445d-b9b0-5ec189ddb5cf. Ten executed freshly and publication_guard_test was cached.

The quality delta against checkpoint10e108a reports zero new gating regressions, three minor existing-module growth findings and one new-module size finding. Earlier shared-eligibility review findings remain retained; this is not a blanket clean-quality claim.

No PR, native No-mistakes run, deployment, host activation, custody receipt, rebaser attribution or merge is implied.
