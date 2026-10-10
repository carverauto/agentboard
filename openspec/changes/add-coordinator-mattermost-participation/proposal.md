# Coordinator participation and a decision message round-trip

## Why

[Issue #80](https://github.com/carverauto/agentboard/issues/80) requires a reachable
coordinator ask-user inbox, interruption recovery and attributed thread replies.
Main `0ba0e26b7124e323859b85fab0c99b5a5943df1d` already has shared-bot chat,
exact-version worker inboxes and canonical board decisions, but its intentional
read-only coordinator credential cannot heartbeat, acknowledge messages or chat.
The existing generic chat retry lookup is bounded and does not supply the durable
uncertainty guarantee needed for a decision round-trip.

## What Changes

- Add an explicit, never-default `coordinator_participant` credential scope with
  immutable, nonempty channel grants. Preserve every existing coordinator token's
  read-only meaning. Bind the new scope to the configured, active coordinator.
- Permit explicit board reads, own heartbeat, own board-message acknowledgment
  and channel-granted chat. Do not grant task ownership, assignments, decision
  answers, settings, credentials, worker administration or captain powers.
- Add typed decision notification and reply operations. A notification retains
  one board-primary notice and one metadata-only Mattermost intent; a reply binds
  the exact recipient inbox ID/version to that canonical decision and verified
  thread. Chat remains evidence, never decision authority.
- Reuse protected, repository-scoped worker inbox reads/acknowledgments and their
  existing ingestion/recovery/receipt owner. Add no second inbox or polling loop.
- Persist one send intent and explicit submission uncertainty. Reconcile only
  actual shared-bot posts matching the pinned source, thread and payload hash;
  a bounded scan miss never permits a blind repost.
- Deliver enforced-auth, source-isolation, interruption/replay and packaged
  coordinator/worker acceptance tests without production activation.

## Capabilities

### New Capabilities

- `coordinator-participation`: explicit least-privilege credential and channel grant.
- `decision-conversation`: board-primary canonical notification, exact-source
  reply correlation and durable remote-write evidence.

### Modified Capabilities

None in the main specification inventory. Preserve the approved shared-bot
identity/root-reply contract in the [issue decision](https://github.com/carverauto/agentboard/issues/80#issuecomment-6048800273)
and `align-agensh-worker-runtime` without claiming its live/cutover gates complete.

## Impact and limits

Auth policy/token custody, a small Ash send-intent resource, decision/chat API/CLI,
source-correlation projection, packaged fixtures and operator/workflow guidance.
No schema number is reserved by this proposal. Before adding a migration, check
fresh main/open work for collisions with the parent; no atomic allocator exists.

No live token issuance, enrollment, credentials, channel membership, authentication
flip, deployment, scheduler installation, fleet activation or monitoring retirement.
Board mode and all sole-Mattermost readiness blockers remain unchanged. #149 tick,
#150/#156 native dispatch and #153 signed outbound coordination remain separate.
