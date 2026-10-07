## Purpose

Connect durable worker deliveries to heterogeneous persistent agent sessions through explicit bindings and independently validated host and harness capabilities.

## ADDED Requirements

### Requirement: Explicit host service activation and ownership
Skill installation SHALL remain instruction-only. Worker installation SHALL preview integration-owned changes, preserve existing hooks/configuration, report reload requirements and provide supervised host execution. Pause/uninstall SHALL remove only owned integration state and retain pending deliveries.

#### Scenario: Install global skills
- **WHEN** a user installs the Agentboard skills
- **THEN** no host daemon, hook, automatic prompt or registration is silently activated

#### Scenario: Existing Herdr or Firstmate hooks
- **WHEN** the worker adapter installs alongside existing hooks
- **THEN** it preserves their entries, selects one compatible wake owner and reports conflicts instead of overwriting configuration

### Requirement: Stable identity and binding generations
Bindings SHALL use stable board agent identity, explicit host/session/transport handles and a generation. Pane titles/model names SHALL NOT determine identity. Session replacement, fork, pane movement or changed occupant SHALL require verified rebinding or disable dispatch; unrelated focused panes SHALL never be fallback targets.

#### Scenario: Same pane hosts a replacement agent
- **WHEN** the bound pane's occupant changes
- **THEN** the old binding cannot prompt or acknowledge on behalf of the new occupant

#### Scenario: Session changes in the same process
- **WHEN** a native harness resumes, forks or creates a different session
- **THEN** previous-generation callbacks are retired and only the verified new binding can consume new frames

### Requirement: Safe Herdr transport
Herdr automation SHALL require negotiated installed-server capabilities and a verified recipient/safe-input boundary. It SHALL defer working, blocked, unknown, paused or occupied-composer sessions. Herdr state SHALL NOT become board roster, ownership or batch-handling authority.

#### Scenario: Approval dialog active
- **WHEN** a delivery targets a Herdr agent waiting for approval
- **THEN** the runtime retains pending work and does not type into or answer that dialog

#### Scenario: No safe-input evidence
- **WHEN** the installed Herdr server cannot prove safe automatic submission for the selected session
- **THEN** automatic prompting stays disabled with an explicit reason and manual/native check-in remains available

#### Scenario: Herdr reports done
- **WHEN** Herdr observes the bound session as done after a submission
- **THEN** the runtime treats that as lifecycle evidence and still requires exact Agentboard handling receipts

### Requirement: Truthful per-adapter capabilities
Each binding SHALL report versioned support for idle wake, turn-start delivery, tool-return delivery, native receipts and recovery, with unsupported/degraded reasons. A model change SHALL NOT imply a harness feature. Unsupported native adapters SHALL retain verified fallback/check-in without a claim of mid-turn parity.

#### Scenario: Muse or AGY has no validated hook contract
- **WHEN** it can use a verified Herdr transport but lacks native boundary proof
- **THEN** the dashboard reports idle delivery/check-in support and explicitly marks native mid-turn delivery unsupported

### Requirement: Boundary delivery preserves existing tools
Ordinary events SHALL enter at an eligible turn boundary. Urgent DMs/new relevant Context SHALL enter supported infrastructure-tool return boundaries in delimited source frames preserving the original tool result. Existing CLI JSON/NDJSON contracts SHALL remain unchanged, and arbitrary running processes SHALL NOT be interrupted.

#### Scenario: Context arrives during a supported tool call
- **WHEN** a scoped peer entry arrives before the infrastructure tool returns
- **THEN** its bounded priority frame accompanies that result and remains unhandled until explicitly acknowledged

#### Scenario: Raw CLI JSON requested
- **WHEN** an agent invokes an existing command with `--json`
- **THEN** its stdout remains compatible JSON/NDJSON without appended runtime prose

### Requirement: Harness-owned continuation mechanisms
Native adapters SHALL use the installed harness's supported completion/hooks/extensions with one wake owner and generation-aware cleanup. Codex fallback SHALL use bounded foreground checkpoints; native background wake SHALL be advertised only with a verified completion callback. Detached shell backgrounding SHALL NOT stand in for a supported wake path.

#### Scenario: Tracked callback capability absent
- **WHEN** a harness cannot prove a native background completion resumes the correct session
- **THEN** the adapter uses a supported fallback or reports unavailable rather than starting a detached watcher

### Requirement: Host recovery and independent health
Host service restart SHALL reconcile durable server pending state and its uncertain submission journal before dispatching. Connector health, adapter readiness and agent heartbeat SHALL be distinct. Runtime health reporting SHALL NOT manufacture busy/idle model activity or renew task leases.

#### Scenario: Healthy connector with stopped model
- **WHEN** the connector is running but its agent session is absent
- **THEN** the dashboard reports the missing session and pending delivery without presenting the model as fresh/busy or taking over its claim
