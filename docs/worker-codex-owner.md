# Connect-only owner bridge: durable advisory profile

Status: **unregistered, live-disabled implementation; actual Unix integration is
not yet verified in the assistant VM**. Nothing imports this into worker run,
host supervision, installation, admission, or enrollment. No native connection,
credential, schema approval, deployment, service or production wake was created.

## Contract choice

`codex-durable-advisory-v1` targets an explicitly enrolled **persistent
conversation**, including after unload/resume. An old pointer notice can start a
later model turn and consume tokens. The notice grants no work authority. The
receiver must resolve its exact attempt against current authenticated server
source/claim/capability state, then explicitly send separate received/handled
receipts. Merely printing an instruction to recheck is not a machine-enforced
consumer gate; that server/receiving-tool integration remains a separate gate.

The existing `codex-native-queue-v1` APIs keep their strict native-incarnation
contract. They reject this new identity. There is no implicit conversion or
use of an enrollment epoch as a fictional native lifetime.

The endpoint keeps the existing version/source/schema fields, but uses
`profile: "codex-durable-advisory-v1"`. Its `generation` is derived by the Go
owner from the verified kernel peer identity and approved running executable,
not supplied by the calling manifest. The recipient has exactly:

```json
{
  "threadId": "11111111-1111-4111-8111-111111111111",
  "identityKind": "durable-conversation-v1",
  "enrollmentRevision": 123,
  "bindingEpoch": 3,
  "persistent": true,
  "topLevel": true
}
```

These values are illustrative. Enrollment revision and binding epoch are
server authority, not native fields. New advisory journal records contain this
explicit profile and recipient shape, so strict/changed identities cannot
inherit prior evidence. Attempt bindingEpoch must equal recipient.bindingEpoch.

## Callable integration boundary

Go package: `internal/nativequeue/owner`.

1. Obtain an independently approved, immutable `owner.Approval`. This includes
   approved schema/profile/build, exact `Peer` inventory, recipient enrollment,
   authority revision, explicit initialization approval, and a local `Deadline`
   no more than 30 seconds away. Anchor that deadline before fetching upstream
   authority so transit time reduces validity; do not refresh it on Dial/retry. Leave endpoint Generation empty. `InspectProcess(pid)`
   can gather Linux process inventory for review; it approves nothing.
2. `owner.Dial(ctx, physicalSocketPath, approval)` validates approval before
   connecting once. The caller supplies the already-approved physical address;
   this is not discovery. Missing proof is refused. There is no reconnect,
   launcher, stale-record repair, native lifecycle helper or fallback.
3. `owner.Start(cmd)` starts only a trusted reviewed Node client program with the
   same verified connected socket on FD 3, private owner replies on FD 4 and
   private owner challenges on FD 5. Use an absolute executable path. The caller
   owns `cmd.Wait()`. Existing ExtraFiles, repeated Start and a retired owner fail.
4. In that child, call
   `connectInheritedCodexAdvisory({approvalId, authorityRevision, timeoutMs, lifetimeMs})`
   from `internal/nativequeue/codex/inherited-client.mjs`. The caller pins the
   expected approval ID/revision independently of pipe data. This initializes
   through the existing bounded ws implementation, then performs a metadata-only
   read to check the exact persistent top-level recipient before returning.
5. Use `createCodexAdvisoryTransport({client, endpoint, recipient, journalDir})`
   from `transport.mjs` with the returned identity and a protected existing
   journal. The caller still owns the one canonical reservation and source gate.
6. Invoke `owner.Retire()` when server authorization changes or its authoritative
   feed disconnects. Cancellation and the absolute approval expiry also retire.
   This package provisions no server feed. The separate
   [bounded server authority bridge](worker-native-authority.md) supplies
   authenticated snapshots and fixed-deadline serial polling; it is default-off
   and is not registered with a live host.

The child must receive an explicit sanitized environment. Allowed keys are
PATH, LANG, LC_ALL, TZ, WS_NO_BUFFER_UTIL and WS_NO_UTF_8_VALIDATE. The last two
must both be `1`. Nil environment, unknown keys, duplicates, credential variables,
NODE_OPTIONS, NODE_PATH and loader preload variables are rejected. The native
server's existing environment is never changed. The owner does not inherit or
forward user authentication into the Node child.

## Actual peer and process proof

Linux verification uses `UnixConn.SyscallConn` with `SO_PEERCRED` on the very
socket passed to Node. It verifies the peer UID/PID, Linux boot ID, process start
ticks and the SHA-256 of the running image opened through `/proc/PID/exe`.
Process and image identity are reread around hashing. Later owner attestations
recheck identity, image inode/size/mtime and protected socket pathname metadata.
Same-UID hostile modification, ptrace, or a malicious trusted client/owner is
outside this boundary. Pathname checks are not atomic protection against such
an adversary. A PID or pathname alone never qualifies.

The Go owner retains a duplicate FD but never reads native RPC bytes. The child
checks its inherited socket inode/device against the original owner observation.
Retirement uses `shutdown(SHUT_RDWR)` before closing, so it affects all duplicates
of this connection; closing only the parent's descriptor would be insufficient.
Native daemon shutdown is never called.

Darwin is **unsupported before dial**, including in cross-compiled binaries.
Apple exposes `SOL_LOCAL/LOCAL_PEERPID` and local peer credentials/audit tokens,
and libproc exposes process start/unique identifiers. Peer PID alone is not
running-process/build proof; this stdlib-only implementation does not fabricate
it or hash an arbitrary current pathname as proof of a mapped executable. A
reviewed Darwin peer-token/lifetime/running-image verifier and actual Darwin
conformance are required before enabling this provider on Macs.

## Bounded retirement, not instantaneous revocation

The owner answers ordered per-child challenges only while the immutable approval
is current and the actual peer remains verified. Each reply is valid for at most
250 ms, measured from the child's challenge-send time using its monotonic clock.
A reply delayed beyond that deadline is rejected. Refresh after the preceding
local deadline is rejected even if an event-loop timer has not run. Replies
cannot change identity, authority revision, socket identity or approval ID.

The child challenges every 50 ms with at most one outstanding challenge. Pipe
EOF/error, malformed/oversized data, missing refresh, native disconnect or
expiry retires local identity before rejecting pending operations. Owner-process
exit closes the private pipes. This does not make remote server revocation
instantaneous: upstream feed latency and already-sent native bytes still matter.
The host must retire on a feed gap and must obtain its current authority before
a new owner is created. No renewal, reconnect or replay is performed here.

A retired connection cannot remove a queued notice or prevent a later resumed
thread from observing it. A possibly-written add remains uncertain; no add is
replayed for the same journaled attempt, and queue absence proves nothing.
Historical acceptance remains historical evidence after retirement. Existing
received/handled and source authorization remain server responsibilities.

## Verification and remaining gates

The mandatory `//internal/nativequeue/owner:owner_test` target runs an actual
invented Unix HTTP/WebSocket peer, Go process/FD verification, Node inherited-FD
initialization, durable advisory queue submission, retained acceptance,
retirement, owner-pipe EOF, lease expiry, lost-add uncertainty, wrong approval,
closed FD and deliberate real-socket substitution. It uses the existing pinned
ws archive, with no install scripts or native addons. It never accesses a real
Codex socket, account, session or credential. It is in `//:acceptance`, and the
native-fixtures hosted workflow requires the same suite with the Go race detector.

Run on an authorized Linux fixture host with Unix sockets available:

```sh
OWNER_INTEGRATION=1 OWNER_NODE=/ABSOLUTE/node \
OWNER_WS_ARCHIVE=/ABSOLUTE/ws-8.22.0.tgz \
go test -count=1 -race ./internal/nativequeue/owner
```

Bazel must use `./scripts/bazel test //internal/nativequeue/owner:owner_test`
with configured remote execution. Unit-only commands do not establish FD
interoperability. Without OWNER_INTEGRATION the named integration test explicitly
reports UNRUN; the mandatory Bazel/hosted paths set it to 1.

Assistant-VM checks: existing and new no-listen RPC/owner-control fixtures passed;
Go non-socket approval/environment tests passed; Darwin cross-compilation is
checked separately. The attempted actual Unix fixture is blocked at socket
creation by EPERM, including the reviewed sandbox escalation. This is **not a
passing native integration result**. No other host was used to evade the limit.

Before live use: prove real packaged owner/FD interoperability on an authorized
fixture runner; integrate/verify the server authority producer and receiving
source-resolution gate described in [the authority contract](worker-native-authority.md);
verify installed 0.162.0 binary/exported experimental
schema/profile; approve native initialization side effects; and separately
approve enrollment, wake-owner election and canary activation. Linux fixture
success would not imply Darwin or existing Muse idle-wake support.

Primary references:
- [Go UnixConn descriptor access](https://pkg.go.dev/net#UnixConn.SyscallConn)
- [Go child ExtraFiles](https://pkg.go.dev/os/exec#Cmd)
- [Node inherited socket descriptor](https://nodejs.org/api/net.html#new-netsocketoptions)
- [Apple local peer options](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h)
- [Apple process information](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h)
- [Pinned Codex process identity](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-daemon/src/backend/pid_identity.rs)
- [Pinned queue parameters](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L879-L889)
- [Pinned persistent queue/resume behavior](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/ext/queue/src/service.rs#L509-L534)

### Diagnosing fixture timing failures

The merged-main hosted race run `38211010405` failed before the child emitted
`accepted` in `pipe-eof`. The Go parent closes the control pipe only after that
explicit marker, following native acceptance and a successful historical journal
read. Thus the intentional EOF injection did not cause that failure. Its exact
uncertainty cause was not recorded. The failure diagnostic also read a live
`os/exec` stderr buffer concurrently; fixture logs now synchronize both writes
and snapshots, with a race regression test.

The inherited client exposes read-only `diagnostics()` containing only local
retirement status, a fixed retirement-reason enum, challenge counters and lease
remaining/retirement age milliseconds. It exposes no endpoint, socket metadata,
source text, credentials or peer-controlled error text. The fixture records these
along with the transport outcome/reason, journal phase and synchronous fsync
count/total/max durations before the strict acceptance assertion. These fields
help distinguish local expiry, owner-pipe closure and native connection closure;
they are observations, never authorization or proof of remote acceptance.

The hosted Go owner suite now runs ten repetitions under `-race -v`, requiring
actual inherited-FD interoperability in every repetition. Any unexpected
uncertainty still fails. A deterministic in-memory-stream test injects retirement
during the submitting-file fsync and requires retained `submitting` uncertainty,
zero native writes and no replay. This classifies a possible safe failure mode;
it does not establish that an fsync stall caused the hosted failure. The 250 ms
health bound, prior-deadline fence, durable fsync sequence, no-retry behavior and
strict acceptance barrier are unchanged. Linux socket execution must pass hosted
CI; this VM cannot certify it. Darwin remains unsupported at runtime.
