# Coordinator protocol implementation checkpoint

## Scope and custody

Implemented the explicit user-directed, decision-only #149 foundation in a
separate disposable assistant-VM worktree based on main
`4850aecc3207744d216c32c7e177b1bc0ef8e121`. The OpenSpec proposal was prepared
before product edits. Physical cwd and Git top-level were verified.

The parent checked historical #149 custody and authorized this bounded code
slice without representing the old board assignment as transferred. No board
claim/update, worker contact, credential provisioning, live setting change,
deployment, schedule, push or PR operation occurred. #150's parked owner and
all native dispatch work remain separate.

Schema 40 / `20261008004000_coordinator_handling.exs` is a collision-checked
candidate, not an atomic allocation: #168's reservation ledger is unfinished.
The parent must recheck main, competing work and migration inventory before
publication. This checkpoint does not complete #161 or its Phase 1A gates.

## Implemented behavior

- Explicit `coordinator_runner`, preserving existing scope/default/grant behavior
- Revision-1 protected tick, exact decision read, atomic ack and own heartbeat
- Count plus complete serialized-envelope byte bounds and strict cursor/query input
- UTC-canonical source hashing/cursors and restart-from-start for late commits
- Immutable normalized retry batches/members with database completeness guards
- Exact-version escalation retained independently of latest handling disposition
- Source/task/credential/identity checks with compatible task/agent/FK lock order
- Thin CLI, mixed-disposition JSON, no-I/O ack dry-run and explicit capability preflight
- Generic protocol/scope/identity documentation and corrected adapter matrix

## Verification completed in the disposable VM

- Go CLI/client/config unit and race suites; `go vet ./...`.
- Full ExUnit: 208 tests, zero failures; focused coordinator contract: 7 tests.
- Production Phoenix release assembly using the repository-pinned toolchain
  and existing built assets. Integration Go binary used `-buildvcs=false`
  because default VCS stamping failed in the linked-worktree execution context.
- `coordinator_protocol_test.py`: packaged HTTP/Go CLI plus normal-role
  certificate-verified TLS PostgreSQL. Checks include exact metadata/body/CLI
  parity, byte/count boundaries, invalid/ambiguous cursors/query/JSON, late
  commits, Unicode source size, unchanged source/liveness/audit on reads,
  mixed atomic receipts, concurrent matching/conflicting keys, historical
  retries, canonical answer/withdraw/supersede, owner/revision changes, real
  source and credential/retirement/config/mode/model lock races, all old-scope
  denials, own heartbeat and 24 contending old/new heartbeat calls, immutable
  SQL/audit guards and rejected post-commit batch expansion.
- Timezone coverage: `America/Chicago` fixture plus production-domain reads in
  `Pacific/Honolulu` and `Asia/Kathmandu`; identical versions and valid traversal.
- `coordinator_upgrade_test.sh`: actual Ecto migration boundary 39, then 40;
  separate normal-role TLS cases retain markers 9000 and 40 respectively.
  Exact snapshots preserve all 96 pre-existing public tables (11 populated,
  21 rows), legacy scopes and participant grants, source/history/conversation
  evidence, no runner promotion/backfill, channel constraints, incomplete-batch
  rollback, immutable evidence, repeat migration and refused down migration.
- Existing packaged `decision_requests_test.py` and
  `decision_conversation_test.py` pass without changing their behavior.
- Formatting and Git whitespace checks pass. Python/shell test syntax checked.

The existing broad `release_schema_test.sh` also passes. Its 13 full-migration
expectations now target 40 while partial boundaries remain unchanged. The VM
adapter changed only fixture/archive/runfiles setup and the unavailable Unix
database-client socket to the same verified-TLS TCP fixture; assertions were
unchanged apart from those intended marker updates. Coverage includes legacy
schema 4/7/10/14/15/20/22/24/31, pending backfill, scope/fleet/triage/pin/metadata/
participant upgrades and higher-marker 99 preservation.

## Failures found and corrected

- A non-UTC database timezone made the first page generate an invalid next
  cursor and made source digests timezone-dependent. Source selection now pins
  transaction-local UTC before hashing and output; cross-zone regressions pass.
- Malformed cursor timestamp types raised before validation, and year 0000 was
  accepted by Elixir but not PostgreSQL. Type/syntax/range checks now reject both.
- Plug could collapse nested/array query keys into a valid scalar. Raw decoded
  query keys must now be an exact unique member of the closed scalar allowlist.
- Lock review found a legacy heartbeat task-FK inversion. New task locks use
  `NO KEY UPDATE`, which still excludes canonical writers but permits their
  required `KEY SHARE`; concurrent old/new heartbeat proof passes.
- Escalation projection now uses any exact-version escalation, so later
  reviewed/deferred evidence cannot hide an unanswered captain-pending source.

## Explicitly unavailable or unrun

- Full `go test ./...` reaches the existing native worker fixture
  `TestStepConflictDispatchBeforeNativeIO` and fails its AF_UNIX socket creation
  in this sandbox. Root/CLI/client/config tests pass. No socket restriction was
  bypassed and this is not claimed as a full Go-suite pass.
- Remote Bazel `//:acceptance` is unrun: remote configuration/credentials are
  absent. No local Bazel fallback was invoked. All new tests are wired into
  the remote acceptance targets for publication-time execution.
- OpenSpec, Archify and Lavish executables/installed skills are unavailable.
  Text proposal/protocol documentation was reviewed; no tool validation,
  generated diagram, browser/perceptual check or live review is claimed.
- No production or live dot/GrokBot/Herdr conformance, native acceptance,
  policy-engine screening, stable role-epoch handoff or exactly-once external
  effects are implied by these isolated tests.
