# Spec Delta

## Purpose

Provide bounded, policy-approved recovery of a stale host-owned seat while preserving claimed work, original captain decisions and uncertain delivery evidence independently of coordinator availability.

## ADDED Requirements

### Requirement: Explicit policy admission
The system SHALL admit recovery only under an active captain-approved policy for opted-in registered seats with known heartbeat cadence, authorized host/session identity and outstanding claims or open/answered decisions. Reserved, out-of-service, paused and revoked seats MUST be excluded. Dry-run and disabled mode MUST cause no native effect.

#### Scenario: Missing cadence or disabled policy
- **WHEN** a stale registered agent has no recovery enrollment/cadence or recovery is disabled
- **THEN** reads can report staleness but no restart is reserved

#### Scenario: Reserved seat
- **WHEN** effective availability becomes reserved before restart admission
- **THEN** recovery is deferred without starting or prompting the session

### Requirement: One fenced recovery episode
A stale-heartbeat episode SHALL have one durable identity scoped to the enrolled seat incarnation and policy version. Concurrent detection and retries MUST reserve at most one effect for an attempt. A fresh heartbeat before reservation MUST cancel stale admission; later results MUST match the exact host/session/attempt fences.

#### Scenario: Concurrent detectors and new heartbeat
- **WHEN** two detectors observe the same stale incarnation and a fresh heartbeat arrives before reservation
- **THEN** no duplicate recovery episode or native restart is produced

#### Scenario: Old host result
- **WHEN** an old incarnation reports startup success after replacement
- **THEN** the result is rejected and cannot mark the current episode recovered

### Requirement: Owned isolated restart
A host SHALL restart only its explicitly enrolled, verified owned seat. It MUST preserve WIP, Git/pipeline custody and exact lease ownership; it MUST validate identity, source/root/worktree environment and isolated cwd before editing resumes. A responsive live session MUST be preserved. A foreign lease or unsupported replacement capability MUST fail closed.

#### Scenario: Missing or foreign Treehouse lease
- **WHEN** the recorded slot cannot be verified as the recovering seat's lease
- **THEN** the host neither steals nor resets it and retains an audited blocked outcome

#### Scenario: Live old session
- **WHEN** host inspection proves the old session is responsive
- **THEN** no duplicate session is launched and the stale observation is cancelled

### Requirement: Reconcile uncertain native effects
A repeated restart request SHALL reconcile a durable host journal rather than repeat a native effect. If prior spawn/submission cannot be proved absent or complete, uncertainty MUST persist, automatic replay MUST stop, and reconciliation MUST remain bounded by policy.

#### Scenario: Crash after spawn before receipt
- **WHEN** the host loses its response after launching the child
- **THEN** a retry discovers the same child/incarnation or retains uncertainty instead of launching another

### Requirement: Verified responsibility catch-up
Recovery SHALL require host-authenticated new-incarnation and isolation proof, a fresh correlated heartbeat and canonical responsibility/decision catch-up. A mere heartbeat or successful spawn MUST NOT count as completed recovery. Transport receipts MUST NOT acknowledge decisions or complete tasks.

#### Scenario: Forged heartbeat alone
- **WHEN** a heartbeat refreshes without the reserved host/incarnation startup proof
- **THEN** the episode cannot be marked recovered

### Requirement: Preserve original decisions and ownership
Restart SHALL retain the original decision ID, task/gate, answer and frozen wake route. Canonical catch-up MUST deliver answered-but-unapplied references without replaying uncertain physical delivery. Only the rightful seat applying a still-applicable answer and renewing its held lease may acknowledge it; recovery MUST NOT release, supersede or transfer ownership.

#### Scenario: Answered decision when session is killed
- **WHEN** an opted-in proven seat disappears with an answered decision and its original native gate remains applicable
- **THEN** restart and catch-up deliver the same answer for verified application and requester acknowledgement without human or coordinator intervention

#### Scenario: Gate no longer applicable
- **WHEN** the restarted seat finds the referenced native gate terminal or incompatible
- **THEN** the answer stays unapplied with an inspectable diagnostic and no guessed replacement action

### Requirement: Automatic audit evidence
Every detection, reservation, reconciliation, restart, verification, catch-up and exhaustion SHALL retain an automatically generated structured reason and outcome under its policy/episode/attempt identity. Evidence MUST exclude secret values and prompt transcripts and remain inspectable without coordinator state.

#### Scenario: Coordinator process unavailable
- **WHEN** recovery runs while the coordinator is offline
- **THEN** server and host audit records still explain each step without a manually entered recovery reason

### Requirement: Bounded retries and single escalation
After the policy's bounded failures or unresolved reconciliation budget, the system SHALL stop new native effects and create one durable captain escalation per episode. It MUST preserve claims, decisions, WIP and uncertainty. Notification retries MUST NOT create duplicate escalations. Manual authenticated Supersede MUST remain available.

#### Scenario: Repeated failed recovery
- **WHEN** K attempts fail and multiple workers retry escalation delivery
- **THEN** one exhausted episode and one escalation remain while ownership and decision holds persist

#### Scenario: Manual override races a retry
- **WHEN** the captain supersedes the outstanding decision before another attempt reserves
- **THEN** new restart admission rechecks outstanding work and never restores the superseded request
