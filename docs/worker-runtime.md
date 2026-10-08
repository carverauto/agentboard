# Supervised host worker

The host runtime implements worker API protocol 1. It contacts Phoenix exclusively
through `internal/client`; it has no database credentials. Server enrollment,
immutable batches and obligations belong to the server release. This host PR
must follow collector and server merges. Production activation and the joint
failed-PR/reminder/repaired-head demonstration remain coordinated release gates.

## Supported adapter and evidence

The first automatic adapter is `pi-native-v1` for a deliberately enrolled Pi
0.99.2 **exclusive RPC session**. Native extension lifecycle and socket handling
own wake delivery. No shell watcher or terminal typing is used. The explicitly
selected profile is `AGENTBOARD_PI_PROFILE=exclusive-rpc`; the session starts with
`--no-extensions -e PATH/pi-native.mjs`, so this new enrolled session has one wake
owner. This does not alter Firstmate, Herdr or user hooks in existing sessions.
Loading skills never starts a service or enrolls a worker.

| Surface | Idle wake | Turn start / tool return | Receipt and recovery |
| --- | --- | --- | --- |
| Pi 0.99.2 exclusive RPC | Actual isolated model wake proved | Versioned native events; dedicated `agentboard_check_in` only; original tool output preserved | Explicit exact-ID tool, protected native evidence, replacement retires callbacks |
| Pi TUI or competing wake owner | Disabled | Automatic delivery disabled until live conformance and wake-owner coordination | Explicit manual check-in remains available |
| Herdr 0.9.0 / protocol 22 | Disabled: no expected-recipient/composer guard on installed `agent.prompt` | Unsupported | Manual protected API check-in; terminal lifecycle is not a handling receipt |
| Claude, Grok, Muse, AGY | No host automation claimed by this release | Native hooks unimplemented here | Existing manual board workflow; no fabricated healthy enrollment |

The isolated Herdr server was named `agentboard-runtime-conformance`; no user's
active server/session was inspected or prompted. [Herdr socket documentation](https://herdr.dev/docs/socket-api/)
and [automation documentation](https://herdr.dev/docs/agent-automation/) describe
its candidate APIs; the installed request schema has only target/text/wait for
prompting. The runtime therefore uses the specified native fallback.

See `docs/verification/worker-pi-live.json` for the actual model and native session
identity. That historical harness proof used invented local HTTP contracts.
[Fresh packaged server/host acceptance and isolated Pi evidence](verification/worker-packaged-api.md)
now cover the shipped boundary separately; the coordinated release proof remains open. A second actual busy model turn consumed the frame at the dedicated check-in tool return while retaining its original result (`docs/verification/worker-pi-busy-live.json`). Remote socket
fixtures test occupied composer, busy native queuing, original result preservation,
pause, exact generation rejection and uncertainty. No TUI parity is implied.

## Explicit installation and enrollment

1. Obtain the immutable remote-built release asset for the host architecture and
   verify its published SHA-256. Install it as `~/.local/bin/agentboard` and check
   `agentboard version`. Never compile on the Mac. The repository's
   `./scripts/bazel build //cmd/agentboard:agentboard_darwin_arm64 --remote_download_outputs=all`
   is the remote development route; Linux targets are also provided.
2. Register the actual stable agent/model/harness through the existing CLI. The
   captain provisions worker/host/repository scope using the server's documented
   protected provisioning API. Store the returned host capability in an owned
   regular 0600 file in an owned 0700 directory. Tokens are file contents, never
   command-line values, environment values, diagnostics or artifacts.
3. `agentboard worker install --config ABSOLUTE_CONFIG --json` previews the
   service and extension file hashes. Inspect the output, then use `--apply` to
   write only owned files. No service is started. Existing hooks/settings are
   untouched. Changed foreign files cause refusal; prior owned versions receive
   protected content-addressed backups.
4. Start the explicitly authorized dedicated Pi session with the environment
   references below. Read its protected `SOCKET.identity.json`, then put its exact
   native session ID and generation into the versioned protected config. Do not
   infer them from titles/models/focus.
5. Run `worker bind --config ABSOLUTE_CONFIG --worker-id ID --key STABLE_BIND_KEY`.
   The host verifies the native socket occupant, binds against the expected
   epoch, saves the epoch-specific receipt capability beside the host capability
   as `TOKEN_FILE.receipt`, and updates the config. Its stdout omits the secret.
   A lost bind response requires inspection and an explicit new bind; retry does
   not regenerate a lost secret.
6. `worker doctor` verifies scoped protocol/API access, the actual native
   identity/capabilities and receipt-token read path. It reports unsupported
   surfaces rather than treating file existence as readiness. Then activate the
   reviewed service explicitly using the install plan's reload instructions.

Example nonsecret session references (all values are operator-chosen paths):

```sh
export AGENTBOARD_PI_PROFILE=exclusive-rpc
export AGENTBOARD_PI_SOCKET=/ABSOLUTE/PRIVATE/DIR/pi.sock
export AGENTBOARD_WORKER_CONFIG=/ABSOLUTE/PRIVATE/DIR/config.json
export AGENTBOARD_WORKER_ID=YOUR_STABLE_AGENT_ID
pi --mode rpc --no-extensions --no-skills --no-context-files \
  --no-builtin-tools -e /ABSOLUTE/HOME/.config/agentboard/worker/pi-native.mjs \
  --session-dir /ABSOLUTE/PRIVATE/DIR/sessions --name YOUR_ENROLLED_SESSION
```

The RPC session must have a real authorized owner/client. This command is a
profile example, not permission to replace an existing interactive agent. A
conformance runner may set `AGENTBOARD_WORKER_BINARY` to a remote-built executable
reference; the installed default remains `~/.local/bin/agentboard`.

Protected config shape, with invented identities and references only:

```json
{
  "version":1,
  "url":"https://agentboard.example",
  "journal_dir":"/ABSOLUTE/PRIVATE/DIR/journal",
  "bindings":[{
    "agent_id":"example-worker","model":"actual-model","harness":"pi",
    "host_id":"example-host","server_id":"example-pi-server",
    "session_id":"NATIVE_SESSION_UUID","adapter_generation":"NATIVE_GENERATION_UUID",
    "adapter":"pi-native-v1","socket_path":"/ABSOLUTE/PRIVATE/DIR/pi.sock",
    "token_file":"/ABSOLUTE/PRIVATE/DIR/host-token","binding_epoch":0
  }]
}
```

After first bind, the config stores the returned positive epoch. Enrollment and
provisioning scope do not authorize unrelated work, reclaim, merge or deployment.

## Check-in, receipts and CI responsibility

`worker check-in --config PATH --worker-id ID --json` traverses responsibilities,
unresolved obligations and pending pages and rereads binding state. It does not
consume anything or renew task leases. Repeated cursors, page-budget or output
limits return a catch-up-incomplete error rather than false completion.

The dedicated native `agentboard_check_in` tool exposes the same machine-readable
result, with any frozen pending source frame added separately at its supported
return boundary. Arbitrary shell tool returns and existing CLI JSON/NDJSON/watch
stdout are unchanged. Every source frame is bounded and delimited; JSON encoding
prevents source text from closing the delimiter. Read canonical current state
before acting on an old alert.

Record meaningful repair progress, a specific blocker or an explicit handoff on
the board. Then use exact IDs and a stable receipt key:

```sh
agentboard worker ack --config PATH --worker-id ID --kind received \
  --ids DELIVERY_ID --key RECEIPT_KEY --json
agentboard worker ack --config PATH --worker-id ID --kind handled \
  --ids DELIVERY_ID --key HANDLING_KEY --json
```

The native `agentboard_ack` tool provides the same explicit operation. It uses the
session receipt capability, reconciles source state first and rejects foreign or
nonmember IDs. Received/handled preserve original attribution on retries. Turn
completion never acknowledges. Handling a CI alert never resolves a still-red
repair obligation or completes its task; keep inspecting `gh-axi pr checks NUMBER`
and record the current head/CI status on the owned task.

## Recovery, pause and supervision

Each binding has its own cancellation, dispatch state and retry loop. Default
fallback is 30 seconds; reconnect is jittered exponential 1–60 seconds, retaining
a longer server Retry-After up to a 24-hour host safety ceiling. A Retry-After
beyond 24 hours sleeps 24 hours and emits an explicit degraded reason keeping
the raw server duration as diagnostic; cancellation stays immediate.
No connector heartbeat manufactures model activity
or renews/reclaims board task leases.

Before native I/O the protected fsync journal records reservation key, exact
batch/attempt/epoch/generation/hash, payload and phase. A crash before the call
began can report positive non-submission. Submitting-phase, partial write,
timeout and unknown results remain uncertain. Restart reconciles server current
sources/receipts and native evidence before any new batch. Submitted and uncertain
attempts never become replayable merely because a lease expires or Pi is idle.
Unreconciled old-generation journals remain visible and block new dispatch.
A rebinding host may read the old owned attempt once through the current host
credential (`POST attempts/:attempt/reconcile` with the frozen epoch, generation
and hash, no adapter I/O, no result write, no receipt credential). Only an
explicit resolved or replay_allowed answer with the original canonical frozen
batch retires that journal. The attempt, batch ID, epoch, dispatch generation,
payload bytes/hash and ordered delivery membership must match the protected
journal. A missing or mismatched batch, missing route or empty journal keeps the
visible block. Server health reports deferred, paused and uncertain adapter states as
busy, blocked and unknown while keeping the explicit reason text.
Captain resolution of orphan uncertainty is an explicit server decision that
records possible duplicate effects; it is never a host retry heuristic.

`worker pause`, `resume` and `unbind` are explicit epoch-fenced actions that retain
server deliveries. Native callbacks reread durable pause and current identity
before injecting source text. Epoch loss/pause cancels an in-flight native call;
already-issued external effects may still have happened and stay uncertain.
A session replacement retires its socket/callback generation. Read the new
identity, explicitly rebind, and restart the host service with the new config.
A stale socket from an ungraceful crash requires operator ownership inspection;
the extension never removes a foreign/unknown socket to take over.

On macOS, previewed launchd files use `KeepAlive`, restrictive umask and a 30-second
throttle. Bootstrap the reviewed plist for the actual GUI UID. Replacements require
bootout/bootstrap. On Linux, daemon-reload and enable/start the reviewed user unit;
restart after config replacement. No token value is placed in plist/unit arguments.
Both reference `~/.local/bin/agentboard worker serve --config PATH`.

`worker uninstall` previews; `--apply` removes only unchanged hash-matching owned
service/extension files. Stop/unload the service explicitly; deletion alone does
not stop a running process. Protected config, credentials, journals, backups and
pending server obligations remain. Foreign or edited integration files cause
refusal. Global production services and existing sessions are never activated by
skill installation or by the default install preview.

The subsequent opt-in [Claude native adapter](worker-claude-adapter.md) supports
generation-fenced prompt and dedicated check-in boundaries. Its idle wake remains
unsupported; readiness is per worker and surface.

The opt-in [dedicated Codex adapter](worker-codex-adapter.md) uses an exclusive
ephemeral app-server stdio child. Its approved implementation is being validated;
installed-model conformance and the scoped effective-availability dependency are
separate readiness gates. It does not enroll or activate existing sessions.
