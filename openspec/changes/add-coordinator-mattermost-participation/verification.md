# Acceptance plan and evidence

Implementation base: `0ba0e26b7124e323859b85fab0c99b5a5943df1d` (schema 38).
Schema 39 / `20261008003900` was collision-checked against fresh main, open PRs
and retained work before implementation. It is a checked candidate, not an atomic
reservation. Parent scope review and independent contract review preceded product
edits. All credentials and service actions in the tests below are synthetic and
confined to disposable fixtures in the approved VM.

No production access, token issuance, enrollment, deployment, live configuration,
board assignment changes or cutover proof is included.

## Executed results (2026-10-10)

- Final combined release build and ExUnit: 201 tests passed after the one-shot
  transport, source/configuration binding and conservative reconciliation fixes.
- All Go packages passed with the race detector when skipping the existing
  `TestStepConflictDispatchBeforeNativeIO`, whose Unix socket bind is unsupported
  in this VM. The unskipped full run failed only at that environment limitation.
  Go vet passed. These checks were repeated after the fail-closed CLI capability
  guard; all typed commands require schema 39 and advertised boolean support.
- Final packaged typed round-trip fixture passed its 132 assertion sites. The
  fixture uses the actual HTTP API, CLI, release, real PostgreSQL and a synthetic
  shared-bot HTTP server. Its fenced RPC inbound-observer adapter is explicitly
  not native dispatch or a live Mattermost connection. Terminal-request,
  revoked-enrollment, duplicate-race and incomplete-history cases all passed.
  Fixture SHA-256: `da87036806dea00c61740957e630511577810dc4337f5cc183edbf31c8bc99b7`.
- Final combined-release packaged decision-request, participant API authorization,
  shared/elastic-bot conversation and coordinator shadow-triage regressions passed.
  Protected Mattermost inbox/WS/exact-receipt regression also passed against
  the final composite release, including exact handling and fenced wake recovery.
- Complete release-schema regression passed fresh schema 39 and legacy upgrades,
  including schema-38 coordinator credentials, immutable/default-empty grants,
  invalid-grant rejection, evidence preservation and higher marker 99 preservation.
  The VM wrapper uses its available TCP PostgreSQL fixture instead of Unix sockets.
- Independent static review found no remaining actionable blocker after the
  source/configuration, duplicate-proof and transport corrections.
- Remote Bazel aggregate and Docker-image workflows have not run: this VM has no
  configured BuildBuddy remote credentials. No local Bazel fallback was used.

The tested CLI SHA-256 is
`f0c6637fa19a8e4e468f4f99dd35e5969e8d7a524d69f43177603d9788622a87`.
Fresh origin/main and GitHub open-PR/migration reads at 09:09 UTC still showed the
same base, zero open PRs and 38 migration files, highest `20261008003800`.
A fresh retained-work check at 09:10 UTC found no competing candidate-39 owner.
This remains an observed collision check, not an allocation guarantee.

The acceptance matrix below distinguishes desired coverage from executed evidence.
Logical transaction/admission boundaries and accepted-response loss are exercised;
actual operating-system process-kill/restart at every boundary is not claimed.

## Enforced authorization

- Existing coordinator scope remains read-only; default issue/rotate never yields
  participant scope. Ordinary agent token cannot use the configured coordinator ID.
- New scope requires explicit captain issuance and nonempty immutable channel grant.
  Empty/unknown/duplicate/oversized grants and grants on other scopes are rejected.
- Participant may heartbeat only itself and acknowledge only its addressed board
  message; repeat acknowledgment preserves first attribution.
- Deny impersonation, other-recipient exact reads/list/watch, task claims/assignments,
  availability/settings/token administration and all captain decision mutations.
- Grant intersected with current channel policy and bot membership. Revocation,
  retirement, coordinator-ID change and verifier failure fail closed.
- A rotated/replacement grant lacking the retained intent's channel cannot read
  its receipt or trigger remote reconciliation. Four-byte Unicode boundaries keep
  the final attributed typed message within the inbound byte budget.
- Participant bearer cannot read/ack protected worker inbox; host/receipt capability
  alone cannot use the new participation endpoint. Off/observe cannot use typed API.

## Canonical round-trip on packaged API/CLI and real PostgreSQL

1. Synthetic requester owns a scoped task and opens a canonical decision.
2. Notify creates one board notice/one typed intent; dual mode adds no second legacy
   chat mirror and preserves ordinary board wake/shadow triage.
3. HTTP/WebSocket fixture records the shared-bot root with attributed props, then
   scoped coordinator catch-up finds the exact inbox ID/version/decision relation.
4. Protected source read leaves unread; participant sends an exact-source thread
   reply. Canonical answer/status, hold, lease and assignment remain unchanged.
5. Asking worker catches up and reads the reply, with its retained decision relation.
6. Each recipient explicitly acknowledges its own exact source. Retries preserve
   the first handling receipt and normal cooperation wake suppression.

## Adversarial source/authorization coverage

- Wrong worker, repository, channel, decision ID, root, source fingerprint or version.
- Human-forged/copy-pasted props and markers; wrong actual bot user; multiple matching
  remote posts. Deliberate shared-bot path despite an active elastic bot.
- Source edited at the same timestamp, deleted or inaccessible; revoked membership,
  service URL changed, coordinator changed, task reassigned or request superseded.
- Concurrent duplicate notify/reply; same key with changed body/source/decision.
- Inbound root observed before sender receives 201; correlation waits for verified
  receipt and never promotes arbitrary props into canonical source proof.
- Typed body mentions cannot create extra-recipient inbox rows, including before
  receipt verification. Human-forged markers do not suppress normal human delivery.
  Deferred exact metadata recovers through the existing inbound owner after the
  verified receipt arrives, including when history no longer contains the post.
- Failed transaction leaves neither a partial board notice nor partial intent.

## Interruption and replay coverage

- Crash before/after intent commit, before submission admission, after admission but
  before POST, after remote acceptance and before local receipt commit.
- Accepted-post/lost-response reconciles to one logical intent and verified post.
- Five-page budget miss, complete miss, 429, timeout and unavailable history remain
  explicit uncertainty; no repeated POST or invented successful receipt.
- Credential revoked while prepared; current authorization rechecked before POST.
  Retain admitted-request race semantics and no delayed queue authorization.
- Restart inbound owner, coordinator and worker checkpoint traversal. Recover
  retained exact versions without inventing old bodies or eliminating honest gaps.
- Reads/replies/turn completion never auto-ack; edited versions/other recipients
  stay pending. Explicit receipts never apply a canonical decision answer.
- Mattermost outage leaves the board notice/canonical decision usable. No fallback
  to another public channel, new coordinator, broad token or legacy mirror.

## Execution and publication gates

Use existing `agent_tokens_test.py`, `mattermost_inbox_test.py`,
`mattermost_wake_assertions.py`, decision fixtures and a focused packaged round-trip
fixture. Extend CLI and policy unit tests; run gofmt/vet, focused/full supported Go,
ExUnit, schema upgrade/preservation, existing inbox/conversation regressions and
repository aggregate gates. Every Bazel invocation must use remote configuration.
The approved disposable VM toolchain is usable without workstation builds; missing
remote BuildBuddy or native-socket capability is an explicit unrun gate.

Before any publication fetch/rebase fresh main and rerun affected final checks.
Record exact base/head, source tree, fixture logs and independent review. Do not
represent a controlled manual adapter as a live native pilot. No production
enrollment, scheduling, code deployment, scope issuance, AUTH_MODE/MESSAGE_MODE
change, sweep retirement or two-real-worker parity is part of this fixture.
