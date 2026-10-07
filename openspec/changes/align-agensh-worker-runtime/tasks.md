# Tasks

All boxes describe future implementation. Each group lands its own focused acceptance and documentation. Remote-only builds/tests use `./scripts/bazel` (injects `--config=remote`); new acceptance targets belong alongside the packaged API/CLI fixtures in `build/integration/`. Each PR starts from freshly fetched main.

The **first release gate is group 3**, an actual failed PR returning to its responsible running worker. Groups 4–8 must not delay that release. Existing Ash/CI tasks remain authoritative for provider truth, diagnostics and completion gates; completing a subset here does not mark their larger tasks complete without all required evidence.

## 1. Server observes CI after the owner moves on

- [ ] 1.1 Extend `Agentboard.Delivery` with due-PR reservation/generation and additive observation state (existing Ash/CI 1.3, 4.2–4.4); verify fresh/repeat/schema-7 upgrade preservation and two concurrent poll reservations remotely, and document the observation cutoff/default-off switch.
- [ ] 1.2 Add independent bounded AshOban due scheduling and immediate PR-link scheduling (existing 4.2); verify restart, archived/terminal links, previously green open PRs, disabled queued jobs and shared per-provider budgets remotely, and document actual poll/backoff bounds.
- [ ] 1.3 Implement current-head GitHub metadata/check/status pagination and latest-attempt observation (existing 5.1–5.3); verify old-head failure, superseded attempts, equal-time ordering, partial pages, auth failure and 429 remotely with controlled provider fixtures, and retain failed-job source links.
- [ ] 1.4 Add confirmed-failure episode and one canonical responsible-agent repair obligation (existing 7.1, 7.3); verify repeated/concurrent polls, unknown/conflicting attribution, changed current-task pointer, explicit handoff and recurrence remotely, and document notification versus repair resolution.
- [ ] 1.5 Add compact CI/responsible-agent/obligation reads in planned `/prs` and related task links (existing 8.1–8.2 subset); verify failing/pending/unknown/stale/green fixture rendering and desktop/narrow containment, and document evidence limitations without claiming full dashboard delivery.

## 2. Durable CI delivery and one supervised worker

- [ ] 2.1 Add Cooperation event/delivery/batch/attempt/receipt Ash resources and scoped runtime capability actions; verify recipient uniqueness, revoked/foreign credentials, transactional failure-intent rollback and a lower-ID late commit remotely, and document proposed API schemas/error/429 contracts.
- [ ] 2.2 Implement scoped enrollment/bootstrap, pending reads and source-state reconciliation; verify lost notification, all-page recovery, previously handled Context receipt compatibility and unresolved CI after source-task completion remotely, and document the enrollment start policy.
- [ ] 2.3 Implement immutable bounded reservation and epoch/generation-checked submit/reconcile/receipt actions; verify crash-before/after submission, stale writers, exact-id receipts, arrivals mid-batch and no automatic acknowledgement on turn end remotely, and document uncertain-delivery resolution.
- [ ] 2.4 Add `internal/worker` host loop and CLI `worker serve/check-in/ack/bind/doctor/pause/resume` seams through `internal/client`; verify API-only operation, independent blocked workers, cancellation, rate limiting, protected crash journal and restart reconciliation through remote-built binaries and transport fixtures.
- [ ] 2.5 Package launchd/systemd installation/removal with owned configuration and credential references; verify idempotent preview/install/uninstall and preservation of foreign hooks remotely, then inspect rendered operator files without local compilation and document reload requirements.
- [ ] 2.6 Validate installed Herdr session/safe-input capabilities in a named isolated session, then implement explicit socket/binding transport if supported; verify replacement occupant, busy/blocked/unknown/occupied composer, reconnect and uncertain submission. If that contract is unavailable, ship one proven Claude/Pi native boundary path instead; document the actual supported adapter, not an untested universal fallback.
- [ ] 2.7 Add visible connector/binding/pending/received/handled/uncertainty state to existing agent/task views; verify stale heartbeat versus live lease/healthy connector distinctions remotely and in a real browser, and keep Herdr out of roster GC authority.

## 3. First release: red CI reaches the owner and stays accountable

- [ ] 3.1 Add obligation reminder/escalation scheduling with defaults from design D9; verify acknowledgement without progress, progress postponement, blocker, pause, duplicate reminder jobs, four-per-hour bound and new failure episodes remotely, and document the captain escalation path.
- [ ] 3.2 Run a controlled live PR failure after its recorded owner starts another issue; measure detection/eligible-boundary delivery, inspect failed-head/job links, record an exact receipt and show the still-red obligation in the dashboard. Then leave it without progress to prove bounded reminder/escalation.
- [ ] 3.3 Restart the host connector and selected agent session during the same controlled obligation; verify pending recovery, stale-generation rejection, no automatic lease recovery and retained repair responsibility. Repair/rerun CI and verify canonical current-head recovery without silent follow-up task completion.
- [ ] 3.4 Publish remote-built immutable service/CLI assets, enroll the selected worker explicitly and enable observation/delivery only after the proof; verify production service health/pause/rollback and update participation skills with actual check-in/repair/receipt commands. Record unsupported agents separately.
- [ ] 3.5 Deliver this first release's Archify JSON/HTML and portable Lavish proposal with separate deterministic/browser/perceptual evidence; upload from the live claimed task, link the PR and verify the sandboxed viewers. Keep the broader implementation checklist open.

## 4. Outbound Mattermost bridge, independent of CI wake delivery

- [ ] 4.1 Add additive lifecycle outbox/task-thread mappings and transactional board source capture; verify rollback, duplicate jobs, pinned fan-out continuation, late commits and multi-pod contention remotely, and document the independent queue/runtime fence.
- [ ] 4.2 Implement bounded Mattermost posts, thread roots and event-marker reconciliation outside transactions; verify accepted-post/lost-response, unresolved uncertainty, 429, timeout and duplicate-root reporting remotely against controlled HTTP fixtures, and document actual receiver idempotency limits.
- [ ] 4.3 Prepare the existing Mattermost service bot/channels/Secret references and validate member scopes without exposing tokens; run a controlled lifecycle/handoff outage-and-recovery demonstration, verify board/CI delivery remains available, and document rotation/rollback.

## 5. Worker identities and real peer inboxes

- [ ] 5.1 Provision explicit stable-agent/Mattermost-user mappings and worker-scoped secret storage; verify token revocation, renamed handles, membership loss and foreign sender attribution remotely, and document headless enrollment without admin credentials in steady state.
- [ ] 5.2 Add dedicated conversation send/read tools/CLI with protected local outbound spool and source references; verify exact retry keys, uncertain sends, own-send/bridge echo suppression and machine-readable output remotely, and preserve legacy `msg` contracts until cutover.
- [ ] 5.3 Implement per-worker WebSocket plus paginated REST catch-up with persisted coverage/version ledger; verify equal-time posts, edits, concurrent page/live arrival, newly discovered DM channels, outage, retention gap and deleted posts remotely, and expose incomplete coverage explicitly.
- [ ] 5.4 Run two real enrolled workers through headless channel/urgent-DM send/receive/handling and reconnect recovery in `dual` mode; verify the bridge bot alone does not satisfy peer identity parity and document the measured capability matrix.

## 6. Context and native boundary adapters

- [ ] 6.1 Wire scoped Context source intents/priority frames and atomic existing Context receipts; verify receipt rollback, own-entry suppression, task-independent repository findings, bounded/fair backlog and late commits remotely, and document findings versus chat/ownership.
- [ ] 6.2 Add the 20-entry task Shared context section through `Agentboard.Context.recent`, filtered link and independent error handling; verify empty/long/escaped entries, read-without-ack and section failure remotely and in a real browser, keeping documents/timeline separate.
- [ ] 6.3 Add generation-aware Claude hook integration and Pi extension integration, reusing the first-release adapter where applicable; verify session/new/resume/fork, one wake owner, pause, foreign-hook preservation and tool-result preservation in remote conformance plus isolated live harness sessions.
- [ ] 6.4 Add Codex checkpoint/dedicated infrastructure-tool boundary integration and Grok supported completion integration only against installed capability evidence; verify cancellation, compaction, correct-session callback and absence of detached shell watchers, and document App/CLI and headless limitations.
- [ ] 6.5 Validate Muse/AGY and remaining workers through the supported transport; report native boundary unsupported where appropriate, verify explicit receipt/check-in on each installed harness, and publish per-worker readiness instead of claiming blanket parity.
- [ ] 6.6 Add bounded authorized idle/no-findings continuation and cooldown; verify no work/no new finding, paused/blocked/quota-exhausted worker, outage and repeated no-progress turns remotely, and document suppression/escalation rather than forcing publications.

## 7. Staged chat cutover and coherent contracts

- [ ] 7.1 Add default `board`, explicit `dual` and readiness-gated `mattermost` modes with atomic handoff event/outbox behavior; verify offline handoff, recipient explicit claim, disabled jobs and no partial assignment remotely, and document mode prerequisites.
- [ ] 7.2 Add read-only historical board-message archive/export while retaining recipient acknowledgement and migration errors for legacy sends; verify pending legacy messages, pagination, export escaping, rollback and no data loss remotely, then update primary navigation/task thread links.
- [ ] 7.3 Reconcile completed/active `board-messaging`, `agent-workflows` and handoff deltas with the chosen transport before archive/cutover; update README, PRD #1, #37/#41, API and canonical/harness/captain skills. Validate OpenSpec and verify documented commands against the remote-built CLI; preserve all uncompleted Ash/CI tasks.

## 8. Wider integration and final evidence

- [ ] 8.1 Run remote packaged API/CLI acceptance covering legacy board/context/document/watch contracts, additive upgrades, multi-replica routing, shared budgets and independent provider/session failures; record exact BuildBuddy invocations and report any unsupported live adapter as untested.
- [ ] 8.2 Complete the remaining CI provider policy, BuildBuddy diagnostics and completion-guard gates through `adopt-ash-and-monitor-pr-ci`; prove no false green/early completion and available/degraded evidence, without replacing its task checklist with notification success.
- [ ] 8.3 Update architecture and portable proposal artifacts for implemented behavior, upload/link immutable versions and verify live sandbox rendering; record final mode, image/CLI digests, enrollment capability matrix and a tested no-data-loss rollback before marking the whole runtime change complete.
