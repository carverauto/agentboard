# Tasks

Captain approved implementation only in decision a4c791db-30e8-4923-8556-b27b6447f1ae. Checked boxes below identify proved server/shadow behavior or an explicitly permitted unsupported path; they do not authorize native delivery or activation. Each chunk targets one focused session (about two hours or less); a missing dependency is reported rather than substituted. All Bazel calls use `./scripts/bazel` / `--config=remote`, and tests follow the installed test-audit skill.

## 1. Contract and authorization prerequisites

- [x] 1.1 Obtain captain approval of proposal/defaults and record exact decision/version; verify decision show reports approval before any product-code edit.
- [x] 1.2 Confirm #150's shared nudge/admission/schedule seam and #123 explicit dependency event identity with their owners; retain durable interface receipts and missing-capability reasons in design. (Owner messages1607/1611/1622/1662 confirm proposed seams and absent producers; this is interface/absence evidence, not readiness.)
- [x] 1.3 Reserve a fresh schema version and confirm no conflicting migration timestamp; verify ledger and fresh-DB migration inventory, keeping recovery31 unchanged.
- [ ] 1.4 Negotiate installed Herdr capabilities in a disposable session without touching production input; document exact safe-input/recipient/CAS/reconcile evidence or mark automatic delivery unsupported.

## 2. Server occurrence ledger and bounded producers

- [x] 2.1 Add audited intent/attempt resources, uniqueness and additive migration; remotely prove concurrent capture, failed-transaction rollback and retained audit history against real Postgres.
- [x] 2.2 Implement unread-DM and decision-answer source adoption; remotely prove an existing DecisionWake is reused and enrollment/fallback/bootstrap does not duplicate handled occurrences.
- [x] 2.3 Implement exact-expiry claim warnings and authorized idle-assignment predicates with DB time; remotely prove renewal, terminal/foreign assignments, availability and scan replay boundaries.
- [x] 2.4 Consume #123 explicit blocker terminal events without inferring notes or auto-resuming claims; remotely prove two-blocker/one-shipped and duplicate terminal-event behavior, or keep this producer unsupported until #123 exists.
- [x] 2.5 Implement bounded pending-state reconciliation independent of high-water IDs; remotely prove lower-ID late commits, pagination restart and source deletion/edit/echo invalidation; document reason hashes and configured bounds.

## 3. Scoped reservation and result API

- [ ] 3.1 Add host/worker-scoped read and reservation actions with fixed total lock order; remotely prove two-daemon CAS, foreign credential, revoked/pause/epoch race and read-not-consume scenarios through packaged HTTP/Postgres.
- [x] 3.2 Freeze source/payload/fence identity and adopt existing cooperation batch receipts; remotely prove accepted-but-unhandled source state, exact ack/idempotency and no duplicate logical answer delivery; document the API and compatibility floor.
- [ ] 3.3 Add transport-result/reconcile actions preserving uncertainty; remotely prove response loss, expiry-without-replay and old-incarnation callbacks cannot consume new work.

## 4. Local daemon and proof-gated Herdr adapter

- [ ] 4.1 Add proposed host run orchestration using existing worker locks/journals and protected token-file references; remotely prove daemon/foreground contention, restart/reconnect, scope refusal and bounded backoff without reading secrets into frames.
- [ ] 4.2 Integrate #150's safe boundary under one elected wake owner; prove actual disposable Herdr rejection for occupied composer, working/blocked/unknown/approval UI and replaced session, or retain explicit unsupported/manual readiness.
- [ ] 4.3 Prove actual accepted native prompt, lost acceptance and exact later reconciliation without duplicate input; capture native evidence distinct from mocked fixture/unit evidence and document per-binding capability limits.
- [x] 4.4 Add dry-run inspection and owned supervision previews without activation; remotely prove no reservation/ack/task mutation and preservation of foreign hooks, credentials and journals; publish setup and rollback docs with generic paths.

## 5. Recovery boundary and operational visibility

- [x] 5.1 Implement only the approved #164 restart transport extension once its real policy/episode producers exist; remotely prove exact incarnation/lease/STOP-brief/pipeline custody refusals and no second spawn while uncertain, otherwise expose blocked-on dependencies without claiming restart ready.
- [ ] 5.2 Expose compact reason/source/disposition and per-binding health/capability summaries; remotely prove reads do not acknowledge, long identifiers remain contained and no host heartbeat fabricates model activity; deliver Archify and portable OpenSpec docs.
- [ ] 5.3 Compare dry-run reason hashes to #150/current nudger on controlled source transitions; record parity gaps and keep the old nudger until captain elects the new wake owner explicitly.

## 6. Integration delivery and captain-held activation

- [x] 6.1 Run affected remote suites and packaged fresh-DB acceptance on the complete integration; record exact commit, BuildBuddy invocation IDs and unsupported/live-untested scenarios.
- [ ] 6.2 Publish through native No-mistakes without --yes, retain custody fixes, link PR/docs and exact-head CI on this task; never merge and preserve all work before coordinated own-lease return.
- [ ] 6.3 Stop for separate captain activation approval before enrollment/secret provisioning, service loading, hook registration, production restart or retiring the current nudger; record the activation decision/checklist independently of implementation approval.

## Current implementation proof boundary

See `docs/verification/wake-intents-shadow-checkpoint.md`. Tasks2.4 and5.1 use their explicit unsupported alternatives. Tasks3.1/3.3/4.1 remain open for the full requested race/loss/native coverage despite passing scoped CAS, real expiry and read-only host contention tests. #169 typed metadata is captured, but its missing currentness resolver stays unsupported/manual. #150 and actual guarded Herdr delivery are unavailable; native tasks and reason-hash parity remain open. No activation approval is implied.
