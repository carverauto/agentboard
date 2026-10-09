# Conflict audit and typed capture v1

This supplements the shared eligibility v1 checkpoint and captain-approved source contract. Captain message1824 assigns the minimal shared evaluator to #169; #170 reuses it. Inbox owner message1828 confirms the deferred-notice producer contract. Neither agreement supplies native custody or authorizes deployment.

## Typed inbox capture

Runtime.fallback/4 remains the sole Event/Delivery versus canonical Message election. Its optional capture_notice?: false defers MessageNotice and WakeIntents capture; existing callers retain the default behavior.

The conflict producer requests deferred capture, records the immutable ConflictSource relation, and captures MessageNotice plus the typed WakeIntents occurrence inside the collector's existing transaction. Message ID and exact creation-time version remain the occurrence identity. The closed order_ref remains unchanged and is evidence for the shared currentness fence, not branch-write authority. The producer emits no second task order or selector.

If a source/audit/typed-wake write fails, the collector transaction rolls back its snapshot, new order, repair, selected Event/Message, source relation and wake together. Its separately committed poll reservation survives for crash recovery. The next ordinary collection attempt retries the sole election. No generic orphan is committed from the failed typed path.

An unassigned repair has no authorized order recipient. Its captain triage Message therefore retains a generic notice/wake rather than inventing an assigned-order reference. Resolving that Message as an assigned conflict order fails closed.

The actual worker and typed wake consumers now use the shared globally sorted batch prefix and authoritative currentness map. See conflict-consumers.v1.md for frozen reserve/dispatch, exact prior receipts and native notification-host proof. A reference by itself remains insufficient authority.

## Snapshot and deadline dry-run ledger

Rebase.observe calls ConflictDryRun.observe only in dry-run mode. The caller owns the collector's sorted base/PR/poll fence and the existing AshEvents transaction.

ConflictEvaluation uses Ash's Simple data layer for its transient evaluation value. Its create action persists an append-only record in the existing board_action_events log through AshEvents. It has no mutable table, repair identity, source effect or additional migration. The supplied database observation time is the event timestamp.

The retained event contains canonical PR/snapshot identity, phase snapshot, mode, lifecycle/mergeability, observed head, actual default/target names and tips, immutable submission attribution, shared author-eligibility evidence, queue/deadline policy and prior current-order identity/revision. Native custody remains unsupported.

Plans include create, retain or supersede an order; clear without rebaser credit; cancel closed order; no conflict/open order; unsupported base identity; unknown mergeability; and cooperation disabled. Observation classification is shared with legacy repairs and apply-mode current orders. Submission attribution also shares the exact repair-excluding TaskLink query with apply mode.

Dry-run commits ordinary provider snapshots and polling/watch evidence. It never creates an assignment, repair card, claim, inbox Message, cooperation Event/Delivery, wake, captain decision or publication grant. Audit failure rolls back the provider snapshot rather than leaving observation evidence without its attributable plan.

Retained current orders also support deadline dry-run through the existing scheduled action. It acquires the same sorted base/PR/poll, policy/seat/agent, repair and order prefix as apply mode; selects with the shared eligibility evaluator; and rechecks currentness before recording phase deadline. Evidence includes the selected candidate or no-seat plan, routing reason, retained deadline/episode, repair revision and both branch identities. No handoff, claim, selected source, grant or captain decision occurs. A dry-run evaluation reports no change.

Deadline planning evaluates actual retained orders; snapshot dry-run does not invent virtual repair/order identities for future deadlines. Terminal same-head repair reconciliation and disable-time grant cleanup remain pending. No installed-adapter custody or live farm01 parity is inferred; OpenSpec task5.1 remains unchecked.

## Verification ownership and limits

conflict_routing_test owns deadline dry-run candidate/no-seat evidence and unchanged repair/source leases and effect counts. It also checks that a busy author can be replaced at deadline and the selected seat must explicitly claim the repair. Its generated AshOban worker/default system actor executes the unique job persisted by the canonical order producer.

conflict_order_sources_test owns the packaged provider-to-source boundary. It independently asserts the closed typed reference, exactly one wake, failure/retry atomicity, dry-run audit identities and author eligibility, create/retain/supersede/clear plans, and unchanged effect counts and source claims. Its audit failures are invented PostgreSQL triggers at the real commit boundary; there is no test-only production export.

The pre-fix typed-capture regression failed on an empty source_ref (BuildBuddy a11bbce7-f096-47bd-b84e-6dd6b8982bd7). The pre-fix dry-run regression failed on the missing evaluation record (BuildBuddy 33f3bd7e-ea04-41c3-84ed-3c0356ad1256). Four remote owner/sibling targets passed at the first audit/capture checkpoint: https://carverauto.buildbuddy.io/invocation/6da4c89e-6fc4-4c36-a0a9-77f9afc237aa. All eleven combined remote targets pass after the shared observation-classification cleanup and expanded dry-run transition assertions: https://carverauto.buildbuddy.io/invocation/7b315629-ee23-445d-b9b0-5ec189ddb5cf. Ten executed freshly and publication_guard_test was cached.

After adding retained-order deadline audit, the quality delta against checkpointecf1e24 reports zero new gating regressions and one minor growth finding in ConflictRouting. Snapshot/deadline evidence builders share the audit resource writer; the phase constructors remain separate. Earlier shared-eligibility review findings remain retained; this is not a blanket clean-quality claim.

The deadline audit regression failed before the change on missing canonical selection evidence (https://carverauto.buildbuddy.io/invocation/3d42b65d-f0da-4486-8e91-c5358347c0d8). Four current remote owner/sibling targets pass at https://carverauto.buildbuddy.io/invocation/9181cc5a-da4b-4240-b631-cc9697154abb. Busy-author and explicit repair-claim assertions additionally pass at https://carverauto.buildbuddy.io/invocation/8b8250b8-96c1-447b-acf9-995532d6333e. The final persisted-job/default-actor proof also passes at https://carverauto.buildbuddy.io/invocation/d1c28971-c40e-44af-a77c-c646c1c8f787. These supplement the eleven-target checkpoint, rather than claiming it tested later code. OpenSpec4.2 is complete at the server boundary; native publication custody remains a separate unfinished item; actual notification dispatch is covered by the consumer companion.

Archify conflict-audit.v4 depicts the apply versus audit branch after the current repair/order fence. Deterministic validation passes 9/9 with zero errors/warnings. Automated browser containment/readability checks pass at four desktop sizes. Actual image review passes at 1440x900 dark and 2048x1320 light. A prior diagram was revised to put no-seat escalation after currentness and remove a visually ambiguous shared corridor; the accepted v4 source/HTML are frozen.

No PR, native No-mistakes run, deployment, host activation, custody receipt, rebaser attribution or merge is implied.
