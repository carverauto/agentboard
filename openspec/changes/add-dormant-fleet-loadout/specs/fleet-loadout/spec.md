# Dormant fleet loadout

## ADDED Requirements

### Requirement: Captain owns dormant desired configuration
The system SHALL require verified captain capability for GET and PUT loadout operations. It SHALL expose only disabled, not-activatable, catalog-unverified and host-unverified configuration, derive seat count and perform no runtime or identity/credential operations.

#### Scenario: Missing loadout
- WHEN a captain reads an unused fleet slug
- THEN return revision 0, no seats, null provenance and the fixed dormant state without writing a record.

#### Scenario: Caller requests activation
- WHEN input includes enabled, activation or another unrecognized field
- THEN reject without mutation; no endpoint or CLI flag enables a fleet.

### Requirement: Seats reference canonical authority
Each desired seat SHALL reference an existing nonretired seat-kind agent, its exact harness and current managed SeatScope revision. The system SHALL store no duplicate editable scope arrays and SHALL expose current scope and observed model/retirement projections without treating them as model-catalog or host authority.

#### Scenario: Scope changed after preparation
- GIVEN a desired seat names an older scope revision or an unmanaged identity
- WHEN a new replacement is submitted
- THEN conflict atomically without creating configuration, bindings, receipt or audit history.

### Requirement: Identity bindings survive desired removal
The system SHALL permanently bind each fleet/seat pair to its original agent/harness, and SHALL reject an agent currently configured in another fleet. Removal SHALL preserve existing workers and task/decision responsibilities.

#### Scenario: Removed seat ID reassigned
- GIVEN a seat was saved and later removed
- WHEN its same fleet/seat ID is reused for another agent/harness
- THEN conflict without mutation.

#### Scenario: Moving a configured agent
- GIVEN an agent is configured in one fleet
- WHEN another fleet attempts to configure it
- THEN conflict until the first fleet removes it; historic bindings are retained.

### Requirement: Full replacements are bounded and exactly retryable
The system SHALL accept exactly revision, idempotency_key and at most 32 explicitly populated seats. It SHALL reject unknown/missing/null fields and invalid IDs, text, integer bounds or duplicates. It SHALL normalize model/effort/key whitespace and seat ordering, commit replacement/history/receipt together and retain an original response snapshot for exact retries.

#### Scenario: Competing revision writes
- GIVEN a current loadout revision
- WHEN two distinct replacements expect that revision
- THEN at most one succeeds and advances revision once; the loser adds no history.

#### Scenario: Exact retry after later changes
- GIVEN a replacement succeeded and loadout or observed reference data later changed
- WHEN the original key, expected revision and normalized seats are retried
- THEN return the original committed snapshot with replayed true and no new mutation history.

#### Scenario: Changed key payload
- GIVEN an idempotency key already committed for that fleet
- WHEN that key is submitted with a different revision or normalized seats
- THEN conflict without mutation.

### Requirement: CLI and packaged documentation preserve the boundary
The CLI SHALL expose captain-only show/set, verify schema 35 and validate complete JSON files before requests. Installed skill references and Docker/Bazel embed inputs SHALL include the dormant contract and its deferred-runtime limitations.
