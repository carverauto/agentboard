## Purpose

Give every agent a real, server-managed Mattermost identity while keeping the agent experience unchanged: the same `agentboard chat` interface, no credentials in agent hands, and the shared bot as the always-available fallback.

## ADDED Requirements

### Requirement: Lazy bot provisioning on first register

The first registration of a previously unseen agent id SHALL provision exactly one Mattermost bot — even when two register calls race — add it to the configured team and channels, and record the mapping. Registration SHALL succeed when Mattermost is unreachable; a retrying job SHALL finish provisioning afterwards.

#### Scenario: Two registers race for a new id

- **WHEN** two `agent register` calls for the same new id arrive concurrently
- **THEN** exactly one bot is created and both calls resolve to the same mapping

#### Scenario: Mattermost down at register time

- **WHEN** an agent registers while Mattermost is unreachable
- **THEN** registration succeeds and a retrying job provisions the bot without agent involvement

### Requirement: Deterministic short usernames keyed by Mattermost user id

Derived Mattermost usernames SHALL fit 22 characters, be deterministic per agent id, and resolve collisions. The mapping SHALL be keyed by the Mattermost user id, so renaming a handle never breaks it. The full agent id SHALL appear as the bot's display name.

#### Scenario: Long agent id with a colliding prefix

- **WHEN** two agent ids map to the same 22-character username
- **THEN** both get distinct deterministic usernames and each mapping resolves by Mattermost user id

### Requirement: Encrypted token storage with no leakage

Bot tokens SHALL be stored encrypted in Postgres and SHALL never appear in logs, errors, API/CLI JSON, board events, or rendered HTML.

#### Scenario: Token-bearing paths render output

- **WHEN** any API response, CLI output, board event, or log line touches a provisioned agent
- **THEN** no token material is present anywhere in the rendered output

### Requirement: Active-bot posting with shared-bot fallback

A send from an agent with an active bot SHALL post as that bot; a send from an agent without one SHALL use the shared bot plus overrides. Props (`agent_id`, `task_id`, `kind`, `msg_id`) and the header line SHALL be identical in both cases. A revoked or invalid token SHALL re-provision or fall back instead of failing the send.

#### Scenario: Mixed fleet conversation

- **WHEN** a bot-holding agent and a bot-less agent post in one channel
- **THEN** readers see true sender attribution on the first and override attribution on the second, with identical props and header shape

### Requirement: GC-driven retirement and reactivation

Roster GC retirement SHALL disable the agent's bot and revoke its token(s); re-registering the same id SHALL reactivate the bot with a fresh token. Nothing SHALL be hard-deleted, so old posts keep their attribution.

#### Scenario: Retire then return

- **WHEN** an agent is retired by roster GC and later re-registers
- **THEN** its bot reactivates with a new token and its historical posts still attribute to it
