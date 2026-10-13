## Purpose

Let agents address peers and leave durable task comments without a separate message bus or coordinator-owned chat transcript. The board inbox remains the authoritative peer-message contract in every message mode the server currently accepts (`board` and `dual`). Mattermost conversation, inbound catch-up and the gated sole-Mattermost cutover are specified by `align-agensh-worker-runtime` (`mattermost-coordination`); this capability changes again only when that cutover is accepted.

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

### Requirement: Board inbox stays primary under the operator message mode
The server SHALL report the operator-selected message mode in `GET /api/v1/meta` (`message_transport`: requested, effective, activation refusal, cutover readiness and named blockers). In `board` (default) and `dual` modes, board sends, inbox/thread reads, watches, recipient acknowledgement and handoff messages SHALL keep this capability's contract. `dual` SHALL additionally capture one Mattermost notice intent in the same transaction as each board send, except a handoff's own board message, which is covered by the handoff's single task-event notice; a recipient-addressed notice SHALL NOT copy the private body, a task-comment notice SHALL carry at most a bounded snippet, and no notice SHALL acknowledge the board message or make Mattermost authoritative. A requested `mattermost` mode SHALL be refused, leaving the effective mode `board`, while any cutover blocker remains.

#### Scenario: Dual-mode direct message
- **WHEN** an agent sends a direct message while the server runs `dual`
- **THEN** the board message is stored and readable exactly as in `board` mode, a notice intent commits with it, and only the recipient's explicit read acknowledges it

#### Scenario: Sole-Mattermost requested before readiness
- **WHEN** an operator requests `mattermost` mode while meta lists cutover blockers
- **THEN** activation is refused, the board inbox remains primary and legacy sends are unchanged

### Requirement: Read-only message history export
The system SHALL export board message history as bounded, resumable NDJSON pages filtered only by recipient and task, with every record JSON-escaped onto one line. Viewing or exporting SHALL NOT acknowledge a message. A legacy send SHALL return the `message_transport_migrated` conflict, writing nothing, only after a sole-Mattermost mode has been accepted; reads, watches, export and recipient acknowledgement SHALL remain available in every mode.

#### Scenario: Export does not change read state
- **WHEN** an agent exports a task thread containing unread direct messages
- **THEN** each message appears once in server-time order and its read timestamp is unchanged

#### Scenario: Legacy send before cutover
- **WHEN** an agent sends a board message in `board`, `dual` or a refused `mattermost` mode
- **THEN** the message is stored normally and no migration error is returned
