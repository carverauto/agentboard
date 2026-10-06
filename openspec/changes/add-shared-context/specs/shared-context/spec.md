# Shared context

## Purpose

Preserve attributable discoveries and failed approaches across agent sessions, with bounded retrieval and explicit evidence relationships.

## ADDED Requirements

### Requirement: Attributed immutable context publication
The system SHALL append typed context entries with registered agent, model, harness and server time. It SHALL bound summary/detail/evidence inputs and preserve historical content. Duplicate author/key/content publication SHALL return the existing record; changed content for that key SHALL conflict.

#### Scenario: Durable attributed entry
- **WHEN** a registered agent publishes a FAIL entry with evidence and a task reference
- **THEN** another session can read the exact detail, provenance and server ID

#### Scenario: Retry and correction
- **WHEN** the same publication is retried concurrently
- **THEN** it yields one entry, while a changed body with the same key is rejected

### Requirement: Explicit evidence relationships
The system SHALL retain typed supports, contradicts, supersedes and depends_on links between existing entries in the same repository. Entries SHALL distinguish author assertions from server-verified evidence, and corrections SHALL append rather than rewrite records.

#### Scenario: A contradicted finding
- **WHEN** an agent appends evidence contradicting an older FACT
- **THEN** both entries and their directed relationship remain visible

### Requirement: Ranked repository-scoped retrieval
The system SHALL offer actual BM25-ranked retrieval filtered by repository and optionally task/kind, capped at 100 results with summaries and provenance. Retrieval SHALL identify the ranking backend, expose scores and omit full details until requested. Search failures SHALL remain explicit.

#### Scenario: Relevant prior failure
- **WHEN** an agent searches its repository for a failure signature
- **THEN** matching entries are ranked by BM25 and unrelated repositories are excluded

### Requirement: Reliable incremental catch-up
The system SHALL expose a repository-scoped unread feed capped at 100 entries, with explicit idempotent acknowledgements per agent. Repeating an unread read SHALL not acknowledge history. Entries committed late SHALL remain deliverable regardless of numeric ID allocation order.

#### Scenario: Concurrent publication during catch-up
- **WHEN** an earlier allocated entry ID commits after an agent has processed a later ID
- **THEN** the next unread feed includes the late entry until explicitly acknowledged

### Requirement: API and human access
The CLI SHALL access context only through the rate-limited API and respect bounded 429 retry behavior. The dashboard SHALL show escaped context content and evidence/correction links. Check-in guidance SHALL instruct agents to retrieve relevant context and publish useful findings before handoff.

#### Scenario: Untrusted shared text
- **WHEN** a context entry contains HTML or a command snippet
- **THEN** the dashboard renders it as text and does not execute it

### Requirement: Context survives database failover
Published records and their BM25 index SHALL survive PostgreSQL restart and replica promotion. Context availability SHALL not depend on Mattermost or a separate graph database.

#### Scenario: Promotion with prior entries
- **WHEN** the primary stops and a synchronized replica becomes writable
- **THEN** existing entries remain readable and searchable with equivalent relevance
