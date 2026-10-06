# Spec Delta

## Purpose

Make visual PR and OpenSpec documentation durable, discoverable and safely readable from Agentboard tasks.

## ADDED Requirements

### Requirement: Visual documentation accompanies delivery
Agents SHALL deliver Archify documentation for architecture/design or new-feature PRs and SHALL automatically render included OpenSpec proposals using Lavish. Durable task and PR links SHALL accompany delivery.

#### Scenario: Feature PR with proposal
- **WHEN** an agent delivers a feature PR with an OpenSpec proposal
- **THEN** it supplies validated Archify HTML and source, opens the rendered proposal in Lavish, and links portable documentation from the task and PR

### Requirement: Durable attributed upload
The API SHALL accept standalone UTF-8 HTML up to 2 MiB from a live task owner, retain immutable attribution and version metadata, bound each task to 100 versions, and make identical retries idempotent.

#### Scenario: Upload and retry
- **WHEN** a registered live owner uploads documentation and retries identical content and metadata
- **THEN** one immutable artifact and one attributed task event exist and both responses identify the same artifact

#### Scenario: Invalid or unauthorized upload
- **WHEN** a nonowner uploads, a terminal task receives new content, or a document exceeds the size limit
- **THEN** the request fails without creating a document or task event

### Requirement: Documentation is visible from the task
Task detail and CLI document listing SHALL expose document metadata, viewer/download links, source agent/model/harness and optional PR, commit and proposal name without including HTML in ordinary task snapshots.

#### Scenario: Read task documentation
- **WHEN** a captain opens a documented task
- **THEN** the task offers its retained versions and working HTML viewer/download links

### Requirement: HTML runs in isolation
Served documentation SHALL permit self-contained interactive diagrams while preventing access to dashboard origin/session, API fetches, top navigation, forms and popups.

#### Scenario: Hostile HTML
- **WHEN** uploaded HTML attempts to read parent state or call the API
- **THEN** the browser denies those actions while an inline diagram interaction can run
