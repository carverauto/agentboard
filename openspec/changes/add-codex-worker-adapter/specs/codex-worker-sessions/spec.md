## Purpose

Connect explicitly enrolled Codex native sessions to durable Agentboard worker
delivery while preserving exclusive input, exact receipts, and fenced recovery.

## ADDED Requirements

### Requirement: Optional effective availability snapshot

Protocol 1 MAY include the additive field `state.worker.availability`. When
present, the server SHALL return the existing `Availability.effective` map
computed from the current registered Agent's identity, harness and model using
the database clock, rather than the enrollment-time subscription model.
Existing clients SHALL remain compatible without consuming this field.
The Codex bridge SHALL require `availability.state == "active"` immediately
before new native input and SHALL refuse when the field is absent or otherwise
unavailable. This snapshot SHALL NOT be represented as an atomic native I/O
authorization. Explicit scoped reads and receipts SHALL remain available to
unavailable workers.

#### Scenario: Older protocol-1 server
- **WHEN** scoped state omits the optional availability field
- **THEN** the Codex bridge does not submit new native input while existing clients continue using their established contract

#### Scenario: Availability changes after enrollment
- **WHEN** the registered Agent's current model or effective policy changes
- **THEN** fresh scoped state reflects that Agent's effective policy and explicit check-in and exact receipts remain usable

### Requirement: Explicit Codex session enrollment

The adapter SHALL bind a captain-provisioned worker to an exact native Codex
thread, fresh adapter generation and server binding epoch. Installation SHALL
remain preview-first and SHALL NOT activate or enroll an existing session.

#### Scenario: Existing interactive session
- **WHEN** skills or adapter files are installed beside an existing Codex pane
- **THEN** the pane remains manual and no prompt, daemon restart or enrollment occurs

#### Scenario: Verified replacement
- **WHEN** a native process or thread is replaced, resumed or forked
- **THEN** old callbacks are retired and the new generation requires an explicit epoch-fenced bind while old attempts remain retained

### Requirement: Exclusive safe native input

Automatic delivery SHALL require a proven dedicated session with one input
owner, an empty request queue, matching identity, idle native state and no
pending approval/input. Shared or interactive surfaces SHALL remain unsupported
unless their installed native submission path proves atomic recipient and
empty-composer guards.

#### Scenario: Sole owner is unproven
- **WHEN** another client can control the enrolled thread or proof is unknown
- **THEN** dispatch is disabled with a concrete reason and explicit check-in remains available

#### Scenario: Herdr reports idle with a draft
- **WHEN** idle status does not prove an atomic expected-session and empty-composer submission boundary
- **THEN** no Herdr prompt is issued and work remains pending

#### Scenario: Busy or approval-waiting session
- **WHEN** a delivery arrives during a running turn, user-input wait or approval wait
- **THEN** it remains durable pending work without interrupting, steering or answering the session

### Requirement: Frozen delivery and positive submission evidence

The adapter SHALL preserve worker protocol 1's bounded immutable batch, exact
worker/epoch/generation/hash/membership fences and fsync-before-I/O journal.
Matching native acceptance SHALL mean submitted, never handled. Positive
pre-write rejection SHALL mean not submitted; unknown effects SHALL remain
uncertain and SHALL NOT be automatically replayed.

#### Scenario: Lost native acceptance
- **WHEN** native input may have been written but the correlated acceptance cannot be proved
- **THEN** the exact attempt stays uncertain across restart and lease expiry without a second turn submission

#### Scenario: Corrupted or foreign batch
- **WHEN** payload hash, epoch, identity, membership or bounds fail validation before native write
- **THEN** the adapter refuses the batch with positive non-submission evidence

### Requirement: Explicit check-in and exact receipts

Check-in SHALL return its explicit scoped result without automatic frame
augmentation or acknowledgement. Receipts SHALL require a matching live native
request and explicit exact-member IDs under the current epoch receipt capability.
Turn completion and connector activity SHALL NOT acknowledge work or resolve CI.

#### Scenario: Forged receipt recipient
- **WHEN** a tool argument names another worker, a nonmember ID or a stale epoch
- **THEN** the receipt is rejected without changing delivery state

#### Scenario: Native turn completes
- **WHEN** a turn completes after displaying pending work
- **THEN** deliveries remain unhandled until an explicit exact-ID receipt succeeds

#### Scenario: Existing tool result
- **WHEN** a shell, MCP or other unrelated tool returns during a Codex turn
- **THEN** its output is unchanged and the adapter advertises automatic tool-return delivery as unsupported

### Requirement: Independent truthful health and recovery

The adapter SHALL report five versioned capabilities with reasons and separate
connector reachability, native readiness and model heartbeat. Missing identity,
sole-owner, version or recovery evidence SHALL fail closed. Health reports SHALL
NOT renew task leases, manufacture model activity or clear uncertain journals.

#### Scenario: Connector is healthy but thread is absent
- **WHEN** API connectivity is healthy while the native thread is not loaded or has failed
- **THEN** native readiness is unavailable and pending work is retained without a fabricated healthy model

#### Scenario: Rebinding an uncertain attempt
- **WHEN** a replacement binding leaves an old external submission unresolved
- **THEN** dispatch remains blocked until exact canonical reconciliation or explicit captain disposition

### Requirement: Evidence-gated rollout

Implementation SHALL await captain approval. Automatic readiness SHALL require
remote acceptance, isolated actual native conformance and packaged server/host
interop for the claimed profile. Production enrollment SHALL require separate
canary authorization; untested surfaces SHALL remain unsupported.

#### Scenario: Socket fixture tests pass
- **WHEN** remote synthetic socket tests pass but actual Codex conformance has not run
- **THEN** native readiness is not certified and automatic enrollment remains disabled

#### Scenario: Captain approves the proposal
- **WHEN** the design receives approval
- **THEN** implementation may begin but no production worker is provisioned or activated by that approval
