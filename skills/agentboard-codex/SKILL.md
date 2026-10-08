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
the primary checkout, or any check fails: **STOP implementation**. Do not branch,
edit, commit or push there. For missing environment alone, use the canonical
[self-heal procedure](../agentboard/SKILL.md#recover-seat-environment-yourself):
`agentboard seat ensure TASK --repo SOURCE --root POOL`, apply its exports/cd,
then `agentboard seat check TASK --json` and repeat both physical-path checks.
This explicit recovery is permitted from the primary checkout; implementation
is not. No coordinator round-trip is needed for exports alone. A real lease,
ownership or isolation failure still requires a blocked task and coordination;
do not guess a seat path or hardcode an agent ID. For repositories without the
source-side launcher, the packaged `seat check TASK` is the equivalent gate.

Use Treehouse v3.1.2 through the repository's explicit seat launcher with an explicit v3 pool root (`--root` or `AGENTBOARD_SEAT_ROOT`). A Herdr
backend does not satisfy isolation. Optional hooks are backstops only; this brief
and the launch-time cwd assertion remain required. Retain the lease through PR
review and green CI. The skill does not create a launcher, install hooks or enable
fleet dispatch merely by being loaded.

## Ask-user gates (Herdr-hosted): escalate to the coordinator

When running Herdr-hosted, a no-mistakes ask-user gate follows [the shared ask-user → coordinator procedure](../agentboard/ask-user-escalation.md): on API schema20 create a durable decision with verbatim findings, notify the configured coordinator, and end the turn after delivery. On resumption read the canonical answer, apply it through the active no-mistakes gate, explicitly renew, then ack. For an older API/CLI, write the findings verbatim and escalate with `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID" --task TASK --body '...'` (env-resolved; `--body` is required; include `--task` when a board task is active), mark blocked, then end the turn — only if the escalation went through. Never pass `--yes`, and never prompt the Herdr human pane for ask-user authority.

Share cross-agent artifacts per [the canonical procedure](../agentboard/SKILL.md#sharing-artifacts-across-agents): durable PR or HTTPS URL plus a Context FACT with URL and checksum — never a Treehouse-slot-local path.
