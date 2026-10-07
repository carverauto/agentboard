# PR polling foundation

This documents tasks 1.1–1.2 of [the approved CI-first runtime](../openspec/changes/align-agensh-worker-runtime/tasks.md). Task 1.3 adds the [current-head GitHub collector](github-ci-observation.md). A live CI repair loop, repair obligations, session delivery and reminders remain pending. A submission or a poll reservation is never evidence of passing CI.

## State and concurrency

Schema 8 adds `Agentboard.Delivery.PollState` alongside the immutable schema-7 PR inventory. One row per canonical PR stores due time, reservation generation/UUID/expiry, operational errors, and an initially unknown CI projection. New task submissions enroll that row in the same transaction as the task, submission, PaperTrail and AshEvents records. Enrollment failure rolls back the submission. Polling does not acquire an agent-row lock or serialize requests through a GenServer.

`Agentboard.Delivery.reserve_due(limit)` selects at most 100 due rows (default 20), with `FOR UPDATE SKIP LOCKED`. It commits a new attempt UUID, incremented generation and a 120-second reservation before returning canonical PR identity to its eventual provider worker. Clock sampling follows the row lock. No HTTP call or sleep occurs inside the transaction. A held PR row does not stop independent PRs or board writes.

`Agentboard.Delivery.defer_poll(id, attempt_id, generation, delay_seconds, reason)` releases only the still-live matching reservation, records a declared operational failure (`unavailable`, `rate_limited`, `unauthorized`, `incomplete`) and schedules a bounded 1-second to 7-day delay. A second completion, expired result or older generation is rejected. Delay survives process restart because PostgreSQL owns it. Operational reserve/defer updates produce neither PaperTrail versions nor AshEvents noise; meaningful enrollment does. Neither action can set a green verdict or provider head. These are internal domain operations; there is no new public CLI/API command yet.

## Cutoff, enablement and rollback

Migrate and serve the same immutable schema-10 image. Schema 10 adds retained CI snapshots/current head/base pointers and provider cooldown without fabricating old observations. Schema 8 introduced PollState and enrolled each then-existing canonical PR as one due, unknown row at that migration's PostgreSQL transaction timestamp. Schema 9 adds shared operational provider budgets and preserves those PollState rows, including backoff; it does not reset due times or invent observations. Task, event, document, PR, task-link and audit rows remain unchanged across both migrations. Neither migration invents historical provider observations or replays enrollment audits. Repeating migration is harmless. Existing archives and terminal tasks do not erase canonical PRs.

`AGENTBOARD_PR_OBSERVATION_ENABLED` defaults to false, independently of inventory catch-up's `AGENTBOARD_PR_DISCOVERY_ENABLED`. Disabled reservation calls return no work; disabled result calls reject without consuming state. When enabled at boot, it installs the AshOban minute scheduler and per-PR polling queue. The collector now runs behind this flag but cannot deliver alerts or certify passing CI without policy. Keep it off in deployment until the first-release live proof. Missing credentials defer `unauthorized`; unavailable/incomplete collection preserves prior evidence.

Rollback deploys an older compatible image and retains the additive schema and evidence. A schema-7 writer does not enroll PollState, so the scheduler reconciles missing rows from **all canonical inventory**, including PRs whose task URLs were later cleared, before observation is re-enabled. Inventory catch-up of current task links alone is insufficient. Pending reservations remain durable; an expired reservation can be replaced with a new generation, without changing the independent two-hour task lease or allowing automatic task takeover.

## Scheduling and pacing

The generic Ash resource `Delivery.Observation` owns the minute `schedule_due` action. The independent `delivery_scheduler` queue has concurrency one; `delivery_polling` has four per-PR jobs per node. Inventory discovery retains its separate queue and flag. These are per-node concurrency limits, not global provider limits. PostgreSQL reservations fence concurrent replicas; no network operation holds a PR or budget transaction open.

An enabled canonical PR submission inserts its unique per-PR Oban job in the same transaction as enrollment. Insert failure rolls back the task/submission/enrollment. Each minute tick first enrolls at most 100 missing states from all canonical PR inventory, then enqueues at most 100 due, enabled, unreserved PRs without an active polling job. Excluding active jobs before the limit prevents a queued early batch from starving later PRs. No task-status, archive, current-task pointer, or prior-green filter ends scheduling. Canonical inventory remains authoritative after URLs are cleared and across rollback/restart. Oban job uniqueness reduces duplicate dispatch; the generation-fenced reservation owns correctness.

Each polling job reserves its exact PR, then every actual GitHub HTTP request obtains an admission token after the reservation commits. Shared PostgreSQL windows admit up to 60 GitHub requests and 30 BuildBuddy admissions per 60 seconds across replicas; BuildBuddy collection remains pending. Provider Retry-After/reset establishes an independent durable shared cooldown. See [collector bounds](github-ci-observation.md#bounds-and-provider-isolation). Exhaustion persists a PR defer and failures preserve earlier evidence. Supported defer bounds remain 1 second–7 days, with 120-second attempt expiry; scheduler latency, backlog, collection and budgets prevent a fixed observation SLA.

Disabled at boot removes observation cron entries and pauses both observation queues. Already queued workers independently check the flag and snooze 60 seconds without mutating PR state or budgets. Changing environment flags requires a release restart; an internal test toggle does not add cron entries or resume queues. Roll back by disabling observation and deploying the compatible older image while retaining schema 10, jobs, snapshots, evidence and budgets. The board and unrelated housekeeping remain available.

## Evidence

The packaged-release/TLS PostgreSQL fixtures test two callers reserving the same PR, a held-row skip with an unrelated board write, expired/replaced results, persisted one-hour provider backoff, default-off/runtime fencing and unknown CI without provider evidence. The schema fixture tests fresh/repeated migration plus schema-4 and schema-7 upgrades, schema-8 unknown enrollment, and schema-9 retention of poll backoff, preserving source history and immutable HTML bytes. All execution is through BuildBuddy remote configuration, including the real Ash actions and database constraints; fixtures are invented.

See [the foundation diagram](architecture/pr-polling-foundation.html) for this implemented boundary and [the approved whole-runtime diagram](architecture/agensh-worker-runtime.html) for later delivery, Herdr/native adapters and Mattermost work. The original proposal's exported HTML is its approved planning snapshot; current implementation progress is the Markdown checklist.

The quality-delta scan flags overlap between the new enrollment-version DDL
and the earlier immutable inventory migration. The tables independently own
forward-only schema/audit contracts; the historical migration is preserved
rather than refactored into a changing runtime helper. The remote migration
and behavioral acceptance above validate both boundaries.

Scheduling acceptance executes the configured AshOban cron, two bounded recovery pages, actual Oban supervisor restart, immediate job rollback, archived/previously-green repolls, queued disabled jobs and contending independent provider budgets against the packaged release and TLS PostgreSQL. [Full 18-target remote acceptance](https://carverauto.buildbuddy.io/invocation/c39b75ed-fca7-4114-b78c-4992a52d3ed9) passed (11 executed, seven unchanged cached targets). See [scheduling architecture](architecture/pr-observation-scheduling.html).

The quality scan reports shared due predicates between batch reservation, exact-PR reservation and scheduling. Their SQL owns different locking and dispatch semantics; each reuses the existing reservation mutation rather than introducing a generic selector that hides those contracts. Framework callbacks reported as dead code are exercised by the real AshOban/Oban and migration acceptance.

After remote formatting, [full 18-target acceptance](https://carverauto.buildbuddy.io/invocation/eb4b683e-7e3d-42d1-ae45-9412e467059b) passed. Scheduling Archify passed 9/9 showcase checks with zero errors/warnings, four desktop containment measurements, and separate actual light/dark image review; viewer interactions are not covered by that image review.
