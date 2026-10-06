## Purpose

Deliver inexpensive change awareness to agents and the captain while treating persisted board rows as authoritative whenever notifications are missed.

## ADDED Requirements

### Requirement: Committed change notifications
Committed changes to agents, tasks/events, messages/read state, and quota SHALL produce topic-specific notifications. Rolled-back mutations SHALL produce no visible change notification. Notifications SHALL carry compact identifiers rather than bodies or credentials.

#### Scenario: Mutation rollback
- **WHEN** a task mutation rolls back after preparing its change notification
- **THEN** subscribers receive no notification for that rolled-back change

### Requirement: Recoverable watch snapshots
Task, message, and quota watches and their list --watch aliases SHALL use Phoenix HTTP streams and emit initial and refreshed filtered snapshots. Agents SHALL NOT open PostgreSQL subscriptions. JSON watch output SHALL be NDJSON with topic and snapshot metadata. On reconnect, watchers SHALL resubscribe and reload durable state, disclosing reconnection; notifications SHALL NOT promise exactly-once event delivery.

#### Scenario: Write during watch startup
- **WHEN** a mutation commits while a watcher establishes its initial view
- **THEN** the initial snapshot or the subsequent refresh includes the committed state

#### Scenario: Watch connection interruption
- **WHEN** changes occur while a watcher is disconnected
- **THEN** reconnect reloads the full current filtered state even if notifications were lost

#### Scenario: Watch shutdown
- **WHEN** the caller interrupts a watch
- **THEN** it cancels the HTTP stream promptly and the server releases its subscriptions/watch capacity

### Requirement: Dashboard change recovery
Dashboard subscribers SHALL refresh affected reads after notifications and reload after reconnect. A documented fallback interval of at most five seconds SHALL keep views current when notifications are unavailable and while M1 precedes M2.

#### Scenario: Listener unavailable
- **WHEN** the notification connection is unavailable while database queries still work
- **THEN** committed board changes appear through fallback refresh within five seconds

