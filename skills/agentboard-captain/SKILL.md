---
name: agentboard-captain
description: Help the captain inspect agentboard tasks, peer activity, and producer quota evidence and make explicitly directed assignment choices.
---

# Captain routing

Read [the canonical workflow](../agentboard/SKILL.md) first. Register a stable captain/shell/assistant identity with the current model and real harness so decisions have provenance.

Inspect relevant task state, peer roster, unread messages, and quota observations, following pagination. Compare available evidence for the actual task's scope and expected duration:

```sh
agentboard task list --status open --json
agentboard agent list --json
agentboard quota list --json
agentboard msg list --unread --json
```

Distinguish agent stale status from claim expiry. A fresh agent can hold expired work. Neither flag authorizes automatic takeover; inspect the task/history and coordinate deliberate release/reclaim or handoff.

Quota observations are human routing evidence. Respect account identity, producer state, observation age, untrusted/conflicting bounds, and scope-specific runway. Unknown or stale percentages are not capacity. A parent-share meter has no inferred remaining capacity. `through_reset` is not infinity or a common reset; `selection.spend_priority` is advisory and cannot override exhaustion/uncertainty. Prefer an explanation tied to the task's scope over a synthetic provider ranking.

Present explicit assignment choices with evidence and gaps. Assign when the user has directed the assignment or given a policy that covers it:

```sh
agentboard task assign TASK --to PEER --json
agentboard msg send --to PEER --task TASK --body 'Assignment context and requested next step' --json
```

Pending work still requires the assignee to claim. An assistant uses the same API/CLI contract; it does not become a mandatory AI coordinator or automatically launch workers. Board coordination does not grant external merge, publication, deployment, or messaging permission.

Route cross-agent artifacts the same way workers do: durable PR or HTTPS URL plus a Context FACT with URL and checksum, never a seat-local path. See [the canonical procedure](../agentboard/SKILL.md#sharing-artifacts-across-agents).

Collection, when explicitly requested and available, is `quota-axi --json --max-age 90s | agentboard quota push --json`. Agentboard does not refresh provider credentials. Inspect [quota semantics](../../docs/quota.md) before making decisions from unfamiliar fields.

For architecture/design or feature PR delivery, inspect `agentboard doc list TASK --json` and open the task's documentation links. Require the Archify source/HTML and validation evidence in the PR. When OpenSpec proposals are included, require automatic Lavish rendering and a portable `openspec` artifact linked to the change name. An external PR link alone does not complete visual documentation delivery.
