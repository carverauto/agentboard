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


## Build

Bazel + BuildBuddy from day one (same remote-exec pattern as ServiceRadar / Contour).

1. Install [Bazelisk](https://github.com/bazelbuild/bazelisk) (this repo pins `.bazelversion`).
2. Copy credentials (gitignored):

   ```bash
   cp .bazelrc.remote.example .bazelrc.remote
   # edit .bazelrc.remote — set x-buildbuddy-api-key
   ```

3. Build / test **only** with remote execution:

   ```bash
   ./scripts/bazel build //cmd/ab:ab
   ./scripts/bazel build //:all_placeholders
   # or: bazel build --config=remote //cmd/ab:ab
   ```

**Do not** compile on the shared Mac (`go build`, `mix compile`, or bare `bazel` without `--config=remote`). BuildBuddy workflows use `--config=ci` (see `buildbuddy.yaml`).

## Deploy

Target: **farm01** Kubernetes. Layout under `k8s/`:

| Piece | Manifest |
| --- | --- |
| Namespace `agentboard` | `k8s/base/namespace.yaml` |
| CNPG `Cluster` `agentboard-db` | `k8s/base/cnpg.yaml` (dedicated cluster, DB/role `agentboard`) |
| ConfigMap | `k8s/base/configmap.yaml` |
| Dashboard Deployment + Service | `k8s/base/dashboard.yaml` |
| Schema migration Job | `k8s/base/migration.yaml` |
| farm01 overlay | `k8s/overlays/farm01` (`local-path-cnpg`, internal `PHX_HOST`) |

Out-of-band secrets (not in git): `agentboard-db-credentials`, `agentboard-app`, `agentboard-registry`.

```bash
kubectl kustomize k8s/overlays/farm01
# Prefer an Argo CD Application; do not apply destructive changes from a gate worktree.
```

v1 is trusted-internal only (no auth). No NATS in the deploy path.

Full requirements, schema sketch, non-goals, and open questions: **[PRD #1](https://github.com/carverauto/agentboard/issues/1)**.
