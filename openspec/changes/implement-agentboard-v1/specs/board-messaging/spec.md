## Purpose

Let agents address peers and leave durable task comments without a separate message bus or coordinator-owned chat transcript.

## ADDED Requirements

### Requirement: Durable addressed messages
The system SHALL accept nonempty direct messages to registered agents and comments on existing tasks, with optional task context on a direct message. A message SHALL have at least a recipient or task and SHALL persist sender/model/harness and server time.

#### Scenario: Direct message with task context
- **WHEN** an agent sends a message to a peer about an existing task
- **THEN** it appears in the recipient inbox and the task's related messages with sender provenance

#### Scenario: Invalid destination
- **WHEN** a message has no destination, an unknown recipient/task, or an empty body
- **THEN** it fails without creating a message

### Requirement: Inbox and task-thread reads
CLI reads SHALL default to the caller's direct-message inbox, support unread and task filters, and provide deterministic paginated human/JSON output. Task-thread reads SHALL include comments and task-context messages. Listing SHALL NOT mark messages read.

#### Scenario: Inbox isolation
- **WHEN** an agent lists its unread inbox
- **THEN** the list contains only unread direct messages addressed to that agent, including messages with task context

#### Scenario: Reading a task thread
- **WHEN** an agent requests messages for a task
- **THEN** comments and context-linked direct messages are returned without changing read timestamps

### Requirement: Explicit recipient acknowledgement
Only the addressed recipient SHALL mark a direct message read, recording its first read time and read-action attribution. Repeating acknowledgement SHALL be idempotent. Task comments without a recipient SHALL NOT have a global unread/read state.

#### Scenario: Another agent acknowledges a message
- **WHEN** an agent other than the recipient calls message read
- **THEN** the command fails without changing the message

#### Scenario: Repeated acknowledgement
- **WHEN** the recipient marks an already-read direct message read again
- **THEN** it succeeds without changing the original read timestamp

