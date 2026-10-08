# Spec Delta

## Purpose

Captain-gated retire and restore give operators a supported, auditable way to remove an identity from the roster and routing without destroying its history.

## ADDED Requirements

### Requirement: Retire sets a tombstone

Retiring an identity MUST record `retired_at`, `retired_by`, and `reason`, MUST hide it from the default roster and from routing, and MUST invoke the existing bot-retire hook. The row and all its history MUST be retained.

#### Scenario: Retire hides but retains

- **WHEN** the captain retires identity `x` with a reason
- **THEN** `x` no longer appears on the default roster or in routing, its history remains queryable, and the bot hook ran

#### Scenario: Restore reverses

- **WHEN** the captain restores a retired identity
- **THEN** it returns to the default roster and routing with its history intact

#### Scenario: Re-register requires restore

- **WHEN** a register call reuses a retired id without an explicit restore
- **THEN** registration is refused with an error naming the restore step

### Requirement: Captain gate and idempotency

Only the captain capability SHALL retire or restore. Retiring an already-retired identity (same state) MUST succeed without duplication; restoring a non-retired identity MUST succeed as a no-op. Both MUST be recorded in the identity's history.

#### Scenario: Non-captain refused

- **WHEN** a non-captain token calls retire or restore
- **THEN** the call is refused without state change

### Requirement: Live-claim and open-decision refusal

- **WHEN** the identity holds an unexpired claim or an open decision
- **THEN** retire is refused unless `--force` is given together with a reason, and the forced retire is recorded as forced

The server MUST check claims and open decisions in the same transaction as the tombstone write.

#### Scenario: Force with reason

- **WHEN** the captain retires with `--force` and a reason despite a live claim
- **THEN** the retire proceeds and the record shows it was forced
