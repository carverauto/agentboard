# Proposal

## Why

Seats waiting for a captain decision currently rely on free-text task notes and relayed inbox messages; claims can expire before the answer arrives. A durable request makes the wait, authority, answer and resumption visible through one API contract.

## What Changes

- Add audited decision requests keyed by task and gate, retaining verbatim question/findings, options, recommendation, answer attribution and lifecycle timestamps.
- Provide API-only `decision request|list|show|recommend|answer|ack|withdraw`, stable oldest-first pages and server-computed wait/stale/lease fields.
- Atomically block owned tasks on request and deliver one task-tagged inbox answer, timeline event and frozen wake intent on answer; retain idempotency and rollback across the whole transaction.
- Protect claims while decisions are open or answered even past lease expiry; expose stale requesters. An explicitly authorized, audited supersede action releases outstanding holds before normal explicit reclaim (coordinator ruling799).
- Add a secondary Waiting-on-captain board panel and agent filter, with verified captain answer controls using the same domain action.
- Move escalation and harness overlays to durable requests and answer acknowledgment. Preserve a compatibility fallback against older schemas.
- Add schema 20 monotonically and remote behavioral integration proof. No Mattermost transport or production cutover.

## Capabilities

### New Capabilities

- `decision-requests`: durable captain decisions, ownership hold, answer delivery and resumption across API, CLI and dashboard.

### Modified Capabilities

None; this repository currently has no canonical specs under `openspec/specs`.

## Impact

Adds Ash resources/migration and a domain boundary. Integrates Board Operations/Transition/Reads and Task calculations, protected Phoenix routes, captain sessions, existing cooperation capture and API-only CLI schema guards. Updates escalation skills; remote packaged fixtures prove the complete loop, pagination, retries, authority and rollback. Wake adapter compatibility is being coordinated with #52; explicit fallback metadata avoids waking twice. Existing ordinary message, lease, historical receipt, and unavailable-owner semantics remain.
