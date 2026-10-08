# Tasks

Implementation starts only after captain approval of the portable proposal. All checks execute remotely through ./scripts/bazel; no workstation compilation.

## 1. Approval and durable compatibility
- [ ] 1.1 Record captain approval and coordinator allocation of a free schema version before implementation; verify the decision answer and pending PR140/version union.
- [ ] 1.2 Add only required additive decision kind/identity/expiry fields and preserve legacy rows/history; extend release_schema_test for upgrade from schema20 and a higher existing version, with remote RED/GREEN.
- [ ] 1.3 Implement universal request forms, bounded inputs and normalized task-question retries under the task lock; extend decision_requests_test through public CLI/API for Unicode/whitespace retries, concurrency, changed-payload refusal and retained terminal results, with remote RED/GREEN.
- [ ] 1.4 Add guarded deliberate re-ask generations and stable retry identity; prove one new request/event on concurrent retries and unchanged explicit-gate behavior in the same owner fixture.
- [ ] 1.5 Update API/setup docs for the exact CLI forms, normalization and compatibility errors; execute the documented commands against invented packaged fixtures remotely.

## 2. Derived intake and attributed recovery
- [ ] 2.1 Add the bounded waiting read model with exact scoped count and stable filter-bound mixed-source cursor; extend decision_requests_test for multiple pages, timestamp ties and count consistency, including unavailable reads.
- [ ] 2.2 Derive latest explicit owner captain asks without creating authority; extend the owner fixture for latest-message/update selection, negation/quoted old asks, non-captain progress and terminal suppression, with remote RED/GREEN.
- [ ] 2.3 Implement owner/coordinator promotion with source/revision compare-and-set and provenance; prove stale source/changed owner denial, protected capability enforcement, idempotent retry and no inferred reclaim remotely.
- [ ] 2.4 Document unfiled marker recognition and promotion examples; verify API responses retain escaped verbatim source and promoter/requester distinction.

## 3. Board placement and accessibility
- [ ] 3.1 Move the lane above Kanban and wire the same scoped total into navigation; extend packaged dashboard/LiveView owner checks for DOM order, 32-row count with 20-row page, age/order/links and preserved column paging.
- [ ] 3.2 Collapse answered-awaiting-ack separately and retain honest unavailable state; prove answer/ack/supersede transitions through actual CLI and rendered dashboard remotely.
- [ ] 3.3 Review invented multirow board fixtures in light/dark desktop and narrow views; retain browser geometry, keyboard/link checks and separate inspected screenshots without compiling assets on the workstation.

## 4. CLI capability guard and universal seat protocol
- [ ] 4.1 Add read-only CLI/server capability diagnostics and stderr/JSON compatibility warnings; remote cli_test and packaged decision_requests_test prove current, older and unavailable combinations.
- [ ] 4.2 Make source launch-seat and check preflight the resolved CLI before acquisition/edit authorization; extend seat_isolation_test using executable invented old/current CLI fixtures, no local builds, with RED/GREEN.
- [ ] 4.3 Update every shipped harness overlay and ask-user workflow to file any captain question, notify by decision ID and stop dependent work; verify all nine overlays are included in skills-install packaging and inspect emitted installed documents as their owned distribution contract.
- [ ] 4.4 Update install/setup guidance with SHA256SUMS-verified upgrade hints and truthful manual fallback; remotely execute safe fixture commands and preserve secret-file protections.

## 5. Cleanup and preserved answer delivery
- [ ] 5.1 Add default-off non-gate expiry and terminal bound-PR retirement through the audited lifecycle; prove matching/stale/unrelated PR evidence, TTL and no answer/wake effects remotely in the decision owner.
- [ ] 5.2 Preserve exact answer retry, claim hold through ack and frozen wake uncertainty; rerun existing decision_requests_test plus worker_runtime_test as needed if wake contracts change.
- [ ] 5.3 Document expiry configuration/rollback and ensure superseded promoted sources do not reappear; verify retained audit reasons and default-off behavior through the owner fixture.

## 6. Integrated publication after approval
- [ ] 6.1 Run affected decision, release-schema, CLI, seat-isolation, board/paging and worker siblings remotely; retain actual invocation URLs and disclose any untested boundary.
- [ ] 6.2 Refresh Archify and portable OpenSpec against the final approved implementation, validate and inspect artifacts, upload immutable final-head docs and read back bytes.
- [ ] 6.3 Drive all native no-mistakes phases without --yes, skips, manual push/PR or merge; verify current-head green GitHub CI, link the agent's PR/task/docs and retain native custody through review.
