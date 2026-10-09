# Captain-managed seat scopes (schema 34)

Seat scope limits new task admission by registered agent ID. It is separate from availability, self-reported capabilities and cooperation enrollment. Only a verified captain can change it; an ordinary agent or coordinator credential cannot.

## Scope semantics

- `allowed_repos`: required nonempty list of explicit `owner/repo` names, canonicalized to lowercase.
- `required_labels`: every label must be on the task (ALL).
- `allowed_labels`: when nonempty, at least one must be on the task (ANY).
- Both label gates and repository match apply together. Extra task labels are allowed. Empty label arrays disable that gate. Labels are exact and case-sensitive; ASCII control characters are invalid.
- No policy displays **Unmanaged**: existing manual claims and explicit captain broadcasts retain compatibility. Unmanaged does not authorize future automatic pickup. Existing roster `routing_eligible` describes availability/retirement only, not a particular task match or auto-claim readiness.

A security-only seat should require `security`, rather than merely putting it among optional pool labels. There is no independent role model or role enforcement in this slice; no authority is inferred from names or capabilities.

## CLI

Use the existing protected `AGENTBOARD_CAPTAIN_TOKEN_FILE` for captain writes. Do not put credentials in command arguments or task notes.

```sh
agentboard agent scope show codex-example-security --json
agentboard agent scope set codex-example-security \
  --repo example/service --required-label security --revision 0 --json
```

A replacement sends complete arrays, not patches. Repeat flags for multiple entries; omit a label flag to send that gate as an empty array. Always read first and pass the returned revision. Revision 0 creates only. A stale write returns conflict, even for identical contents; reread before deciding whether to replace. After an uncertain response, read current scope before retrying. This preliminary API has no idempotency-key protocol. There is no delete/reset-to-Unmanaged command.

## HTTP API

GET `/api/v1/agents/AGENT_ID/scope` returns a `scope` object with `agent_id`, `state`, the three arrays, `revision`, `changed_by` and `updated_at`. Missing policy returns `state: "unmanaged"`, revision 0, empty arrays and null provenance. Agent list/show includes the same scope projection.

PUT the same URL with verified captain transport and all fields:

```json
{"allowed_repos":["example/service"],"required_labels":["security"],"allowed_labels":[],"revision":0}
```

Success returns the managed scope at the next revision. Invalid/missing/null fields, unknown keys, wildcards, empty repos and malformed repo names return 422. Lists are limited to 100 entries each; strings to 256 bytes. Missing agents return 404 on reads. Unauthorized writes return 403; stale revision and out-of-scope work return 409 using existing API error/CLI exit conventions.

## Admission and continuity

Scope applies centrally to claim, assign, handoff and reclaim, including captain assignments to reserved seats. The task must have a full canonical repo; nil or bare repository names cannot match a managed scope. Typed `task_order` messages require an explicit existing task; mismatched recipients reject. Captain broadcasts exclude mismatched managed recipients. Ordinary coordination notes continue to work.

Internal CI/rebase assignment uses the same guard and retains unrouteable work Open for captain routing. Editing an owned task's repository/labels cannot move it outside its managed owner's scope. Narrowing scope does not revoke a lease or prevent renewal, progress, release or receipt/recovery. A concurrent scope edit and admission serialize at the database transaction boundary; a previously admitted task remains owned.

Cooperation provisioning cannot exceed a managed seat's approved repositories. Narrowing does not modify existing credentials or subscriptions. Retired workers cannot reserve or replay a cooperation batch; state, receipts and reconciliation remain usable.

Agents UI shows actual Managed/Unmanaged scope and captain-only editing. Stale saves preserve the draft; close/reopen to review the current scope before replacing it.

## Boundaries

This is an additive issue #60 admission foundation, not complete FleetLoadout/host/Deck delivery. It starts no workers, adds no scheduler and enables no native wake. There is no separate MCP server; clients using the task API share its admission checks. Filesystem, Git publication and deployment permissions remain separate.

Future automatic fleet routing also needs explicit role, enrollment, readiness and host gates, plus the retained proposal’s nonempty required-label rule. Scope matching alone does not establish that eligibility. Optional allowed-label ANY is an additive restriction, never a replacement for required-label ALL. Future FleetLoadout integration must reference/update the same authority and fence fleet enrollment from legacy-route bypass.
