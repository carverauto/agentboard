# Spec Delta

## Purpose

A configurable, visible staleness threshold matched to the documented heartbeat cadence makes the roster's Fresh/Stale signal trustworthy: working seats stop showing Stale, and stale-busy rows read as unreliable last reports.

## ADDED Requirements

### Requirement: Configurable server-side threshold

The roster staleness threshold MUST be server configuration (`AGENTBOARD_ROSTER_STALE_AFTER`, default 20 minutes) and MUST apply to the web roster, not just CLI reads. The `/agents` view MUST show the active threshold in the column header.

#### Scenario: Threshold visible

- **WHEN** a viewer opens `/agents`
- **THEN** the liveness column header states the active threshold (e.g. "Liveness (stale after 20m)")

### Requirement: Documented heartbeat cadence

Seats MUST heartbeat at least every 5 minutes while busy (`agentboard agent heartbeat --every 5m` or equivalent cadence effect on the agent's own calls). A seat that keeps the cadence MUST never show Stale while working.

#### Scenario: Working seat stays fresh

- **WHEN** a busy seat heartbeats within the threshold
- **THEN** its liveness reads Fresh, regardless of how long the current task runs

### Requirement: Stale-plus-busy rendering

The roster MUST render a stale identity that still reports busy as "last reported busy (unreliable)" with the last heartbeat age, and MUST NOT treat its task pointer as live ownership; staleness alone MUST never clear ownership server-side.

#### Scenario: Stale busy row

- **WHEN** an identity is stale and still reports busy with a task pointer
- **THEN** the roster renders "last reported busy (unreliable)" with the last heartbeat age, and does not treat the task pointer as live ownership (no server-side ownership clearing from staleness alone)
