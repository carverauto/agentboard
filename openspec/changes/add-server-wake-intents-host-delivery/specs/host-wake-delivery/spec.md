## Purpose

Deliver eligible server wake intents through one locally owned session boundary while retaining uncertain effects, protecting native input and separating host readiness from agent activity.

## ADDED Requirements

### Requirement: Local scoped delivery ownership
The host daemon SHALL use protected local configuration and credential-file references for explicitly enrolled agent/repository bindings. The server SHALL NOT open native sockets or provide arbitrary shell commands, paths or credential values. Foreground check-in and nudge paths SHALL share one dispatch owner.

#### Scenario: Host manifest contains an unregistered binding
- **WHEN** local configuration cannot correlate a server intent to an authorized exact recipient
- **THEN** delivery is refused without targeting a focused or similarly titled pane

#### Scenario: Concurrent foreground check-in
- **WHEN** the daemon and a foreground nudge/check-in overlap
- **THEN** their shared ownership guard prevents a second native submission

### Requirement: Proven atomic safe-input boundary
Herdr prompting SHALL remain disabled until the installed profile proves exact recipient identity and atomic rejection of changed generation, occupied input, active work or approval UI. A snapshot followed by unguarded typing SHALL NOT count as proof. Unsupported sessions SHALL retain explicit check-in.

#### Scenario: Composer changes between probe and submit
- **WHEN** input becomes occupied or the recipient changes after inspection
- **THEN** the guarded native operation refuses without modifying input or answering a dialog

#### Scenario: Safe-input capability unavailable
- **WHEN** installed Herdr exposes only unguarded send-text/keys
- **THEN** readiness says unsupported and no automatic prompt is sent

### Requirement: Durable uncertainty reconciliation
The host SHALL journal an attempt before external I/O and reconcile unfinished attempts after reconnect or restart. Lost submission/spawn results SHALL remain uncertain. Reservation timeout, idle state or service restart SHALL NOT alone permit replay.

#### Scenario: Crash after prompt write
- **WHEN** the daemon loses the acceptance result after native I/O begins
- **THEN** restart reconciles the same attempt and cannot issue a duplicate prompt without proof of non-submission

#### Scenario: Pause races a native call
- **WHEN** pause, revocation or epoch loss occurs during dispatch
- **THEN** new effects stop and any started call is retained as uncertain until exact evidence settles it

### Requirement: Native completion is not handling authority
The delivered frame SHALL direct canonical check-in and exact acknowledgements while preserving underlying tool results. Native idle/done, prompt receipt or host health SHALL NOT renew leases, apply a decision, resolve a PR, update roster authority or fabricate model heartbeat.

#### Scenario: Seat finishes a turn
- **WHEN** a prompted session reports done without acknowledging the source
- **THEN** its source remains unhandled and its task/decision state is unchanged

### Requirement: Independently gated restart extension
Ordinary wake delivery SHALL NOT recreate or kill a session. A restart effect SHALL require a separately approved policy, matching recovery attempt/incarnation and preserved exact local seat custody. An uncertain effect SHALL block a second spawn, and new-session startup proof SHALL be returned without automatic answer replay.

#### Scenario: Missing retained seat or unresolved pipeline custody
- **WHEN** restart cannot prove the expected lease, WIP preservation, isolated cwd/brief or native pipeline custody
- **THEN** it refuses without allocating a replacement seat or releasing original claims

#### Scenario: Restart result is lost
- **WHEN** spawn may have happened but new-session proof is unavailable
- **THEN** the effect stays uncertain with the original attempt identity and no second process is started

### Requirement: Per-binding readiness and explicit cutover
Readiness SHALL independently expose connector health, capability support and reasons for each binding/action. Service/hook activation and replacing the existing nudger SHALL require separate captain authorization after dry-run parity and disposable native proof. Install/uninstall SHALL preserve foreign state and pending journals.

#### Scenario: Install owned supervision files
- **WHEN** an operator previews or writes an owned service plan
- **THEN** no service, hook, credential provisioning or fleet policy is silently activated

#### Scenario: Roll back host delivery
- **WHEN** dispatch is paused and the prior wake owner is restored explicitly
- **THEN** pending/uncertain attempts remain available for reconciliation without duplicate replay
