## Purpose

Keep tasks, their ownership, and an attributed history in one durable board with deterministic transitions that prevent concurrent agents from silently taking the same work.

## ADDED Requirements

### Requirement: Durable task records
The system SHALL create tasks with unique caller-chosen IDs or generated collision-resistant slugs, title, description, nonnegative priority (default 3), repo, labels, and optional issue/PR URLs. Tasks SHALL support list/show filters and metadata edits through the CLI. Duplicate explicit IDs SHALL fail; v1 SHALL retain tasks and history without hard deletion.

#### Scenario: Create and find work
- **WHEN** an agent creates a task with a repo, priority, and issue URL
- **THEN** the task is open, unassigned, discoverable by status/repo, and has an attributed created event

#### Scenario: Duplicate ID
- **WHEN** a create request reuses an existing task ID
- **THEN** it fails without overwriting the task or appending a created event

### Requirement: Stable machine output
List/show SHALL support stable JSON envelopes with snake_case fields, UTC timestamps, explicit nulls for absent ownership, and deterministic ordering. Lists SHALL support bounded pagination. Machine output SHALL contain no prompts or logs; failures SHALL use stderr and nonzero exit codes.

#### Scenario: Non-interactive task listing
- **WHEN** an agent requests an empty open-task list with JSON enabled
- **THEN** stdout is valid JSON with an empty tasks array and pagination metadata

### Requirement: Atomic claim and assignment acceptance
An unassigned open task SHALL be claimable atomically. An assigned task SHALL be claimable only by its named assignee. Success SHALL move it to in_progress, record the assignee and a two-hour lease by default, and append one claimed event in the same transaction. Live claims SHALL refuse further claims, including repeated claims by the owner.

#### Scenario: Concurrent claimers
- **WHEN** two agents concurrently claim the same open task
- **THEN** exactly one succeeds and only its ownership and claimed event commit

#### Scenario: Accept assigned work
- **WHEN** the named assignee claims an assigned task
- **THEN** the claim succeeds even though assignee_id is already populated

#### Scenario: Another agent attempts acceptance
- **WHEN** an agent other than the named assignee claims an assigned task
- **THEN** the claim fails and assignment remains unchanged

### Requirement: Explicit lease renewal and recovery
Lease timestamps SHALL use database time. Positive configured TTLs SHALL override the two-hour default. Only the owner of an unexpired active claim SHALL renew it. Expiry SHALL preserve owner/status and SHALL require explicit reclaim or release. Explicit reclaim SHALL atomically replace an expired active claim; terminal tasks SHALL never be reclaimable.

#### Scenario: Expired work stays visible
- **WHEN** an in_progress, blocked, or review task's lease expires
- **THEN** it remains assigned and is identified as expired until someone explicitly releases or reclaims it

#### Scenario: Reclaim races with renewal
- **WHEN** a renewal and reclaim compete at the expiry boundary
- **THEN** database-time checks permit only the valid operation and each committed ownership change has an event

#### Scenario: Former owner posts after reclaim
- **WHEN** the former owner tries to change task metadata or status after another agent reclaims it
- **THEN** the write fails and current ownership is preserved

### Requirement: Task lifecycle and ownership discipline
Task states SHALL be open, assigned, in_progress, blocked, review, done, and cancelled. Ownership changes SHALL use assign/claim/release/reclaim/handoff. Active-task edits SHALL require an unexpired owner. Any registered actor SHALL be able to edit or cancel unclaimed open work and cancel pending assignments; all accepted changes SHALL be attributed.

#### Scenario: Block and resume
- **WHEN** a live owner changes in_progress to blocked with a reason and later resumes it
- **THEN** both transitions commit with status events and ownership is retained

#### Scenario: Invalid transition
- **WHEN** an agent requests an unsupported transition or edits a terminal task
- **THEN** the mutation fails without changing the task or its history

### Requirement: Explicit status transition rules
Generic status updates SHALL permit in_progress to blocked/review/done/cancelled, blocked to in_progress/review/cancelled, review to in_progress/blocked/done/cancelled, and open/assigned to cancelled only. Entering blocked SHALL require a reason. Terminal states SHALL be immutable; terminal transitions SHALL clear the active lease while retaining historical assignment.

#### Scenario: Complete reviewed work
- **WHEN** a live owner moves a review task to done
- **THEN** the task becomes terminal, retains its historical assignee, and has no active lease

#### Scenario: Bypass ownership through status update
- **WHEN** a caller attempts open to in_progress using a generic status update
- **THEN** the request fails and the caller must use atomic claim

### Requirement: Assignment release and handoff
Any registered actor SHALL assign open unclaimed work to a registered agent. Pending assignments SHALL be changeable by the assigner or assignee. Release SHALL require the current assignee or explicit expired-claim recovery and return the task to open. Handoff by a live owner SHALL set assigned, clear the lease, append a reasoned event, and atomically create a direct message to the recipient in M2.

#### Scenario: Handoff requires acceptance
- **WHEN** a live owner hands off a task to a registered peer
- **THEN** the peer receives an assigned task and message, and must claim it before performing owner-only updates

#### Scenario: Handoff transaction fails
- **WHEN** the handoff message cannot be persisted
- **THEN** neither the assignment change nor handoff event commits

### Requirement: Atomic append-only task history
Each accepted task mutation SHALL append an immutable event containing task ID, actor, model, harness, kind, server timestamp, and relevant before/after fields. Task state and its event SHALL commit together. Timeline reads SHALL use a deterministic order and retain GitHub links without performing forge actions.

#### Scenario: Event write failure
- **WHEN** a task mutation's event insertion fails
- **THEN** the task mutation rolls back

#### Scenario: Link a pull request
- **WHEN** a permitted actor records a valid HTTPS GitHub PR URL
- **THEN** the task and timeline show the link without creating, commenting on, or merging a PR
