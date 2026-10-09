# Store dormant captain-owned fleet loadouts

## Why

The broader FleetLoadout/host/Deck proposal needs durable desired configuration tied to canonical captain-managed seat scope. This slice adds bounded storage and read/full-replacement interfaces while leaving that proposed runtime design unaccepted and incomplete.

## What changes

- Captain-only schema-35 GET/PUT and CLI show/set for a dormant loadout.
- Explicit desired seats referencing existing seat identities and current managed scope revisions; no duplicate independently editable allowlists.
- Optimistic loadout revision, normalized exact-retry idempotency, permanent per-fleet seat bindings and cross-fleet configured-agent uniqueness.
- Derived seat count, current canonical scope/observed metadata projections and explicit disabled/catalog-unverified/host-unverified output.
- Atomic attributed immutable history and packaged CLI reference documentation.

## Non-goals

No activation or automatic matching, task assignment, worker launch/stop, host enrollment/reconciliation, identity/credential creation, authoritative model catalog, readiness/role enforcement, Deck integration, publication or deployment. Scope's existing manual admission and ownership-continuity rules remain unchanged. Saving or removing desired configuration does not change running workers or existing responsibilities. This is partial implementation only; broader epic acceptance remains open.
