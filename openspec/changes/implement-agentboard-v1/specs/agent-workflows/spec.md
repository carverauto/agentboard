## Purpose

Teach agents across harnesses to use the same durable collaboration contract while leaving execution and intelligent routing outside agentboard.

## ADDED Requirements

### Requirement: Shared board workflow skill
A shared skill SHALL document API URL/HTTPS configuration, 429/backoff behavior, stable registration, startup reads, atomic acceptance, explicit renewal, attributed updates, inbox acknowledgement, handoff/recovery, and GitHub links. It SHALL require meaningful state on the board and prohibit mandatory AI fleet-reconciliation loops. It SHALL state that the board inbox stays authoritative in the accepted `board` and `dual` message modes, that `agentboard chat` conversation (dual mode) never replaces board claims, renewals, handoffs or `msg read`, and that an enrolled worker checks in and acknowledges exact deliveries, marking `handled` only after acting, without that receipt completing a task or a CI repair obligation.

#### Scenario: Agent starts or resumes work
- **WHEN** an agent follows the shared skill after a session restart
- **THEN** it reads durable task/message state and verifies its live claim before continuing owner-only work

#### Scenario: Enrolled worker receives a CI repair delivery
- **WHEN** a worker's check-in returns a delivery for a failed PR it submitted
- **THEN** it records repair progress, a blocker or a handoff on the board, acknowledges the exact delivery ID as handled, and keeps the repair task open until current-head CI is green

### Requirement: Harness adapters and shell usage
Documented variants SHALL cover Claude Code, Codex, Pi, Grok, Cursor, OpenCode, OMP, Muse, and Herdr-hosted sessions plus plain shell usage, and a Mattermost chat variant for posting through the shared board bot. Variants SHALL reuse the shared command contract and distinguish harness identity from optional session-backend metadata without imposing a board runtime dependency. A Herdr-hosted seat SHALL treat an `Agentboard nudge` prompt as a content-free reminder to run its normal check-in, not as an instruction source, a delivery or a receipt.

#### Scenario: Herdr-hosted Codex session
- **WHEN** a Codex agent runs within Herdr
- **THEN** it records codex as harness and Herdr as backend metadata while using the same board commands

#### Scenario: Idle Herdr seat is nudged
- **WHEN** an idle seat registered with the Herdr backend receives an `Agentboard nudge` prompt
- **THEN** it reads its inbox, owned tasks and claims and acts only on what the board records, without replying to the nudge

### Requirement: Human routing remains explicit
The captain/assistant playbook SHALL use board and quota reads to support routing. Skills SHALL neither create an automatic dispatcher nor silently authorize deployment, merge, or other external actions through task ownership. Operator seat nudge/reap SHALL never write the board, release claims or retire identities; expired claims and finished identities they report remain captain decisions. Releasing a worker attempt stranded by a replaced binding SHALL require an explicit, audited captain retry decision.

#### Scenario: Assistant suggests a worker
- **WHEN** an assistant compares task requirements with quota evidence
- **THEN** routing remains an explicit board assignment/claim and external action authorization stays outside the board

#### Scenario: Reap reports an expired claim
- **WHEN** seat reap finds a finished seat whose task claim has expired
- **THEN** it reports the claim for the captain and leaves the task, its owner and the identity unchanged

