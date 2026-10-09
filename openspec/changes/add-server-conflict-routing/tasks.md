# Tasks

This checklist is implementation work after proposal review. No runtime task is completed by drafting this change. Every Bazel command uses `./scripts/bazel` or explicit `--config=remote`; no workstation compilation.

## 1. Durable contracts and migration

- [x] 1.1 Reconcile #170 shared eligibility and #156/#150 wake/custody envelopes; apply captain decision aca78ca8's existing Event/Delivery worker versus canonical Message inbox amendment with #122's sole selector. Per coordinator1837, implement against the shipped main #156/#122 contracts; both actual consumers share the globally sorted currentness prefix and unchanged portable closed reference. Verify worker frozen reserve/dispatch, canonical inbox adoption, exact prior bytes and the two-PR prefix race without activating host delivery. Native publication custody remains separately assigned and unsupported.
- [x] 1.2 Recheck the schema reservation against current main and add schema32 migration `20261008003200` with binding, current-order/history and publication-grant Ash resources, constraints, AshEvents and mutable AshPaperTrail; verify remote migration from the actual preceding schema preserves old follow-ups and is idempotent.
- [ ] 1.3 Implement order/binding/grant public serialization and auth policies; verify remote API tests reject cross-owner, expired-claim, ambiguous binding and wrong-repository writes and never serialize credentials; document response and permission contracts alongside this group.

## 2. Publication admission and link recovery

- [ ] 2.1 Add durable bind/admit/complete API actions and Go API client commands, preserving task-link metadata semantics; verify remote public API tests for live binding, publication nonce replay, conflicting tracked PR admission refusal and same-card immutable submission attribution.
- [x] 2.2 Extend the exact-ref native pre-push path with fresh actual-default fetch, ancestry and merge-tree evidence, behind warning and conflict/unknown refusal; verify executable remote hook tests using disposable Git repositories for current, behind-clean, conflicting, shallow, failed-fetch, unrelated ref and multi-ref cases; update publication docs with the observed commands.
- [ ] 2.3 Integrate a supported native PR-open/update adapter that verifies admission and records the returned URL; verify remote end-to-end controlled publication refuses an unbound PR before open and repairs a crash after open before acknowledgment. Do not claim pre-push alone gates PR creation.
- [ ] 2.4 Add budgeted, paginated registered-branch/open-PR reconciliation and unlinked findings; verify remote API/provider-fixture tests for unique auto-link, shared-login ambiguity, multiple cards, existing different URL and retry idempotency; document attribution limits.

## 3. Current-base conflict orders

- [ ] 3.1 Extend current `BaseMonitor` enrollment/invalidation and PR open/link scheduling without a second poller; verify remote provider-fixture tests for N linked PRs, unlinked/default-branch advance, absent webhook, multiple repos, page restart and stale response fencing; preserve main-failure repair tests.
- [ ] 3.2 Extend `Rebase` with current-tip order identity/version, retained earliest deadline and supersession, using existing repair cards and transactional selected Event/Delivery or Message capture; verify repeated poll/webhook produces one live order, a new tip supersedes, another dirty head does not stack repairs, both source paths fence frozen stale orders, and fallback/bootstrap interleavings retain exactly one effect; document exact ledger identities.
- [ ] 3.3 Implement changed-head/current-base resolution, unchanged-head conflict clearance and closure cancellation; verify remote races between newer base admission, clean old responses and owner completion, including preservation of rebaser credit and cancellation of obsolete grants/wakes.

## 4. Deadline routing and native custody

- [x] 4.1 Implement one shared eligibility evaluator and candidate admission with #170, including policy/liveness/decision/retirement/repository/queue checks and deterministic ties; verify remote concurrent selections cannot oversubscribe or steal source leases; document the shared queue count and threshold.
- [x] 4.2 Add AshOban deadline and state-change reevaluation plus repair-only audited handoff/reclaim and captain-lane no-seat escalation; verify owner stale, captain-held, out-of-service, busy-at-deadline, owner-resolves-first and duplicate deadline delivery cases through public APIs and retained events.
- [ ] 4.3 Implement the explicit host/native custody handoff and receipt verification before reassigned writes, preserving all native fixes and original run identity; verify an isolated executable adapter fixture for active publisher, terminal preserved head, divergent/unavailable custody, missing capability and replay. Unsupported custody must visibly escalate with no foreign process/ref mutation.
- [ ] 4.4 Add action-scoped repair grants and native same-PR publication using exact remote-head CAS; verify remote two-writer races refuse the loser, invalidate old grants, never create a second PR and keep original authorship/task ownership. Document how the real repair seat gets a fresh Treehouse lease and drives No-mistakes without --yes.

## 5. Audit, dashboard and activation

- [ ] 5.1 Implement disabled/dry-run/apply routing policy and ledger projections; verify remote dry-run changes only audit evidence, and disabling revokes pending grants without erasing history or stopping ordinary observation; document policy/rollback controls.
- [ ] 5.2 Extend existing task/PR views with order deadline, repair owner, rebaser, admission and escalation evidence using Tailwind v4 tokens; verify remote LiveView contracts, then explicitly exercise keyboard/narrow-screen behavior in the deployed product or record it UNTESTED-live.
- [ ] 5.3 Run the combined remote delivery/publication/availability/decision suite with no coordinator process and restart/concurrency/provider-limit fixtures; verify typed contracts and actual consumer behavior rather than source-string tests.
- [ ] 5.4 Refresh Archify and portable OpenSpec HTML, validate/browse them, upload both with `agentboard doc push`, and verify task viewer/download SHA receipts; publish through native No-mistakes without --yes, immediately link the PR and track current-head CI to green without merging.
- [ ] 5.5 After captain deployment authorization, prove dry-run parity on retained farm01 cases and installed-adapter custody capability before staged enablement; record exact flag/ledger evidence and leave the coordinator stopgap in place until explicit cutover. Recheck schema32 before migration and preserve rollback data.
