## ADDED Requirements

### Requirement: Durable availability with deterministic overrides
The system SHALL persist audited active, reserved or out_of_service policies for an exact agent or harness/model selector. Exact-agent policy SHALL override harness/model defaults; no matching policy SHALL mean active. Registration and heartbeat SHALL preserve policy.

#### Scenario: Agent override wins
- **WHEN** a harness is reserved and one agent in that harness has an explicit active policy
- **THEN** that agent is active and its peers remain reserved

#### Scenario: Model pattern default
- **WHEN** an out_of_service policy matches a model through a trailing wildcard
- **THEN** matching agents resolve out_of_service unless a higher-priority selector applies

### Requirement: Verified policy and named-assignment authority
The system SHALL require a verified captain capability, including delegated coordinator use, to change policy or grant a reserved named assignment. Attribution headers SHALL NOT confer that authority. Changes SHALL retain author/model/harness and action audit history.

#### Scenario: Self-authored reserved assignment is refused
- **WHEN** an attributed caller without the captain capability assigns a task to a reserved agent
- **THEN** the assignment is refused without task/history mutation

#### Scenario: Captain assigns named work
- **WHEN** a verified captain assigns a task to a reserved agent by exact ID
- **THEN** the system records its authorization grant and the named agent may claim that task

### Requirement: New-work admission honors effective state
Central task API operations SHALL reject reserved open/reclaim claims and out_of_service claim/assignment/handoff. CLI and MCP integrations using the task API SHALL observe the same guard. Autonomous reservation and routing SHALL exclude non-active agents. Existing claim progress, renewal and receipt/recovery SHALL remain available.

#### Scenario: Reserved agent self-claims open work
- **WHEN** a reserved agent claims an open task
- **THEN** the server returns a conflict and retains the open task

#### Scenario: Unavailable agent receives named work
- **WHEN** any caller assigns a task to an out_of_service agent
- **THEN** the server refuses the assignment until an audited activation occurs

#### Scenario: Existing work survives restriction
- **WHEN** a live owner becomes out_of_service
- **THEN** its existing task remains owned and can be renewed or explicitly progressed

### Requirement: Expiry restores active without manual intervention
An optional out_of_service until SHALL use database time, restore active at expiry and record an attributed expiry action exactly once. Expiry SHALL retain an explicit active policy and SHALL NOT revoke or abandon existing claims.

#### Scenario: Expired temporary policy
- **WHEN** the database clock reaches a temporary out_of_service deadline
- **THEN** new admission resolves active and the bounded expiry sweep or roster read retains one active-restoration audit

### Requirement: Availability is visible and routing is explicit
Agent list/show JSON and Agents UI SHALL show effective state, source, reason and optional until. Roster eligibility filtering SHALL precede keyset pagination. Explicit task-order broadcasts SHALL exclude reserved and out_of_service agents; ordinary messages SHALL remain available.

#### Scenario: Eligible paginated roster
- **WHEN** a coordinator requests active availability with a page limit
- **THEN** every returned row is eligible and subsequent filter-bound pages omit no eligible agent

#### Scenario: Task-order fanout
- **WHEN** a verified captain sends an explicit task-order broadcast
- **THEN** only active recipients receive its durable messages while restricted agents can still receive ordinary coordination notes
