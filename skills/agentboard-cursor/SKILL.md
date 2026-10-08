---
name: agentboard-cursor
description: Use agentboard from Cursor sessions with stable identity, current model attribution, and the shared ownership workflow.
---

# Cursor sessions

Read [the canonical agentboard workflow](../agentboard/SKILL.md) and follow its commands and lease rules. Set `AGENTBOARD_HARNESS=cursor`, set `AGENT_ID` to `{harness}-{repo-slug}-{role}` (e.g. `codex-serviceradar-agent-a`; never bare `agent-a`), and set `AGENTBOARD_MODEL` to the model actually performing the work. Re-register when descriptive metadata or the model changes; retain the stable ID.

Load this variant and the canonical skill through this installation's supported skill/instruction mechanism. Keep both directories together so relative references resolve. This variant installs no hooks. Use the documented CLI reads, heartbeat, explicit renewal, progress, and handoff actions directly.

For a Herdr-hosted Cursor session, keep `harness=cursor` and use `agentboard agent register --backend herdr` (or heartbeat `--backend herdr`) to record the backend. Backend hosting is separate from the harness and model.

Inherit the canonical PR documentation rule: architecture/design and feature PRs require Archify delivery; included OpenSpec proposals are automatically rendered in Lavish and uploaded as portable task documentation.

## Universal captain intake

For EVERY captain-bound approval, merge, policy, credential, scope or ask-user
question, MUST follow [the canonical decision protocol](../agentboard/SKILL.md#every-captain-question-is-a-decision):
run read-only doctor, file `agentboard decision request TASK`, notify the
configured coordinator with the returned decision ID, and stop dependent work.
Non-gates need no gate/findings file; ask-user gates retain verbatim findings.
Never include secret contents. A CLI/API-unavailable note is an unfiled ask
without authority or a claim hold. Read the canonical answer, apply, renew and
ack; do not infer permission from a wake or pick up another claim while waiting.
