---
name: agentboard-codex
description: Use agentboard from Codex sessions with stable identity, current model attribution, and the shared ownership workflow.
---

# Codex sessions

Read [the canonical agentboard workflow](../agentboard/SKILL.md) and follow its commands and lease rules. Set `AGENTBOARD_HARNESS=codex`, set `AGENT_ID` to `{harness}-{repo-slug}-{role}` (never bare nicknames), and set `AGENTBOARD_MODEL` to the model actually performing the work. Re-register when descriptive metadata or the model changes; retain the stable ID.

Load this variant and the canonical skill through this installation's supported skill/instruction mechanism. Keep both directories together so relative references resolve. This variant installs no hooks. Use the documented CLI reads, heartbeat, explicit renewal, progress, and handoff actions directly.

For a Herdr-hosted Codex session, keep `harness=codex` and use `agentboard agent register --backend herdr` (or heartbeat `--backend herdr`) to record the backend. Backend hosting is separate from the harness and model.

Inherit the canonical PR documentation rule: architecture/design and feature PRs require Archify delivery; included OpenSpec proposals are automatically rendered in Lavish and uploaded as portable task documentation.

## Mandatory seat brief

Before editing, run `pwd -P` and `git rev-parse --show-toplevel`; both physical
paths must equal the expected leased disposable Treehouse worktree root in
`AGENTBOARD_SEAT_WORKTREE`. Run the source checkout's
`scripts/launch-seat --repo "$AGENTBOARD_SEAT_SOURCE" --check`. Keep this rule
in every subsequent ship brief. If the expected worktree is missing, the cwd is
the primary checkout, or any check fails: **STOP**. Do not branch, edit, commit
or push there. Report the isolation failure to the coordinator and mark your
owned task blocked only after verifying its live claim. For a primary launch,
report `launched in primary checkout, not an isolated worktree` on the task and
the status channel if one exists. Request a correctly
leased task worktree; do not guess a seat path or hardcode an agent ID.

Use Treehouse v2.0.1 through the repository's explicit seat launcher. A Herdr
backend does not satisfy isolation. Optional hooks are backstops only; this brief
and the launch-time cwd assertion remain required. Retain the lease through PR
review and green CI. The skill does not create a launcher, install hooks or enable
fleet dispatch merely by being loaded.

## Ask-user gates (Herdr-hosted): escalate to the coordinator

When running Herdr-hosted, a no-mistakes ask-user gate follows [the shared ask-user → coordinator procedure](../agentboard/ask-user-escalation.md): write the findings verbatim, escalate with `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID" --task TASK --body '...'` (env-resolved; `--body` is required; include `--task` when a board task is active), mark blocked, then end the turn — only if the escalation went through. Never pass `--yes`, and never prompt the Herdr human pane for ask-user authority.
