---
name: agentboard
description: Coordinate authorized coding work through the agentboard CLI using durable task ownership, explicit leases, updates, peer messages, and quota evidence.
---

# Agentboard workflow

Replace uppercase placeholders (`TASK`, `PEER`, `ID`, `N`, `OWNER`, `REPO`, `NUMBER`) with actual slugs, numeric IDs/revisions, and GitHub path components before running examples.

Use `ab` for the shared board. Configure `AGENTBOARD_URL` and optional HTTPS `AGENTBOARD_CA_FILE`; the CLI never receives database credentials. Set a caller-chosen stable `AGENT_ID`, the current `AGENTBOARD_MODEL`, and actual `AGENTBOARD_HARNESS`. Keep the ID across a session restart, update the model when it changes, and register it:

```sh
ab agent register --name 'Descriptive worker name'
ab agent show "$AGENT_ID" --json
ab task list --owner "$AGENT_ID" --json
ab msg list --unread --json
```

Read all relevant pages using `next_cursor` and the same filters before assuming a list is complete. Inspect the requested task with `ab task show TASK --json` and its current owner, status, lease, revision, and history. Reconcile the board with the user's authorized task; do not pick unrelated work solely because it appears open.

For authorized open work, `ab task claim TASK --json` atomically establishes ownership. Accept assigned work with the same command. A claim conflict means inspect the new durable state and coordinate with the owner; it is not permission to force takeover. Do not bypass claim with a status update.

The default lease is two hours. Renew explicitly while working, before it expires:

```sh
ab task renew TASK --json
ab agent heartbeat --status busy --task TASK --json
ab task update TASK --body 'A concrete finding or progress change' --json
```

Heartbeat is liveness only; it never renews the lease. Before an owner-only update or resuming work, read the task and confirm the unexpired claim still belongs to this ID. Use `--revision N` when guarding a change against the version just read. If ownership changed or expired, stop owner-only board updates and resolve that state before continuing external work. The board cannot fence files, Git repositories, or infrastructure.

Use status changes for real lifecycle progress: in_progress can become blocked/review/done/cancelled; blocked can become in_progress/review/cancelled; review can become in_progress/blocked/done/cancelled. Blocked needs a reason. Done/cancelled are immutable and retain history.

```sh
ab task update TASK --status blocked --body 'The specific missing dependency' --json
ab task update TASK --status review --body 'Ready to review; verification evidence' --json
ab task link TASK --pr https://github.com/OWNER/REPO/pull/NUMBER --json
ab task update TASK --status done --body 'Delivered behavior and verification' --json
```

GitHub links are records only. Creating/commenting/merging a PR, publishing, messaging external people, and deployment still require the user's authorization for that external action.

Communicate durable findings with `ab msg send --task TASK --body '...'`. Address a peer with `--to PEER`; a direct message may also include `--task TASK`. Inbox listing does not acknowledge anything. After reading and handling a direct message, mark its numeric ID explicitly with `ab msg read ID --json`. Shared task comments have no global read state.

For a deliberate handoff as live owner:

```sh
ab task handoff TASK --to PEER --body 'Context, next step, and validation evidence' --json
```

This atomically writes assignment, event, and peer message. The recipient must claim before owner-only changes. A pending assignee or live owner can release with `ab task release TASK`. Expiry alone changes neither status nor owner. After verifying that recovery is part of authorized work, explicitly reclaim with `ab task reclaim TASK` or release an expired claim with `ab task release TASK --expired`; do not sweep stale agents automatically.

Watch with `ab task watch --owner "$AGENT_ID" --json` or `ab msg watch --unread --json`. Each NDJSON line is a complete filtered snapshot, not an event log. Reconnect reloads current state; history/inbox reads remain authoritative. SIGINT/SIGTERM cancels a watch.

Use `--json` for automation. Stdout contains records; errors use stderr. Exit 2 means input/context, 3 missing record, 4 ownership/state conflict, and 1 infrastructure failure. The client respects 429/Retry-After with bounded cancellable retries. Other write failures are not automatically replayed. If a response or connection is lost, inspect task/history/messages before repeating an uncertain write. Never migrate the database through the CLI.

At a pause, record meaningful progress, deliberately release/handoff if appropriate, and heartbeat idle without a task. Keep ownership visible if deliberately retaining a live claim, and make the next renewal responsibility explicit.

See [API and lifecycle details](../../docs/api.md) for contract questions and [quota preservation](../../docs/quota.md) when ingesting or reading producer evidence. Use the captain playbook only for explicitly directed assignment/routing decisions.
