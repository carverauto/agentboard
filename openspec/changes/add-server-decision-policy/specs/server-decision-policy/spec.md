## ADDED Requirements

### Requirement: Exact captain-approved immutable versions
The server MUST create edits as a new draft and MUST require verified captain
approval of that exact digest before an explicit compare-and-set activation.

#### Scenario: Forged approval metadata
- **WHEN** a client submits approved status or another person's approval fields
- **THEN** the draft write fails and no active authority is created.

### Requirement: Atomic fenced event-created answers
The server MUST enqueue from decision creation transactionally and MUST only
answer an unchanged open source under the same active approved policy generation,
with limits, canonical answer delivery and immutable ledger in one transaction.

#### Scenario: Concurrent duplicate jobs
- **WHEN** two jobs evaluate one captured decision and policy identity
- **THEN** at most one answer, ledger, message, task event and wake commits.

#### Scenario: Human or policy state changed
- **WHEN** source/task currentness, policy generation or apply mode differs
- **THEN** the queued job cannot overwrite an answer or switch policy versions.

### Requirement: Default no-answer and transparent escalation
Human plan/explain MUST be read-only. Server mode MUST default to dry_run.
Unmatched, tied, captain-only, unverifiable and over-budget decisions MUST remain
open. Missing human push transport MUST be disclosed, without claiming cutover.

### Requirement: Shared serialized budgets
Answers MUST consume the PR (or task fallback) UTC-day budget across policy
versions; CI grants MUST be bounded per decision and never reset on retries.
