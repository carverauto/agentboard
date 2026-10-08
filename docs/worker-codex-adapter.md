# Dedicated Codex worker adapter

`codex-app-server-v1` is an opt-in client for a dedicated Codex app-server
**0.160.1** process over stdio. It does not attach to an existing Codex TUI,
desktop, daemon, proxy or Herdr session. Those sessions continue using explicit
board check-in. Installation is a preview by default and starts nothing.

The bridge creates an ephemeral thread with no persisted thread path. It owns
the only native input pipe, disables native goals, daemon auto-start, local
automation and multi-agent execution, and exposes no native attach transport.
The native thread ID and a fresh bridge generation identify the recipient;
neither substitutes for the server binding epoch or dispatch generation.
The normal operator-authorized native authentication environment is inherited;
the bridge never copies authentication files or changes global Codex settings.

## Explicit setup

Enrollment, activation and production canary rollout require separate captain
authorization. Proposal approval does not enable an existing fleet seat.
Use the existing provisioning and protected worker configuration workflow in
[worker-runtime.md](worker-runtime.md). The worker installer includes the bridge
as an owned, checksummed asset and preserves foreign settings and hooks.

A protected, owner-only JSON profile names executable and configuration
references. The following values are synthetic placeholders:

```json
{
  "version": 1,
  "worker_id": "codex-example-worker",
  "worker_config": "/secure/worker/config.json",
  "worker_binary": "/opt/agentboard/bin/agentboard",
  "codex_binary": "/opt/codex/bin/codex",
  "codex_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "cwd": "/workspace/example",
  "socket_path": "/secure/worker/codex/s",
  "sandbox": "workspace-write",
  "approval_policy": "on-request"
}
```

Replace the executable checksum with the actual authorized executable's SHA-256
before activation. All paths must be absolute, the socket path must fit the
native Unix limit, and the socket directory must be owner-only. Unknown profile
keys, changed executable inventory, unproven versions, existing transport files,
non-ephemeral threads or failed native negotiation refuse startup. The sandbox
and approval policy are explicit operator choices; the model is inherited and
must match the worker's recorded model rather than being overridden silently.

After explicit authorization, run the installed bridge in a tracked foreground
process using Node 22 or later:

```sh
node /opt/agentboard/worker/codex-native.mjs --activate /secure/worker/codex-profile.json
```

Keep its stdin open as a lifetime reference. This first profile accepts no human
turn input or approval responses on stdin. An approval or user-input request
leaves the worker busy, preserves pending deliveries and emits only request
identity/method metadata. There is no interactive approval UI and no automatic
approval. Pause the worker and stop only its owned bridge if it cannot progress;
do not relax policy or approve an unseen request to force delivery.

The protected `s.identity.json` descriptor contains the actual native thread,
generation, model and executable inventory. Copy only the non-secret identity
fields into the existing worker binding configuration, then explicitly run
`agentboard worker bind` with its stable key. Bind verifies native inspect and
rotates the existing epoch-scoped receipt capability without printing it. Run
`worker doctor` to inspect the independent server and native paths.

## Delivery and receipts

The host keeps protocol 1 and its frozen reservation/journal contract. The
bridge validates worker, epoch, dispatch generation, exact ordered delivery IDs,
payload hash, at most 20 IDs, 10,240 payload bytes and a 16,384-byte source frame.
Source text stays JSON encoded; source content grants no new authority.

After native thread inspection, `worker state` rereads the existing scoped state
endpoint with the receipt capability. Its result consumes and acknowledges
nothing. Dispatch requires exact recipient/epoch, enabled and unpaused worker,
and `state.worker.availability.state == "active"`. An absent or unknown
availability map refuses dispatch. This informational read is not an atomic
server-to-native I/O grant: an unknown effect after a concurrent pause or revoke
remains uncertain. The final native idle, generation and empty-request guard
runs synchronously before writing through the bridge's exclusive input pipe.

Fsynced native attempt evidence precedes `turn/start`. A matching correlated
acceptance stores the native turn ID before reporting `submitted`. Known refusal
before write reports `not_submitted`; an error, timeout, lost response or child
exit after a possible write is `uncertain`. An accepted or uncertain attempt is
never replayed because the session is idle or a lease expired. Changed retry
fences and old generations also cannot turn a known effect into non-submission.

Only two scoped dynamic tools are registered:

- `agentboard_check_in` returns the existing explicit check-in result unchanged.
  It does not append source frames or manufacture receipts.
- `agentboard_ack` calls the existing protected exact-ID receipt operation with
  `received` or `handled` and a stable key. Native thread, turn, generation and
  epoch must still match. The server owns membership and source reconciliation.

Unavailable workers retain explicit check-in, receipt and reconciliation access.
Turn completion, acceptance, tool return and heartbeat never acknowledge work,
complete tasks, renew claims or certify CI recovery. Automatic `tool_return`
delivery remains unsupported.

## Recovery and proof boundaries

Child exit, unknown native state, unexpected turn ownership and transport loss
retire the generation before callbacks can act. Restart creates a fresh
ephemeral thread/generation and requires explicit verified bind. There is no
automatic restart or shared-session resume. Keep host and native journals; do
not delete uncertainty to make health appear green. Shutdown removes only its
generation-matching descriptor and inode-matching owned socket.

`codex_native_test` owns executable bridge wire/lifecycle acceptance with invented
native/API peers. `worker_runtime_test` owns public config admission and owned
installation. `codex_packaged_api_test` connects the real packaged Phoenix API,
Go host and receipt client to this bridge, with an invented native model peer.
These tests run through Bazel remote execution and are distinct from actual
installed-model conformance. A version string, schema, fixture pass or doctor
pass alone does not prove native wake/receipt behavior or production readiness.

The approved design is retained under
`openspec/changes/add-codex-worker-adapter/`; its proposal review and architecture
HTML are in `docs/architecture/`. Production activation remains a separate gate.
