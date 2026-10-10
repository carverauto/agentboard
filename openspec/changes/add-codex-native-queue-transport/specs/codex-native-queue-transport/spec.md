## ADDED Requirements

### Requirement: Explicit native queue identity
The transport SHALL accept only an already-negotiated, exact endpoint/profile,
version/schema and full persistent top-level thread identity. It SHALL preserve
unknown native status and SHALL NOT create, attach or resume a session.

#### Scenario: Wrong incarnation
- **WHEN** the endpoint or recipient incarnation changes
- **THEN** the transport refuses a new submission and cannot accept old callbacks.

### Requirement: Durable one-add boundary
The transport SHALL persist immutable caller fences and submitting evidence
before one queue-add RPC. It SHALL NOT automatically issue another add for that
attempt after a possible write, regardless of errors, timeout or queue absence.

#### Scenario: Lost response
- **WHEN** native insertion occurs and its response is lost
- **THEN** retry returns uncertain without a second queue add.

### Requirement: Exact positive acceptance only
Acceptance SHALL require a fully correlated queue ID, client message ID and
unchanged input for the exact endpoint and thread. Reconciliation SHALL NOT infer
non-submission from missing, consumed, deleted or incompletely paginated items.

#### Scenario: Historical receipt
- **WHEN** a durably accepted item no longer appears in the queue
- **THEN** retained acceptance remains historical evidence, never handled status.

### Requirement: No live authority
The transport SHALL remain unregistered and unreachable from serve, host and
installation. It SHALL NOT elect, reserve, provision, acknowledge or complete
work; canonical-source and explicit receipt integration remain separate gates.

#### Scenario: Busy thread
- **WHEN** an eligible persistent thread is busy and accepts a notice
- **THEN** the result records native acceptance without manufacturing idle,
  received, handled or completed state.
