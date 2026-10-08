## Purpose
Provide an audited, durable captain decision workflow that preserves a waiting seat's ownership, delivers a single answer intent, and makes stalled requests visible without relying on chat parsing.

## ADDED Requirements

### Requirement: Owned idempotent requests
The system SHALL permit only the registered live task owner to open a bounded plaintext decision request, preserving question and findings verbatim. The unique task/gate key MUST return the original request on identical retries and reject changed content. Request creation MUST atomically block the task and add its timeline link.
#### Scenario: Concurrent retry
- **WHEN** the owner submits the same task/gate and content twice
- **THEN** one request and one request timeline event exist
#### Scenario: Unauthorized requester
- **WHEN** another seat submits a request for the claimed task
- **THEN** the mutation is refused and the task remains unchanged

### Requirement: Authenticated captain decisions
Recommendation, answer and supersede MUST require verified captain capability plus captain or configured coordinator attribution. The requester MUST NOT answer their own request. An answer MUST record answer text, actor, answered_at and on_behalf_of=captain.
#### Scenario: Spoofed coordinator header
- **WHEN** a caller supplies the coordinator attribution without a valid capability
- **THEN** no recommendation, answer, recovery or delivery is recorded

### Requirement: Atomic answer delivery
An answer SHALL atomically retain one task-tagged board inbox message, one timeline event and exactly one durable wake intent. Matching answer retries MUST return the retained result; conflicting answers MUST fail. No decision delivery SHALL depend on or emit Mattermost.
#### Scenario: Answer retry
- **WHEN** the same authorized answer is retried after a lost response
- **THEN** the original message, event and wake IDs are returned without duplicates
#### Scenario: Transaction failure
- **WHEN** a delivery write fails before commit
- **THEN** the request remains open and no partial answer delivery exists

### Requirement: Frozen wake route
The answer transaction MUST freeze either an eligible enrolled worker route or a seat-watcher route. Worker events SHALL use decision_answered and decision:<id>:answer. Later enrollment MUST NOT create a second route. Fallback reservation MUST be durable and uncertainty MUST prevent automatic physical-effect replay.
#### Scenario: Enrollment after answer
- **WHEN** a fallback-routed requester enrolls a worker after being answered
- **THEN** its retained wake remains fallback-routed and no worker answer event is created
#### Scenario: Uncertain fallback submission
- **WHEN** a watcher reserves a wake and loses proof of native submission
- **THEN** the wake stays uncertain and subsequent polls do not submit it again

### Requirement: Explicit held-claim recovery
Open and answered requests MUST protect ownership despite expiry or stale heartbeat. Reads SHALL expose held_by_decision, raw claim expiry and requester_stale. Only requester ack/withdraw or authenticated audited supersede SHALL release the hold. Supersede MUST close every outstanding request atomically and record actor/reason before normal explicit reclaim.
#### Scenario: Stale requester
- **WHEN** heartbeat and claim timestamp become stale while a request is open
- **THEN** normal reclaim is refused and the request is prominently labeled requester_stale
#### Scenario: Coordinator recovery
- **WHEN** the authenticated coordinator supersedes with a reason
- **THEN** all outstanding requests are superseded and an expired task may be explicitly reclaimed
#### Scenario: Apply answer
- **WHEN** the owner renews, applies the recorded answer and acknowledges it
- **THEN** the request becomes applied and the last outstanding request's hold is released

### Requirement: Durable inspectable surfaces
The API and CLI SHALL support request/list/show/recommend/answer/ack/withdraw/supersede and explicit wake consumption. Lists MUST have stable oldest-first filter-bound keyset pagination. Dashboard SHALL retain Kanban and add a secondary Waiting on captain view with verbatim escaped findings, age, attribution and authenticated captain controls; agent and PR surfaces SHALL show waiting/stale state.
#### Scenario: Pagination
- **WHEN** requests share a creation timestamp across pages
- **THEN** IDs provide a stable tie-breaker and a cursor from another filter is refused
#### Scenario: Dashboard findings
- **WHEN** findings contain HTML-like text and long lines
- **THEN** the dashboard displays escaped verbatim content in a contained preformatted region

### Requirement: Monotonic schema and remote proof
Schema 20 migration MUST preserve a higher board_schema value and audit history. Builds and tests MUST run remotely. Feature delivery SHALL include retained Archify and portable OpenSpec documents plus current-head green PR CI through native no-mistakes.
#### Scenario: Higher schema
- **WHEN** migration runs on a database whose board_schema exceeds 20
- **THEN** its schema value is not lowered

