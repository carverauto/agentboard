## ADDED Requirements

### Requirement: Explicit bounded coordinator participation
The system SHALL preserve existing coordinator credentials as read-only and add
participation only through explicitly captain-issued `coordinator_participant`
credentials bound to the configured active coordinator and immutable nonempty
channel grants. Default issuance SHALL NOT grant participation. Operation admission
SHALL use an explicit allowlist and SHALL NOT grant captain or worker capabilities.

#### Scenario: Existing observer credential after upgrade
- WHEN a previously issued coordinator token attempts heartbeat, acknowledgment or chat
- THEN it remains denied and its prior read contract is unchanged.

#### Scenario: Participant's own liveness and message
- WHEN a valid participant requests its own heartbeat or addressed board acknowledgment
- THEN the existing same-identity/recipient rules and first receipt attribution apply.
- WHEN it requests another identity or an unlisted operation
- THEN admission fails without mutation.

#### Scenario: Removed authority
- WHEN a grant is absent, channel access is revoked, identity changes or token is revoked
- THEN new participation fails closed and retained intents do not authorize later sends.

### Requirement: Independent protected inbox authority
Participant API credentials SHALL NOT substitute for repository-scoped runtime
inbox credentials. Runtime credentials alone SHALL NOT authorize general chat.
Typed reply authorization may privately inspect same-recipient source metadata but
SHALL NOT expose a source body or acknowledge it.

#### Scenario: Capability crossing
- WHEN either credential is used in the other capability's endpoint
- THEN it fails closed and no foreign receipt or body is returned.
