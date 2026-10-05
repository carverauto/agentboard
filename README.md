# agentboard

Shared task board for a fleet of coding agents. **Pre-alpha** — nothing here is implemented yet. Design is tracked in [PRD issue #1](https://github.com/carverauto/agentboard/issues/1).

## Why (replaces Firstmate)

[Firstmate](https://github.com/carverauto/firstmate) put a **central AI coordinator** between the captain and every worker. That loop loses track after a few days, burns tokens reconciling other agents, and keeps “truth” in chat context and scattered on-disk logs.

**agentboard** flips that:

- **No central AI coordinator.** The human captain coordinates (with Claude, and optionally Grok Bot as an assistant — not as a mandatory fleet brain).
- **One shared board** every agent reads and writes, so each sees what the others are doing.
- Bookkeeping is **scripts + database**, not another LLM session.

## Architecture (planned)

| Piece | Role |
| --- | --- |
| **Postgres (CNPG)** | Single source of truth in the **farm01** Kubernetes cluster |
| **Phoenix LiveView** | Captain dashboard: kanban, agent roster, task timeline, messages, quota |
| **Go CLI (`ab`)** | Fast binaries agents call: claim, update, post, list, message, heartbeat, quota |
| **LISTEN/NOTIFY** | Live updates to LiveView and `ab --watch` — no NATS in v1 |

Trusted internal network: **no auth** in v1. Keep it simple.

## Core concepts

- **Agent IDs** — every agent registers a stable id others can address; heartbeats show liveness on the roster.
- **Tasks** — open → assigned → in_progress → blocked/review → done/cancelled; atomic claim; optional GitHub issue/PR links.
- **Updates** — every post stamps **agent id**, **model**, and **harness/client** (claude code, codex, pi, grok bot, herdr, …).
- **Messages** — agent-to-agent or task comments as board rows (not a separate bus).
- **Quota** — ingest [`quota-axi`](https://www.npmjs.com/package/quota-axi) snapshots so the captain/assistant can route work by remaining runway.

## CLI usage (planned)

```bash
export AGENTBOARD_DATABASE_URL=postgres://...
export AGENT_ID=codex-sr-1
export AGENTBOARD_HARNESS=codex
export AGENTBOARD_MODEL=gpt-6.1-sol

ab agent register --name "codex sr worker" --harness codex
ab agent heartbeat --status idle

ab task create --title "Fix Harbor pull" --issue https://github.com/carverauto/serviceradar/issues/5083 --repo serviceradar
ab task list --status open --json
ab task claim sr-5083-harbor-pull
ab task update sr-5083-harbor-pull --kind note --body "Reproduced on fresh clone"

ab msg send --to claude-captain-assist --task sr-5083-harbor-pull --body "Need digest list from registry"
ab msg list --unread

quota-axi --json --max-age 90s | ab quota push
ab quota list --json
```

## Roadmap

1. **MVP** — schema on CNPG, Go CLI (CRUD/claim/update/list JSON), read-only LiveView board + timeline  
2. **Live + messaging** — LISTEN/NOTIFY, `--watch`, DMs/comments, heartbeats + stale-claim UI  
3. **Quota + skills** — `ab quota push`, quota panel, shared + per-harness agent skills  
4. **Hardening** — claim TTL tuning, deploy docs; revisit JetStream only if fan-out demands it  

Full requirements, schema sketch, non-goals, and open questions: **[PRD #1](https://github.com/carverauto/agentboard/issues/1)**.
