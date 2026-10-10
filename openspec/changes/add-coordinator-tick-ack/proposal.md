# Portable coordinator attention protocol

## Why

[#149](https://github.com/carverauto/agentboard/issues/149) needs one HTTPS
contract and a thin CLI through which any authenticated harness can inspect
judgment work and record its handling. Today the registered coordinator is a
specific immutable agent identity, and the existing coordinator bearer is
read-only. A portable protocol must not silently grant that bearer broader
authority or claim that server policy and native dispatch are finished.

## What Changes

- Add revision-1 `/api/v1/coordinator` tick, exact decision-source, ack and
  bounded own-heartbeat operations, with equivalent CLI commands.
- Return a non-consuming, count- and serialized-byte-bounded page of canonical
  open decision attention. Include exact source/version, task/requester,
  references and retained handling disposition. An escalated but unanswered
  decision remains visibly captain-pending.
- Record append-only, exact-version handling receipts in an atomic bounded
  batch. Identity/operation-scoped retry keys return the original receipt for
  identical normalized input and conflict for changed input.
- Introduce only an explicitly issued `coordinator_runner` credential scope.
  New operations require enforce mode and an actually verified bearer, even
  when legacy routes permit unauthenticated private-network use.
- Document truthful pagination, periodic restart-from-start, denied capabilities,
  current identity custody and the remaining server/native prerequisites.

## Capabilities

### New Capabilities

- `coordinator-attention-protocol`: portable non-consuming attention, exact
  source reads and append-only idempotent handling evidence.

### Modified Capabilities

None in the main specification inventory. Existing authentication, decision,
conversation and wake contracts retain their own semantics and ownership.

## Scope and Dependencies

This is a first decision-only foundation for #149/#161, not completion of the
#161 adapter rollout. #154 server policy is unfinished: items are explicitly
`policy_evaluation=not_available`, not purported auto-policy failures. #150/#156
native admission/delivery, #153 transport, #155 liveness and broader attention
sources remain independent work. No polling schedule or cutover is installed.

Preserve the configured coordinator ID and harness. Another product can
implement this wire protocol, but switching dot/Grok identities still needs a
later captain-controlled role-to-principal epoch handoff. Never share credentials,
rewrite the agent harness or change #206's pinned sender/recipient attribution.

## Impact

New server protocol/resource/controller, additive receipt storage and explicit
auth allowlist; thin Go commands; metadata/schema compatibility; contract,
concurrency, real PostgreSQL/HTTP/CLI and migration tests. The next logical
schema is a candidate only until a coordinated reservation is confirmed.

## Non-goals

Decision answer/recommend/supersede/apply; source acknowledgment; assignment,
claim/lease changes, task completion, worker or wake administration; chat sends;
policy/settings/credential administration by runners; leader election, shared
credentials, automatic takeover, webhooks, native dispatch, production setup or
retiring an existing routine. A handling receipt proves the caller recorded a
disposition; it does not prove a captain was contacted or any external effect.
