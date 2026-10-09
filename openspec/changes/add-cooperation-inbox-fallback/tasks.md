# Tasks

## 1. Durable routing
- [x] 1.1 Reproduce zero-worker inbox loss on unchanged production through remote packaged collector/API test; retain intended RED invocation9d0b98b6.
- [x] 1.2 Atomic fallback capture under source election lock; verified owner/coordinator/missing-recipient and concurrent replay remotely. Schema change WITHDRAWN per coordinator ruling (msg 1646): no migration for #122, single-source keeps existing tables; routing boundaries documented on Runtime.fallback/4.
- ## 2. Continuation and visibility
- [x] 2.1 Reminder freshness/generations/cadence/cap and enrollment sunset preserved; tick/enrollment/replay/resolution cases green remotely (coop_inbox_fallback_test).
- [x] 2.2 Conflict owner notice carries the exact source marker and is adopted (no second DM); /prs follow_up_delivery exposes worker/inbox_fallback/undeliverable (pr_conflicts_test green). Flag-off behavior covered by ci_accountability_test + cooperation_api_test (green).
- [ ] 2.3 Deliver Archify JSON/HTML and portable OpenSpec/guide; verify deterministic, browser and perceptual checks separately and publish immutable final-head viewers.

## 3. Integration
- [ ] 3.1 Run relevant remote acceptance and native No-mistakes through current-head green CI; link PR immediately, retain all pipeline fixes.
- [ ] 3.2 Reconcile ownership/repair notices, hand off final docs/proof to coordinator and return only own Treehouse lease after preservation.
