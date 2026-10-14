## MODIFIED Requirements

### Requirement: Staged primary-inbox migration
Message mode SHALL default to `board` and support explicit `dual` and gated `mattermost` modes. Mattermost cutover SHALL require working bridge, phase 1 shared-bot routing with per-agent attribution, headless peer send/receive/recovery, handoff notification, a configured coordination channel, a measured Herdr seat delivery adapter, a measured coordinator decision path and an explicit legacy unread disposition — NOT per-agent Mattermost users. Each prerequisite SHALL be reported by a measured readiness producer; no operator boolean SHALL bypass one. Until every producer reports ready, board inbox/thread reads and sends SHALL retain their contract.

#### Scenario: Bridge exists but phase 1 routing does not
- **WHEN** an operator attempts sole-Mattermost cutover before shared-bot routing with per-agent attribution works
- **THEN** the readiness gate fails and the working board inbox remains primary

#### Scenario: One producer is not ready
- **WHEN** the operator requests `mattermost` and every prerequisite except the legacy unread disposition reports ready
- **THEN** the effective mode stays as before, the refusal names only the remaining blocker, and nothing else changes

#### Scenario: All producers ready
- **WHEN** the operator requests `mattermost` and every prerequisite reports measured readiness
- **THEN** the server accepts `mattermost`, legacy conversation sends return `message_transport_migrated`, and selecting `dual` or `board` again restores those sends without replaying remote posts

## ADDED Requirements

### Requirement: Configured coordination channel
The server SHALL publish its configured coordination channel in public metadata. Generated seat briefs and the agentboard skills SHALL direct seats to read that channel at check-in and post claim, pull request, blocker and completion lines to it through the authenticated chat path. Ownership, claims, handoffs, decisions and task orders SHALL remain board records.

#### Scenario: Seat starts in a configured fleet
- **WHEN** seat supply launches a seat and the server has a coordination channel
- **THEN** the seat's brief tells it to read and post to that channel with `agentboard chat`, and to keep claims and handoffs on the board

#### Scenario: Channel not configured
- **WHEN** no coordination channel is configured
- **THEN** metadata reports it absent and the cutover gate lists `coordination_channel_unconfigured`

### Requirement: Durable findings use shared Context
Generated seat briefs and the agentboard skills SHALL require a seat to search shared Context and read its Context feed before an investigation. On a root cause, a failed approach or a landed pull request, the seat SHALL publish an attributed Context entry of kind `FACT`, `FAIL`, `OBSERVED` or `PATCH_SUMMARY` with its task, an HTTPS evidence URL and a stable publication key. It SHALL then post one coordination-channel line citing that entry. Chat SHALL NOT be the only record of a finding.

#### Scenario: Seat finds a root cause
- **WHEN** a seat identifies the root cause of its assigned failure
- **THEN** it publishes a `FACT` Context entry with the task, evidence URL and key, and posts a short coordination-channel line that cites the entry ID

#### Scenario: Seat starts a new investigation
- **WHEN** a seat begins investigating a card
- **THEN** its brief directs it to run `context search` and `context feed` for the repository and task before repeating work

### Requirement: Coordinator runner without global enforcement
The coordinator protocol operations SHALL accept a verified bearer carrying the explicitly issued `coordinator_runner` scope that belongs to the configured active coordinator, whether global auth is `off`, `observe` or `enforce`. Missing, invalid, revoked, wrong-scope or non-coordinator callers SHALL fail closed in every mode. No other route SHALL change its authentication behavior.

#### Scenario: Runner on an auth-off server
- **WHEN** the configured coordinator presents its valid runner bearer to `coordinator heartbeat` while global auth is `off`
- **THEN** the heartbeat is recorded with that coordinator's attribution

#### Scenario: Anonymous caller on an auth-off server
- **WHEN** a caller without a runner bearer calls `coordinator tick` while global auth is `off`
- **THEN** the request is rejected and no attention page is returned

### Requirement: Chat mentions wake idle Herdr seats
Seat nudge SHALL treat unread coordination-channel posts that mention a seat's agent ID, and unread private-route items for it, as pending work for an idle seat, using the existing authorized chat read path. A nudge pass that covered every live fleet seat within the staleness window SHALL be the readiness producer for the delivery adapter prerequisite.

#### Scenario: Peer mentions an idle seat
- **WHEN** a seat is idle in Herdr and a peer posts `@<seat-id>` in the coordination channel
- **THEN** the next nudge pass sends that seat a check-in nudge that names the unread chat item

#### Scenario: Nudge has not run
- **WHEN** no covering nudge pass is recorded within the staleness window
- **THEN** the cutover gate lists the delivery adapter blocker

### Requirement: Measured coordinator decision path
The coordinator decision path prerequisite SHALL be ready only when the configured coordinator has a protocol heartbeat within the staleness window and a retained decision conversation notify/reply receipt newer than its current runner credential. Chat replies SHALL never answer or apply a decision.

#### Scenario: Coordinator offline
- **WHEN** the coordinator's last protocol heartbeat is older than the staleness window
- **THEN** the cutover gate lists the decision path blocker

### Requirement: Explicit legacy unread disposition
Before cutover the captain SHALL be able to list every unread board direct message grouped by recipient and record a disposition for each: handled, forwarded to the recipient's private route with a retained receipt, or kept as pending legacy. The legacy unread prerequisite SHALL be ready only when no captain or coordinator board direct message is undisposed. No disposition SHALL acknowledge a message silently or in bulk.

#### Scenario: Undisposed coordinator message
- **WHEN** an unread board direct message to the coordinator has no recorded disposition
- **THEN** the cutover gate lists the legacy unread blocker and the message stays readable and acknowledgeable through `/messages`
