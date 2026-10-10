# Codex native queue transport core

Status: **unregistered, fixture-tested candidate**, not a live worker adapter.
The code lives in `internal/nativequeue/codex/`. No serve, worker host, installer,
configuration allowlist or wake/admission path imports or activates it. It has
no executable entrypoint and starts no native process. The existing exclusive
`codex-app-server-v1` bridge remains unchanged, pinned to 0.160.1 and ephemeral
threads. This candidate profile is separately named `codex-native-queue-v1`.

## Evidence and limits

The protocol source pin is **`rust-v0.162.0`**. An installed CLI reporting 0.162.0
and advertising `queue --thread` is only inventory. The actual server version,
experimental schema/export, profile, native queue behavior and installed native
conformance remain unverified. Synthetic fixtures cannot establish these facts.
No actual Codex session, shared daemon, composer, approval or credential was used.

Release-pinned source:

- [Protocol structs](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs): `thread/queue/add` takes `threadId`, `input`, `clientUserMessageId` and returns `queuedSubmission` with `id`, `input`, `clientUserMessageId`. There is **no response threadId**. Exact request-ID correlation, the frozen request thread, and the negotiated endpoint/recipient incarnation supply that fence.
- [Queue processor](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server/src/request_processors/thread_queue_processor.rs): list uses decimal offset cursors and can shift as other clients edit the queue; native admission rejects ephemeral and certain subagent targets. This library conservatively accepts only explicitly verified persistent top-level recipients.
- [Queue service](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/ext/queue/src/service.rs): adding is effectful and can wake an idle loaded thread. It starts a turn before deleting an item, leaving a crash interval. Queue absence is never a received/handled receipt.
- [Queue storage](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/state/src/runtime/queued_items.rs): every enqueue creates a new UUID; client message IDs are correlation, not native deduplication.
- [CLI queue path](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/tui/src/session_queue_commands.rs): queueing uses shared-server discovery. This library neither invokes the CLI nor implements discovery or fallback.

No exactly-once delivery or execution claim is made.

## Injected-client contract

`createCodexQueueTransport` accepts `{client, endpoint, recipient, journalDir}`.
The caller must already have negotiated and explicitly verified the real
endpoint. This module supplies no production client. The trusted client must:

- Provide synchronous `identity()` returning exactly `{endpoint, recipient}`.
- Send a frozen `{id, method, params}` once via `request(request)` and return the
  raw correlated JSON-RPC response `{id, result}` (optional `jsonrpc: "2.0"`).
- Never retry, redirect, switch endpoints or reopen a daemon internally. Bound
  raw wire input before decoding. Update identity immediately on retirement.
- Prove the recipient incarnation from enrollment/native lifecycle, rather than
  treating a caller's arbitrary string or a thread name as proof.

The exact endpoint descriptor is:

```js
{
  serverId: 'verified-server', endpointId: 'verified-endpoint',
  generation: 'verified-server-incarnation', profile: 'codex-native-queue-v1',
  nativeVersion: '0.162.0', protocolSource: 'rust-v0.162.0',
  schemaSha256: '<independently approved exported experimental-schema SHA-256>',
  experimentalApi: true, queueApi: true
}
```

The descriptor is an internal attestation contract, **not native wire fields**.
The schema digest must come from independent version-bound negotiation and
approval. This core validates equality, not the truth of a caller's attestation.
The recipient descriptor is `{threadId, incarnation, persistent:true,
topLevel:true}`; `threadId` must be the full canonical lowercase UUID. Names,
prefixes, titles and pane positions are rejected. Constructor/current-call
identity checks fail closed on endpoint, schema or recipient changes.

Only `thread/read`, `thread/queue/add` and `thread/queue/list` are called. No
queue start/update/delete/reorder, turn start/steer, terminal typing or fallback
is exposed. Methods:

- `inspect()` performs only metadata `thread/read` with `includeTurns:false`.
  It verifies thread ID, non-ephemeral status and a known top-level source.
  It returns raw `nativeStatus` plus `status`; missing/future status stays
  `unknown`. Native `active` stays active and is never converted to idle.
- `submit(attempt)` snapshots the caller's frozen attempt and submits one
  bounded source-pointer notice. Busy queue acceptance does not require or
  imply idle. It does not use read-then-write status as an atomic guard.
- `reconcile(attempt)` returns retained acceptance, or scans a bounded native
  queue for positive exact evidence. It never submits, starts or consumes work.

Timeout is bounded (default five seconds); late responses cannot alter evidence.
Page size defaults to 50, maximum 100; at most eight pages by default, maximum
32. The raw decoded response bound is 256 KiB. A list error, malformed/changed
page, duplicate queue ID or client correlation, edited input, incomplete scan,
or changed incarnation remains uncertain. Every entry, including unrelated
items, is checked against the pinned text/image/localImage/audio/localAudio/skill/mention
input union; no input or attachment is executed or fetched by this validation. Offset pagination is not a snapshot:
undetected concurrent changes are possible. Even an exhausted scan proves no
negative fact. A positive matching item proves historical acceptance only,
never uniqueness or execution.

## Frozen notice and results

An attempt has exactly these fields:

```js
{
  attemptId: 'caller-reserved-attempt',
  source: {
    kind: 'wake', id: 'canonical-source-id', version: '<source SHA-256>',
    uri: 'https://agentboard.example.com/canonical-source'
  },
  recipient: {threadId: '<full UUID>', incarnation: 'verified-incarnation',
              persistent: true, topLevel: true},
  bindingEpoch: 1, dispatchGeneration: 1
}
```

The transport does not reserve/elect/recompute an occurrence, provision a
credential, claim a task or create a second wake-reason ledger. The caller owns
these IDs and fences and must reuse the same attempt. Creating a new attempt to
work around uncertainty is not recovery. Source pointers are bounded HTTPS URIs
without query, fragment or credentials; arbitrary task bodies are not accepted.
The clearly attributed notice contains the frozen fences, not full source text,
and is at most 4 KiB. The hash covers the exact rendered notice.

Results are either `outcome: "accepted"` with a retained native `receipt`, or
`outcome: "uncertain"` with a bounded reason. Acceptance includes the exact queue
ID, client ID, thread/recipient and endpoint incarnation, attempt, epoch,
generation and frame hash. It does not mean received, handled or completed.
`historical:true` explicitly identifies a retained earlier receipt; changed
native status, consumption, deletion or disconnect does not erase it.

Invalid input, mismatched existing attempts or corrupt evidence may throw.
An exception refuses the current operation; it does **not** establish that an
old effect never occurred. Changed source, recipient, epoch or generation cannot
inherit the old receipt. Missing evidence and native absence remain uncertain.

## Journal and crash custody

The caller supplies a stable existing private owned 0700 directory across
restarts and retries. Clearing or relocating it is not recovery. The core will not
create, chmod, chown or repair it. Directory paths cannot contain symlinks. Every ancestor must be owned by the
current UID or root; group/other-writable ancestors require sticky deletion
protection (such as a trusted `/tmp`). Foreign-owned ancestry is rejected even
if currently read-only. Records and locks must be owned regular 0600 single-link files. Records are
bounded to 64 KiB and named by SHA-256 of the caller's attempt ID.

The library uses an exclusive per-attempt 0600 lock file, checks identity on
release and never steals an existing lock. An abandoned lock remains fail-closed;
PID existence, elapsed time and an absent queue item do not clear it. This is
local native-evidence custody, not a replacement for server or worker fencing.
An operator may resolve a demonstrably stopped writer's filesystem custody
separately, preserving the record. There is intentionally no unlock/reset API.
The private directory protects against other OS users; hostile same-UID code
with access to this directory is outside the storage trust boundary.

Before any RPC in submit, an atomic same-directory write, file fsync, rename and
directory fsync retain immutable frame/fences, endpoint/recipient incarnation,
client message ID and `phase: "submitting"`. A failed save makes zero RPC calls.
Every retained-record read also fsyncs its checked record descriptor and root
directory, then rechecks the pathname's inode. This independently establishes
durability when a writer's rename is visible but its directory fsync is pending
or failed; visibility alone never certifies acceptance. A failed read barrier
refuses success even for a historical receipt. Acceptance is durably retained
before returning success. Failed persistence of an acceptance remains uncertain. Timeout, disconnect, server error or malformed
response after add invocation remains uncertain, even if it looks like rejection.
The library never performs a second add for a retained attempt. A crash leaves
submitting evidence (and possibly custody lock), preventing automatic replay.

## Remaining gates

Before integration: obtain Muse's shared runtime agreement and Rollout's admission
agreement; implement verified negotiated-client lifecycle, source eligibility
and consumption-time canonical-source fencing; connect existing explicit
received/handled operations; verify installed binary/schema/profile conformance,
real packaged interoperability and remote aggregate acceptance. A source-recheck
instruction in a notice is advisory, not an enforced consumer fence. There are
no receipt handlers in this transport. Enrollment and live canary activation
require separate authorization and proof.

## Verification

Run the standalone invented-peer test in an authorized assistant VM:

```sh
node build/integration/codex_queue_test.mjs internal/nativequeue/codex/transport.mjs
```

The isolated Bazel target is `//build/integration:codex_queue_test`, also included
in `//:acceptance`. Run only with configured remote execution:

```sh
./scripts/bazel test //build/integration:codex_queue_test
```

The script injects `--config=remote`. Without remote configuration/credentials,
remote Bazel is **unrun**, not replaced by a local Bazel build. Fixtures use only
invented RPC peers and disposable process/filesystem state; they require no
AF_UNIX socket, native CLI, account, network or production session.
