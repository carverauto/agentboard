---
name: agentboard-codex
description: Use agentboard from Codex sessions with stable identity, current model attribution, and the shared ownership workflow.
---

# Codex sessions

Read [the canonical agentboard workflow](../agentboard/SKILL.md) and follow its commands and lease rules. Set `AGENTBOARD_HARNESS=codex`, set `AGENT_ID` to `{harness}-{repo-slug}-{role}` (e.g. `codex-serviceradar-agent-a`; never bare `agent-a`), and set `AGENTBOARD_MODEL` to the model actually performing the work. Re-register when descriptive metadata or the model changes; retain the stable ID.

Load this variant and the canonical skill through this installation's supported skill/instruction mechanism. Keep both directories together so relative references resolve. This variant installs no hooks. Use the documented CLI reads, heartbeat, explicit renewal, progress, and handoff actions directly.

For a Herdr-hosted Codex session, keep `harness=codex` and use `agentboard agent register --backend herdr` (or heartbeat `--backend herdr`) to record the backend. Backend hosting is separate from the harness and model.

Inherit the canonical PR documentation rule: architecture/design and feature PRs require Archify delivery; included OpenSpec proposals are automatically rendered in Lavish and uploaded as portable task documentation.

## Ask-user gates (Herdr-hosted): escalate to the coordinator

When running Herdr-hosted, a no-mistakes ask-user gate follows [the shared ask-user → coordinator procedure](../agentboard/ask-user-escalation.md): write the findings verbatim, escalate with `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID"` (env-resolved; include `--task` when a board task is active), mark blocked, then end the turn. Never pass `--yes`, and never prompt the Herdr human pane for ask-user authority.
