## Purpose

Replace the hand-run curl sequence for worker identities with idempotent CLI subcommands: create-or-reuse, converge-only enroll, and revoke — all through the existing captain-gated worker endpoints.

## ADDED Requirements

### Requirement: Create-or-reuse worker identity

`admin worker create <worker-id> --token-file PATH` SHALL create the identity via captain-gated `POST /api/v1/workers/provision` when absent, or reuse the existing identity when present. The token SHALL be written only to `PATH` (atomic write, mode `0600`); it SHALL NOT appear on stdout, logs, or board records.

#### Scenario: Create twice

- **WHEN** `admin worker create` runs twice for the same worker-id
- **THEN** the second run reuses the identity and writes nothing (no rotation, no new file)

### Requirement: Converge-only enroll

`admin worker enroll <worker-id> [--config PATH]` SHALL run protected-config, bind, install-supervision, and doctor in sequence, applying only the steps whose state is not yet converged (built on the existing `worker bind/install/doctor` mechanics).

#### Scenario: Enroll twice

- **WHEN** `admin worker enroll` runs twice against an enrolled worker
- **THEN** the second run reports converged and changes nothing

### Requirement: Revoke worker identity

`admin worker revoke <worker-id>` SHALL revoke the identity through the existing revoke endpoint semantics and SHALL be safe to repeat against an already-revoked identity.

#### Scenario: Revoke twice

- **WHEN** `admin worker revoke` runs twice for the same worker-id
- **THEN** the second run succeeds reporting already-revoked, with no error and no side effect

### Requirement: Board-side mutations stay captain-gated

All worker-lifecycle mutations SHALL use the existing captain capability; per-agent tokens (#128) SHALL NOT be accepted for `admin` operations.

#### Scenario: Agent token rejected

- **WHEN** an `admin worker` subcommand is invoked with an agent-scoped token
- **THEN** it refuses before any state read or write, naming the captain-capability requirement
