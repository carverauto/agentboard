# Packaged host/server acceptance

The remote-built public host CLI now passes against the packaged Phoenix release
and real PostgreSQL. Only the native socket recipient is invented in this test.
The host receives no database credentials; fixture setup uses the release RPC,
while host commands use the public API.

[Fresh five-suite acceptance](https://carverauto.buildbuddy.io/invocation/43d0c2e6-3ab7-4292-be09-27c771ad62a2)
covers the packaged test, host transport/runtime, Pi native contract, CLI and
HTTP client. The packaged target is part of `//:acceptance`; BuildBuddy runs it
for future PRs.

The real API/CLI boundary proves enrollment/bind and secret omission, default-off
source retention without dispatch, immutable batch membership, arrivals outside
an active batch, exact received/handled receipts and idempotent attribution,
foreign-ID refusal, restart without replay, pause/resume, generation replacement
with historical journal reconciliation, and revoked-host refusal. Submitted or
completed turns never acknowledge the remaining deliveries automatically.
The test deliberately shuts its invented HTTP listener down before host commands.

The [Darwin arm64 binary](https://carverauto.buildbuddy.io/invocation/759a4772-c929-40fe-a36f-0c9ea78a6cb5)
has SHA-256 `09ee1a9deaf555fcd1e7047e3374fc7133a91cc4057ffb924e26bfcf8ad779e3`.
A private immutable copy was used for the named
`agentboard-b-runtime-20261008-conformance` Pi 0.99.2 exclusive RPC sessions.
With xAI/Grok 4.3, the actual idle model consumed the source frame and explicitly
handled both exact IDs. A separate busy model consumed it at the dedicated
`agentboard_check_in` tool return while preserving its original result.
Both runs replaced the session, rejected the stale CLI identity, and explicitly
rebound at epoch 2. Session and receipt records are in
`worker-packaged-pi-live.json` and `worker-packaged-pi-busy-live.json`.

These live Pi runs use invented HTTP contracts. They are distinct from packaged
server acceptance and do not establish a live published-server end-to-end run.
The supported profile remains exclusive RPC with one wake owner. Herdr automatic
prompting, Pi TUI input and blanket cross-harness parity remain unsupported here.
The initial fresh Pi attempts failed honestly on ZAI 429 quota exhaustion,
Codex OAuth refresh 401 and DeepSeek 402 insufficient balance; they supplied no
passing evidence. Each owned probe was stopped.

Disposable operator inspection of both launchd and systemd files passed preview,
repeat installation and owned uninstall with an unchanged foreign hook. launchd
uses KeepAlive; systemd uses Restart=on-failure. The generated service argv points
at the owned binary and protected config reference. No service was activated.
See `worker-packaged-install.json`.

OpenSpec host tasks 2.4–2.6 now have shipped implementation plus fresh executable
proof. Production enrollment/assets/activation/rollback in 3.4 require captain
inputs, and the controlled real failing-PR/reminder/restart/repaired-head
demonstration in 3.2–3.3 remains open. No global host service, automation,
production rollout or merge is authorized by these receipts.
