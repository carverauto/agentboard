# Seat attachment

## Purpose

Let an authorized agent recover its task's isolated worktree and environment across session attachment without losing work or weakening the primary-checkout prohibition.

## ADDED Requirements

### Requirement: Owned task resolution
The CLI SHALL resolve a seat only for the caller's active, unexpired owned task. It SHALL read all task event pages and refuse terminal tasks, missing ownership, expired claims and unreadable board evidence without allocation.

#### Scenario: Foreign or expired claim
- **WHEN** ensure is requested for another actor's task or an expired claim
- **THEN** it fails before allocating or updating a seat

#### Scenario: Seat recorded on a later event page
- **WHEN** the newest task-seat record appears after the first page
- **THEN** resolution verifies that record instead of allocating a replacement

### Requirement: Idempotent task seat acquisition
Ensure SHALL reuse a verified durable task binding, preserve dirty/unpushed work and serialize concurrent local acquisition. It SHALL persist allocation before recording it on the board so retry after a failed record write reuses the same lease.

#### Scenario: Concurrent first ensure
- **WHEN** two local ensure requests target the same owned task, source and pool
- **THEN** both resolve the same worktree and one persistent lease

#### Scenario: Retry after board record failure
- **WHEN** allocation succeeds but recording fails and ensure is retried
- **THEN** it reuses the durable allocated seat without resetting files or acquiring another seat

### Requirement: Physical isolation remains mandatory
Resolution SHALL require a registered linked Git worktree in the specified v3 pool, matching source/common Git identity, task binding and current lease holder/identity. It SHALL reject primary, foreign, legacy/out-of-pool, redirected metadata and conflicting bindings.

#### Scenario: Primary or legacy target
- **WHEN** a target is the primary checkout or a non-pool legacy worktree
- **THEN** no agent is launched and no project files are edited

#### Scenario: Task or lease mismatch
- **WHEN** retained metadata names another task or a different current lease
- **THEN** reuse fails and preserves the conflicting worktree and metadata

### Requirement: Secret-free shell and JSON handoff
Ensure and env SHALL emit only selected non-secret seat/identity values, with shell-safe quoting or JSON. Env SHALL never allocate. Check SHALL verify actual physical cwd and the expected seat environment; neither output SHALL include credentials or arbitrary inherited environment.

#### Scenario: Existing session loses environment
- **WHEN** an owner obtains env exports, applies them and changes into the task seat
- **THEN** all three seat variables resolve correctly and check succeeds

#### Scenario: Paths contain shell metacharacters
- **WHEN** a validated seat path contains spaces, quotes or shell substitutions
- **THEN** emitted commands preserve literal values and execute no path text

### Requirement: Native launch and attach handoff
Task-aware launch and attach SHALL use the same verified seat, provide the mandatory brief and set worktree, source and pool environment before the child runs. Reattachment SHALL preserve credentials and task work and refuse incompatible retained briefs or protected metadata.

#### Scenario: Repeat native attach
- **WHEN** the same task and brief are attached twice
- **THEN** both children receive the same three seat variables and isolated cwd without replacing credentials or acquiring another lease

### Requirement: Self-heal instructions are shipped
The canonical and applicable harness skills SHALL document owned-task ensure/env/check recovery for missing environment while forbidding implementation in the primary checkout. An environment-only recovery SHALL not require a coordinator round-trip; decision holds and real isolation/ownership failures SHALL retain their escalation rules.

#### Scenario: Packaged skill installation
- **WHEN** an agent installs the embedded workflow bundle
- **THEN** the canonical recovery procedure is available with the relevant harness instructions

### Requirement: Packaged recovery without repository clone
The installed CLI SHALL provide the resolution engine without an Agentboard source checkout, using Git, Python 3 and the pinned Treehouse binary. Missing prerequisites SHALL produce a clear failure without implicit installation.

#### Scenario: Different product repository
- **WHEN** the CLI resolves an owned task in another Git repository with prerequisites installed
- **THEN** it does not depend on that repository containing Agentboard scripts
