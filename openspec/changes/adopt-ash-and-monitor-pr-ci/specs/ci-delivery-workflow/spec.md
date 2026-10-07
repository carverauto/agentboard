## Purpose

Make CI verification and failure follow-up part of delivering a linked PR across every supported agent harness.

## ADDED Requirements

### Requirement: CI-aware completion
An owner-requested transition of a linked-PR task SHALL reject a new transition to done unless its monitored current revision has fresh passing CI under its repository policy. Rejection SHALL preserve the task/lease and return a conflict with the CI state and evidence/follow-up links. Tasks without PRs and existing terminal records SHALL retain their established lifecycle.

#### Scenario: Agent submits PR then completes immediately
- **WHEN** a live owner requests done while linked PR checks are pending, failed, unknown or stale
- **THEN** the task remains nonterminal and the response explains what CI evidence or remediation is outstanding

#### Scenario: Agent verifies all checks
- **WHEN** a live owner requests done with fresh current-revision passing evidence
- **THEN** completion commits normally with the verified PR revision recorded in delivery history

### Requirement: Continued CI responsibility
Canonical and harness skills SHALL require agents to wait for CI, inspect failures and logs, fix and recheck the latest revision, and explicitly record blockers or handoffs before changing work. Creating a PR or seeing a partial green check set SHALL NOT be described as completed delivery. Archify/OpenSpec delivery requirements SHALL continue to apply.

#### Scenario: Failure requires outside access
- **WHEN** an agent cannot fix or inspect a failing job because access is unavailable
- **THEN** it records the specific blocker and evidence on the board and deliberately retains, releases or hands off ownership

### Requirement: Captain follow-up review
The captain workflow SHALL inspect outstanding CI follow-ups and stale/unknown provider states when assessing completed delivery. Green CI SHALL resolve the failure condition but SHALL NOT silently execute work or grant merge/deploy authorization.

#### Scenario: Original owner unavailable
- **WHEN** a CI follow-up is assigned to an unavailable agent
- **THEN** the captain can explicitly reassign/handoff it under ordinary ownership rules without automatic expired-claim reclamation

### Requirement: Merged Review disposition
When PR observation is enabled, a system-only AshOban catch-up SHALL complete a source Review task whose current canonical PR and every retained submitted PR have matching immutable merged observations. It SHALL preserve the assignee, clear the completed task lease, notify an assigned owner through one durable inbox message and append attributed action/version/timeline proof atomically. Enabled Mattermost intents SHALL be captured in that transaction. Merged lifecycle SHALL NOT certify CI, resolve an obligation or complete its repair task. The owner-requested completion guard remains a separate policy.

#### Scenario: Final poll is pruned or application restarts
- **WHEN** retained merged evidence exists and terminal PR polling has stopped or the application was offline
- **THEN** catch-up completes eligible Review cards without another provider call, including cards with expired leases

#### Scenario: Current link or another submission is unfinished
- **WHEN** the current PR was cleared or relinked to an unmerged PR, or any retained submission is open, closed-unmerged, unobserved or inconsistent with its snapshot
- **THEN** the task remains unchanged for explicit disposition and provider lifecycle/evidence remains visible

#### Scenario: CI is unknown or failing after merge
- **WHEN** every submitted PR has trustworthy merged lifecycle evidence but CI is unknown, failing or stale
- **THEN** source Review completion records that evidence without reporting passing CI and existing repair tasks/obligations retain their explicit lifecycle

#### Scenario: Replayed jobs or audit failure
- **WHEN** concurrent catch-up jobs race or the transactional audit/notification capture fails
- **THEN** successful work produces exactly one completion/version/timeline event, and failed work retains task status, assignee, lease and history

#### Scenario: Disabled action and ineligible source
- **WHEN** observation is disabled, the source is outside Review, it has no canonical PR, it is a CI repair task, or it exceeds the bounded submission limit
- **THEN** the action leaves it unchanged; queued disabled jobs snooze without completing tasks
