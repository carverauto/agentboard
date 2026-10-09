## Purpose

Give downstream hosts durable, attributable reasons to resume eligible agent sessions without transferring task ownership or treating transport success as source handling.

## ADDED Requirements

### Requirement: Canonical reason occurrences
The server SHALL expose versioned occurrences for unread DM, decision answered, claim expiring, idle assigned work and explicit blocker completion. Each SHALL retain recipient, repository, reason, canonical subject/version and a stable reason hash. Repeated scans SHALL NOT invent new occurrences from time alone.

#### Scenario: Late source commit and repeated scan
- **WHEN** an earlier source commits after a later one and scanners restart or overlap
- **THEN** both pending occurrences are discovered once with stable hashes

#### Scenario: Claim renews after warning
- **WHEN** a task claim's expiry changes
- **THEN** its old warning is invalidated and any later eligible warning identifies the new expiry

### Requirement: Existing source delivery is adopted once
An intent SHALL reference existing answer/delivery/inbox identity when available. Enrollment changes SHALL NOT create a duplicate signal for an already handled source. Reading a candidate, polling or receiving a prompt SHALL NOT mark its source handled.

#### Scenario: Answer already has a frozen worker wake
- **WHEN** an answered decision already has a pending wake and the new host starts
- **THEN** it adopts that wake instead of delivering the same answer through a second owner

#### Scenario: Recipient has no enrolled transport
- **WHEN** a source targets a worker without enabled authenticated delivery
- **THEN** durable inbox fallback remains available and later enrollment preserves the original handling identity

### Requirement: Availability and rightful audience remain authoritative
Reservation SHALL require active effective availability, enabled unpaused enrollment, allowed repository and matching current binding. Invalidated/terminal/foreign source occurrences SHALL not submit. Idle-assigned wakes SHALL refer only to authorized assigned work, without claiming it.

#### Scenario: Reserved or retired identity
- **WHEN** an identity becomes reserved, out of service, retired, paused or revoked before reservation
- **THEN** automatic wake is refused and the reason remains inspectable

#### Scenario: Other blockers still open
- **WHEN** one explicit blocker ships while another remains open
- **THEN** the occurrence names both states and the dependent task stays blocked without automatic claim renewal or resume

### Requirement: Immutable fenced dispatch
Each reservation SHALL freeze exact source refs, reason hash, payload hash, host/enrollment revision, binding epoch, native recipient generation, expiry and attempt identity. Authenticated retries SHALL return the same reservation; competing hosts SHALL NOT create a second active effect for it.

#### Scenario: Two host daemons reserve together
- **WHEN** concurrent authorized requests target one occurrence and incarnation
- **THEN** at most one effect is reserved and the other receives the exact existing reservation or a conflict

#### Scenario: Foreign host or old epoch
- **WHEN** a caller uses attribution headers or a stale binding to reserve or settle another host's intent
- **THEN** the action fails without consuming or acknowledging pending work

### Requirement: Distinct transport and handling state
Intent state SHALL distinguish pending, deferred, reserved, submitted, uncertain, suppressed and explicitly handled. Source handling SHALL require the existing exact authenticated acknowledgement. Cooldown or expiry SHALL NOT replay a submitted/uncertain occurrence.

#### Scenario: Native call accepted but worker does not handle
- **WHEN** transport accepts a prompt without an exact source acknowledgement
- **THEN** the source remains unhandled, the accepted occurrence is not resubmitted and its disposition is visible

#### Scenario: Read after source deletion
- **WHEN** an unread message is deleted or explicitly handled before a reservation
- **THEN** it is suppressed or resolved from canonical state rather than dispatched as stale work

### Requirement: Bounded and truthful dry-run
Default dry-run SHALL return bounded reason/source references and eligibility explanations without reservation, native I/O, acknowledgement or task mutation. Unsupported producers and missing proof SHALL be explicit. No report SHALL claim a fixture or static inspection proves production readiness.

#### Scenario: Legacy free-text blocker
- **WHEN** a blocked note names a dependency without an explicit confirmed dependency link
- **THEN** dry-run reports unsupported/manual dependency evidence instead of inferring a shipped-blocker wake

### Requirement: canonical repository scope
Board-message wakes MUST derive scope from the canonical task, never a worker's
current subscription list. Taskless legacy messages MUST stay in the inbox without
a repository-scoped wake. Discovery MUST apply scope before bounded pagination.

#### Scenario: subscription changes cannot relabel a DM
- **GIVEN** taskless and foreign messages precede a task-scoped unread message
- **WHEN** subscriptions are reordered, narrowed or changed and reconciliation runs
- **THEN** only the canonically scoped message is captured, excluded rows do not
  starve it, and retained occurrence identity is unchanged

### Requirement: historical callbacks cannot own newer state
A prior not-submitted attempt's repeated result or reconciliation MUST NOT regress
a later reservation, rewrite its intent revision or append misleading audit history.
Non-decision adopted deliveries MUST NOT bypass canonical wake admission through
the generic cooperation reservation or its oldest-ordinary fairness slot.
