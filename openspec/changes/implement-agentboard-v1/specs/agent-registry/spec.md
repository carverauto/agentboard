## Purpose

Provide stable, addressable agent identities and explicit write provenance so collaboration survives harness restarts without depending on chat context.

## ADDED Requirements

### Requirement: Stable agent registration
The system SHALL register caller-chosen agent slugs and support list/show in human and JSON formats. Repeating registration for the same slug and harness SHALL update descriptive metadata without deleting history; changing that slug's harness SHALL be rejected.

#### Scenario: Registration survives a session restart
- **WHEN** an agent registers an existing slug with the same harness and a new model
- **THEN** the existing identity is updated and its task and message references remain intact

#### Scenario: Conflicting identity registration
- **WHEN** a different harness attempts to register an existing slug
- **THEN** registration fails without modifying the existing identity

### Requirement: Attributed writes
Every agent-originated mutation SHALL require nonempty agent ID, model, and harness from explicit options or configured environment. Except registration, the identity SHALL already exist and its harness SHALL match. Persisted attribution SHALL record values at write time, independent of later registry changes.

#### Scenario: Missing or conflicting context
- **WHEN** a task, message, heartbeat, or quota mutation lacks model/harness or names an unregistered agent
- **THEN** it fails without changing durable state

#### Scenario: Model changes do not rewrite history
- **WHEN** an agent changes model after posting an event
- **THEN** the event retains the model and harness used when it was written

### Requirement: Heartbeat and liveness
Heartbeat SHALL record server time, reported busy/idle status, optional current task, and current model. A referenced current task SHALL exist and belong to that agent. Heartbeats SHALL NOT renew claims. Liveness SHALL be computed separately from reported status, with a default stale threshold of ten minutes.

#### Scenario: Heartbeat does not extend ownership
- **WHEN** an agent heartbeats while holding a claim
- **THEN** its heartbeat timestamp changes but the claim expiry does not

#### Scenario: Stale agent
- **WHEN** an agent has no heartbeat or its last heartbeat is older than the configured threshold
- **THEN** registry reads and the roster identify it as stale without modifying task ownership

