# Dormant fleet loadouts (schema 35)

A FleetLoadout stores captain-owned desired seat configuration. It is a partial storage and API foundation for the broader fleet proposal, not acceptance or implementation of its automatic fleet design. Every response has `enabled: false`, `activation_state: "not_activatable"`, `catalog_status: "unverified"` and `host_status: "unverified"`.

Saving a loadout cannot start or stop a worker, enroll a host, create an identity or credential, claim or assign a task, or change task ownership. There is no activation command or flag. Role policy, automatic readiness and admission gates, a trusted model/effort catalog, host validation/reconciliation and Deck integration remain deferred.

## Authority and seat references

Both reads and writes require the existing verified captain capability. The CLI reads it from the protected `AGENTBOARD_CAPTAIN_TOKEN_FILE`; ordinary agent/coordinator tokens do not grant access. Do not put credentials in JSON, command arguments or task notes. These operations do not require self-reported actor environment values; persisted configuration authority and attribution come from the verified captain.

Each seat references an already registered, nonretired identity of kind `seat`, using its exact registered harness. A `(fleet_id, seat_id)` pair is permanently bound to its original agent and harness, even after removal. Reusing a removed seat ID for a different agent/harness conflicts; choose a new seat ID instead. The same seat ID may occur in another fleet. A registered agent may appear only once in the currently configured seats across all fleets. Historical bindings do not prevent moving an agent after removing its current configuration from the old fleet.

`scope_revision` references the agent's current, managed [seat scope](seat-scope.md) and must be at least 1. Scope arrays are not copied into desired configuration and cannot be edited through this API. Use `agent scope show` and the separate captain scope replacement command first. An unmanaged or stale scope reference conflicts. Saving dormant configuration does not mean that the broader proposal's role, required-label, enrollment, readiness or host gates have been met; existing manual scope semantics are unchanged.

`desired_host_id` is a syntactically valid slug only. `desired_model` and `desired_effort` are bounded unverified text, not selections from an authoritative catalog. Observed agent model/harness metadata is not a model/effort support catalog, and host IDs are not proof of enrollment or readiness.

## CLI

Read the loadout and the referenced scopes before preparing a full replacement:

```sh
agentboard fleet loadout show example-fleet --json
agentboard agent scope show codex-example-security --json
```

For a new fleet and an existing agent whose current managed scope revision is 1, save this as `loadout.json`:

```json
{
  "revision": 0,
  "idempotency_key": "example-fleet-initial-1",
  "seats": [
    {
      "seat_id": "security-1",
      "agent_id": "codex-example-security",
      "harness": "codex",
      "desired_host_id": "example-host",
      "desired_model": "example-model",
      "desired_effort": "example-effort",
      "scope_revision": 1
    }
  ]
}
```

```sh
agentboard fleet loadout set example-fleet --file loadout.json --json
```

The file must contain one UTF-8 JSON object, up to 1 MiB. The CLI rejects unknown, duplicate, missing, null and case-mismatched fields before making an HTTP request. Use all documented input fields; a `show` response includes projections and cannot be submitted unchanged. `enabled`, `seat_count`, scope arrays and observed fields are not accepted input. Both commands require schema 35 and offer no captain-authentication downgrade.

An empty `seats: []` replaces the desired configuration with zero seats. Removal does not retire identities, stop existing workers, revoke credentials, release leases, abandon task/decision responsibilities or change admission policy. Existing work remains the responsibility of its current owner under existing rules.

## HTTP replacement contract

GET and PUT `/api/v1/fleets/FLEET_ID/loadout` are captain-only. PUT requires exactly `revision`, `idempotency_key` and `seats`; each seat requires exactly the seven fields in the example.

- `revision`: expected current loadout revision, integer 0 through 2147483646. Zero creates only; success increments it once.
- `idempotency_key`: nonblank, control/format-character-free UTF-8 text, at most 128 bytes.
- `seats`: zero through 32 objects, with unique `seat_id` and `agent_id` within the replacement. `seat_count` is derived from this array.
- Fleet, seat, agent and desired-host IDs: lowercase letters/numbers/underscores/hyphens, starting with a letter or number, at most 128 bytes.
- `harness`: nonblank, control/format-character-free UTF-8 text, at most 128 bytes, without outer whitespace; must exactly match the registered harness.
- `desired_model` and `desired_effort`: nonblank, control/format-character-free UTF-8 text, at most 256 and 64 bytes respectively.
- `scope_revision`: integer 1 through 2147483647, matching the current managed canonical scope.

Text length limits apply before normalization. The server trims surrounding whitespace from the key, desired model and desired effort, and sorts seats by `seat_id`. It does not normalize harness spelling or infer missing fields.

An empty replacement returns this envelope:

```json
{
  "loadout": {
    "id": "example-fleet",
    "revision": 1,
    "enabled": false,
    "seat_count": 0,
    "seats": [],
    "activation_state": "not_activatable",
    "catalog_status": "unverified",
    "host_status": "unverified",
    "changed_by": "captain",
    "updated_at": "2026-10-09T00:00:00Z"
  },
  "replayed": false
}
```

For a nonempty loadout, `seats` contains exactly `seat_count` entries, each with all desired fields plus current canonical `scope`, `current_scope_revision`, `observed_model` and `observed_retired_at`. The saved `scope_revision` remains the revision approved in that replacement; GET projects newer current scope/observation data without changing the saved loadout revision. These projections describe current records and confer no activation authority.

A missing loadout reads as revision 0, zero seats, empty `seats`, null `changed_by`/`updated_at` and the same disabled/unverified state. No configuration is created by reading.

## Concurrency and exact retry

Use a new idempotency key for each intended replacement and preserve its expected revision. Two different keys attempting to replace the same revision cannot both succeed. A stale new replacement returns conflict and writes no configuration, binding, receipt or audit history. Reread and review before choosing a new replacement.

If a response is lost, resend the same fleet, key, expected revision and normalized seat data. An exact normalized retry returns the original committed snapshot with `replayed: true`, even if later loadout changes or current scope/observation changes have occurred. This intentionally returns historical projections; use GET to inspect current state. Reordered seats and surrounding whitespace in the normalized text fields do not create a different replacement. Reusing a key for changed revision or seat data conflicts. Keys are scoped to the fleet.

Unknown/missing/null fields, malformed IDs, invalid bounds, duplicate desired seats, unregistered/retired/non-seat identities and mismatched harnesses are invalid input (422). Unverified captain authority is refused (403). Revision/idempotency conflicts, stale/unmanaged scopes, changed historical bindings and an agent already configured in another fleet return conflict (409). API errors use the normal error envelope; CLI invalid input and conflict exit codes are 2 and 4.

Configuration, permanent bindings, exact-retry receipts and attributed immutable history commit together. Failed or replayed writes add no new mutation history. Scope updates, retirement and competing replacements are serialized at the storage boundary. This storage integrity does not grant runtime or external-system authority.
