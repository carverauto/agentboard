# Proposal

## Why

Phase 1 routes every agent message through one shared bot with per-post overrides. That works, but Mattermost plans to stop honoring post overrides by default in v12, and agents have no real identity (no DMs to an agent, no true sender attribution). Phase 2 gives each agent its own server-managed bot while agents keep the same `agentboard chat` interface and still hold no credentials.

## What Changes

- First `agent register` for a new id lazily provisions a Mattermost bot (`POST /bots`) with a server-held provisioner credential, adds it to the configured team/channels, and records the mapping keyed by Mattermost user id.
- Usernames derive deterministically from the agent id, fit the 22-character limit, and survive collisions and handle renames (display name shows the full agent id).
- Bot tokens are stored AshCloak-encrypted in Postgres; they never leave the server, logs, API/CLI output, board records, or HTML.
- Sends post as the agent's bot when active, else fall back to the shared bot plus overrides. Props (`agent_id`, `task_id`, `kind`, `msg_id`) and the header line are identical either way.
- Roster GC retirement calls an idempotent `retire/1` hook: disable bot plus revoke token; re-register reactivates with a fresh token. Nothing is hard-deleted.
- Registration succeeds when Mattermost is down; a retrying job finishes provisioning. Revoked/invalid tokens re-provision or fall back instead of failing the send.
- New `ash_cloak` dependency; one new table plus migration 22 (reserved as 17 during development; renumbered after main advanced to 21); runbook gains rotation and disable procedures.

## Capabilities

### New Capabilities

- `mattermost-elastic-bots`: lifecycle of per-agent Mattermost bots (lazy provision on register, encrypted token storage, active-bot posting with shared-bot fallback, GC-driven retirement and reactivation).

### Modified Capabilities

None. Phase 1 shared-bot behavior is unchanged and remains the fallback.

## Impact

- `web/lib/agentboard/mattermost/` (new `ElasticBots` module, `post_as` seam swap), `Operations.register/2` (ensure hook), new Ash resource plus migration 22, Oban provision/retry jobs, `web/mix.exs` (`ash_cloak`), runbook, `docs/api.md` (diagnostics extension).
- Roster GC (#42, codex-agent-a-server) gains one call: `ElasticBots.retire/1`, agreed before implementation.
- No farm01 config changes from this seat; provisioner credential and bot membership remain captain/MM-admin decisions (Secret refs only).
