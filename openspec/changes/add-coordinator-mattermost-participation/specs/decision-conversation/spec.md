## ADDED Requirements

### Requirement: Canonical board-primary notification
An authenticated canonical requester SHALL create at most one retained board notice
and typed notification intent per decision. Destination and identity SHALL be pinned
to approved configuration and canonical records. Board notice and source intent
SHALL commit atomically before remote I/O; chat failure SHALL leave board access.

#### Scenario: Concurrent notification retry
- WHEN identical requests race or a response is lost
- THEN they retain the same notice/intent and do not create a second mirror.

### Requirement: Exact recipient/source decision correlation
A typed coordinator reply SHALL reference its own exact inbox UUID/SHA-256 and the
same canonical decision as the verified retained notification. The destination,
root, source service, requester and repository SHALL be derived, not caller-chosen.
The current exact source SHALL be verified before a fresh remote send.

#### Scenario: Spoofed or changed source
- WHEN props are forged or the source/decision/repository/version does not match
- THEN no remote reply is submitted and no canonical decision is mutated.

### Requirement: Durable remote uncertainty
The system SHALL persist metadata-only intent and submission admission before a
remote POST. Semantic retry conflicts SHALL be rejected. An uncertain submitted
intent SHALL never become sendable merely because time elapsed or history search
did not find it. Adoption SHALL verify actual bot author, source, thread, marker
and payload hash; several matches SHALL remain explicit duplicate uncertainty.

#### Scenario: Accepted post and lost response
- WHEN Mattermost accepts a post but the acknowledgment is lost
- THEN replay adopts the verified existing post or retains uncertainty without reposting.

### Requirement: Explicit handling is separate from approval
Existing protected exact-version receipts SHALL own handling and retain first
attribution. A read, reply or completed turn SHALL NOT acknowledge a source, apply
a decision answer, change task ownership or supply captain authorization.

#### Scenario: Coordinator reply followed by explicit source handling
- WHEN a verified reply is sent and later the recipient explicitly acknowledges
- THEN the exact source becomes handled while canonical decision/hold state is unchanged.

### Requirement: Safe staged operation
This slice SHALL leave board-primary transport, legacy unread access, monitoring
and sole-Mattermost gates unchanged. Controlled fixtures SHALL NOT stand in for
live native readiness, credential issuance, enrollment or deployment approval.

#### Scenario: Interrupted coordinator catches up
- WHEN it resumes with a current scoped runtime capability
- THEN existing inbox recovery returns unhandled versions and honest gaps without
  inventing historical bodies or automatically consuming legacy board messages.
