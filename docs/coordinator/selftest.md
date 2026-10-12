# Safe coordinator selftest

`agentboard coordinator selftest` is a portable, read-only diagnostic for
[attention protocol revision 1](protocol.md). It does not activate an adapter
or certify the full [coordinator role](role.md).

```sh
# Uses this agent's existing explicitly issued coordinator_runner credential.
agentboard coordinator selftest --json

# Synthetic local checks only: no credentials, configuration or API needed.
agentboard coordinator selftest --offline --json
```

The default command performs only public compatibility bootstrap
`GET /api/v1/meta`, followed by an authenticated
`GET /api/v1/coordinator/tick?limit=1&max_bytes=4096`. It checks API version 1,
schema 40 or newer, advertised coordinator revision 1, the tick revision,
returned coordinator identity against configured `AGENT_ID`, echoed bounds,
basic item identity/version/source-kind/status and pagination-envelope shape.
An item that cannot fit is a diagnostic failure; no source is skipped and no
larger query is silently substituted. Only the first page is sampled. A complete
page is not a stable snapshot or proof of full backlog traversal. The final
metadata response is limited to 16 KiB and the tick response to 4096 bytes on
the wire, before redaction. Both probes share a 20-second deadline. Existing
transport rate-limit retries can drain up to 64 KiB per retry; these are final
response budgets, not a total network-traffic budget. Other item
fields and policy outcomes are not a full conformance check.

Use the agent's own issued identity, model, harness and runner bearer. The
command never borrows another coordinator's credential, falls back to a captain
capability, enrolls an agent, changes configuration, starts a recurring schedule
or performs a migration. Default read checks may update ordinary bearer
last-use telemetry. They do not ack decisions or sources, stamp heartbeat,
renew leases, change roster/liveness, contact a captain or dispatch workers.
No canonical source prose is fetched.

## Reports and exits

Both modes run synthetic ack parsing, validation and normalization fixtures
through the same local helpers used by `coordinator ack`. This proves only
local behavior. It creates no receipt and does not exercise server atomicity,
replay, source freshness, concurrency or external delivery.

`--json` returns report version 1:

```json
{"report_version":1,"mode":"offline","status":"WARN","checks":[{"name":"local_ack","status":"PASS","detail":"Synthetic parser, validation and normalization fixtures passed; no request or receipt was created."},{"name":"live_protocol","status":"WARN","detail":"Not checked: offline mode uses no credentials or network."}]}
```

This abbreviated example omits the always-present warnings described below.
Without `--json`, the command emits the same checks as human-readable lines.
Report statuses are `PASS`, `WARN`, or `FAIL`. Detected failures produce an
overall `FAIL` and exit 1. Usage/flag errors retain ordinary CLI exits. `WARN` exits zero and means the tested subset
completed with known unverified scope, not operational readiness. No current
run can produce overall `PASS`: `native_schedule`, `native_admission`,
`delivery`, `received_handled`, and `activation` always remain `WARN`.
Offline success does not establish any live API access.

A successful live sample adds `metadata` and `authenticated_tick` passes and a
`pagination` warning. A failed prerequisite stops dependent requests. Neither
server error bodies nor returned IDs, cursors, versions, source prose, secrets,
credential paths or connection URLs are included in reports. A response reflecting a configured
credential is rejected, rather than silently repaired by redaction. Diagnostic error
text is fixed; investigate configuration privately. Do not add secrets to
command arguments or paste credential files into reports.

## Operator next steps

A failure requires fixing the named prerequisite and rerunning the command;
it does not authorize credential rotation, deployment, or a role handoff. A
warning means that separate evidence is needed for that capability. Native
schedule admission, captain delivery and received-versus-handled evidence must
come from the actual harness/adapter and authenticated live receipts. This
command does not inspect that evidence or award a persisted conformance badge.
See [the adapter capability matrix and conformance checklist](role.md),
[the protocol's receipt and identity limits](protocol.md), and
[decision-policy rollout requirements](../decision-policy.md).
