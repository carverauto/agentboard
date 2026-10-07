---
name: agentboard-herdr
description: Use the shared agentboard workflow from Herdr-hosted sessions while preserving the actual underlying harness and model identity.
---

# Herdr-hosted sessions

Read [the canonical workflow](../agentboard/SKILL.md) and the variant for the actual underlying harness. Set worker `AGENT_ID` to `{harness}-{repo-slug}-{role}` (never bare nicknames like `agent-a`), set `AGENTBOARD_HARNESS` to that harness, and set `AGENTBOARD_MODEL` to its current model. Register with `--backend herdr`; heartbeat may refresh the same backend tag. Herdr is backend metadata, not a replacement harness or a model.

Load these files using the session's supported instruction mechanism. No hook integration or automatic worker dispatch is installed. Commands, explicit leases, inbox acknowledgement, and authorization boundaries remain those of the canonical skill.

## Ask-user gates: escalate to the coordinator, never the human pane

On a no-mistakes ask-user gate, follow [the shared ask-user → coordinator procedure](../agentboard/ask-user-escalation.md): write the findings verbatim, escalate with `agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID"` (env-resolved; include `--task` when a board task is active), mark blocked, then end the turn. Never pass `--yes`, and never prompt the Herdr human pane for ask-user authority — the coordinator (or captain via coordinator) is the only escalation path.
