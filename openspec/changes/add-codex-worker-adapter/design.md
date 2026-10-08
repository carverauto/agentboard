# Codex worker session design

## Context

The motivation and scope are in `proposal.md`. This is a design, not a report of
implemented or live-proven behavior.

Repository baseline: `829d468a99b6a707c463b6a3f4c3c5d1aa08a4fb`.

| Existing boundary | Evidence | Constraint carried forward |
| --- | --- | --- |
| Protected native transport | `internal/worker/adapter.go` | Protocol 1, owned private Unix socket, exact session/generation response, five named capabilities with reasons |
| Frozen delivery and recovery | `internal/worker/runtime.go`, `docs/worker-api.md` | Fsync before I/O; epoch, dispatch generation, hash, ordered IDs; uncertainty is never a replay heuristic |
| Native reference | `internal/worker/pi-native.mjs` | Exact occupant and one input owner; protected native attempt evidence; lifecycle replacement retires callbacks |
| Explicit check-in policy | `docs/worker-claude-adapter.md` | Tool results do not imply receipt; no automatic check-in augmentation on unproven surfaces |
| Server bind | `web/lib/agentboard/cooperation/runtime.ex` | Adapter names are stored as bounded text; capabilities and expected epoch are verified by existing contract |

The local installed Codex CLI reports `0.160.1`. Its generated experimental
schema exposes `thread/start`, `thread/resume`, `turn/start`, native thread status,
dynamic tool requests, and dynamic tool responses. Inspection of a schema is
not conformance. In particular, `TurnStartParams` requires `threadId` and `input`
but exposes no expected-idle compare-and-submit field. A shared client cannot
claim safety merely by reading status before starting a turn.

[Official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes initialization, thread/turn events and experimental dynamic tools.
The proposal maps those surfaces to the existing worker contract; it does not
infer installed support or live safety from documentation alone.

Prior isolated Herdr conformance observed an idle report while a draft existed,
followed by appending and submitting that draft with a probe. The installed
`agent.prompt` contract lacked expected-session and empty-composer guards.
That failure excludes Herdr prompting from this slice.

## Goals / Non-Goals

**Goals:** preserve protocol 1; implement one explicitly enrolled Codex profile;
make input ownership a prerequisite; keep all work pending until exact handling;
publish independently falsifiable evidence for each claimed capability.

**Non-Goals:** attach to or take over an existing TUI/desktop/Herdr session;
interrupt a running turn; steer model execution; answer approvals automatically;
change global settings/authentication; replace the shared Codex daemon; enroll
the fleet; add Claude/Grok/Muse implementations; finish the broader runtime
release gates simply by shipping this adapter.

## Decisions

### D1. One dedicated native session, with one writer

Proposed adapter name: `codex-app-server-v1`; harness attribution stays `codex`.
The explicitly activated bridge owns a dedicated app-server child over stdio,
creates a thread, and is the only client allowed to write turn control for that
thread. It never connects to a shared daemon/proxy or exposes an attach socket.
The process must use an operator-authorized isolated thread store and existing
authorized authentication without copying credential files or changing shared
settings. A conflicting owner, unsupported installation, unavailable auth, or
unproven storage isolation prevents automatic readiness.

No composer exists in this supported profile. Its queue must also be empty.
This is a structural eligibility condition, not a claim that a TUI composer is
empty. Status inspection alone cannot qualify any interactive surface.
Native goal/continuation sources must also be disabled or proven to share the
same dispatcher. A server that can autonomously start a competing turn cannot
qualify merely because its client has one writer. Failure to establish this
property disables automatic readiness and requires a revised native boundary.

The bridge serializes native events, explicit user requests, and dispatch in one
per-session queue. Final recipient, generation, enabled/paused/availability,
idle status, queue-empty, and pending-approval checks occur in that queue before
the first native write, with no intervening owner change. Work arriving during
an active turn is deferred; no `turn/steer`, interrupt, terminal input, or broad
history injection is used. A restart invalidates automatic eligibility until
old attempts reconcile and a new binding is explicitly verified.

Alternative: a read-status-then-Herdr-prompt sequence is rejected because it
cannot protect a draft or occupant change atomically. A native interactive hook
adapter would be a separate profile requiring executable hooks/composer proof.

### D2. Explicit identity, binding, and lifecycle

The protected descriptor contains protocol, adapter version, actual thread ID,
fresh random adapter generation, and socket reference. A new worker config
retains existing `agent_id`, model, `host_id`, `server_id`, token references and
epoch fields. Native thread ID maps to `session_id`; the bridge generation maps
to `adapter_generation`. These are distinct from server `binding_epoch` and
batch `dispatch_generation`; neither pair substitutes for the other.

Captain provisions scope with the existing API. The operator invokes existing
`worker bind` after native `inspect` matches the descriptor; bind compares the
expected epoch, rotates receipt scope, and increments the server epoch. No model
name, focus, title, pane position, or board heartbeat determines the session.
Install previews owned files; explicit apply/start/enroll are separate actions.

Exit, resume, fork, thread replacement, process replacement, and loss of sole
writer proof retire old callbacks before any fallible discovery. Resuming the
same thread still needs a fresh adapter generation and verified new bind.
Rebinding preserves old journals and server attempts. An old-generation socket
or callback cannot submit or acknowledge in the replacement. Native cleanup
removes only hash/generation-matching owned integration files.

### D3. Idle delivery through the existing reservation contract

The existing host loop reconciles pending/current sources and uncertain journals,
then reserves a bounded immutable batch only when native `inspect` is eligible.
Limits remain 20 distinct delivery IDs, 10,240 payload bytes, and a 16,384-byte
wrapped source frame. Generic event kinds, including decision-answer wakes,
are accepted without a Codex-specific source-kind switch.

The host fsyncs its existing journal before `submit`. The bridge verifies the
request identity, generation, batch worker/epoch, exact payload SHA-256,
membership and size, then rereads durable worker state with the scoped protected
client. It fsyncs native submitting evidence before writing `turn/start` for the
bound thread. The input contains a JSON-encoded bounded source frame and an
instruction to reread canonical source state before acting; source content
grants no authority. No authentication material enters the source frame.
Canonical wake reason/hash and source references remain server-owned. A wake
does not authorize spawning/restarting a worker or transferring branch custody.

The `turn/start` response is correlated by request ID and thread, and its turn ID
is persisted before reporting `submitted`. Matching native acceptance proves
submission, not delivery handling or task progress. Positive rejection before
native write is `not_submitted`. Partial write, disconnect, unmatched acceptance,
lost response, cancellation after write, or timeout is `uncertain`. Identical
attempt retry consults protected evidence; it never starts another turn.

Pause or revoke races cannot erase an already issued effect. Final pre-write
checks prevent known ineligible dispatch; an effect whose outcome becomes
unknown remains fenced uncertain for reconciliation or captain disposition.

### D4. Explicit dynamic tools; no automatic tool-return delivery

Register narrowly scoped `agentboard_check_in` and `agentboard_ack` through the
installed dynamic-tools protocol only after verifying its version/schema. A
native tool request must match the bound thread, current turn, generation and
epoch; arbitrary client/model arguments cannot select another worker or secret.
Tool handlers invoke the existing protected Go worker operations with bounded
arguments. Credentials stay in protected files, never argv or rendered results.

Check-in returns the existing explicit responsibilities/obligations/pending
result, including catch-up-incomplete failures. It does not automatically append,
take, stamp, or acknowledge a frozen frame. Unrelated shell, MCP and infrastructure
tool outputs are unchanged. `tool_return` remains unsupported in this first slice.

Acknowledgement is an explicit model action with kind `received` or `handled`,
exact member delivery IDs, and a stable idempotency key. The handler verifies
the current native request and server binding before invoking `worker ack` using
the epoch receipt capability. The server still enforces frozen batch/hash/
generation membership and canonical source reconciliation. Retrying preserves
original attribution. Turn completion, text such as "done", socket acceptance,
heartbeat and check-in never generate handling receipts. Handling a CI notice
does not complete a task or certify CI green.

### D5. Health and a conservative capability matrix

Every `inspect` returns all five capability names with support and reasons.
Installed protocol negotiation, version/hash inventory, live identity and proof
are required; a version string or socket file alone is insufficient.

| Capability | Proposed proven profile | Without profile/conformance proof |
| --- | --- | --- |
| `idle_wake` | Native turn start under exclusive input ownership | Unsupported; manual check-in |
| `turn_start` | Source frame on bridge-owned new idle turn | Unsupported; no interactive prompt-hook claim |
| `tool_return` | Unsupported; explicit result only | Unsupported |
| `receipt` | Explicit exact-ID tool with live epoch capability | Unsupported automatic receipt path |
| `recovery` | Protected attempt and native acceptance correlation | Unknown/blocked if evidence is insufficient |

Connector reachability, native process/thread state and model heartbeat stay
independent. Unknown, not-loaded, system-error, in-flight turn, pending approval,
pending user input, paused, out-of-service/reserved, stale identity or lost sole
writer proof disables dispatch with a specific reason. Interactive composer
uncertainty reports `wake skipped: composer not confirmed empty`. Connector
reports never renew task claims or manufacture model activity.

### D6. Keep the server protocol and schema stable

Use current binding, reserve/result/reconcile, health and exact-receipt APIs.
Add only the Go adapter/config allowlist and owned install assets after approval;
server adapter fields already accept text under protocol 1. No migration is
anticipated. Any discovered schema requirement pauses implementation for a
coordinator-reserved schema number; no unreserved migration is authored.

## Risks / Trade-offs

- Dedicated-session enrollment does not fix existing panes automatically ->
  require an explicit captain choice and advertise their manual status honestly.
- Experimental Codex methods can differ by installation -> record installed
  schema/binary hashes and refuse unproven versions; preserve manual workflow.
- A second writer would invalidate preflight safety -> do not expose shared
  transports; fail closed on ownership ambiguity; prove conflict refusal.
- Acceptance can outlive disconnect/pause -> preserve uncertainty and never
  infer non-submission from an idle session or expired dispatch lease.
- Busy sessions can wait for a long turn -> retain durable pending deliveries
  visibly, with normal host polling; no arbitrary tool-result interception.
- Credentials or source text could leak -> use protected references, synthetic
  fixtures and selected metadata evidence; no raw credential-bearing logs.

## Proof and rollout gates

1. Captain approves this exact profile and implementation scope. Proposal-only
   review does not provision or activate anything.
2. Remote executable acceptance proves config/installation compatibility,
   capability refusal, hash/epoch/generation/ID fences, busy/approval deferral,
   foreign ownership, lost acceptance, restart/rebind, exact receipts and
   unchanged Pi/Claude behavior. Demonstrate pre-fix failures for substantive
   safety regressions; canned socket replies are not native conformance.
3. An explicitly authorized disposable actual Codex session proves idle wake,
   pending busy work without interruption, native request correlation, exact
   receipt actions, pause/availability, replacement and lost-response recovery.
   No live or reserved production session is prompted. Inspect output and
   publish version/hash-bound evidence; unexecuted cases stay untested.
4. Remote packaged Phoenix + host + adapter acceptance proves real reservation,
   received/handled receipt scope and health, not only an invented HTTP fixture.
   Schema and historical runtime release gates are reported separately.
5. Fetch/rebase current main, run no-mistakes without automatic approval,
   link this slice's own PR, publish validated architecture and portable review,
   and require current-head CI. Captain merges.
6. Separate captain authorization enrolls one canary; compare retained pending
   IDs, native attempt/turn, exact receipts, health and unchanged task ownership.
   Production fleet activation and broader parity remain separate decisions.

## Rollback

Durably pause/unbind the canary, stop only its owned bridge/service, retain
protected journals and pending deliveries, and use ordinary explicit board
check-in. Do not delete evidence to make the worker appear healthy. Unresolved
native effects require canonical reconciliation or explicit captain disposition.
No database rollback is required by this design.
