## Purpose
Deliver responsibility follow-ups durably to enrolled workers or board inboxes while preserving one signal per source event across retries and enrollment.

## ADDED Requirements
### Requirement: Flag-gated recipient routing
The system SHALL route cooperation-enabled CI/conflict signals to a registered responsible agent, repair assignee or configured coordinator. An enabled unpaused worker scoped to the repo SHALL receive the new signal through worker delivery; otherwise the recipient SHALL receive one task-linked inbox message. Missing recipients SHALL be recorded as undeliverable.
#### Scenario: Zero workers
- **WHEN** a linked PR fails with a responsible agent and no subscriptions
- **THEN** one inbox note names that repair task and the failure evidence
#### Scenario: Captain escalation
- **WHEN** a captain digest has no worker recipient
- **THEN** its configured registered coordinator receives it, or absence is retained without broadcasting
#### Scenario: Flag disabled
- **WHEN** cooperation is off
- **THEN** fallback emits no message and legacy conflict notice behavior remains

### Requirement: Atomic immutable receipt
The system SHALL atomically retain event delivery mode, recipient and inbox message identity, deduplicated by source_key across retries and restarts. The receipt SHALL remain immutable. A resolved signal SHALL not be resent.
#### Scenario: Replay and rollback
- **WHEN** capture retries or concurrent collectors report the same signal
- **THEN** only one event/message pair commits; failure rolls both back
#### Scenario: Conflict notice
- **WHEN** cooperation creates a conflict repair for an owned PR
- **THEN** its common fallback emits one notice without a second legacy owner message

### Requirement: Reminder and enrollment continuity
The system SHALL count inbox and worker reminders under the existing generation, freshness, blocker, 4-per-hour cap and 900s/3600s cadence. Hourly digest slots SHALL stay idempotent. Enrollment SHALL send subsequent events only to workers and SHALL not bootstrap an already inbox-delivered source.
#### Scenario: Reminders and escalation
- **WHEN** current failing evidence remains and reminders are due
- **THEN** each eligible generation produces one message until the cap; escalation produces one coordinator digest per hour
#### Scenario: Enrollment after fallback
- **WHEN** the responsible seat enrolls after inbox delivery
- **THEN** bootstrap does not duplicate that source and a subsequent event selects worker delivery

### Requirement: Delivery observability
PR/obligation reads and the dashboard SHALL expose per-event worker, inbox_fallback or undeliverable mode with retained recipient/message/reason evidence, without claiming physical host acceptance.
#### Scenario: Dashboard evidence
- **WHEN** a follow-up is inbox-delivered or cannot be delivered
- **THEN** /prs displays its truthful delivery mode and the obligation read retains the same receipt
