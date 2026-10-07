# Claude native boundary adapter

`claude-hook-v1` adds an explicitly loaded Claude Code plugin to the supervised
worker runtime. The plugin preserves existing settings hooks and does not add an
idle wake owner. Its native `prompt.submit` hook appends a frozen source frame to
context while preserving the user's prompt and existing context. Its dedicated
MCP check-in tool retains the original result and appends an eligible pending
frame. Other tools are unchanged.

The first supported profile is a deliberately enrolled headless Claude session
with native mods available. Claude 2.1.289 is the installed version used for
conformance. A version number alone does not prove availability: the installed
binary can report a saved-off rollout until startup refreshes it. If no native
session generation is established, the adapter reports unsupported and refuses
submission. An ordinary explicit `agentboard worker check-in` remains available.

## Installation and enrollment

`agentboard worker install` previews the owned service and adapter files. An
explicit `--apply` installs a plugin directory under
`~/.config/agentboard/worker/claude-native`; it does not load the plugin, edit
Claude settings or enable a service. Foreign or modified files are refused.

Choose a short, private directory (0700) and a socket unique to the session. Set
these variables only on the newly enrolled session:

```sh
export AGENTBOARD_CLAUDE_SOCKET=/ABSOLUTE/PRIVATE/DIR/cc
export AGENTBOARD_WORKER_CONFIG=/ABSOLUTE/PROTECTED/config.json
export AGENTBOARD_WORKER_ID=codex-example-worker
export AGENTBOARD_WORKER_BINARY=/ABSOLUTE/PATH/agentboard
claude --plugin-dir /ABSOLUTE/HOME/.config/agentboard/worker/claude-native
```

Node must be available to Claude's MCP child. The child is supervised through
MCP stdio; no shell watcher or model supervisor runs. Loading skills alone does
not enroll a worker. Preserve normal Claude settings for a user session; the
empty settings-source list used in isolated conformance is not a recommendation
for existing sessions.

Read the generated `cc.identity.json` descriptor and create a protected worker
binding using its exact `session_id` and `generation`. Set the binding's
`harness` to `claude`, `adapter` to `claude-hook-v1`, and `socket_path` to the
chosen socket. Other config fields and protected host/receipt token references
follow [worker-runtime.md](worker-runtime.md). Run the existing explicit
`worker bind` and `worker doctor` commands against the supported server before
enabling host dispatch. Binding does not silently enable the worker.

The descriptor is local native identity evidence, not server authorization.
Each source delivery rechecks durable enabled/paused state, epoch, session and
generation through the scoped API. A successful native submission or a model
turn ending never records received/handled. Those receipts require exact IDs
and a stable key through the dedicated ack tool or explicit CLI.

## Lifecycle and readiness

`session.end` invalidates the generation before awaiting other middleware or
I/O. Resume, fork, clear and plugin reload establish a fresh generation from
Claude's native session ID and require explicit verified rebind. Interrupted
check-ins are cancelled; accepted attempt evidence is retained. An old or
uncertain attempt is never automatically replayed into a new generation.
Existing sockets/evidence require explicit stale-owner inspection after a crash;
the plugin refuses takeover.

| Capability | Readiness |
| --- | --- |
| Turn start | Native prompt context, preserving the original prompt and foreign context |
| Tool return | Dedicated Agentboard MCP check-in only; original result retained |
| Receipt | Explicit received/handled with exact IDs and protected epoch capability |
| Recovery | Protected attempt evidence and generation retirement; uncertain replay refused |
| Idle wake | Unsupported: atomic composer and competing wake-owner guards are unproven |

A boundary-only batch waits for the next prompt or check-in. It cannot wake a
paused or idle session itself. Firstmate remains the existing wake owner if
installed; its hooks are preserved. Interactive, Desktop, App and resumed-session
readiness must be proven separately rather than inferred from a headless result.
Herdr automation remains disabled.

## Evidence

Installed Claude headless conformance consumed a source frame at a native prompt,
received a batch that arrived while check-in was running, and explicitly recorded
exact received/handled receipts. Resume retained the session ID with a fresh
generation; fork changed the session ID. Old config and old attempt evidence
were refused. [The retained proof](verification/worker-claude-live.json) uses an
invented API, so it does not satisfy the separate published-server gate.

Remote conformance executes the real MCP child and Unix socket protocol, native
callback entry points, protected evidence, pause checks, exact receipt calls and
retirement during an in-flight guard. The invented engine/API fixture is distinct
from installed-Claude proof and published-server interoperability.

- [Remote adapter and worker tests](https://carverauto.buildbuddy.io/invocation/a05541bd-476c-4610-8ae2-ff9c80c020e3)
- [Remote Darwin binary build](https://carverauto.buildbuddy.io/invocation/1a465c0f-0ba3-4b2a-8639-e27602fbb9a2)
- [Architecture](architecture/claude-native.html), with retained JSON, artifact and browser receipts

OpenSpec 6.3 remains open until both Claude and Pi lifecycle and installed-harness
requirements are complete. This slice makes no parity claim for later harnesses.

A delayed-bind regression first failed remotely because an old prompt consumed a
replacement's pending frame. The fix pins the bind callback to its original
lifecycle revision and recipient; the replacement retains its own source.
[Pre-fix reproduction](https://carverauto.buildbuddy.io/invocation/58e70254-6dfe-4ac2-bf64-08ca4a91f31d).
