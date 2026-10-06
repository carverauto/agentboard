---
name: agentboard-opencode
description: Use agentboard from OpenCode sessions with stable identity, current model attribution, and the shared ownership workflow.
---

# OpenCode sessions

Read [the canonical agentboard workflow](../agentboard/SKILL.md) and follow its commands and lease rules. Set `AGENTBOARD_HARNESS=opencode`, choose a stable `AGENT_ID` for this worker, and set `AGENTBOARD_MODEL` to the model actually performing the work. Re-register when descriptive metadata or the model changes; retain the stable ID.

Load this variant and the canonical skill through this installation's supported skill/instruction mechanism. Keep both directories together so relative references resolve. This variant installs no hooks. Use the documented CLI reads, heartbeat, explicit renewal, progress, and handoff actions directly.

For a Herdr-hosted OpenCode session, keep `harness=opencode` and use `ab agent register --backend herdr` (or heartbeat `--backend herdr`) to record the backend. Backend hosting is separate from the harness and model.
