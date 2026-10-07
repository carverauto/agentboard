# Tasks

## 1. Ash dependency and migration foundation

- [x] 1.1 Pin Ash, AshPostgres, AshPhoenix, AshPaperTrail, AshEvents, Oban, AshOban and provider HTTP client in Mix and hermetic Hex/Bazel closure; verify dependency compilation and release packaging only through remote Bazel.
- [x] 1.2 Map existing Agent/Task/TaskEvent/Message/Document/quota tables into Ash resources/domains without recreating tables; verify remote schema fixtures preserve v0.1.0 IDs, constraints and HTML bytes.
- [ ] 1.3 Add additive audit/version/Delivery/Oban schema with generator baselines; verify fresh install, schema-4 upgrade and repeat migration remotely, and document audit cutoff/rollback compatibility in docs/release.md.

## 2. Existing operations through Ash

- [x] 2.1 Convert Agent registration/heartbeat and board read/pagination/snapshots to domain actions; verify current API/CLI registration, harness conflict and keyset/full-watch behavior remotely.
- [x] 2.2 Convert Task create/assign/claim/renew/release/reclaim/status/link/update to atomic resource operations; verify one-winner claims, revision conflicts, manual expiry recovery, lifecycle restrictions and compatible error envelopes remotely.
- [x] 2.3 Convert handoff and Message send/recipient acknowledgement into shared transactional actions; verify assignment/event/message rollback and recipient-only acknowledgement through the real API/CLI remotely.
- [x] 2.4 Convert quota evidence resources/ingest and immutable Document uploads/fetches; verify schema 5/6 retention, canonical retries, live-owner/terminal rules, size bounds and metadata reads excluding HTML remotely.
- [ ] 2.5 Route API/watch/document controllers and LiveView reads through domain interfaces, removing independent mutation authorities; verify all existing routes/streams and sandbox viewer in remote acceptance plus a real browser, and document the shared operation boundary.

## 3. Attributed audit and concurrency

- [x] 3.1 Enable atomic-compatible PaperTrail versions on meaningful mutable state with actor/action metadata and heartbeat/HTML exclusions; verify versions reflect actual mutations and contain no noisy refreshes or full document copies remotely.
- [x] 3.2 Add versioned AshEvents recording and one compatible task timeline projection in each mutation transaction; verify an induced audit insert failure rolls back state and timeline remotely.
- [ ] 3.3 Implement aggregate-scoped advisory keys, ordered multi-record locking and no shared actor-row write lock; verify an intentionally held unrelated task/PR lock does not block independent mutations or reads remotely.
- [ ] 3.4 Expose bounded escaped version/event reads without public replay; verify legacy/new history attribution and absence of secrets/HTML in read payloads remotely, and document the audit cutoff and concurrency rules.

## 4. Durable PR inventory and worker runtime

- [x] 4.1 Implement canonical monitored PR/task links and submitting-agent attribution; verify paginated discovery includes terminal tasks and deduplicates multiple links to one PR remotely.
- [ ] 4.2 Supervise Oban/AshOban with stable module names, due-record scheduler, immediate link scheduling and queue budgets; verify restart recovery and schedule reconciliation remotely, and document per-pod concurrency/poll defaults.
- [ ] 4.3 Implement reservation/fetch/commit orchestration with provider I/O outside transactions and generation comparison; verify timeout/crash recovery, overlapping polls and out-of-order replies remotely.
- [ ] 4.4 Add immutable CI snapshots/check attempts/evidence and current projection with idempotent identity; verify duplicate job delivery produces no duplicate snapshots or obligations remotely.

## 5. GitHub CI observations

- [ ] 5.1 Implement bounded PR metadata/check-run/status/required-policy reads with all-page completion and current head/base/test-ref association; verify pagination, merge-ref checks and revision changes during collection against controlled HTTP fixtures remotely.
- [ ] 5.2 Implement latest-attempt normalization and explicit repository policies; verify failures, pending, missing checks, unknown policies, accepted skipped/neutral outcomes and superseded retries remotely.
- [ ] 5.3 Implement provider health/backoff, conditional requests where supported, 401/403/429/reset handling and read-only failed Actions job details; verify no fake passing on partial/error responses and no busy retry loops remotely.
- [ ] 5.4 Document repository credential scopes and expected-check configuration, including AgentboardAcceptance correlation/publication; verify the documented policy matches actual provider metadata during read-only rollout checks.

## 6. BuildBuddy failure diagnostics

- [ ] 6.1 Implement configured GetInvocation/GetLog clients with pagination and repo/revision/CI-role/completion correlation; verify matching and rejected unrelated/manual invocations remotely using controlled API fixtures.
- [ ] 6.2 Store bounded normalized/redacted excerpts, source links, truncation and unavailable reasons; verify GitHub failure remains failing after BuildBuddy permission denial, oversized responses and missing invocations remotely.
- [ ] 6.3 Enforce destination/TLS/redirect and request/response limits for GitHub/BuildBuddy evidence fetches; verify hostile URLs never receive provider credentials and cross-origin downloads do not forward Authorization remotely.
- [ ] 6.4 Add namespace Secret references/configuration with no values and a disabled observation-mode option; server-dry-run rendered manifests, verify actual API entitlement/key scopes out of band and document secret rotation/evidence limits.

## 7. Delivery gate and follow-up accountability

- [ ] 7.1 Implement one active follow-up per PR/failure episode with submitting-agent assignment or captain queue; verify concurrent/repeated failure polls create one task and one notification without modifying terminal source tasks remotely.
- [ ] 7.2 Implement fresh current-revision completion guard and verified-revision delivery metadata; verify failed/pending/unknown/stale completion rejects without changing lease/state, and passing/no-PR completion retains normal lifecycle remotely.
- [ ] 7.3 Implement machine-resolution tracking without silent follow-up task completion, plus explicit handoff/acknowledgement reads; verify passing recovery, recurrent failure and unavailable-owner cases remotely.
- [ ] 7.4 Update canonical/harness/captain skills and API documentation for wait/fix/recheck/block/handoff obligations; verify all adapters inherit the rule and documented commands against the remote-built CLI.

## 8. PR dashboard and CLI visibility

- [ ] 8.1 Add paginated domain-backed `/prs` table, filters, accessible CI labels, responsible agent, freshness and follow-up links; verify boundary fixtures for every state remotely and browser-review desktop/narrow layouts.
- [ ] 8.2 Add PR detail with current/historical attempts, failed-job excerpts, provider/task/document links and evidence-degraded states; verify escaping/truncation and preserved data during provider/database outage remotely.
- [ ] 8.3 Add API v1 PR list/detail/watch and CLI `pr list/show/watch`, retaining 429/cancellation/reconnect contracts; verify actual remote-built binaries against packaged HTTP application remotely.
- [ ] 8.4 Add compact CI notifications and LiveView durable reread/fallback; verify failure-to-passing updates and missed-notification recovery remotely, and document dashboard/CLI inspection commands.
- [ ] 8.5 Refresh Archify source/HTML/receipts, browser/perceptual evidence and portable Lavish proposal; upload/link both from the live claimed board task and PR and verify sandboxed HTML remains readable.

## 9. Integration and staged farm01 rollout

- [ ] 9.1 Run full remote acceptance/release packaging including legacy M1–M3/document behaviors and provider outage/restart/concurrency flows; record actual BuildBuddy invocation results with no local compilation.
- [ ] 9.2 Publish a new immutable image/CLI release and deploy additive migration plus Ash application in observation-only mode; verify healthy CNPG/app/jobs, provider access, complete linked PR inventory, expected checks and BuildBuddy correlations.
- [ ] 9.3 Enable follow-ups/completion guard after observation evidence passes; demonstrate a controlled failing PR row/job/log, one assigned follow-up, rejected early completion, successful retry and passing delivery, retaining exact head/digest evidence.
- [ ] 9.4 Verify live long-lived PR/task/message/quota watches through Gateway, all dashboard routes and sandbox documentation; record rollout/rollback evidence and mark tasks complete only after demonstrated behavior.

## Foundation-stage evidence

The first implementation stage completes Board registration/lifecycle/messages,
board read/watch queries, immutable document and quota ingestion, and attributed
PaperTrail/AshEvents writes. The packaged release/CLI acceptance passed remotely
in [BuildBuddy 6809dbc8](https://carverauto.buildbuddy.io/invocation/6809dbc8-0cc4-4715-9486-9dda39a4a54c),
including audit insert failures, one-winner claims, scoped audit contention,
canonical evidence retries, raw retention, HTML exclusions and sandbox serving.
Schema-6 fresh, repeat, and schema-4 upgrades passed in
[BuildBuddy 5d07772f](https://carverauto.buildbuddy.io/invocation/5d07772f-147e-47f2-a049-9fe5a0164b9a).
The quota latest-observation SQL projection, public audit inspection, Delivery
schema, PR workers/providers/UI/CLI, completion guard and live rollout remain
unchecked. Scoped Task audit isolation is demonstrated; PR lock ordering is not
yet implemented, so 3.3 remains open. Archify documents this stage; it does not
claim CI-monitor delivery. Database-clock expiry, bounded time input, and
nonqueued pool checkout then passed packaged board API and schema acceptance in
[BuildBuddy 4f96f5ff](https://carverauto.buildbuddy.io/invocation/4f96f5ff-8ecf-48aa-a7f2-990e10c76b9c).
That run did not execute the other acceptance targets or a live rollout.


### Durable PR inventory stage

Task 4.1 is implemented with the Ash Delivery domain, atomic task submission
links, per-task first submitting-agent/model/harness evidence, case-canonical
PR deduplication, immutable links retained after handoff/URL changes, and
keyset discovery of current links including terminal and archived tasks.
Legacy introduction events supply attribution; absent provenance and time
remain explicitly unknown. No historical task/timeline rows are rewritten.

The [15-target remote acceptance run](https://carverauto.buildbuddy.io/invocation/806505ce-555b-4bf3-9514-a00e607e7ddd)
passed; the [focused final inventory proof](https://carverauto.buildbuddy.io/invocation/2d534d51-125b-4267-bc34-d2b87c66b16f)
also covers archived-terminal discovery and explicit immutable-trigger errors.
Fresh/repeated/schema-4 upgrade migrations preserve existing IDs, timeline and
HTML bytes. The [Archify diagram](../../../docs/architecture/pr-inventory.html)
has all nine deterministic checks with no warnings, four desktop browser
measurements and separate light/dark perceptual review receipts.

Task 1.3 remains unchecked: this preparatory schema does not supply the complete
Delivery snapshot/policy schema or Ash migration-generator baselines. Tasks
4.2–4.4 and the provider, follow-up, CI dashboard/API/CLI and monitored rollout
remain pending. Discovery is an explicit domain operation until the next
AshOban scheduler stage; inventory existence is not a CI health verdict.

### Inventory catch-up worker stage

The Delivery discovery resource now supplies a stable AshOban scheduled action
with one-minute root sweeps, durable 100-task cursor continuations, independent
per-task transactions, five-attempt retry, a separate one-worker-per-pod queue
and a default-off runtime fence for already-queued jobs. Historical model and
harness strings now retain exact source bytes instead of Ash's trimming default.

This is preparatory work within task 4.2, which remains unchecked: due-PR
observation scheduling, immediate poll enqueueing and the four-worker provider
budget still require the reservation/provider stages. No CI result, follow-up,
completion guard or deployed monitor is implied. The approved change remains
9/37 complete; no outstanding requirement has been removed or waived.
