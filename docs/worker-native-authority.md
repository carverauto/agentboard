# Durable advisory authority and exact callback bridge

Status: **default-off, unregistered integration library**. The server, CLI and
mapping exist; no native host loop calls them. Approval does not enroll a worker,
bind a session, mint a receipt credential, elect a wake owner, enable a profile,
initialize Codex or submit input. Muse's receiving runtime and host admission
remain separate integrations. Linux owner proof is not Darwin support.

This implements the `codex-durable-advisory-v1` contract: a pointer notice may
survive unload/resume and cause a later turn to consume tokens. It grants no
work authority. It does not represent a loaded native incarnation.

## Evidence boundaries

1. A captain explicitly approves immutable inventory: binary digest, exported
   experimental schema digest, pinned profile/version, exact Linux peer
   inventory, physical socket address, initialization permission, and one
   persistent top-level thread. The server records that operator decision. It
   does not claim to have measured the remote process or verified its socket.
2. A host-authenticated snapshot checks the approved document against current
   server enrollment, binding and eligibility. The enrollment revision remains
   the existing `enrolled_at` Unix microsecond value; binding epoch remains the
   existing server epoch. Session/pane handles are never native lifetimes.
3. `owner.Dial` verifies the actual connected Linux peer against the approved
   expected UID/PID/boot/start/image values, derives endpoint generation, and
   passes that exact socket to the reviewed Node client. Metadata-only thread
   inspection verifies the persistent top-level recipient. The snapshot never
   supplies a generation or substitutes for same-FD proof.

Neither a host capability report nor `InspectProcess` approves inventory.
Operator approval and host measurement are deliberately different steps.

## Storage and migration

Schema 42 adds immutable `cooperation_native_approvals` records and a current
approval pointer plus monotonic native authority revision on the existing
Binding. Existing bindings receive revision zero and no approval. Approval
history uses existing audit facilities; there is no delivery ledger, scheduler,
per-poll lease table or new enrollment identity system.

Approval IDs are immutable. Captain approval uses the current authority revision
as a compare-and-set precondition; the submitted enrollment and binding must
match authoritative state. Approval replacement creates a new record.
Retirement clears the pointer, retaining historical approval evidence.

Approval retry keys are retained per worker. An exact retry after its authority
was superseded conflicts and never reinstates it. Retirement keys are scoped to
their expected revision and the last retirement result; they are not a global
never-reuse namespace. Retiring an already-empty pointer is a recorded no-op and
does not increment authority revision. Repeating that exact current no-op is
idempotent; a stale expected revision cannot clear a later approval.

The migration is forward-only: old code would ignore the new fence. Downgrade
refuses instead of dropping approvals or silently discarding authority history.
Deploy a compatible release to roll back application behavior.

## HTTP contract

Every operation requires `x-agentboard-worker-protocol: 1`. Unknown fields,
duplicate JSON keys, unsafe numbers, conflicting identities and oversized input
fail closed. Manifest identity fields are at most 240 printable ASCII bytes and numbers are safe integers; recursive
sorted-key compact JSON without HTML escaping defines its SHA-256.

- `POST /api/v1/workers/:worker_id/native-approval`: existing captain capability;
  exact body `expected_authority_revision`, `idempotency_key`, `manifest`.
- `POST /api/v1/workers/:worker_id/native-retire`: existing captain capability;
  exact body `expected_authority_revision`, `idempotency_key`.
- `GET /api/v1/hosts/:host_id/workers/:worker_id/native-authority`: existing host
  bearer capability, exact enrolled host/worker, no query parameters. Receipt
  capabilities cannot read owner authority. Reads are non-consuming and
  `Cache-Control: no-store`; they do not call the state endpoint, expire attempts,
  dispatch, create credentials or write receipts.

The manifest contains exactly:

`manifest_version`, `id`, `worker_id`, `host_id`, `enrollment_revision`,
`binding_epoch`, `session_id`, `pane_id`, `socket_path`, `initialize_approved`,
`endpoint`, `recipient`, `peer`.

The endpoint, recipient and peer use the precise JSON fields in
[`owner.Approval`](worker-codex-owner.md). Endpoint generation must be empty.
Manifest version is 1, initialization is explicitly approved, and the endpoint
is pinned to Codex 0.162.0 / rust-v0.162.0 / durable advisory profile. No executable
path or loader selection is supplied by a server response.

Snapshot fields are `protocol_revision`, `authority_contract_revision`,
`worker_id`, `host_id`, `authority_revision`, `approval_id`, `manifest_sha256`,
`manifest`, `enrollment_revision`, `binding_epoch`, `permitted`, `reason_codes`,
`valid_for_ms`. Approved inventory can appear in a denied snapshot; its presence
does not grant permission. A permitted snapshot has an empty reason list and a
5000 ms lifetime. Denied snapshots have zero lifetime.

`AGENTBOARD_NATIVE_AUTHORITY_ENABLED` defaults to false. Enabling it is a separate
explicit operator/deployment action, never a side effect of approval. This gate
controls transport authority snapshots; it does not install a host, elect a wake
owner or enable native delivery. Isolated tests enable it only for invented
fixture workers, proving genuine server-produced positive snapshots.

## CLI and callable Go boundary

`worker native-approval validate --manifest-file FILE` validates and hashes
offline. `approve` additionally requires an explicit expected authority revision
and key; `retire` requires worker ID, expected revision and key. Both use the
existing protected captain token file. Neither invokes provision or bind.

`worker native-authority` reads using the selected existing host binding.
With `--manifest-file FILE`, it additionally verifies that the authenticated
snapshot can construct the expected owner approval, without dialing. This flag
does not accept denied authority or discover/update inventory.

The callable path is `API.FetchNativeAuthority` → `BuildNativeApproval` →
`owner.Dial` / `owner.Start`. `API.PollNativeAuthority` observes that one owner's
authority and calls its retirement callback. None is wired into worker run,
installation, host admission or native reconnect.

The Go API fetches through the existing authenticated client in one request,
rejects redirect origin switching, captures the request-start monotonic time,
and validates the returned body. A parsed file or a captain mutation response
is not a host-authenticated snapshot and cannot construct an owner approval.

## Bounded retirement, not an event stream

The owner deadline is anchored **before** fetching authority. Transit consumes
the five-second lease; retries and unchanged polls cannot extend it. Polling is
serial at one-second intervals. A changed revision, denial, identity/hash
mismatch, malformed response, authentication failure, timeout or cancellation
retires the owner. A response arriving after the original deadline cannot revive
it. There is no automatic renewal, reconnect or replay.

The authority revision covers approved inventory and enrollment/binding
lifecycle: approval replacement/retirement, bind, unbind, revoke, reenrollment,
and genuine pause/resume transitions. A pause followed by resume between polls
still changes the revision and retires the old owner on the next observation.

It is **not** a lossless revision of all fleet policy. Availability, roster,
seat-scope and global configuration are checked in each actual snapshot; a
persistent denial prevents permission and causes retirement when observed. A
brief deny/allow transition entirely between reads need not change this revision
or retire the old owner before its original five-second deadline. Stronger
permanent invalidation requires a reviewed admission integration, not a claim
that polling supplies an ordered event feed. Host #150 still owns its current
pre-submit admission; receiving-side server checks still enforce current source
and capability state.

Retirement shuts down the shared connected socket. It cannot retract bytes
already sent or remove a queued notice. A possibly-written add remains uncertain;
historical acceptance remains historical and the journal never replays it.

## Exact source callback mapping

`createWakeAdvisory({reservation, batch, manifest, serverOrigin})` accepts the
public immutable reservation and cooperation batch returned together by the
existing wake reservation. It compares their attempt/worker/epoch and the
approved durable descriptor. It retains the five callback fields unchanged:

`attempt_id`, `intent_id`, `reason_hash`, `payload_hash`, `recipient`.

That recipient is the complete frozen server recipient, including legacy
session/pane binding handles. It is not replaced by the latest worker state.
The separate durable recipient comes from the approved manifest, never a
fictional native lifetime. Dispatch generation comes from the actual batch.

The mapped typed notice adds `wakeCallback`; its source pointer identifies the
existing protected POST wake-resolve route, with the reservation payload hash as
its version. It does not invent a digest from the original source version.
No credentials, source prose, query string or arbitrary fetch destination appear
in the notice. The complete bounded frame and exact callback are retained in the
existing native journal before submission.

`parseWakeAdvisoryFrame` checks bounded canonical framing and returns the exact
callback only after comparing the receiving tool's trusted origin and retained
approved descriptor. `extractWakeCallback` performs the same checks on a parsed
typed notice. Parsing is not authorization. The receiving tool passes that
callback to the existing authenticated `wake-resolve` / `API.WakeResolve` using
its receipt capability. It must check the returned current actionable result
before protected work actions; received/handled receipts remain explicit.

`API.ResolveNativeNotice` composes strict typed-notice validation with the same
protected resolver. It does not fetch a notice-provided URI. Neither helper
intercepts arbitrary model filesystem/shell actions or claims to sandbox all
model behavior. Muse #41 must actually call the receiving bridge at its runtime
boundary; a printed recheck instruction is not an integration.

## Lock and verification contract

Authority transactions use admission then existing worker custody, rechecking
capability after custody. No provider, process or socket I/O occurs inside them.
Lifecycle invalidation occurs under existing worker locks; it never acquires
source/event election locks afterward. Reservation, resolution and receipt
transactions keep their existing source-first lock order.

Acceptance includes strict server/CLI role and CAS tests, real schema-42 packaged
PostgreSQL API tests, 41→42 upgrade preservation, pure cross-language manifest
hash/mapping tests, serial fixed-deadline polling tests, and the existing real
Linux Go→Node FD suite carrying the exact mapped callback. The packaged source
fixture maps an actual server reservation, extracts its callback and calls the
actual protected resolver without writing a receipt. These fixtures do not prove
installed Codex conformance, Darwin support, a deployed profile, or an integrated
Muse/#150 live host.
