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
When PR observation is enabled, a system-only AshOban catch-up SHALL complete a source Review task whose current canonical PR and every retained submitted PR have matching immutable merged observations. It SHALL preserve the assignee, clear the completed task lease, notify an assigned owner through one durable inbox message and append attributed action/version/timeline proof atomically. Enabled Mattermost intents SHALL be captured in that transaction. Merged lifecycle SHALL NOT certify CI or complete its repair task. Terminal obligations SHALL follow the separate audited disposition requirement. The owner-requested completion guard remains a separate policy.

#### Scenario: Final poll is pruned or application restarts
- **WHEN** retained merged evidence exists and terminal PR polling has stopped or the application was offline
- **THEN** catch-up completes eligible Review cards without another provider call, including cards with expired leases

#### Scenario: Current link or another submission is unfinished
- **WHEN** the current PR was cleared or relinked to an unmerged PR, or any retained submission is open, closed-unmerged, unobserved or inconsistent with its snapshot
- **THEN** the task remains unchanged for explicit disposition and provider lifecycle/evidence remains visible

#### Scenario: CI is unknown or failing after merge
- **WHEN** every submitted PR has trustworthy merged lifecycle evidence but CI is unknown, failing or stale
- **THEN** source Review completion records that evidence without reporting passing CI and repair tasks retain their explicit lifecycle and machine obligations close with terminal proof, preserving the observed CI state

#### Scenario: Replayed jobs or audit failure
- **WHEN** concurrent catch-up jobs race or the transactional audit/notification capture fails
- **THEN** successful work produces exactly one completion/version/timeline event, and failed work retains task status, assignee, lease and history

#### Scenario: Disabled action and ineligible source
- **WHEN** observation is disabled, the source is outside Review, it has no canonical PR, it is a CI repair task, or it exceeds the bounded submission limit
- **THEN** the action leaves it unchanged; queued disabled jobs snooze without completing tasks

### Requirement: Cooperation-gated rebase accountability
With cooperation enabled, a definitive current-head conflict SHALL create one retained rebase follow-up per PR/head through system Ash actions, assigned from immutable submitting-owner attribution or visible unassigned for captain routing. An identified owner SHALL receive one durable inbox message and the same cooperation wake/receipt path. The source task and independent CI obligations SHALL remain unchanged. Disabling cooperation SHALL retain observations without publishing rebase work.

#### Scenario: Repeated conflicting-head polls
- **WHEN** repeated or concurrent polls observe the same conflicting head with cooperation enabled
- **THEN** one repair task, follow-up proof, owner message and cooperation event commit, including across restart or flag reenablement

#### Scenario: Conflict clears or notification capture fails
- **WHEN** definitive newer mergeable evidence arrives or transactional audit/notification capture fails
- **THEN** successful resolution clears the machine signal without auto-completing repair work, and failed publication commits no partial task/message/proof

### Requirement: Terminal CI obligation disposition
The system SHALL resolve an unresolved obligation with a recorded reason when its PR reaches merged/closed lifecycle or its own repair task is Done/Cancelled. It SHALL atomically suppress pending/received failure, reminder and digest deliveries without certifying passing CI, completing repair work, deleting history or resolving an independent obligation merely because a source task completed.

#### Scenario: Terminal lifecycle despite unknown or failing CI
- **WHEN** a fenced observation commits merged or closed lifecycle for an unresolved episode
- **THEN** the episode closes with its lifecycle reason and resolving snapshot, pending notices are suppressed, and CI and repair task status remain unchanged

#### Scenario: Repair completion or cancellation
- **WHEN** the own repair task transitions to Done/Cancelled through the Board transaction
- **THEN** its obligation closes atomically with a repair disposition reason; identical dismissed head failures do not recreate the episode until a new head, verified recovery after dismissal, or retained merged/closed lifecycle after dismissal

#### Scenario: Recovery after downtime while cooperation is disabled
- **WHEN** observation is enabled and retained matching terminal proof or a terminal repair task exists
- **THEN** a bounded minute AshOban job closes the old episode through audited actions without a provider call and persists cursor continuations beyond 100 rows

#### Scenario: Replay, unknown proof, reopened PR or audit failure
- **WHEN** concurrent closure replays, retained proof is mismatched, a closed PR reopens with a new failure, or audit capture fails
- **THEN** replay creates no second resolution, mismatched proof remains active, a fenced closed observation preserves the retained disposition but ends same-head suppression, a reopened failure creates a new episode, and failed transactions retain the original task/obligation/delivery state
