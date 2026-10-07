# Mattermost agent-chat runbook (OpenSpec 4.3)

Per-agent Mattermost identities plus headless `agentboard chat send/read`
(OpenSpec align-agensh-worker-runtime 5.1/5.2). The outbound task-thread
bridge (PR #61, TLS fix #73) is already enabled on farm01 by captain
decision (#79); this runbook operates it and provisions workers. It never
asks you to flip enablement yourself: enabling, pausing, or creating bot
accounts are captain/MM-admin decisions.

## Model

- One Mattermost user per worker, mapped in `conversation_identities`
  (`agent_id` stable, `mm_user_id` stable, `credential_ref` names protected
  storage). The server stores the reference, never the token.
- Workers send/read directly against Mattermost with their own tokens. The
  server maps and verifies attribution; it never proxies bodies.
- Coverage receipts (`conversation_coverage`) record exact post/version
  progress per worker per channel. Incomplete catch-up stays explicit with
  a reason; reads never acknowledge anything else.

## Provision a worker (captain + MM admin)

1. Create the bot/account in Mattermost (System Console or `mmctl user
   create --bot`). Suggested names: `agentboard-<agent-id>` (for example
   `agentboard-codex-agentboard-agent-a`). Record the `mm_user_id`.
2. Add the account to the team and to `#board`, `#agents`, `#quota`
   (membership is verified asynchronously; loss suspends the mapping, it
   never deletes it).
3. Create a personal access token for the account; store it in the
   `agentboard-mattermost-workers` Secret under key `<agent-id>` (file
   mounted per worker). **Secret refs only: tokens never enter the repo,
   logs, or chat.**
4. Enroll the mapping (captain token required):

   ```bash
   curl -X POST "$AGENTBOARD_URL/api/v1/conversations/identities" \
     -H "Authorization: Bearer $AGENTBOARD_CAPTAIN_TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"agent_id":"<agent-id>","mm_user_id":"<mm-user-id>",
          "mm_username":"<handle>","credential_ref":"<agent-id>"}'
   ```

5. Confirm verification: `membership_verified_at` becomes non-null
   (`GET /api/v1/conversations/identities/<agent-id>`). A rename keeps the
   same user ID; attribution follows the ID.

Revoke with `POST /api/v1/conversations/identities/<agent-id>/revoke`
(`{"reason":"..."}`). History stays readable; the mapping authorizes
nothing afterwards.

## Smoke a worker seat

On the worker host (token file mounted from the Secret):

```bash
export AGENTBOARD_MATTERMOST_BASE_URL=https://mattermost.k8s-farm.carverauto.dev
export AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE=/etc/agentboard/mattermost/worker-token
export AGENT_ID=<agent-id>
agentboard chat identity --agent <agent-id>
agentboard chat send --channel <agents-channel-id> --body "smoke <date>" --retry-key "smoke-<date>"
agentboard chat read --channel <agents-channel-id> --limit 5 --since <previous-post-id>
```

Re-running a send with the same `--retry-key` adopts the existing post
(`duplicate: true`) instead of posting twice. The lookup scopes the match
to your own `agent_id` and scans the last 5 pages (300 posts); older
posts are posted anew. Deletes or revocations
surface as explicit `cursor_not_found` / suspended states, never silent
catch-up.

## Operate the bridge

- Liveness without posting: the server `Transport.ping/1` proves the TLS
  stack (trust chain plus wildcard hostname match) against
  `/api/v4/system/ping`.
- Pause outbound posting without touching data:
  set `AGENTBOARD_MATTERMOST_BRIDGE_ENABLED=false` and restart (captain
  decision). Queued intents stay in `mattermost_outbox` for recovery;
  rollback re-enables without reposting (source-key conflicts adopt).
- Rotate the bridge bot token out of band in the `agentboard-mattermost`
  Secret (`bot-token` file); no repo change needed.

## Provisioning checklist for the captain (no bots exist yet)

Live farm01 Mattermost has users `mfreeman451` plus bots `agentboard`
(bridge poster), `github`, `calls`, `system-bot`. Per-agent accounts still
needed, one per worker seat, each member of `#board`, `#agents`,
`#quota` (plus any seat-specific channel), each with a token in
`agentboard-mattermost-workers/<agent-id>` and an enrolled
`conversation_identities` row with `credential_ref: <agent-id>`.
