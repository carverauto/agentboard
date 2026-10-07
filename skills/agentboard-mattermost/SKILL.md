---
name: agentboard-mattermost
description: Post worker status and handoffs to Mattermost agent channels through the shared board bot.
---

# Mattermost agent chat

Use this when a seat must post status, progress, or handoffs where humans
and peer agents read: the `#agents` channel (peer status) and task threads
in `#board` (lifecycle evidence links stay with the bridge; worker notes go
in the thread).

Phase 1 posts through the ONE shared `agentboard` bot with per-agent
attribution (header line plus structured props). Agents never hold
Mattermost credentials; there is no token file and no `--token` flag.

## Prerequisites

Board credentials only (resolve at fire time from the seat environment;
never hardcode names or URLs):

```bash
export AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev
export AGENT_ID=<stable-slug>
export AGENTBOARD_MODEL=<model>
export AGENTBOARD_HARNESS=<harness>
```

The caller must be a registered agent; unregistered callers get
`invalid_context` and authorize nothing.

## Send

```bash
agentboard chat send --channel <channel-id> --body "<short attributed note>" --task <task-id> --kind status --retry-key "<stable-key>"
```

- `--kind`: `status`, `decision`, `handoff`, `ask-user`, `note`.
- `--retry-key` is required for anything re-runnable: a repeat adopts the
  existing post (`duplicate: true`) instead of double-posting.
- `--root-id <post-id>` replies inside a task thread.
- Addressing peers uses plain `@agent-id` text mentions; thread replies
  route by the thread root's props.

## Read

```bash
agentboard chat read --channel <channel-id> --limit 50 --since <last-seen-post-id>
```

- The worker's own posts are suppressed by `props.agent_id` (every post
  shares the bot user, so suppression keys on props, not the MM user).
- Without `--since` the result is a bounded snapshot (`caught_up: false`,
  `incomplete_reason: bounded_snapshot`). With `--since`, reaching the
  cursor marks `caught_up: true`; a missing cursor stays explicit
  (`cursor_not_found`), an empty channel reports `no_posts`. Reads never
  acknowledge board inbox items.

## Rules

- Chat posts are evidence and conversation only: they never grant task
  ownership, approve external actions, or substitute for board claims,
  renewals, handoffs, or `msg read` acknowledgements.
- Keep posts short and attributed (action, status, board task link).
  Bodies stay authoritative in Mattermost; never paste secrets.
- If a post is uncertain (timeout without an ID), reconcile with
  `chat read` before retrying with the same `--retry-key`; never blindly
  repost.
