# PR polling foundation

This implements task 1.1 of [the approved CI-first runtime](../openspec/changes/align-agensh-worker-runtime/tasks.md), not a running CI monitor. The server does not yet fetch GitHub results, create repair obligations, notify sessions or run reminder timers. Those are the immediately following stages. A submission or a poll reservation is never evidence of passing CI.

## State and concurrency

Schema 8 adds `Agentboard.Delivery.PollState` alongside the immutable schema-7 PR inventory. One row per canonical PR stores due time, reservation generation/UUID/expiry, operational errors, and an initially unknown CI projection. New task submissions enroll that row in the same transaction as the task, submission, PaperTrail and AshEvents records. Enrollment failure rolls back the submission. Polling does not acquire an agent-row lock or serialize requests through a GenServer.

`Agentboard.Delivery.reserve_due(limit)` selects at most 100 due rows (default 20), with `FOR UPDATE SKIP LOCKED`. It commits a new attempt UUID, incremented generation and a 120-second reservation before returning canonical PR identity to its eventual provider worker. Clock sampling follows the row lock. No HTTP call or sleep occurs inside the transaction. A held PR row does not stop independent PRs or board writes.

`Agentboard.Delivery.defer_poll(id, attempt_id, generation, delay_seconds, reason)` releases only the still-live matching reservation, records a declared operational failure (`unavailable`, `rate_limited`, `unauthorized`, `incomplete`) and schedules a bounded 1-second to 7-day delay. A second completion, expired result or older generation is rejected. Delay survives process restart because PostgreSQL owns it. Operational reserve/defer updates produce neither PaperTrail versions nor AshEvents noise; meaningful enrollment does. Neither action can set a green verdict or provider head. These are internal domain operations; there is no new public CLI/API command yet.

## Cutoff, enablement and rollback

Migrate and serve the same immutable schema-8 image. Existing canonical PRs get one due, unknown state at the migration's PostgreSQL transaction timestamp. Their task, event, document, PR, task-link and audit rows remain unchanged; migration does not invent historical provider observations or replay enrollment audits. Repeating migration is harmless. Existing archives and terminal tasks do not erase canonical PRs.

`AGENTBOARD_PR_OBSERVATION_ENABLED` defaults to false, independently of inventory catch-up's `AGENTBOARD_PR_DISCOVERY_ENABLED`. Disabled reservation calls return no work; disabled result calls reject without consuming state. Enabling the flag in this stage installs no scheduler or provider client and cannot deliver alerts. Keep it off in deployment until the later observation/delivery acceptance gate. The proposed 60-second provider cadence is not implemented by a reservation API.

Rollback deploys an older compatible image and retains the additive schema and evidence. A schema-7 writer does not enroll PollState, so the subsequent scheduler must reconcile missing rows from **all canonical inventory**, including PRs whose task URLs were later cleared, before observation is re-enabled. Inventory catch-up of current task links alone is insufficient. Pending reservations remain durable; an expired reservation can be replaced with a new generation, without changing the independent two-hour task lease or allowing automatic task takeover.

## Evidence

The packaged-release/TLS PostgreSQL fixtures test two callers reserving the same PR, a held-row skip with an unrelated board write, expired/replaced results, persisted one-hour provider backoff, default-off/runtime fencing and unknown CI without provider evidence. The schema fixture tests fresh/repeated migration plus schema-4 and schema-7 upgrades, preserving source history and immutable HTML bytes. All execution is through BuildBuddy remote configuration, including the real Ash actions and database constraints; fixtures are invented.

See [the foundation diagram](architecture/pr-polling-foundation.html) for this implemented boundary and [the approved whole-runtime diagram](architecture/agensh-worker-runtime.html) for later delivery, Herdr/native adapters and Mattermost work. The original proposal's exported HTML is its approved planning snapshot; current implementation progress is the Markdown checklist.

The quality-delta scan flags overlap between the new enrollment-version DDL
and the earlier immutable inventory migration. The tables independently own
forward-only schema/audit contracts; the historical migration is preserved
rather than refactored into a changing runtime helper. The remote migration
and behavioral acceptance above validate both boundaries.
