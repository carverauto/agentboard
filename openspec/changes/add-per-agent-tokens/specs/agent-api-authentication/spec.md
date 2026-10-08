## ADDED Requirements

### Requirement: Captain-managed hash-only credentials
The system SHALL restrict credential issue, rotation, revocation and listing to an authenticated captain capability, persist only a digest and safe metadata, and return an issued plaintext only once for protected custody.

#### Scenario: Credential rotates
- **WHEN** the captain rotates an agent credential
- **THEN** the new credential resolves that agent and prior active credentials no longer verify
- **AND** lists, logs and ordinary projections contain no plaintext or digest

#### Scenario: Attribution does not authorize administration
- **WHEN** a request uses coordinator attribution without a captain capability
- **THEN** credential administration is denied without mutation

### Requirement: Observe preserves writes and records authenticated principals
With mode off the system SHALL preserve current attribution behavior. With mode observe it SHALL verify supplied bearers, preserve legacy effective write attribution, and record anonymous, invalid and mismatched writes as durable audit events and bounded telemetry without secret values.

#### Scenario: Mismatched observe write
- **WHEN** a valid credential belongs to one agent and the write attributes another
- **THEN** the write follows existing authorization using the attributed agent
- **AND** a mismatch records both non-secret identities and appears in the Agents report

#### Scenario: Revoked or absent observe credential
- **WHEN** a board write supplies a revoked credential or no credential
- **THEN** legacy write authorization is preserved and the corresponding invalid or anonymous outcome is counted

### Requirement: Protected CLI and launcher custody
The CLI SHALL transport AGENTBOARD_TOKEN without echoing it in stdout, JSON, errors or meta. The launcher SHALL refuse coordinator identity and lease-holder mismatch and exclusively create a git-excluded 0600 seat identity file.

#### Scenario: Secure credential issue output
- **WHEN** fixture credential issuance succeeds through CLI administration
- **THEN** only a protected output file receives plaintext and stdout reports safe metadata

#### Scenario: Coordinator or mismatched lease
- **WHEN** a launcher identity is the coordinator or differs from the persisted Treehouse holder
- **THEN** launch and check fail before executing seat work

### Requirement: Enforcement requires captain approval
The system SHALL default to off and deliver observe first. Enforcement implementation and rollout SHALL wait for explicit captain proposal approval; the later approved phase SHALL derive the effective actor from a valid credential and reject anonymous, revoked and mismatched writes.

#### Scenario: Observe rollback
- **WHEN** an operator sets mode back to off
- **THEN** legacy attribution resumes without deleting credentials or audit history

#### Scenario: Approval not recorded
- **WHEN** the observe PR is delivered without captain approval of enforcement
- **THEN** enforcement remains unimplemented and unactivated, and its tasks remain pending
