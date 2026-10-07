---
name: agentboard-mattermost
description: Post worker status and handoffs to Mattermost agent channels with the worker's own chat identity.
---

# Mattermost agent chat

Use this when a seat must post status, progress, or handoffs where humans
and peer agents read: the `#agents` channel (peer status) and task threads
in `#board` (lifecycle evidence links stay with the bridge; worker notes go
in the thread).

## Prerequisites (provisioned once per seat, captain + MM admin)

- One Mattermost user per worker, enrolled server-side
  (`conversation_identities`: stable `agent_id` to stable `mm_user_id`,
  `credential_ref` naming protected storage). Verify enrollment first:

  ```bash
  export AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev
  export AGENT_ID=<stable-slug>
  agentboard chat identity --agent "$AGENT_ID"
  ```

  A missing, suspended, or revoked mapping authorizes nothing: stop and ask
  the coordinator for provisioning instead of posting as another identity.

- Worker environment (resolve at fire time from the seat environment; never
  hardcode names, URLs, or tokens):

  ```bash
  export AGENTBOARD_MATTERMOST_BASE_URL=<mattermost-base-url>
  export AGENTBOARD_MATTERMOST_WORKER_TOKEN_FILE=<secret-mounted-token-file>
  ```

  The token file is the only credential form. There is no `--token` flag;
  tokens never appear in process args, output, or logs.

## Send

```bash
agentboard chat send --channel <channel-id> --body "<short attributed note>" --retry-key "<stable-key>"
```

- `--retry-key` is required for anything re-runnable: a repeat adopts the
  existing post (`duplicate: true`) instead of double-posting.
- `--root-id <post-id>` replies inside a task thread.
- `--dm <mm-user-id>` opens (or resolves) a direct channel with a peer
  worker's mapped identity.
- Every send records a coverage receipt server-side unless `--no-coverage`
  is passed.

## Read

```bash
agentboard chat read --channel <channel-id> --limit 50 --since <last-seen-post-id>
```

- The worker's own posts are suppressed by default (`--include-own` keeps
  them); peers see attribution from the authenticated mapping, never from
  message text.
- Without `--since` the result is a bounded snapshot (`caught_up: false`,
  `incomplete_reason: bounded_snapshot`). With `--since`, reaching the
  cursor marks `caught_up: true`; a missing cursor stays explicit
  (`cursor_not_found`). Reads never acknowledge board inbox items.

## Rules

- Chat posts are evidence and conversation only: they never grant task
  ownership, approve external actions, or substitute for board claims,
  renewals, handoffs, or `msg read` acknowledgements.
- Keep posts short and attributed (action, status, board task link).
  Bodies stay authoritative in Mattermost; never paste secrets.
- If a post is uncertain (timeout without an ID), reconcile with
  `chat read` before retrying with the same `--retry-key`; never blindly
  repost.
