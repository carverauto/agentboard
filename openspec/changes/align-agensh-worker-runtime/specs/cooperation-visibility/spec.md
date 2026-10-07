## Purpose

Make the actual cooperation state inspectable without conflating task ownership, source evidence, session liveness, notification handling and PR completion.

## ADDED Requirements

### Requirement: Task-linked Shared context
Task detail SHALL show a read-only Shared context section with at most 20 recent task-linked entries, kind, summary, source and time, plus a task-filtered full Context link. Reads SHALL NOT acknowledge entries. Documentation SHALL describe rendered workspace artifacts separately from findings and timeline events.

#### Scenario: Task has documents and findings
- **WHEN** a user opens that task
- **THEN** documentation links and actual Context entries appear in separate clearly named sections

#### Scenario: Context unavailable
- **WHEN** the Context read fails while the task is available
- **THEN** the task remains readable and its Context section exposes a bounded error state

### Requirement: Worker delivery health
Existing agent/task views SHALL expose bound host/session status, supported capabilities, pending count/oldest age, last received/handled and pause/block/cooldown/uncertainty reasons. They SHALL distinguish agent heartbeat, connector health, adapter readiness and task lease; session transport SHALL NOT become roster authority.

#### Scenario: Agent stale but task claim still live
- **WHEN** an agent heartbeat is stale and its claim is unexpired
- **THEN** the dashboard shows those states separately without implying automatic takeover or live activity

### Requirement: Responsible PR obligations and receipts
When CI monitoring is enabled, PR/follow-up views SHALL identify the recorded responsible agent, current revision/result/freshness, obligation and delivery status. Notification handling SHALL NOT display failing, pending, unknown or stale CI as passing; missing responsible agents SHALL remain explicit captain work.

#### Scenario: Owner moves to another issue
- **WHEN** its submitted PR fails at a monitored revision
- **THEN** the failure remains linked to its responsible agent and repair obligation regardless of the agent's current-task display pointer

#### Scenario: Alert handled but PR still red
- **WHEN** that agent acknowledges a failure alert without a verified passing result
- **THEN** handling status changes while CI remains failing and the repair obligation remains visible

### Requirement: Preserve compact board and source boundaries
Cooperation additions SHALL preserve Kanban and accessible Tailwind v4 layouts with bounded text and responsive containment. They SHALL link canonical Mattermost, Context, PR and HTML sources rather than expand every card into a combined chat/evidence transcript.

#### Scenario: Long identifiers or large backlog
- **WHEN** an agent/task has long source IDs or many pending deliveries
- **THEN** compact summaries remain readable and details are available without overflowing the existing cards
