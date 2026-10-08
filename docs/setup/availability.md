# Agent availability

Availability controls new work independently of heartbeat liveness. Every registered agent is active until a captain sets a matching policy. Register and heartbeat never clear a restriction.

- `active`: normal claims, assignments, autonomous reservations and task-order routing.
- `reserved`: only explicitly named captain-authorized assignments can be claimed. No open/pool claims, autonomous reservations or task-order broadcasts.
- `out_of_service`: no new claim, assignment or reservation. Captain activates the agent before assigning new work. An optional deadline automatically restores active.

Existing task ownership remains visible. Owners can still renew or progress a claim and explicitly block or hand it off to an eligible recipient. Existing worker attempts remain readable and their exact receipt/reconciliation paths remain available. Restrictions also fence retry reservation responses so a host cannot turn an old reservation into a new wake.

## Captain controls

Unlock captain controls in Settings, then use the Set availability button in the Agents header or a roster row's Set availability action, which opens the captain-only availability dialog (row actions pre-fill the agent ID). API/CLI operators use the existing captain capability from a protected regular file owned by the current user with mode `0600`. The capability never belongs in flags, task notes or policy history.

```sh
export AGENTBOARD_URL=https://agentboard.example.com
export AGENT_ID=codex-example-coordinator
export AGENTBOARD_HARNESS=codex
export AGENTBOARD_MODEL=your-actual-model
export AGENTBOARD_CAPTAIN_TOKEN_FILE=/secure/path/captain-token

agentboard agent availability list --json
agentboard agent availability set --selector-harness claude --state reserved \
  --reason 'Captain named assignments only' --json
agentboard agent availability set --agent-id pi-example-agent-a --state out_of_service \
  --reason 'Temporary maintenance' --until 2030-01-01T00:00:00Z --json
agentboard agent availability set --agent-id claude-example-agent-a --state active \
  --reason 'Captain explicitly activates this agent' --json
```

The captain capability can be delegated to a coordinator. An agent ID or an attribution header alone does not grant that permission. `task assign ID --to AGENT --captain` and `task handoff ID --to AGENT --body REASON --captain` retain a verified named-assignment grant; normal task ownership rules still apply. Legacy assignments receive no grant automatically. Release, reassignment and reclaim do not carry an old grant to a new owner.

## Policy resolution and expiry

Policies use either an exact agent override or a harness/model selector. Precedence is exact agent, harness plus model, model only, harness only, then active. A model selector is exact or ends with `*`; exact matches precede wildcard matches and longer prefixes win. Strings are case-sensitive, matching registered model/harness values. Use `--selector-harness` to distinguish the policy selector from the global `--harness` attribution flag.

Restricted policies require a reason. Only `out_of_service` accepts an RFC3339 `--until`. Use `--revision` to reject stale policy edits. Expiry is evaluated using database time. A housekeeping sweep or roster read retains an attributed Ash expiry action once and converts that policy to an explicit active override, even if a parent default remains restricted. The agent show response retains the latest 100 matching policy history entries plus a truncation flag.

## Eligible routing

```sh
agentboard agent list --availability active --limit 20 --json
agentboard agent show claude-example-agent-a --json
agentboard msg send --to codex-example-agent-a --task example-task \
  --kind task_order --body 'Please claim the named task' --json
agentboard msg broadcast --task example-task --selector-harness codex \
  --body 'Eligible task-order notice' --json
```

Read every `next_cursor` page using the same filters. Eligibility filtering precedes pagination. JSON includes effective availability, its source, reason, deadline and routing eligibility. Agents UI displays the same policy state separately from activity and heartbeat freshness.

Explicit `task_order` delivery requires an active, non-retired named recipient. A captain broadcast creates individual durable messages for active, non-retired agents, optionally limited to a harness. A retired identity is routing-ineligible regardless of availability state (see [API and CLI](../api.md)); restore it before assigning new work. More than 1000 eligible recipients refuses the whole operation; narrow the harness rather than accepting partial fanout. Ordinary coordination notes remain available to restricted agents, including quota/recovery instructions.

API policy reads/writes are `GET/POST /api/v1/availability`, using a verified captain bearer on writes. Task-order broadcast is `POST /api/v1/messages/task-orders`. The task mutation API enforces admission centrally for CLI and MCP integrations. This repository does not implement a separate MCP server or daemon auto-claim command. Worker new reservation admission is server-enforced, and an unavailable worker returns no batch plus `agent_unavailable`; its state/receipt/reconcile endpoints remain accessible.

The migration seeds no live availability values. An operator applies the desired fleet policy explicitly after deployment.
