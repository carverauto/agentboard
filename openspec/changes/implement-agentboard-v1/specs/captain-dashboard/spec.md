## Purpose

Give the human captain a read-only, continuously refreshed view of task ownership, agent activity, communication, and quota evidence.

## ADDED Requirements

### Requirement: Read-only board and timeline
The dashboard SHALL display kanban columns for every task status with ID, title, priority, assignee, repo, and GitHub links. Task detail SHALL show description, ownership, lease information, and the ordered attributed timeline. v1 dashboard interactions SHALL NOT mutate board records.

#### Scenario: Captain inspects a task
- **WHEN** the captain opens a task from the board
- **THEN** its current fields and persisted timeline show actor/model/harness and link targets

### Requirement: Roster and stale ownership visibility
The roster SHALL show stable ID, harness, model, host, reported status, current task, heartbeat age, and capabilities. M2 SHALL distinguish stale agents from expired claims on task cards/details without treating either condition as automatic reassignment.

#### Scenario: Fresh heartbeat with expired claim
- **WHEN** an agent has a recent heartbeat but its task lease has expired
- **THEN** the roster is fresh and the task is flagged expired independently

### Requirement: Message and quota inspection
M2 SHALL expose a message feed with agent/task filters and task-related messages. M3 SHALL expose latest quota evidence per provider/account/window and scope, including freshness, remaining percentage when known, reset time, runway, and advisory spend priority. Unknown data SHALL stay visibly unknown.

#### Scenario: Unknown quota
- **WHEN** a provider reports unknown availability or stale readings
- **THEN** the panel shows that uncertainty instead of implying remaining capacity

### Requirement: Usable failure and empty states
Views SHALL provide readable empty states, bounded/paginated history and feeds, escaped user content, and database-unavailable states. A temporarily unavailable database SHALL NOT be presented as an empty healthy board.

#### Scenario: Database disconnect
- **WHEN** dashboard reads fail because the database is unavailable
- **THEN** the UI identifies unavailable or stale data and recovers on successful reads

