## Purpose

Return durable, authorized workspace responsibilities and source notifications to their responsible workers across context loss, missed notifications and session restarts.

## ADDED Requirements

### Requirement: CI failure follows its responsible agent
Confirmed monitored PR failures SHALL create a durable repair alert for the recorded responsible agent or visible captain queue. Monitoring SHALL continue after that agent changes tasks and after a previously passing check fails again. PR responsibilities SHALL NOT depend on a mutable current-task display pointer or notification receipt.

#### Scenario: Owner forgets PR while working elsewhere
- **WHEN** its registered open PR fails after it starts another authorized issue
- **THEN** a repair alert remains pending for that owner with the failed revision/job links and the dashboard retains the unresolved obligation

#### Scenario: Previously green PR fails again
- **WHEN** a still-open monitored PR starts a new confirmed failure episode
- **THEN** it generates a new durable alert even though the earlier episode's notification was already handled

### Requirement: Failure delivery and overdue escalation
The system SHALL deliver a confirmed failure within two minutes when provider budget, service health and an enabled verified session boundary permit. Otherwise it SHALL expose the delay reason. An unresolved failure without meaningful progress SHALL receive bounded deduplicated reminders and visible captain escalation; acknowledgements alone SHALL NOT disable them.

#### Scenario: Alert acknowledged without investigation
- **WHEN** the owner handles the notification but records no repair progress, blocker or handoff before its reminder becomes due
- **THEN** the still-current failure remains open and a bounded reminder/escalation is generated without duplicating the repair task

#### Scenario: Paused or unavailable session
- **WHEN** the responsible worker cannot receive safely
- **THEN** the pending alert and overdue reason remain visible to the captain without prompting an unrelated agent

### Requirement: Durable source capture and routing
The system SHALL capture a source intent atomically with relevant board changes and route by durable pending state and unique source/recipient identity. Missed notifications, duplicate jobs, restart and a lower-ID late commit SHALL NOT lose or duplicate the logical pending delivery.

#### Scenario: Late commit after a newer source
- **WHEN** a lower-ID source commits after a higher-ID source has already been routed
- **THEN** reconciliation still discovers the lower-ID source and creates its eligible recipient delivery once

#### Scenario: Source intent rollback
- **WHEN** durable source capture fails during a task or Context mutation
- **THEN** the canonical mutation and related source intent both roll back

#### Scenario: Routing interrupted between pages
- **WHEN** a router restarts after completing only part of its pinned audience
- **THEN** it resumes unfinished routing and preserves prior unique recipient deliveries

### Requirement: Explicit enrollment and bounded bootstrap
Workers SHALL enroll with explicit repository/goal scopes. Bootstrap SHALL present current responsibilities, unresolved obligations and bounded relevant Context with continuation links. Subscriptions and received source text SHALL NOT grant task ownership or permission for unrelated work, merge, deployment or lease recovery.

#### Scenario: Restart after conversation compaction
- **WHEN** an enrolled worker resumes without remembering its prior tasks
- **THEN** check-in exposes its durable assigned/owned work and unresolved obligations before it chooses another authorized task

#### Scenario: Unrelated repository event
- **WHEN** an event belongs to a repository outside the worker's enrolled scope
- **THEN** it does not become an actionable delivery to that worker

### Requirement: Immutable bounded dispatch batches
Dispatch SHALL freeze exact event membership, ordered priority, payload hash, binding epoch and attempt identity. Reads SHALL NOT consume events. Batches SHALL expose truncation and leave omitted or subsequently arriving items pending; urgent traffic SHALL NOT indefinitely starve ordinary work.

#### Scenario: Arrival during an active delivery
- **WHEN** new events arrive after a batch freezes
- **THEN** its membership stays unchanged and the new events remain pending for a later batch or supported priority boundary

#### Scenario: Oversized backlog
- **WHEN** the backlog exceeds the configured batch count or byte bound
- **THEN** the frame stays bounded, discloses remaining work and retains omitted events without acknowledgement

### Requirement: Exact received and handled receipts
The system SHALL distinguish submission, receipt and explicit handling. Only authenticated worker-scoped receipts for exact event IDs SHALL record handling, idempotently retaining first attribution/time. Session idle or turn completion SHALL NOT automatically acknowledge events; notification handling SHALL NOT resolve underlying work.

#### Scenario: Prompt submission succeeds
- **WHEN** a terminal transport reports that it wrote the frame
- **THEN** the attempt records submission while its events remain unhandled

#### Scenario: Worker records a blocker
- **WHEN** a worker handles a CI notification by recording a specific blocker and acknowledging that event
- **THEN** the notification is handled but the failing PR and repair obligation remain unresolved

#### Scenario: Repeated acknowledgement
- **WHEN** the same verified worker retries an already-committed receipt
- **THEN** it succeeds without changing the original time/attribution or acknowledging another item

### Requirement: Fenced attempts and uncertain delivery recovery
Only the current binding epoch and dispatch generation SHALL commit transport state. An ambiguous external submission SHALL remain visibly uncertain; timeout, reservation expiry or session idle SHALL NOT alone trigger resubmission. Recovery SHALL reconcile receipts/source state before any provably safe or explicitly approved retry.

#### Scenario: Connector dies after writing the prompt
- **WHEN** a connector restarts without knowing whether its submission was accepted
- **THEN** it retains uncertainty and reconciles evidence rather than blindly submitting the prompt again

#### Scenario: Late old-epoch result
- **WHEN** a replaced connector commits a transport result for its former binding epoch
- **THEN** the system rejects the stale write and preserves the current binding and pending work

### Requirement: Scoped runtime credentials
New enrollment, dispatch and receipt actions SHALL require credentials scoped to authorized workers/repositories. One worker SHALL NOT acknowledge another worker's delivery or rebind its session. Credentials SHALL be revocable and absent from logs, command arguments, public API records and rendered artifacts.

#### Scenario: Foreign-worker receipt
- **WHEN** worker A attempts to acknowledge worker B's event using A's capability
- **THEN** the action fails without consuming B's delivery

#### Scenario: Credential revoked during delivery
- **WHEN** a runtime credential is revoked or its binding epoch changes
- **THEN** new dispatch and stale callbacks fail without silently dropping pending items

### Requirement: Context receipt compatibility
Runtime handling of a Context entry SHALL atomically record the existing per-agent Context receipt. Existing explicit Context acknowledgement SHALL prevent that entry from being reintroduced as new pending runtime work. Recent/search/UI reads SHALL remain non-acknowledging.

#### Scenario: Context handled through a boundary frame
- **WHEN** a worker explicitly handles a Context event through the runtime
- **THEN** both its delivery receipt and corresponding Context receipt commit together or neither commits

### Requirement: Bounded continuation and durable pause
Automatic continuation SHALL be limited to enabled, authorized workers with unresolved responsibilities and a verified safe boundary. Pause, approval block, quota exhaustion and failure cooldown SHALL suppress wakes. Idle/no-findings reminders SHALL be coalesced, bounded and SHALL NOT demand fabricated findings or authorize new unrelated work.

#### Scenario: Paused worker has an urgent backlog
- **WHEN** pending urgent items arrive for a durably paused worker
- **THEN** they remain visible and pending without waking the session through either host or native hook paths

#### Scenario: Empty progress turn
- **WHEN** a worker completes a turn without establishing a new useful finding
- **THEN** it can record that disposition without forced Context publication or a repeating reminder loop

### Requirement: Failures remain observable and independent
Pending/uncertain deliveries SHALL survive restart and SHALL NOT be pruned while unresolved. Provider/session failures SHALL expose retry/catch-up state and respect 429/backoff. A stalled recipient or transport SHALL NOT block unrelated workers or canonical board/context operations.

#### Scenario: One recipient hangs
- **WHEN** one session transport stops responding
- **THEN** another worker can check in and ordinary task/context operations continue without waiting on the hung transport
