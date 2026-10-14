## MODIFIED Requirements

### Requirement: Staged primary-inbox migration
Message mode SHALL default to `board` and support explicit `dual` and gated `mattermost` modes. Mattermost cutover SHALL require working bridge, phase 1 shared-bot routing with per-agent attribution, headless peer send/receive/recovery, handoff notification, a configured coordination channel, a measured Herdr seat delivery adapter, a measured coordinator decision path and an explicit legacy unread disposition — NOT per-agent Mattermost users. Each prerequisite SHALL be reported by a measured readiness producer; no operator boolean SHALL bypass one. Until every producer reports ready, board inbox/thread reads and sends SHALL retain their contract. A refused `mattermost` request SHALL use effective mode `dual` when the bridge, private recipient routes and inbound catch-up prerequisites hold, and effective mode `board` when any of those three does not. That choice SHALL be computed from the current prerequisites. The server SHALL NOT store a last accepted mode. Mirroring SHALL follow effective mode.

#### Scenario: Bridge exists but phase 1 routing does not
- **WHEN** an operator attempts sole-Mattermost cutover before shared-bot routing with per-agent attribution works
- **THEN** the readiness gate fails and the working board inbox remains primary

#### Scenario: One producer is not ready
- **WHEN** the operator requests `mattermost`, the bridge, private recipient routes and inbound catch-up prerequisites hold, and every other prerequisite except the legacy unread disposition reports ready
- **THEN** the effective mode is `dual`, Mattermost mirroring continues, legacy sends stay open, and the refusal names only the remaining blocker

#### Scenario: Dual prerequisites are absent
- **WHEN** the operator requests `mattermost` and the bridge, private recipient routes or inbound catch-up prerequisite does not hold
- **THEN** the effective mode is `board`, legacy sends stay open, and the refusal names the remaining blockers

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
The coordinator protocol operations SHALL accept a verified bearer carrying the explicitly issued `coordinator_runner` scope that belongs to the configured active coordinator, whether global auth is `off`, `observe` or `enforce`. Missing, invalid, revoked, wrong-scope or non-coordinator callers SHALL fail closed in every mode. The runner bearer SHALL NOT authorize decision-conversation routes. Every route except the coordinator protocol operations and decision-conversation notify and reply SHALL keep its current authentication.

#### Scenario: Runner on an auth-off server
- **WHEN** the configured coordinator presents its valid runner bearer to `coordinator heartbeat` while global auth is `off`
- **THEN** the heartbeat is recorded with that coordinator's attribution

#### Scenario: Anonymous caller on an auth-off server
- **WHEN** a caller without a runner bearer calls `coordinator tick` while global auth is `off`
- **THEN** the request is rejected and no attention page is returned

### Requirement: Chat mentions wake idle Herdr seats
Seat nudge SHALL treat unread coordination-channel posts that mention a seat's agent ID, and unread private-route items for it, as pending work for an idle seat. The host nudge caller SHALL read that pending work from a host-scoped count per seat. The count SHALL return counts only and SHALL NOT return message content, advance `conversation_coverage`, or mark a post read. `chat read` SHALL stay limited to the owning agent and SHALL keep recording that agent's coverage. A nudge pass that covered every live fleet seat within the staleness window SHALL be the readiness producer for the delivery adapter prerequisite.

#### Scenario: Peer mentions an idle seat
- **WHEN** a seat is idle in Herdr and a peer posts `@<seat-id>` in the coordination channel
- **THEN** the next nudge pass sends that seat a check-in nudge reporting the unread mention count, and the seat's `conversation_coverage` is unchanged

#### Scenario: Host reads as the seat
- **WHEN** the host nudge caller calls `chat read` as a seat
- **THEN** the read is rejected and that seat's `conversation_coverage` is unchanged

#### Scenario: Nudge has not run
- **WHEN** no covering nudge pass is recorded within the staleness window
- **THEN** the cutover gate lists the delivery adapter blocker

### Requirement: Measured coordinator decision path
Decision-conversation notify and reply SHALL, while global auth is `off` or `observe`, accept the same verified principal each route already accepts under `enforce`: notify a verified `agent` credential, reply a verified `coordinator_participant` credential. Anonymous, missing, invalid, revoked and wrong-scope callers SHALL fail closed in every mode. Decision-conversation show, reconcile and every other non-protocol route SHALL keep their current authentication. The coordinator decision path prerequisite SHALL be ready only when the configured coordinator has a protocol heartbeat within the staleness window and a retained decision-conversation notify/reply receipt. Readiness SHALL NOT compare that receipt to the runner credential. Chat replies SHALL never answer or apply a decision.

#### Scenario: Round-trip while auth is off
- **WHEN** global auth is `off`, a verified `agent` credential completes notify, a verified `coordinator_participant` credential completes reply, and the coordinator's protocol heartbeat is inside the staleness window
- **THEN** the notify/reply receipt is retained and the decision path prerequisite is ready

#### Scenario: Anonymous notify while auth is off
- **WHEN** a caller without a verified conversation credential calls notify while global auth is `off`
- **THEN** the request is rejected and no receipt is stored

#### Scenario: Show while auth is off
- **WHEN** a verified `coordinator_participant` credential calls decision-conversation show while global auth is `off`
- **THEN** the request is rejected under the route's current authentication

#### Scenario: Runner credential rotates
- **WHEN** a notify/reply receipt is retained, the coordinator's protocol heartbeat is inside the staleness window, and the runner credential is rotated
- **THEN** the decision path prerequisite stays ready

#### Scenario: Coordinator offline
- **WHEN** the coordinator's last protocol heartbeat is older than the staleness window
- **THEN** the cutover gate lists the decision path blocker

### Requirement: Explicit legacy unread disposition
Before cutover the captain SHALL be able to list every unread board direct message grouped by recipient and record one disposition for each: handled, forwarded to the recipient's private route with a retained receipt, or kept as pending legacy. The disposition SHALL be its own per-message record attributed to the captain. The legacy unread prerequisite SHALL be ready only when every unread captain or coordinator board direct message has such a record. Recording a disposition SHALL NOT acknowledge the message, silently or in bulk. Handled and kept messages SHALL stay unread and individually acknowledgeable through `/messages`.

#### Scenario: Undisposed coordinator message
- **WHEN** an unread board direct message to the coordinator has no disposition record
- **THEN** the cutover gate lists the legacy unread blocker and the message stays readable and acknowledgeable through `/messages`

#### Scenario: Kept coordinator message
- **WHEN** the captain records `kept` for an unread board direct message to the coordinator
- **THEN** the legacy unread prerequisite no longer lists that message, and the message stays unread and acknowledgeable through `/messages`
