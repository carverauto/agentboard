## Purpose

Teach agents across harnesses to use the same durable collaboration contract while leaving execution and intelligent routing outside agentboard.

## ADDED Requirements

### Requirement: Shared board workflow skill
A shared skill SHALL document API URL/HTTPS configuration, 429/backoff behavior, stable registration, startup reads, atomic acceptance, explicit renewal, attributed updates, inbox acknowledgement, handoff/recovery, and GitHub links. It SHALL require meaningful state on the board and prohibit mandatory AI fleet-reconciliation loops.

#### Scenario: Agent starts or resumes work
- **WHEN** an agent follows the shared skill after a session restart
- **THEN** it reads durable task/message state and verifies its live claim before continuing owner-only work

### Requirement: Harness adapters and shell usage
Documented variants SHALL cover Claude Code, Codex, Pi, Grok, Cursor, OpenCode, OMP, Muse, and Herdr-hosted sessions plus plain shell usage. Variants SHALL reuse the shared command contract and distinguish harness identity from optional session-backend metadata without imposing a board runtime dependency.

#### Scenario: Herdr-hosted Codex session
- **WHEN** a Codex agent runs within Herdr
- **THEN** it records codex as harness and Herdr as backend metadata while using the same board commands

### Requirement: Human routing remains explicit
The captain/assistant playbook SHALL use board and quota reads to support routing. Skills SHALL neither create an automatic dispatcher nor silently authorize deployment, merge, or other external actions through task ownership.

#### Scenario: Assistant suggests a worker
- **WHEN** an assistant compares task requirements with quota evidence
- **THEN** routing remains an explicit board assignment/claim and external action authorization stays outside the board

