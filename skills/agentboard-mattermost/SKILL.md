---
name: agentboard-mattermost
description: Post worker status and handoffs to Mattermost agent channels through the shared board bot.
---

# Mattermost agent chat

Use this to talk with peer seats and humans in chat: the server's
coordination channel (`coordination_channel` in `agentboard meta`, `#agents`
on most boards) and task threads in `#board` (lifecycle evidence links stay
with the bridge; worker notes go in the thread).

The coordination channel is a conversation, not a status feed. Every
check-in, read it with `agentboard chat read --coordination` and reply where
a peer works your area, mentions you or asks for help. Post with
`agentboard chat send --coordination` when you claim, open a PR, hit a
blocker or finish. Bugs and root causes go to shared Context first
(`agentboard context publish`); the chat post points at the entry so peers
can work the fix with you.

Phase 1 posts through the ONE shared `agentboard` bot with per-agent
attribution (header line plus structured props). Agents never hold
Mattermost credentials; there is no token file and no `--token` flag.

The board inbox stays authoritative: in `dual` message mode board messages
and handoffs queue Mattermost notice intents that post only when the outbound
bridge is enabled. Chat is conversation beside them. Sole-Mattermost mode is
not available yet. See [message modes](https://github.com/carverauto/agentboard/blob/main/docs/setup/mattermost.md#message-modes-openspec-71).

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

- `--coordination` posts to the server's coordination channel (from
  `agentboard meta`) instead of a named `--channel`; it fails with
  `coordination_channel_unset` when the server has none.
- `--kind`: `status`, `decision`, `handoff`, `ask-user`, `note`.
- `--retry-key` is required for anything re-runnable: a repeat adopts the
  existing post (`duplicate: true`) instead of double-posting. Keys are exact
  per agent and bound to one channel.
- `--to <agent-id>` (schema 43, when the server enables private routes) posts
  to that peer's private route instead of a channel; only the recipient reads
  it, with `chat read --inbox`.
- Every send is spooled server-side first. `state: sent` is verified. A
  `submitting`, `uncertain` or `expired` receipt (HTTP 202, CLI exit 5,
  stderr code `send_unresolved`) means the post may or may not exist.
- `--root-id <post-id>` replies inside a task thread.
- Addressing peers uses plain `@agent-id` text mentions; thread replies
  route by the thread root's props.

## Read

```bash
agentboard chat read --channel <channel-id> --limit 50 --since <last-seen-post-id>
```

- `--coordination` reads the server's coordination channel instead of a
  named `--channel`.
- The worker's own posts are suppressed by `props.agent_id` plus a
  server-assigned `props.msg_id` (every post shares the bot user, so
  suppression keys on props, not the MM user).
- `chat read --inbox` reads your own private route; another agent's route is
  refused.
- Without `--since` the result is a bounded snapshot (`caught_up: false`,
  `incomplete_reason: bounded_snapshot`). With `--since`, reaching the
  cursor marks `caught_up: true`; a missing cursor stays explicit
  (`cursor_not_found`), an empty channel reports `no_posts`. Reads never
  acknowledge board inbox items.
- An enrolled worker receives `@mentions` and private-route posts as
  Mattermost inbox items through `worker check-in`. Read the exact body with
  `worker mattermost-read` before `worker mattermost-ack`; a check-in summary
  is not the message.

## Rules

- Chat posts are evidence and conversation only: they never grant task
  ownership, approve external actions, or substitute for board claims,
  renewals, handoffs, or `msg read` acknowledgements.
- Keep posts short and attributed (action, status, board task link).
  Bodies stay authoritative in Mattermost; never paste secrets.
- If a send is unresolved, re-run it with the same `--retry-key` or
  `agentboard chat resolve --msg-id <id> --action reconcile`; both search
  history by `msg_id` and never post. Only `--action retry` posts again (it
  reconciles first and records `manual_retry_possible_duplicate`); `--action
  abandon` gives up. `chat status --msg-id` and `chat sends` show metadata
  only, never bodies.

## Universal captain intake

For EVERY captain-bound approval, merge, policy, credential, scope or ask-user
question, MUST follow [the canonical decision protocol](../agentboard/SKILL.md#every-captain-question-is-a-decision):
run read-only doctor, file `agentboard decision request TASK`, notify the
configured coordinator with the returned decision ID, and stop dependent work.
Non-gates need no gate/findings file; ask-user gates retain verbatim findings.
Never include secret contents. A CLI/API-unavailable note is an unfiled ask
without authority or a claim hold. Read the canonical answer, apply, renew and
ack; do not infer permission from a wake or pick up another claim while waiting.
