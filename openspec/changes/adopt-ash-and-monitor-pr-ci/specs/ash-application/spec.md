## Purpose

Give every application entry point the same attributed operation contract while preserving existing board data and independent concurrency.

## ADDED Requirements

### Requirement: Shared operation boundary
The API, dashboard and background jobs SHALL invoke the same domain operations and ownership/validation rules. Requests SHALL execute independently through the database pool; no single process or global lock SHALL serialize unrelated board operations.

#### Scenario: Independent tasks
- **WHEN** one task mutation is waiting on its task lock
- **THEN** another task mutation and an unrelated board read can complete independently

### Requirement: Transactional attributed history
Successful mutations SHALL commit their state, compatible task timeline and enabled resource/action audit records together. Audit records SHALL include actor, model/harness or explicit system provenance, operation version and correlation identity. Audit failure SHALL roll back the mutation.

#### Scenario: Audit insert fails
- **WHEN** a task claim encounters an audit persistence error
- **THEN** neither the claim nor a partial timeline/audit record commits

### Requirement: Existing data and API compatibility
Migration SHALL preserve existing IDs, terminal states, two-hour explicit leases, manual expiry recovery, append-only history, quota evidence and immutable HTML. Existing API v1 field shapes, pagination, error codes, 429 behavior and watch snapshots SHALL remain compatible except the documented new CI completion gate.

#### Scenario: Previously completed delivery
- **WHEN** the upgraded application reads a v0.1.0 completed task and its documents
- **THEN** its state, IDs, historical attribution, HTML bytes and document URLs remain unchanged

### Requirement: Audit disclosure boundaries
Audit interfaces SHALL exclude credentials and full HTML from general lists and SHALL expose bounded, escaped metadata. Replaying audit records SHALL NOT be available through public API/dashboard actions or enqueue external side effects.

#### Scenario: Captain inspects history
- **WHEN** a captain inspects task versions or action history
- **THEN** attributed changes are readable without credentials, raw HTML duplication or an executable replay control
