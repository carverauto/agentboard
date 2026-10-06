---
name: agentboard-herdr
description: Use the shared agentboard workflow from Herdr-hosted sessions while preserving the actual underlying harness and model identity.
---

# Herdr-hosted sessions

Read [the canonical workflow](../agentboard/SKILL.md) and the variant for the actual underlying harness. Choose a stable worker `AGENT_ID`, set `AGENTBOARD_HARNESS` to that harness, and set `AGENTBOARD_MODEL` to its current model. Register with `--backend herdr`; heartbeat may refresh the same backend tag. Herdr is backend metadata, not a replacement harness or a model.

Load these files using the session's supported instruction mechanism. No hook integration or automatic worker dispatch is installed. Commands, explicit leases, inbox acknowledgement, and authorization boundaries remain those of the canonical skill.
