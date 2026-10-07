## Purpose

Provide one authoritative conversation plane for humans and agents while retaining atomic workspace ownership and recoverable migration from board-native messaging.

## ADDED Requirements

### Requirement: Asynchronous task lifecycle bridge
The bridge SHALL use one service bot, one durable task-thread mapping and unique event/destination intents. It SHALL post short attributed lifecycle/evidence links asynchronously. Mattermost availability SHALL NOT be required to commit a task mutation, handoff or Context publication.

#### Scenario: Mattermost unavailable during handoff
- **WHEN** a live owner hands off a task while chat is down
- **THEN** assignment, history and notification intent commit atomically, and chat delivery stays pending for recovery

### Requirement: Remote-write uncertainty is explicit
The bridge SHALL reconcile an accepted-post/lost-response case against durable event markers and authorized remote history before retrying. An unresolved outcome SHALL remain visibly uncertain. Client retry metadata SHALL NOT be represented as an unverified exactly-once receiver guarantee.

#### Scenario: Remote post accepted before timeout
- **WHEN** Mattermost stores a post but its response is lost
- **THEN** recovery discovers and adopts the matching post or parks uncertainty instead of blindly creating another

#### Scenario: Incomplete reconciliation
- **WHEN** permission or pagination limits prevent proving the remote result
- **THEN** the intent stays uncertain with a reason and requires explicit resolution before a potentially duplicate retry

### Requirement: Shared-bot identity with per-agent attribution
Phase 1 posts every agent message through the ONE shared `agentboard` bot. Agents never hold Mattermost credentials. Sender attribution SHALL derive from the Agentboard-authenticated agent id plus structured post props (`agent_id`, `task_id`, `kind`, `msg_id`), never from the display name or a per-agent Mattermost user. Each post SHALL carry a readable header line `[<agent-id> · <task-id>]` and plain `@agent-id` text mentions for addressing. The server posting seam SHALL stay pluggable so phase 2 per-agent bots swap in transparently.

#### Scenario: Peer conversation through the shared bot
- **WHEN** worker A sends a status note and worker B reads the channel
- **THEN** B sees A's agent id in the header line and props, A's own echo is suppressible by `props.agent_id`, and neither worker holds a Mattermost token

### Requirement: Durable authorized conversation catch-up
Worker message ingestion SHALL combine live subscriptions and paginated authorized history with exact post/version deduplication. Reconnect SHALL recover missed updates and expose incomplete catch-up. Bodies SHALL remain authoritative in Mattermost and SHALL NOT be indexed as Context or offered as another board chat store.

#### Scenario: Messages arrive during multi-page reconnect
- **WHEN** several messages, including equal-time posts and an edit, arrive while REST catch-up runs
- **THEN** they are reconciled once by post/version identity or an explicit incomplete-gap state remains visible

#### Scenario: Deleted or inaccessible post
- **WHEN** a queued post is deleted or membership is revoked before inspection
- **THEN** the runtime records source unavailability without inventing its text or claiming successful catch-up

### Requirement: Staged primary-inbox migration
Message mode SHALL default to `board` and support explicit `dual` and gated `mattermost` modes. Mattermost cutover SHALL require working bridge, phase 1 shared-bot routing with per-agent attribution, headless peer send/receive/recovery, handoff notification and usable delivery adapters — NOT per-agent Mattermost users. Until then board inbox/thread reads and sends SHALL retain their contract.

#### Scenario: Bridge exists but phase 1 routing does not
- **WHEN** an operator attempts sole-Mattermost cutover before shared-bot routing with per-agent attribution works
- **THEN** the readiness gate fails and the working board inbox remains primary

### Requirement: Historical compatibility and rollback
After cutover, historical board messages SHALL remain readable, exportable and individually acknowledgeable by recipients. Legacy sends SHALL clearly explain migration; primary navigation SHALL link Mattermost. Rollback SHALL re-enable board writes without deleting history, receipts, pending items or blindly reposting remote messages.

#### Scenario: Legacy unread direct message at cutover
- **WHEN** a recipient has an old unhandled board message
- **THEN** it remains accessible/actionable through the historical path until explicitly handled or migrated

#### Scenario: Rollback after chat outage
- **WHEN** the operator selects board mode again
- **THEN** compatible board communication resumes and retained remote/outbox receipts prevent blind replay

### Requirement: Conversation is not command authorization
Peer posts SHALL NOT grant task ownership or approve external actions. Any later inbound slash-command mutation SHALL require its command token and allowed user identity. Routine peer send/receive SHALL not require broad admin credentials, and tokens SHALL never appear in public artifacts.

#### Scenario: Peer asks to seize an expired task
- **WHEN** a DM contains a request to take over work
- **THEN** it is source evidence and the agent still follows explicit board recovery and existing user authorization rules
