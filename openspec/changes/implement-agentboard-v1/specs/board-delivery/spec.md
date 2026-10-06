## Purpose

Deliver repeatable remote-built CLI and dashboard artifacts that fit the committed CNPG and farm01 deployment scaffolding without compiling on the shared Mac.

## ADDED Requirements

### Requirement: Remote-only verification and releases
Builds, tests, asset compilation, and release packaging SHALL run through Bazel remote execution or BuildBuddy CI remote configuration. Warning-only diagnostics SHALL NOT fail builds. CLI artifacts SHALL cover Linux/Darwin amd64/arm64; the dashboard image SHALL publish under registry.carverauto.dev/agentboard.

#### Scenario: Release validation
- **WHEN** a release is prepared
- **THEN** remote results identify the tested artifacts and downloads include architecture labels and checksums

### Requirement: Single migration owner
Versioned migrations SHALL create and evolve the shared database before the dashboard becomes ready. Re-running migration on an up-to-date database SHALL succeed without duplicating schema or data. The API SHALL enforce schema compatibility; CLI processes SHALL report incompatible API/schema clearly and SHALL NOT connect to or migrate the database.

#### Scenario: First deployment
- **WHEN** the dedicated empty database is ready
- **THEN** the migration job prepares the schema before dashboard traffic is accepted

### Requirement: Existing farm01 contract
Delivery SHALL preserve namespace agentboard, dedicated agentboard-db, local-path-cnpg, the committed PostgreSQL image pin, dashboard port 4000, confirmed PHX_HOST, in-repo HTTPRoutes, and referenced out-of-band secrets. Only Phoenix SHALL access PostgreSQL, using verified TLS; CLI traffic SHALL use the Phoenix HTTP API over verified HTTPS. No end-user authentication or NATS SHALL be introduced.

#### Scenario: Rendered overlay
- **WHEN** the farm01 overlay is rendered for a release
- **THEN** deployment and migration reference the same real dashboard artifact and confirmed infrastructure values without embedded credentials

### Requirement: Readiness and deployment prerequisites
The dashboard SHALL expose /health/live for process liveness and /health/ready for database/schema readiness. Deployment documentation SHALL require trusted internal exposure, CLI API reachability and HTTPS trust, secrets, and a compatible Gateway listener/certificate before hostname availability is claimed.

#### Scenario: Schema or database unavailable
- **WHEN** the process is running but the database or required schema is unavailable
- **THEN** liveness succeeds and readiness fails

#### Scenario: Gateway hostname mismatch
- **WHEN** the Gateway cannot attach the confirmed hostname
- **THEN** deployment verification reports route unavailability and does not silently change PHX_HOST

### Requirement: Automated internal DNS and certificates
The confirmed hostname SHALL use existing cert-manager DNS01 issuance and external-dns Gateway publication. Shared Gateway/issuer/DNS scope changes SHALL reside in GitOps, with app HTTPRoutes in this repo. Existing cluster DNS ownership and other hostname routes SHALL be preserved.

#### Scenario: Hostname provisioning
- **WHEN** the companion GitOps resources and app routes reconcile
- **THEN** cert-manager supplies the Gateway certificate and external-dns publishes the confirmed hostname to the internal Gateway address

#### Scenario: Existing DNS ownership
- **WHEN** the hostname is added to farm01's DNS scope
- **THEN** farm01 retains its TXT owner, upsert-only policy, and existing domain filters without taking over other clusters' records

### Requirement: Documented pre-alpha recovery
Release documentation SHALL describe install/configure/smoke checks and rollback without deleting durable task history. The README SHALL remain explicit about pre-alpha status and the PRD source.

#### Scenario: Application rollback
- **WHEN** an application rollout fails after additive migrations
- **THEN** operators can restore the previous compatible image while preserving board rows and events

### Requirement: API-only CLI access
The CLI SHALL perform all reads, writes, and watches through the versioned Phoenix API. Database credentials SHALL remain server-side. The API SHALL validate write provenance and expose stable JSON records/errors, schema compatibility, and bounded pagination. The dashboard UI SHALL remain read-only.

#### Scenario: Worker has no database access
- **WHEN** a registered worker has only the API URL and trusted HTTPS configuration
- **THEN** registration, task lifecycle, messaging, quota, and watches work without PostgreSQL credentials or connectivity

#### Scenario: Direct API caller bypasses CLI validation
- **WHEN** a malformed request or missing/mismatched write context reaches the API
- **THEN** it fails with a structured error and no durable state change

### Requirement: Rate limiting precedes mutations
The API SHALL apply configurable request limits and watch-capacity limits, returning structured 429 with Retry-After before database mutation. Health probes SHALL remain independent. Rate-limit responses SHALL NOT be cached. Limit scope, defaults, proxy-address trust, and replica behavior SHALL be documented.

#### Scenario: Excess write request
- **WHEN** a caller exceeds its configured API request limit
- **THEN** the API returns 429 and Retry-After without changing records, events, messages, or quota

#### Scenario: Too many watches
- **WHEN** a caller exceeds configured simultaneous watch capacity
- **THEN** a further stream returns 429 and capacity becomes available after an existing stream disconnects

### Requirement: Respectful bounded client retries
The CLI SHALL honor Retry-After delay-seconds or HTTP-date on 429 and SHALL NOT retry before that delay. Missing/malformed values SHALL use bounded backoff. Retries SHALL have attempt/deadline limits, respect cancellation, replay the same request body, and keep diagnostics off stdout. Non-429 ambiguous write failures SHALL NOT be blindly retried.

#### Scenario: Rate-limited mutation eventually succeeds
- **WHEN** a write receives 429 with a valid delay and then succeeds within the retry budget
- **THEN** the CLI waits at least that delay and returns one successful result without duplicating the mutation

#### Scenario: Persistent rate limit or long delay
- **WHEN** retry attempts are exhausted or Retry-After exceeds the remaining deadline
- **THEN** the CLI stops with a clear infrastructure error instead of hammering the API

#### Scenario: Interrupt during backoff
- **WHEN** the user interrupts a CLI waiting after 429
- **THEN** it cancels promptly without another request

#### Scenario: Write response lost after commit
- **WHEN** an HTTP write fails with an uncertain commit outcome rather than a pre-mutation 429
- **THEN** the CLI reports uncertainty without automatically replaying the write

### Requirement: Independent request concurrency
Independent API requests and dashboard reads SHALL execute concurrently through the database connection pool. An unrelated blocked task mutation SHALL NOT globally serialize other task operations. Notifications and rate limiting SHALL NOT funnel database work through one application process.

#### Scenario: One task mutation is blocked
- **WHEN** a transaction holds a lock on one task while another request reads or mutates an independent task
- **THEN** the independent request completes while the blocked request waits, subject to available pool capacity
