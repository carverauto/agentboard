# Design

## Dormant authority boundary

Both reads and full replacements require verified captain authority. No caller-controlled field or CLI option can enable a fleet. The response always derives `enabled: false`, `activation_state: not_activatable`, `catalog_status: unverified`, `host_status: unverified` and seat count. The boundary stores configuration only; no scheduler or runtime consumer is added.

Each desired seat contains exactly `seat_id`, `agent_id`, `harness`, `desired_host_id`, `desired_model`, `desired_effort` and `scope_revision`. Fleet/seat/agent/host IDs are slugs. Harness is bounded exact registered metadata, not a fixed support catalog. Model/effort hints remain explicitly catalog-unverified, and desired host remains unverified. References must resolve to nonretired identities of kind seat and the current managed canonical SeatScope revision. Scope arrays are projected on reads rather than copied into configuration.

## Replacement and invariants

The loadout ID is a fleet slug; absence projects revision zero and no seats. PUT requires exact nonnegative expected revision, a bounded key and at most 32 seats. Unknown/missing/null fields and duplicate seat/agent entries reject. The server validates raw text bounds and control/format-character exclusions, trims model/effort/key and sorts by seat ID for normalized retry comparison.

An exact `(fleet_id, idempotency_key, normalized replacement)` retry returns its original response snapshot with replayed true, before current reference validation. A changed payload under the same key conflicts. New writes require the current revision, then increment it once. The atomic commit includes configuration, new immutable bindings, a durable response receipt and attributed audit history. Failed writes and exact retries add no mutation history.

A binding is immutable for `(fleet_id, seat_id)` and retains its original agent/harness even after removal. Agent uniqueness applies to currently configured seats across fleets, not to historical removed bindings. Policy serialization and agent locking protect scope/retirement/reference checks and competing replacements. GET projects current canonical scope/model/retirement observations; an exact retry returns its historical projection snapshot. Neither kind of projection is a trusted support catalog or readiness decision.

## Continuity and deferred design

Removing a seat changes only desired configuration. It does not stop a worker, release/transfer a lease, clear task or decision responsibility, retire an identity, revoke credentials or widen/narrow canonical scope. Existing admission and recovery paths continue unchanged.

The retained broader fleet proposal is not modified or accepted by this slice. Roles, nonempty required-label readiness, model/effort catalog production, enrollment/readiness/host gates, host reconciliation, automatic pickup and Deck remain deferred. Persisting dormant configuration neither relaxes those gates nor creates a legacy-route bypass claim.

## CLI packaging

`fleet loadout show FLEET_ID` and `fleet loadout set FLEET_ID --file PATH` require protected captain transport and schema 35. JSON input is locally checked before API probing. Supporting documentation is embedded, installed beside canonical and captain skills, declared in Bazel embed inputs and staged by Dockerfile.cli. Docker-context source staging verifies that missing embedded docs fail compilation; it is not an image build or runtime smoke test.
