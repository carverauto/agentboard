# Spec Delta

## Purpose

Keep agent publications attributable to owned task cards and admit branch writes using fresh repository evidence without losing existing PR tracking.

## ADDED Requirements

### Requirement: Durable branch binding precedes controlled publication
The system SHALL require a unique binding between a task, canonical head repository and exact branch before a controlled push or PR open/update. Attribution SHALL survive claim release, but authorization MUST require the current actor's live task claim or an explicit repair grant.

#### Scenario: Unbound publication
- **WHEN** a worker attempts controlled publication without a valid branch/card binding
- **THEN** publication is refused before the provider write and the refusal names the missing prerequisite.

#### Scenario: Shared repository credentials
- **WHEN** several registered agents share a GitHub login
- **THEN** that login alone does not auto-assign or link a PR to any agent's card.

### Requirement: Fresh default-branch evidence controls admission
Publication SHALL check the exact proposed head against a freshly fetched actual repository default tip at final push and PR open/update. A conflict MUST refuse authorization, a clean but behind branch SHALL produce a retained warning, and unknown or unavailable evidence MUST defer authorization without claiming clean.

#### Scenario: Refuse conflict but retain evidence
- **WHEN** a bound branch conflicts with the freshly fetched default tip
- **THEN** the controlled write is refused, its head/base verdict is retained and the worker is instructed to rebase and remotely revalidate through its native custody flow.

#### Scenario: Warn behind but clean
- **WHEN** a bound branch is behind the fresh default tip but merges cleanly
- **THEN** admission returns a warning recorded on the card without claiming a rebase occurred.

#### Scenario: Unknown evidence
- **WHEN** fetching fails, history is incomplete, or provider mergeability is null
- **THEN** authorization remains unresolved with retry information and no provider write or clean verdict occurs.

### Requirement: Opened publications are linked without an attribution gap
The system SHALL idempotently record the returned PR URL on its bound card immediately after open. A crash between provider open and acknowledgment SHALL be recoverable from registered branch identity; conflicting existing PRs MUST remain tracked even when publication authorization is refused.

#### Scenario: Crash after PR opens
- **WHEN** a bound PR opens and the publisher stops before returning its URL to the board
- **THEN** bounded reconciliation discovers the PR and auto-links its unique valid branch/card mapping exactly once.

#### Scenario: Ambiguous unlinked PR
- **WHEN** a discovered PR matches several cards or lacks a valid unique binding
- **THEN** it produces a retained unlinked-PR finding routed for attribution and no guessed task author or silent metadata overwrite.

#### Scenario: Existing conflicting PR link
- **WHEN** an owner records an already-open conflicting PR
- **THEN** its tracking/submission evidence is retained, publication admission is refused, and immediate conflict evaluation is scheduled with separate explicit dispositions.

### Requirement: Repair publication is head and custody fenced
A replacement seat MUST possess a live repair-only claim, explicit branch-write grant and verified native-custody receipt before writing the existing PR branch. The expected remote head and current base SHALL fence the write. No original task lease, unpublished native fix, authorship or second PR SHALL be substituted.

#### Scenario: Original publisher still active
- **WHEN** a replacement has a repair assignment but cannot prove native custody is quiesced and preserved
- **THEN** no branch write occurs and a durable captain escalation records the unsupported handoff.

#### Scenario: Author resolves first
- **WHEN** the original publisher advances the PR head before a replacement's write
- **THEN** the old grant is invalidated and the losing write is refused without overwriting the resolving head.

### Requirement: Provider limits and credentials are respected
Admission and reconciliation SHALL respect shared request budgets, provider retry delays and bounded requests. Authorization evidence, logs, ledger records and documents MUST exclude credentials. The CLI SHALL use the API for board state and SHALL NOT access the board database directly.

#### Scenario: Provider rate limit
- **WHEN** the provider or API returns a 429 or a retry delay
- **THEN** the client/job defers within the bounded policy, preserves its pending disposition and emits no token or hot-loop retry.
