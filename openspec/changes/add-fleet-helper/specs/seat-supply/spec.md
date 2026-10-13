# Seat supply

## Purpose

Start, reconcile and retire seats from durable server intents and a supervised host daemon, so the fleet keeps running without an LLM watching it.

## ADDED Requirements

### Requirement: Server-owned launch intents
For each activated fleet the server SHALL compute wanted seats as the minimum of the requested count, the captain maximum, and live seats plus eligible backlog, and SHALL write one launch intent per missing loadout seat, bound to that seat's desired host and fenced by fleet revision. Intents SHALL expire. The server SHALL NOT supply binaries, paths or argv.

#### Scenario: Backlog grows
- **WHEN** eligible backlog exceeds live seats and the fleet is below its requested count
- **THEN** launch intents appear for loadout seats that are not live, up to the cap

#### Scenario: Backlog empties
- **WHEN** no eligible backlog remains
- **THEN** no new intents are written and running seats are left to the reap rules

### Requirement: Host daemon launches from a local allowlist
`agentboard host fleet serve` SHALL reserve only intents for its own enrolled host, lease a Treehouse worktree through `launch-seat`, open a new Herdr tab in that worktree, and run the harness command from a host-local allowlist with the seat brief. It SHALL report `launched` with pane and lease identity, or `failed` with a reason. It SHALL never type into an existing pane.

#### Scenario: Harness not in the allowlist
- **WHEN** an intent names a harness the host has no command for
- **THEN** the intent fails with that reason and nothing is launched

### Requirement: Restart reconciliation
The daemon SHALL journal each launch step and, after a restart, adopt an existing pane and lease for a reserved intent, report a missing one, and never launch the same intent twice.

#### Scenario: Host restarts during a launch
- **WHEN** the daemon stops after opening the pane but before reporting
- **THEN** on restart it finds the pane, reports `launched` and opens no second pane

### Requirement: Reap closes the loop
A launched seat SHALL be retired by the existing `seat reap` rules (idle past `reap_after`, no open task, no unread message, landed work), which close the pane, return the lease and close the intent.

#### Scenario: Seat finishes its work
- **WHEN** a launched seat's last card is done and its PR merged and it idles past `reap_after`
- **THEN** its pane closes, its Treehouse lease returns and its intent is closed

### Requirement: Per-fleet activation
Seat supply SHALL require the global flag and a captain activation of the fleet in `dry-run` or `live` mode. Deactivation SHALL stop new intents and launches and SHALL NOT stop running seats, release claims or delete intents.

#### Scenario: Captain deactivates a fleet
- **WHEN** the captain deactivates a live fleet
- **THEN** no new seats launch and every running seat keeps its work
