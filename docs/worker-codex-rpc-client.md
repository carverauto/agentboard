# Codex connect-only RPC candidate

A separate explicit [durable-advisory owner bridge](worker-codex-owner.md) is now
available as an unregistered candidate. It does not weaken the strict identity
contract below or establish live/installed/Darwin readiness.

Status: **unregistered and live-disabled pending owner evidence**. This adds an
actual WebSocket-over-Unix-socket implementation beside the fixture-tested queue
core, not a worker adapter. Nothing in serve, runtime, election, admission,
recovery, installers or deployment imports it. It has no executable entrypoint.
The existing exclusive 0.160.1 bridge remains unchanged.

## Connection and side effects

`connectCodexRpcClient({codexHome, evidence, timeoutMs, lifetimeMs})` discovers the
existing `CODEX_HOME/app-server-control/app-server-control.sock` alias, validates
its canonical ancestry, and connects **once** to its verified physical target.
There is no process launch, daemon restart, stale-file cleanup, chmod, mkdir,
lock, reconnect, redirection, resend or embedded-server fallback. It never scans
session files or creates, resumes or attaches a thread. Closing destroys only
this client's connection.

The exact source pin is `rust-v0.162.0`. On Unix, the advertised socket is an
intentional symlink into `realpath('/tmp')/codex-daemon-<effective uid>/<SHA256>`.
The hash covers UTF-8 bytes of the canonical advertised parent plus socket name.
The daemon directory must already be user-owned 0700; the physical socket must
already be user-owned 0600. Non-UTF-8 paths are refused. `/tmp` is canonicalized
for macOS, never replaced with TMPDIR. The client snapshots the alias, socket
and ancestry metadata and rechecks at discovery, connect, requests, responses,
identity reads and at most 100 ms intervals. Substitution retires the connection.
These filesystem checks are not process identity and do not protect against
hostile same-UID code racing replacement between checks.

HTTP upgrades use `ws://localhost/rpc` on the already-selected Unix stream, not
TCP. The pinned `ws` library implements RFC6455 framing and masking. The client
sends `initialize` with its own name `agentboard_native_queue`, version `0.1.0`,
and `experimentalApi:true`, waits for the exact initialize response, obtains
owner admission, then flushes `initialized`. It does not impersonate a reserved
non-originating client.

**Initialize is effectful.** Native initialization can change process-global
originator/user-agent metadata and automatic gateway-login behavior. Initialized
connections are automatically subscribed to newly created threads. Notification
opt-outs do not remove those side effects. Pre-initialize owner approval must
cover them. This implementation neither answers approvals/auth requests nor
sets credential behavior as a workaround. No live native initialization was
performed in its synthetic validation.

Pinned upstream references:

- [Rendezvous and WebSocket listener](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-transport/src/transport/unix_socket.rs)
- [Protected daemon directory](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/uds/src/daemon_directory.rs)
- [Remote client initialization](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-client/src/remote.rs)
- [Initialization effects](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server/src/request_processors/initialize_processor.rs)
- [New-thread automatic subscription](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server/src/lib.rs)

## Required owner evidence seam

**No evidence provider ships.** Missing methods, missing descriptors, async
truthy values, rejection or revocation fail closed. Tests use explicitly invented
fixture attestations; these cannot authorize a native endpoint.

The trusted existing runtime owner must supply all of:

- `current()`: synchronously return the exact `{endpoint, recipient}` descriptors
  defined in [the queue core contract](worker-codex-queue.md), or revoke them.
  This is an independently approved build/schema/profile, native server lifetime
  and enrolled persistent top-level recipient incarnation, not wire self-report.
- `verifyConnection({connection, socket, initialize})`: synchronously return
  exactly `true` only while the specific connection remains authorized and the
  owner's evidence remains current. Before initialization `initialize` is null;
  this call must authorize the connection and the initialization side effects.
  After the response it contains only native `userAgent`, `codexHome`,
  `platformFamily` and `platformOs`. Those fields do not establish attestation.
- `bindConnection({connection, stream, socket})`: called once after the HTTP
  upgrade, before initialize, with the **actual connected stream**. Return
  exactly `true` only when the owner can independently verify its connected peer.
  The stream is exposed only to this trusted host proof provider, not transport
  callers, for peer verification; it must not inject RPCs, add response handlers,
  retry, or own lifecycle. The immutable `connection` object is an opaque local
  object-identity fence shared with verification calls, **not a native epoch**.
- `subscribeRetirement(callback)`: synchronously register revocation and return
  an unsubscribe function. Invoke the callback synchronously on owner evidence
  retirement; it invalidates identity before rejecting pending operations.

Node's portable stream API does not supply native peer credentials/process-start
identity. A host-owned binding provider and recipient enrollment lifecycle are
therefore explicit remaining gates. No provider may treat socket inode/path,
PID alone, client object identity, `thread.sessionId` or `cliVersion` as a native
server/recipient incarnation. In particular, `thread.sessionId` is a session-tree
identifier and can equal the thread ID for unloaded threads.

Upstream managed-daemon records can contain process-start identity (Linux
boot ID/start ticks; macOS boot ID/unique ID/start timestamps) and BLAKE3 executable
identity. These are useful inputs for a future owner verifier, but are optional
and must be checked against the actual peer/current process. Existing lifecycle
helpers may mutate stale records, so this client never invokes them. An eventual
same-connection diagnostics probe could corroborate PID but cannot independently
prove generation. No diagnostics method is added to this client's caller
allowlist. See [PID record](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-daemon/src/backend/pid.rs)
and [process identity](https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/app-server-daemon/src/backend/pid_identity.rs).

## Bounded protocol and retirement

Once admitted, `identity()` synchronously returns the frozen descriptors or
null. `request({id,method,params})` sends an exact frozen snapshot once and
returns the raw, exactly correlated `{id,result}` or `{id,error}` envelope.
`jsonrpc:'2.0'` may be present. Numeric IDs are safe nonnegative integers;
string IDs are bounded tokens. Numeric and string IDs never alias, and used IDs
cannot be reused during a connection.

Only `thread/read` with `includeTurns:false`, bounded `thread/queue/list`, and
single-text `thread/queue/add` for the attested exact thread are allowed. No
approval/auth response, queue start/update/delete, turn start/steer, resume,
unsubscribe, daemon shutdown or arbitrary RPC is available.

- 256 KiB aggregate incoming WebSocket message limit, before JSON decoding,
  including fragmented messages; maximum 128 fragments and 128 buffered chunks
- 8 KiB HTTP header limit; compression and redirects disabled; strict UTF-8
- 8 KiB outgoing request limit; at most eight pending requests and 128 caller
  requests during the single connection; bounded send buffering
- 128 discarded notifications and 4 MiB total incoming wire bytes per lifetime;
  no notification queue, callback execution or retained notification content
- Five-second default connect/HTTP/initialize/initialized-flush deadline and
  request deadline, configurable from 1 ms to 60 seconds
- 30-second default absolute lifetime, configurable from 1 ms to 60 seconds,
  which also bounds stalled fragments and slow notification drips

A timeout, close, error, invalid framing/envelope, unknown/duplicate response ID,
server request (including an approval), control ping/pong, path change or evidence
revocation synchronously retires identity before rejecting pending work. The
connection is destroyed immediately, without waiting for a close handshake.
No JSON-RPC response or generic method-not-found error is sent to a server
request: that can consume a callback shared with an interactive client. Unknown
notifications are discarded within the bounds; the pinned native optional
`emittedAtMs` safe-integer timestamp is accepted. Late data cannot restore identity
or acceptance. Refused caller inputs never get written.

Retirement does not establish that an in-flight add had no effect. The existing
journal retains `submitting` custody and prevents automatic add replay. Durable
historical acceptance survives disconnection. No journal, election, recovery,
source eligibility or consumer-fence semantics were changed.

## Dependency and tests

The private package pins `ws` **8.22.0**, an MIT-licensed established WebSocket
implementation. The npm lock records its integrity; Bazel/hosted runners fetch
one SHA256-pinned official npm tarball, extract in a disposable staging tree,
and run without install scripts or optional native addons. No hand-written
WebSocket parser is used. See [upstream release](https://github.com/websockets/ws/releases/tag/8.22.0).

Run the no-bind synthetic fixtures in an authorized assistant VM using the
runner, passing the pinned archive downloaded from the URL in MODULE.bazel:

```sh
bash build/integration/codex_rpc_client_test.sh \
  "$PWD/internal/nativequeue/codex/rpc-client.mjs" \
  "$(command -v node)" /path/to/ws-8.22.0.tgz
```

The fixtures use in-memory Duplex HTTP upgrades with the actual `ws` framing
implementation, invented protocol peers, and disposable journal state.
Separate metadata fixtures prove official socket-layout validation. With
`CODEX_RPC_TEST_UNIX=1`, a second fixture requires a real invented Unix socket
under its own temporary directory and exercises initialize plus the queue
transport. It never creates or accesses the real reserved daemon directory.
Hosted CI and `//build/integration:codex_rpc_client_test` require this Unix fixture;
the target is part of `//:acceptance`. A VM denial must remain an explicit unrun
gate, never a skipped success or a different-environment workaround. Remote
Bazel commands must use `./scripts/bazel` with configured remote execution.

## Live activation gates

Before any native connection: obtain runtime/admission owner agreement and
explicit approval for initialize side effects; implement independently verified
connected-peer/build/schema/server-lifetime evidence and recipient enrollment
with synchronous revocation. Then run authorized installed 0.162.0 experimental
schema/profile and real packaged compatibility tests with scoped existing
recipients. Queue/list alone proves neither add behavior nor whole-schema
compatibility. Session readiness, source consumption fencing, received/handled
operations, enrollment and worker activation remain outside this slice.
