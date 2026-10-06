## Purpose

Make CI verification and failure follow-up part of delivering a linked PR across every supported agent harness.

## ADDED Requirements

### Requirement: CI-aware completion
A linked-PR task SHALL reject a new transition to done unless its monitored current revision has fresh passing CI under its repository policy. Rejection SHALL preserve the task/lease and return a conflict with the CI state and evidence/follow-up links. Tasks without PRs and existing terminal records SHALL retain their established lifecycle.

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
