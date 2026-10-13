# Seat supply

## Purpose

Start, reconcile and retire seats from durable server intents and a supervised host daemon, so the fleet keeps running without an LLM watching it.

## ADDED Requirements

### Requirement: Seat-supply flag defaults off
`AGENTBOARD_SEAT_SUPPLY_ENABLED` SHALL default off and SHALL fully disable seat supply. While it is off, the server SHALL write no launch intents and the host daemon SHALL open no tabs, including for a live fleet.

#### Scenario: Flag off
- **WHEN** the seat-supply flag is at its default and a live fleet has eligible backlog above its live seats
- **THEN** no launch intent is written and no tab opens

### Requirement: Server-owned launch intents
Eligible backlog SHALL mean unassigned open cards in the fleet's repositories. `requested_seats` SHALL default to 0. The captain sets `requested_seats` and `max_seats`. For each live activated fleet, while the seat-supply flag is on, the server SHALL compute wanted seats as the minimum of the requested count, the captain maximum, and live seats plus eligible backlog, and SHALL write at most one outstanding launch intent per missing loadout seat, bound to that seat's desired host and fenced by fleet revision. A reserved or uncertain intent occupies its seat and SHALL NOT expire into a successor. The server SHALL NOT write a second intent while one is outstanding. The server SHALL NOT supply binaries, paths or argv.

#### Scenario: Backlog grows
- **WHEN** eligible unassigned open cards exceed live seats, the fleet is live, and the fleet is below its requested count
- **THEN** one launch intent appears for each missing loadout seat, up to the cap

#### Scenario: Requested seats unset
- **WHEN** the captain has not set `requested_seats`
- **THEN** wanted seats are 0 and no launch intent is written

#### Scenario: Backlog empties
- **WHEN** no eligible backlog remains
- **THEN** no new intents are written and running seats are left to the reap rules

#### Scenario: Intent already outstanding
- **WHEN** a loadout seat already has a reserved or uncertain intent
- **THEN** the server writes no successor for that seat

### Requirement: Host daemon launches from a local allowlist
`agentboard host fleet serve` SHALL reserve only live intents for its own enrolled host. It SHALL NOT reserve a dry-run intent. It SHALL lease a Treehouse worktree through `launch-seat`, open a new Herdr tab in that worktree, and run the harness from a host-local allowlist. The allowlist value SHALL be an argv list. `{brief}` SHALL be substituted as exactly one argument and SHALL NOT be interpreted by a shell. Launch SHALL report `launched` with pane and lease identity, or `failed` with a reason. Launch SHALL use `pane run` on that new tab and SHALL NOT type into an existing pane. The existing content-free seat nudge remains the reminder for an idle seat.

#### Scenario: Harness not in the allowlist
- **WHEN** an intent names a harness the host has no command for
- **THEN** the intent fails with that reason and nothing is launched

#### Scenario: Brief contains shell metacharacters
- **WHEN** the seat brief contains shell metacharacters
- **THEN** those characters are one argv element and the host does not run them through a shell

### Requirement: Per-host concurrency cap
The host daemon SHALL enforce a captain-set per-host concurrency cap, which defaults to 0. It SHALL NOT reserve or start more launches at once than that cap. Dry-run intents SHALL NOT count toward the cap.

#### Scenario: Cap holds the second launch
- **WHEN** the cap is 1 and the host already has one launch in progress
- **THEN** the daemon does not reserve or start another launch on that host

#### Scenario: Cap unset
- **WHEN** the captain has not set the per-host cap and a live intent is waiting
- **THEN** the daemon reserves nothing and opens no tab

### Requirement: Restart reconciliation
The daemon SHALL journal each launch step. After a restart it SHALL adopt an existing pane and lease for that same intent. It SHALL launch that same intent again only when the journal shows pane creation never started. A reserved or uncertain intent whose pane creation has started SHALL stay occupied when the pane is missing and SHALL NOT be replaced by a successor. The daemon SHALL NOT launch a second intent for the same seat.

#### Scenario: Host restarts during a launch
- **WHEN** the daemon stops after opening the pane but before reporting
- **THEN** on restart it finds the pane, reports `launched` and opens no second pane

#### Scenario: Restart before pane creation
- **WHEN** the daemon stops after reserving an intent and the journal shows pane creation never started
- **THEN** restart launches that same intent and does not write or open a second one

#### Scenario: Pane missing after creation started
- **WHEN** restart finds that pane creation had started and the pane is gone
- **THEN** the intent stays occupied, no successor is written and no tab is opened

### Requirement: Reap stays board-free
Seat reap SHALL keep its existing landed-work and idle rules and SHALL stay board-free: it SHALL NOT close a launch intent, release a claim or retire an identity. After those rules close a launched seat's pane, or that identity is no longer live, the server SHALL close the intent. A reserved or uncertain intent whose pane is missing before reap SHALL stay occupied and SHALL NOT be closed by this observation.

#### Scenario: Seat finishes its work
- **WHEN** a launched seat's last card is done, its PR has merged, and it idles past `reap_after`
- **THEN** reap closes the pane and returns the Treehouse lease without writing the board, and the server closes the intent after it observes that reap closed the pane

### Requirement: Per-fleet activation
Seat supply SHALL require `AGENTBOARD_SEAT_SUPPLY_ENABLED` and a captain activation of the fleet. This change supersedes the `fleet-loadout` response in `add-dormant-fleet-loadout` that always returned `enabled: false` and `activation_state: not_activatable`. An unactivated fleet SHALL keep `enabled` false, `activation_state` `not_activatable`, `catalog_status` `unverified` and `host_status` `unverified`. Dry-run SHALL set `activation_state` to `dry_run` and leave `enabled` false. Live SHALL set `activation_state` to `live` and `enabled` true. `catalog_status` and `host_status` SHALL stay `unverified`. While the seat-supply flag is on, a dry-run fleet SHALL record would-launch intents in a dry-run state the host daemon never reserves, SHALL file no issues, SHALL assign nothing and SHALL open no tabs. While the flag is off, it SHALL record nothing. Deactivation SHALL stop new intents and launches and SHALL NOT stop running seats, release claims or delete intents.

#### Scenario: Dry-run fleet
- **WHEN** the seat-supply flag is on and the captain activates a fleet in dry-run and eligible backlog exceeds live seats
- **THEN** the loadout shows `activation_state` `dry_run` and `enabled` false, would-launch intents are recorded, and the daemon reserves none and opens no tab

#### Scenario: Live fleet
- **WHEN** the captain activates a fleet in live
- **THEN** the loadout shows `activation_state` `live` and `enabled` true, and `catalog_status` and `host_status` stay `unverified`

#### Scenario: Captain deactivates a fleet
- **WHEN** the captain deactivates a live fleet
- **THEN** no new seats launch and every running seat keeps its work
