# Proposal

## Why

Captain routing currently relies on shared-context notes and display names to keep reserved or unavailable seats out of new work. Persist that policy and enforce it at the server so a CLI, worker, or future MCP caller cannot accidentally bypass it.

## What Changes

- Add audited availability policies for an exact agent or a harness/model selector: active, reserved, and out_of_service, with a reason and optional out_of_service expiry.
- Resolve exact-agent overrides before harness/model defaults, keeping every existing agent active when no policy exists. Expiry restores active and records the system action.
- Require the existing verified captain capability for policy writes and reserved named-assignment grants; a delegated coordinator uses that capability. Actor headers remain attribution only.
- Refuse reserved self-claims of open/pool work and out_of_service claims or assignments. Preserve current leases, owner progress, renewal and receipt/recovery paths.
- Gate new worker reservations and expose eligible routing through the roster. Add explicit task-order messages/broadcasts that exclude non-active recipients while ordinary coordination messages remain available.
- Show effective state, policy source, reason and expiry in Agents UI and agent list/show JSON. Add captain-authorized API/CLI controls.
- Deliver remote executable proof, an OpenSpec review and Archify documentation through a native no-mistakes PR. No production policies are seeded by this change.

## Capabilities

### New Capabilities

- `agent-availability`: Durable policy resolution, authorization, expiry, new-work admission and observable routing eligibility.

### Modified Capabilities

None: the main spec inventory is currently empty; the existing registry and cooperation planning artifacts remain in their separate in-flight changes.

## Impact

Ash/Postgres availability policy and task assignment provenance, Board operations and reads, worker reservation/routing, message API/CLI, agent API/CLI and Agents LiveView. A compatible migration starts with no policies. Existing integrations continue to use central task APIs; there is no separate MCP server in this repository. Existing captain bearer/session authorization is reused, with no new credential type.
