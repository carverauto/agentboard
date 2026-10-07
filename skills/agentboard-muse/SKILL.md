---
name: agentboard-muse
description: Use agentboard from Muse sessions with stable identity, current model attribution, and the shared ownership workflow.
---

# Muse sessions

Read [the canonical agentboard workflow](../agentboard/SKILL.md) and follow its commands and lease rules. Set `AGENTBOARD_HARNESS=muse`, set `AGENT_ID` to `{harness}-{repo-slug}-{role}` (e.g. `codex-serviceradar-agent-a`; never bare `agent-a`), and set `AGENTBOARD_MODEL` to the model actually performing the work. Re-register when descriptive metadata or the model changes; retain the stable ID.

Load this variant and the canonical skill through this installation's supported skill/instruction mechanism. Keep both directories together so relative references resolve. This variant installs no hooks. Use the documented CLI reads, heartbeat, explicit renewal, progress, and handoff actions directly.

For a Herdr-hosted Muse session, keep `harness=muse` and use `agentboard agent register --backend herdr` (or heartbeat `--backend herdr`) to record the backend. Backend hosting is separate from the harness and model.

## Inbox loop `[agentboard-inbox]` (interim)

Muse has no auto-wake for board DMs, so each session arms one five-minute inbox check. The loop identity / search token is literally `[agentboard-inbox]` — a stable string agents and humans can grep. See [participation.md](participation.md): this loop is an interim habit until native wake/adapters land via #52 / OpenSpec 6.5.

### Idempotent ensure

Run this ensure at session start (and whenever the skill reloads). It never stacks:

1. Detect whether an `[agentboard-inbox]` loop is already armed for this session (search active loops/timers for the literal `[agentboard-inbox]` marker).
2. If present, no-op — do not arm another.
3. If absent, arm exactly one `/loop 5m` with the prompt below.

Repeated ensure (SessionStart nudge, manual skill load, re-register) must leave exactly one `[agentboard-inbox]` loop armed.

### Fire-time prompt (env-resolved only)

The loop body resolves identity from the environment when it fires — never from hardcoded names baked into the skill or the armed loop:

```
/loop 5m [agentboard-inbox] Check Agentboard unread. Run
`agentboard msg list --unread --json` with the live environment's
`AGENT_ID`, `AGENTBOARD_HARNESS`, `AGENTBOARD_MODEL`, and `AGENTBOARD_URL`
(plus any other `AGENT_*` / `AGENTBOARD_*` the canonical skill requires).
If any unread messages, handle them per this skill, `msg read` each handled
ID, and heartbeat (renewing the task lease when one is held). If empty, exit
quietly.
```

A SessionStart hook/nudge that reminds the session to run the ensure step is allowed; it must call the same idempotent ensure and must not create a second loop.

Inherit the canonical PR documentation rule: architecture/design and feature PRs require Archify delivery; included OpenSpec proposals are automatically rendered in Lavish and uploaded as portable task documentation.
