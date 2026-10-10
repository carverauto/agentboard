## ADDED Requirements

### Requirement: Verified portable runner
The server SHALL expose protocol-revision-1 HTTPS attention operations with thin
CLI parity and SHALL require an explicitly issued current `coordinator_runner`
bearer in enforce mode. Existing scopes and configured identity SHALL retain
their existing meaning.

#### Scenario: A read-only or participant credential attempts acknowledgment
- **WHEN** an existing coordinator credential invokes runner acknowledgment
- **THEN** the operation is denied and no handling receipt or source write occurs.

#### Scenario: Legacy authentication mode
- **WHEN** a new runner operation is requested in off or observe mode
- **THEN** it fails closed regardless of supplied attribution or bearer.

### Requirement: Bounded non-consuming attention
Tick SHALL list canonical open decisions in deterministic bounded pages with
exact source identity/version, task/requester, references and handling state.
Bounds SHALL include complete serialized response bytes as well as item count.
Reads SHALL NOT consume sources, mark read, renew leases or create liveness.

#### Scenario: Escalated but unanswered
- **WHEN** the exact current source has an escalated handling receipt
- **THEN** it remains visible as captain-pending until canonical source resolution.

#### Scenario: Concurrent late commit
- **WHEN** a decision commits before an already-returned cursor's sort position
- **THEN** restarting from the beginning discovers it, and page completeness does
  not claim transaction-wide or permanent snapshot completeness.

### Requirement: Exact atomic handling evidence
Ack SHALL accept only a strict bounded batch of exact source versions and named
dispositions, revalidate source and authority under locks, and append the whole
batch atomically. It SHALL NOT answer/apply a decision, send a message, wake a
seat or mutate a task/lease/source acknowledgment.

#### Scenario: Lost successful response
- **WHEN** the same authenticated identity retries an identical normalized batch
  with the same operation-scoped retry key
- **THEN** it receives the original receipt with original attribution/time and no
  new mutation, including after canonical source resolution.

#### Scenario: Changed retry or stale batch member
- **WHEN** the retry key has different normalized content, or a new batch contains
  a changed source version/owner or a resolved decision
- **THEN** the entire new acknowledgment is rejected without partial receipts.

#### Scenario: Authority changes while waiting for source locks
- **WHEN** a runner is revoked, its registered attribution changes or its configured
  coordinator binding changes before mutation admission
- **THEN** the new write is denied and no partial evidence commits.

### Requirement: Truthful foundation boundary
The contract SHALL disclose unavailable server policy evaluation and native
dispatch, preserve stable configured identity and pinned conversation attribution,
and distinguish recorded coordinator handling from captain answer, external
delivery and worker handling.

#### Scenario: Another harness adopts the wire contract
- **WHEN** another harness implements tick/ack
- **THEN** protocol portability does not authorize sharing credentials, changing
  an immutable agent harness, taking over the configured role or rewriting history.
