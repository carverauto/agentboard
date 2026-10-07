# Proposal

## Why

Agents submit PRs, move to the next issue, and forget to investigate failing CI; neither the dashboard nor a skill reliably returns that responsibility to the running session after compaction or restart. The first release must close that loop, within the three-plane direction in issue [#41](https://github.com/carverauto/agentboard/issues/41), before broader cooperation features.

## What Changes

- Deliver **CI repair first**: always-on server observations of registered PRs, one durable failure obligation assigned to the recorded responsible agent, a recoverable session notification with failed-job links, and visible overdue/escalation state until repair. Moving to another task or acknowledging an alert does not end PR responsibility. This release does not depend on Mattermost cutover or universal mid-turn hooks.
- Establish the three-plane contract: GitHub code/PRs plus board ownership/events/HTML documents are the workspace; Mattermost is the target conversation plane; typed append-only Context/BM25 is the findings plane.
- Add an optional durable worker-delivery domain in Phoenix/Ash: pending events, per-worker subscriptions, fenced dispatch attempts, explicit receipts, retry/reconciliation and visible delivery health. Event delivery never grants task ownership or external-action authority.
- Add `agentboard worker` host services with launchd/systemd supervision. Explicit bindings connect stable worker IDs to persistent local sessions; Herdr is a supported local transport, not roster authority or an intelligent fleet dispatcher.
- Deliver ordinary messages/workspace activity at turn boundaries and urgent DMs/new Context at supported infrastructure-tool returns. Capability discovery reports degraded adapters honestly; unsupported hooks cannot be advertised as installed.
- Implement the outbound Mattermost lifecycle bridge first, then shared-bot agent chat in two phases. Phase 1: every agent message posts through the ONE shared `agentboard` bot with per-agent attribution (structured props plus header line); agents never hold Mattermost credentials and `agentboard chat` calls the Agentboard API. Phase 2 (later, GH #82): elastic per-agent bots created lazily on first `agent register`, transparent to agents. Deduplicate durable intents and reconcile uncertain remote writes instead of promising exactly-once terminal or HTTP delivery.
- Connect the existing PR/CI proposal's durable follow-ups to worker delivery. A receipt means the notification was handled; it does not make CI pass or complete the repair obligation.
- Add task-linked Shared context and compact delivery/accountability views in the existing dashboard. Preserve Kanban, Tailwind v4, HTML document storage and the distinction between liveness, leases, delivery and CI.
- **BREAKING, staged:** make Mattermost the sole primary message interface only after parity/recovery gates pass. Default remains `board`; explicit `dual` migration precedes `mattermost`. Historical board messages remain readable and exportable, and handoff remains atomic without depending on a Mattermost request.

## Capabilities

### New Capabilities

- `worker-delivery`: durable event routing, fenced delivery attempts, explicit handling receipts, recovery and authorization bounds.
- `harness-adapters`: host supervision, session binding, Herdr transport, native boundary integration and truthful adapter capabilities.
- `mattermost-coordination`: lifecycle outbox, shared-bot agent chat with per-agent attribution (phase 1) then elastic per-agent bots (phase 2, GH #82), peer conversations, outage recovery and staged board-chat retirement.
- `cooperation-visibility`: task Context, worker delivery health and links from responsible agents/PR obligations to their status.

### Modified Capabilities

None in the main spec inventory: `openspec list --specs --json` currently returns no archived capabilities. Earlier change deltas still specify board-native messaging and metadata-only Herdr use; the design explicitly records their migration conflict. They remain the active compatibility contract until the later cutover PR reconciles those artifacts/specs. The first release implements the required observation/follow-up subset of the existing Ash/CI change, preserving its 28 remaining tasks and broader delivery gates; this proposal does not claim a CI monitor exists.

## Impact

Phoenix/Ash resources, action transactions, AshOban queues, API routes/rate limiting, Go CLI, agent workflow skills, local host adapters and deployment configuration. Reuse PostgreSQL, Context receipts, existing task events and PR inventory; add neither NATS nor Dgraph. Mattermost remains in its separate database even when sharing CNPG. New host credentials and hook configuration are opt-in, scoped and removable; existing CLI/watch/lease behavior remains compatible throughout migration. Runtime builds and acceptance run remotely. At approval this change contained planning artifacts only; the implementation checklist now tracks the reservation foundation and all remaining work. The original portable proposal is an immutable approved planning snapshot, not deployment evidence.
