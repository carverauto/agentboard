# Codex worker sessions

Status: proposed; captain approval is required before implementation.
Tracking: [GitHub #52](https://github.com/carverauto/agentboard/issues/52).

## Why

The shipped host runtime can bind Pi and Claude native adapters, but a Codex
session cannot yet participate in automatic worker delivery. Add one narrowly
proven Codex profile while preserving the existing server reservation, fencing,
receipt, and recovery contracts.

## What Changes

- Add the opt-in `codex-app-server-v1` adapter for a dedicated, exclusively owned
  Codex app-server stdio session. Bind its exact native thread ID and a fresh
  adapter generation to a captain-provisioned worker and server binding epoch.
- Deliver frozen work only in an eligible idle session through a serialized
  native turn-start boundary. Work arriving during a turn remains pending.
- Expose explicit check-in and exact-ID receipt tools. Check-in returns its
  explicit result; it does not automatically augment unrelated tool output,
  consume a staged frame, or acknowledge work.
- Distinguish connector health, native identity/readiness, pending approval,
  input ownership, uncertainty, and model heartbeat. Unknown proof disables
  automatic delivery with a concrete reason.
- Require remote acceptance, isolated actual Codex conformance, packaged
  server/host interoperability, and an approved one-worker canary before rollout.

Existing interactive Codex/Herdr panes remain manual. Herdr automatic delivery
stays disabled unless a separate installed native path proves atomic expected
session plus confirmed-empty composer validation at submission. This proposal
does not claim such a path. Claude/Grok/Muse adapters and fleet activation are
outside this slice.

## Capabilities

### New Capabilities

- `codex-worker-sessions`: explicit Codex enrollment, exclusive native input,
  idle delivery, exact receipts, fenced health/recovery, and rollout evidence.
  These specialize the existing in-flight `align-agensh-worker-runtime`
  harness-adapter requirements; they do not replace their shared safety rules.

### Modified Capabilities

None. There are no archived capabilities under `openspec/specs` at this revision.
The existing in-flight worker-runtime proposal remains unchanged.

## Impact

After approval: Go worker configuration/adapter allowlists and installer,
a supervised native bridge, scoped dynamic tool handlers, documentation,
and remote integration acceptance. Worker API protocol 1 and database schema
remain unchanged. No new credentials, API endpoints, global hooks, terminal
typing, shared-daemon restart, or migration are required by this design.

The review explicitly asks whether a dedicated app-server profile is the desired
first slice. Approval authorizes implementation, not production enrollment or
activation. Requiring existing interactive panes instead would require a revised
proposal and fresh native boundary proof.
