## Purpose

Let the captain see which submitted PRs still need CI attention and inspect the evidence without consulting scattered agent sessions.

## ADDED Requirements

### Requirement: PR status table
The read-only dashboard SHALL provide a paginated PR table with linked tasks, repository/PR, head revision, responsible agent, CI state, failed/total check counts, follow-up state and last successful observation age. It SHALL offer state/repository/agent filters and prioritize actionable failures over passing rows.

#### Scenario: Captain opens PR view
- **WHEN** the captain opens the PR table
- **THEN** failing, pending and unverified PRs are distinguishable and each row links to task and provider evidence

### Requirement: Failure detail
A PR detail view SHALL show current-revision checks and job failures with conclusions, times, escaped bounded excerpts and GitHub/BuildBuddy links. Historical attempts SHALL be separately identified. Log retrieval failure and truncation SHALL be explicit.

#### Scenario: Inspect failed test
- **WHEN** the captain opens a failing PR row
- **THEN** its failed check/job and available BuildBuddy excerpt are visible alongside the responsible follow-up task

### Requirement: Freshness and degraded states
The dashboard SHALL distinguish stale/provider-unavailable evidence from live success, preserve last-known observations during outages and never show no checks or unavailable data as passing. Labels SHALL be readable without relying only on color.

#### Scenario: Monitor credentials expire
- **WHEN** observations become stale because provider access fails
- **THEN** the row identifies stale data, its last known result and the access error instead of remaining green

### Requirement: Live and API visibility
Committed CI changes SHALL refresh subscribed dashboard views with durable reread/fallback behavior and SHALL be available through API-only CLI reads. Existing task/document pages and long-lived watches SHALL remain available.

#### Scenario: Recovery becomes green
- **WHEN** the monitor records a successful current-head retry
- **THEN** the row refreshes to passing and its previous failure and follow-up history remain inspectable

### Requirement: Independent merge state visibility
PR table, detail and API-only CLI reads SHALL show observed mergeable/mergeable_state, derived conflict state/freshness, base ref and rebase follow-up link beside independent CI qualification. Old-base, provider-unavailable and uncomputed mergeability SHALL remain visibly stale or unknown, never clean by omission.

#### Scenario: Conflicting PR has passing checks
- **WHEN** an observed open PR has clean check results but definitive merge conflicts
- **THEN** merge conflict and rebase owner/work remain readable next to the unchanged CI result
