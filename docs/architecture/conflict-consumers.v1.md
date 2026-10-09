# Conflict consumer contract v1

Coordinator message1837 confirms #156 worker/wake transport and #122 sole source election are shipped on main. #169 implements against those owners' actual APIs. This contract supplements the unchanged closed conflict-order-ref.v1 schema and immutable ConflictSource relation. It adds no wake reason, new selector, native publication grant or deployment authorization.

## One batch prefix and evaluator

ConflictCurrentness.lock(descriptors, recipient) runs inside the caller's transaction. Descriptors use exact Event source_key or canonical Message creation-time version. It discovers immutable source/order relations, then locks all distinct canonical default/target watch IDs globally sorted, all PR IDs sorted, all PollState IDs sorted, shared availability admission, the recipient agent, sorted repair task IDs, then sorted orders. No worker/intent/source mutation lock may precede this prefix. Single-source resolve delegates to the same evaluator; batches never nest single-source callbacks.

Currentness requires the selected source mode, exact retained version, open current order and revision, current repair recipient/assignment/PR identity, unread canonical Message when applicable, nonretired agent, current PR lifecycle/head and both watched branch identities. The authoritative result is pending, stale_order or unsupported. A source arriving after the prefix snapshot is unfenced and deferred to another request, never locked below worker custody. The existing bounded page/frame limits remain in effect.

ConflictConsumer carries that map into the real Cooperation.Runtime worker reserve, pending, dispatch, result, reconcile and receipt paths, and Wake.Reads/Transport preview/reservation. Existing worker Event deliveries project the closed order_ref into the existing frame. The canonical inbox Message is adopted by the already shipped wake.nudge Event/Delivery and bounded batch; its original pr_conflict Event is never re-elected into another delivery. The reservation's source_refs retains the same closed reference. Runtime.fallback remains the sole election.

## Frozen dispatch and receipts

POST /api/v1/workers/:worker/attempts/:attempt/dispatch uses the existing host capability and exact attempt_id, binding_epoch, dispatch_generation and payload_hash. It fences the real frozen batch sources before worker custody and checks current recipient availability, policy, binding and unresolved reserved attempt. dispatch_allowed is false for an obsolete source, disabled cooperation or historical recipient. The response's native_publication remains unsupported.

Idempotent reserve returns the original frozen payload and hash. Reconciliation adds conflict_source_state and refuses replay of obsolete sources. Reevaluation never rewrites frozen payload/receipt bytes or invents not_submitted after source invalidation. Host result evidence determines transport disposition. Receipt scope and exact frozen fences are still validated; historical receipts remain attributable history. A stale receipt cannot acknowledge the canonical conflict effect or establish repair credit.

The Go notification host detects typed conflict frames and calls this dispatch endpoint immediately before journal submission/native input. Missing authorization, unavailable check or refusal before native input records truthful not_submitted evidence. Monitoring repeats source/recipient checks during native I/O; cancellation after I/O retains uncertainty. The database transaction ends before native input and cannot fence a later external branch write. Notification admission/receipts do not prove No-mistakes custody, PR publication authority, native fixes preserved or a completed rebase.

## Independent proof

conflict_order_sources_test owns the packaged provider-to-public-API boundary. Production creates orders, source relations, wake intents, deliveries and frozen batches. Invented provider data and declared notification capabilities exercise server fences; they supply no custody receipt or installed native input.

It exercises canonical typed Message preview/reserve/result, no original Event delivery or second conflict election, exact closed references in batch and reservation, current worker dispatch, exact idempotent frozen bytes after source invalidation, and a two-PR batch with distinct target watches. While a real worker row is held, the public dispatch transaction blocks there only after taking the complete prefix. The second PR's target watch cannot advance until dispatch commits. Its later advance makes the frozen batch undispatchable even though the first PR's source remains current.

A deliberate mutation moving the prefix below worker custody fails for the intended reason, “Second PR target advanced before the batch fence committed,” at https://carverauto.buildbuddy.io/invocation/d8f307d0-7a23-4a14-96f7-a0cf869b4762. The exact production source was restored byte-for-byte afterward.

The extended typed-inbox/two-PR proof passes remotely at https://carverauto.buildbuddy.io/invocation/9bd60f9c-7dfb-4794-bfc1-19e35c402017. An earlier extended run failed solely because its fixture compared the stored text PR number to an integer; that fixture was corrected before this pass.

The missing worker reference regression failed before integration at https://carverauto.buildbuddy.io/invocation/48de678f-05f1-4548-a582-30c676fa289e. The notification-host test failed for the intended pre-fix reason (native input entered with no dispatch check) at https://carverauto.buildbuddy.io/invocation/6fa5ef2a-e5b5-4278-9584-c36be37e92ed. Its earlier socket fixture privacy failure is not regression proof. The host primary test executes real worker Step against an invented protected Unix-socket adapter and scoped HTTPS server: denied/missing admission enters native input zero times; allowed admission enters once and returns attributable transport evidence.

Five combined owner/sibling targets pass at https://carverauto.buildbuddy.io/invocation/2df8ffc0-e251-4d4e-8727-ab31183568c5: conflict_order_sources_test, coop_inbox_fallback_test, cooperation_api_test, wake_intents_test and internal/worker:worker_test. That run predates the additional two-PR/typed-inbox assertions; the focused receipt above proves those additions.

## Documentation and limits

conflict-consumers.v3.workflow.json and its frozen HTML depict the actual consumer boundaries. Deterministic delivery passes all nine showcase checks with zero composition errors/warnings. Automated real-browser checks pass light/dark desktop containment and supported viewer behaviors; actual image review at 1440x900 dark and 2048x1320 light found clear labels and routes without unrelated opaque-node crossings. Earlier v1/v2 candidates are superseded, not accepted browser evidence.

Native PR admission/custody is separately assigned under captain decision fd4961ff for the quota reset. Positive grants, verified rebaser credit, native publication/cutover and live product rollout remain unsupported or unfinished. Terminal same-head episode reconciliation, registered-branch recovery and disable-time cleanup are separate remaining server work. No PR, native No-mistakes run, deployment or activation is implied by these receipts.

The consumer delta against bdddc839a reports zero material regressions in existing Elixir/Go production symbols and no suppressions. It retains eight minor Elixir signature/size findings and one new-module size finding. The Go primary host test reports fixture size/complexity and a static dead-code false positive: the remote Go test runner actually executes its Test function. Earlier feature-wide quality findings remain review obligations; this incremental result is not a clean-quality claim for the whole branch.

After restoring the prefix, all seven combined targets pass at https://carverauto.buildbuddy.io/invocation/b9a52fde-e8e2-42b6-b14d-309741fb8cce. Routing and schema upgrade ran freshly; the five consumer/sibling targets reused valid identical-source cache receipts. The upgrade preserves current main schema35/fleet state and the additive schema32 contract. Two earlier final-run attempts named nonexistent shorthand targets and ran no checks; they are not verification receipts.
