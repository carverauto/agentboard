# Approved implementation plan — partial preview only

The captain explicitly approved phased implementation on 2026-10-09 after the
proposal merged. Documentation review/merge alone did not grant that approval.
The first product increment delivers a separately scoped busiest-only preview;
none of the broader requirements below is considered fully done by that slice.
See [preview scope](../../../docs/branch-flow.md) and
[verification](../../../docs/verification/branch-flow-overview.md). Captain
pins/settings, role intake, focused topology, row mini-trees and numeric evidence
remain pending. Landing the preview does not close #185.

## 0. Approval and dependency gates

- [x] 0.1 Record explicit captain approval of this three-phase proposal and its bounded, tracked-inventory scope before editing product code.
- [ ] 0.2 Agree the persisted exact-pair numeric divergence contract and ownership with #169; record supported fields, qualification, budget/admission and unavailable fallback. Do not silently add compare calls.
- [ ] 0.3 Approve the scoped #114 integration-workflow intake extension, source/config revision fences, retained-red semantics and separate operational activation boundary.
- [ ] 0.4 Rebase on then-current main, inspect conflicting work, allocate migration identifiers only then, and use the required implementation seat/native publication workflow.

## 1. Shared persisted projection and settings

- [ ] 1.1 Add audited/revisioned pin-order and repository integration-role resources, bounded tracked-repo discovery and provider-derived default-ref metadata without render-time provider calls.
- [ ] 1.2 Extend existing workflow collection/commit to accept only verified default/configured integration refs plus exact unresolved-key resolution-only success; persist accepted role/config revision and retain before/after provider, generation and lease fences.
- [ ] 1.3 Test run/attempt dedupe, delayed failures, branch-isolated recovery, config-change races, previously ignored intake, removed-role red retention, later resolution-only success, cross-run repository-metadata races and cooperation-off behavior; do not change routing semantics.
- [ ] 1.4 Expose matched snapshot head_ref/head_repo/base identity and preserve current CI/merge qualification; add title only by a bounded sanitized field from the existing metadata response, never another request.
- [ ] 1.5 Build batch-bounded BranchFlow read envelopes, inventory aggregates, oldest-red paging, per-section counts/errors/source revisions, filter-bound cursors and explicit unknown/unavailable states.
- [ ] 1.6 Consume #169 numeric divergence if available with exact pair/generation/freshness gates; retain unavailable states and keep numeric acceptance open until supported.
- [ ] 1.7 Add captain Settings chooser, maximum-five ordered pins, unpinned integration editing, audited atomic CAS saves, authority-expiry checks, dirty dismissal and uncertain-save reconciliation.
- [ ] 1.8 Verify query plans/indexes and statement budgets using 1,000-repo/10,000-PR fixtures; record bounded result sizes, no unbounded relation hydration and zero provider I/O/job enqueue for view actions.

## 2. Phase 1 — strip and table filtering

- [ ] 2.1 Replace panel presentation with global Branch attention, ten-run pages and persistent oldest failure; preserve all run/owner/job/source/defer fields and explicit feed/observation limits.
- [ ] 2.2 Add five-card pinned-then-busiest strip with deterministic ties, three-offshoot cap, unknown-lifecycle coverage, accessible overflow chooser and empty/unavailable states.
- [ ] 2.3 Add separate repo-focus and node-filter controls, selected/clear chips, labeled ref/PR-number search and validated route state without changing pins through navigation.
- [ ] 2.4 Preserve the four-column table, twenty-row paging, merged/closed toggle, relevant filters, ownership/repair/delivery/decision/progress and UTC evidence ages.
- [ ] 2.5 Test outside-strip oldest red, more than ten red runs, overflow selection, focused keyboard ranking changes, invalid repo/ref/PR/cursor and independent attention/table paging.

## 3. Phase 2 — focused topology

- [ ] 3.1 Implement one focused repo with explicit role labels, actual base→head relations, fork identity, unknown/deleted/stacked/cyclic cases, text equivalent and no invented DAG/promotion edges.
- [ ] 3.2 Enforce twenty relations, forty-two endpoints and forty connectors per topology page, with stable pagination and off-page continuation labels.
- [ ] 3.3 Add the single non-modal detail panel with full source/time/currentness, separate submitter/CI/rebase responsibility, failure sources and full-detail links.
- [ ] 3.4 Test Enter/Space/open, Escape/Close/outside dismissal, focus fallback, PR-to-PR replacement, repo switch, page switch, removed node and head-change races.

## 4. Phase 3 — row glyph and mini-tree

- [ ] 4.1 Add compact actual base→head glyphs, independent CI/conflict state, qualified ahead/behind or explicit unavailable text without hiding existing row facts.
- [ ] 4.2 Add one disclosure drawer keyed by canonical PR, colspan=4, at most four distinct endpoints, role-vs-observed text, exact evidence/source pair and close/focus behavior.
- [ ] 4.3 Test repeated expansion, switching rows, glyph hiding, filter/page/lifecycle removal, old numeric evidence after force push/base advance and direct-default versus integration PRs.

## 5. Interaction, accessibility and compatibility

- [ ] 5.1 Fence asynchronous reads with section/request generation plus normalized route fingerprint, coalesce refreshes and invalidate transient panel/drawer reads on dismissal and navigation.
- [ ] 5.2 Exercise rapid search, repeated clicks, filter+page changes, Show merged/closed, Back/Forward, full-detail return, disconnection/reconnection, failed refresh and late settings load/save.
- [ ] 5.3 Verify keyboard-only operation, visible focus restoration, names/roles/selected/expanded states, labeled inputs/scroll regions, text alternatives and polite non-spamming announcements.
- [ ] 5.4 Browser-test 320px/768px/1440px, 200% zoom, light/dark, reduced motion, long/Unicode/ref-with-slash inputs, fork collisions and graph-hidden presentation; record actual screenshots and limits.
- [ ] 5.5 Run remote-recommended product suites for Reads/PRLive/Settings/workflow/base/conflict/projection/API compatibility with zero-provider-I/O interaction assertions; report passed/failed/unrun precisely.

## 6. Review and rollout

- [ ] 6.1 Run strict OpenSpec validation with available authorized tooling; complete independent implementation review and address material findings.
- [ ] 6.2 Produce required Archify source/HTML and Lavish portable proposal using their actual tools, validate/render/perceptually inspect and upload/link durable task documents under the repository workflow when available/authorized.
- [ ] 6.3 Roll out the presentation off by default after separate captain authorization, verifying global retained-red parity, query/request budgets and safe switch-back to the original panel/table.
- [ ] 6.4 Separately verify configured integration intake operational readiness/activation without changing observation/cooperation or other schedules implicitly.
- [ ] 6.5 Verify all three phases against acceptance; keep #185 open for any missing numeric producer, accessibility, documentation or runtime evidence. Do not equate a docs PR merge with implementation completion.
