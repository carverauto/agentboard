## Purpose

Make producer-supplied quota evidence durable and visible without losing account identity, reset-window semantics, or uncertainty needed for human routing.

## ADDED Requirements

### Requirement: Versioned atomic quota ingestion
Quota push SHALL accept one schemaVersion 5 or 6 report from stdin or file and require write provenance. Schema 5 SHALL use account_key default; schema 6 SHALL require unique nonempty provider/accountKey pairs. Invalid/unsupported reports SHALL fail atomically. Accepted reports SHALL preserve raw JSON, producer generation time, and ingestion time.

#### Scenario: Two accounts for one provider
- **WHEN** schema 6 contains two distinct accountKey rows for the same provider
- **THEN** both rows persist separately with their windows and scopes

#### Scenario: Unsupported or malformed report
- **WHEN** an unsupported schema, duplicate provider/account pair, or invalid required structure is submitted
- **THEN** no part of that report commits

### Requirement: Preserve quota semantics and freshness
Summaries SHALL preserve window IDs/kinds, percentages, resets, provider state, and per-scope effective availability, runway, and selection fields. Missing, stale, untrusted, conflicting, or unknown values SHALL NOT become available capacity. Parent-share windows SHALL NOT have remaining percentage inferred as 100 minus used.

#### Scenario: Parent-share meter
- **WHEN** a window reports percentUsed and shareOf without percentRemaining
- **THEN** remaining percentage stays unknown

#### Scenario: Through-reset runway
- **WHEN** a scope reports runway through_reset without a finite exhaustion time
- **THEN** the system retains through_reset without inventing runway seconds or a common reset

### Requirement: Idempotent latest report selection
Identical report retries by the same source SHALL NOT duplicate stored reports. History SHALL remain available, and latest reads SHALL select whole provider/account observations by producer time with a deterministic tie-breaker. Older arrivals SHALL NOT replace newer observations; a newer empty-window observation SHALL clear prior windows from the latest view.

#### Scenario: Out-of-order arrival
- **WHEN** an older report arrives after a newer report for the same provider/account
- **THEN** history records it but latest reads retain the newer observation

#### Scenario: New reading has no windows
- **WHEN** a newer accepted observation contains no windows
- **THEN** latest output shows that observation without carrying forward older quota percentages

### Requirement: Read-only routing evidence
Quota list SHALL support provider/account filters, pagination, stable JSON, and source freshness. Dashboard and CLI SHALL expose reported advisory spend priority without automatically assigning or launching work.

#### Scenario: Exhausted account
- **WHEN** quota evidence reports exhausted_now
- **THEN** it is highlighted for the captain and no task assignment or worker launch occurs

