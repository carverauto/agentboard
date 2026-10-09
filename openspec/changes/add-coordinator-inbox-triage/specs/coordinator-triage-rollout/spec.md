# Coordinator triage rollout

## ADDED Requirements

### Requirement: Default-off staged rollout
Triage SHALL default off per board, preserve legacy behavior when off, and offer a non-effecting shadow stage before approved active routing. Existing cooperation/wake flags SHALL remain independent. Shipping the local classification/audit/visibility slice SHALL NOT imply signed transport, typed currentness, native delivery or production readiness.

#### Scenario: Default configuration and shadow
- WHEN no triage activation is configured
- THEN current inbox, wake and read behavior remains unchanged and no coordinator event is emitted.
- WHEN shadow is selected
- THEN candidate classification/disposition is recorded without dispatch, forwarding, reservation, suppression, acknowledgment or task mutation.

#### Scenario: Implementation complete but transport incomplete
- GIVEN local metadata, audit and visibility tests pass but #153 or a required native/currentness contract is unavailable
- WHEN readiness is reported
- THEN the independent slice may be reported implemented while those exact dependencies remain blocked and the inbox sweep remains in place.

#### Scenario: Shadow-to-active transition and historical backlog
- GIVEN shadow or off records already exist before an active configuration revision
- WHEN active mode is enabled
- THEN only newly admitted active sources are eligible by default; historical records cannot be silently replayed by reconciliation.
- WHEN a bounded exact-ID historical cohort is separately approved
- THEN each source retains its original classification/logical key and records activation provenance only after existing accepted/uncertain overlap has been reconciled.

#### Scenario: Pause races with enqueue
- GIVEN a source transaction read an older active mode/coordinator revision
- WHEN that configuration is paused or rotated before enqueue
- THEN current admission is revalidated and stale state cannot authorize a new destination/effect; retained sources remain visible for reconciliation.

### Requirement: Failures and unresolved work remain inspectable
The system SHALL expose pending, blocked, superseded, retrying and dead-letter states separately from routed/recorded and handled. Raw unread messages SHALL remain accessible. Pagination and filtered reads SHALL account for all applicable records rather than hide unresolved work behind a successful subset. Read/watch requests SHALL have no acknowledgment effect.

#### Scenario: Unsupported legacy route in a large backlog
- GIVEN an old ambiguous message or missing owner remains unresolved behind many recent routed messages
- WHEN the coordinator reads unresolved work with pagination
- THEN the old item and its precise reason remain discoverable with exact source reference, without an inferred success or auto-ack.

#### Scenario: Failed webhook masked by routed status
- GIVEN an escalation outbox event is queued but delivery fails or becomes a dead letter
- WHEN its triage projection is read
- THEN queued linkage is shown separately from failed delivery and unresolved handling; it cannot count as successfully handled.

### Requirement: Live equivalence precedes sweep retirement
The exact farm01 inbox-sweep routine SHALL remain enabled until a separately approved live comparison demonstrates equivalent coverage on the exact deployed commit/config and a captain explicitly approves retirement. The evidence SHALL account for every coordinator source in a representative documented interval, all six classes, legacy/taskless cases, source/route failures, retry/restart/rotation/dead-letter recovery and accepted/uncertain overlap. Empty or mocked-only coverage SHALL NOT pass. Routine webhook count SHALL be zero and logical escalation loss/duplication SHALL be zero.

#### Scenario: Quiet interval
- GIVEN no judgment messages or required failure cases occurred during an observation interval
- WHEN a retirement review is requested
- THEN absence of traffic is not proof; the packet requires representative approved live test evidence for missing cases.

#### Scenario: Unsupported or ambiguous messages remain
- GIVEN live comparison finds missing owners, unsupported native/currentness paths or unresolved legacy messages
- WHEN retirement is evaluated
- THEN the gate fails unless each case is cleared or has an explicitly approved visible manual workflow that preserves coverage.

#### Scenario: Proposal or implementation approval only
- GIVEN the captain approved the proposal or local implementation
- WHEN the work reaches a deployable artifact
- THEN no endpoint/key setup, service/schedule change, production enablement or inbox-sweep pause is authorized by that approval alone.

#### Scenario: Cutover with pending effects
- GIVEN an old coordinator wake or consumer invocation is pending, accepted or uncertain
- WHEN the new path is considered for cutover
- THEN retained identities are reconciled and a single owner is established before a duplicate path can be enabled.

### Requirement: Reversible operational cutover preserves evidence
An approved rollback SHALL pause new shared-transport dispatch, preserve source/triage/outbox/audit/consumer records, reconcile accepted/uncertain effects and restore the elected prior sweep path only through the approved operational plan. Rollback SHALL NOT delete backlog, change logical IDs or blindly replay accepted work. Correctness regressions SHALL reopen retirement review.

#### Scenario: Delivery outage after retirement
- GIVEN the signed transport stops delivering after an approved cutover
- WHEN the authorized rollback plan is applied
- THEN new dispatch pauses, pending/dead-letter visibility survives, and the prior sweep resumes only after retained accepted/uncertain effects are reconciled to prevent duplicates.
