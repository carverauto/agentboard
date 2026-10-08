# Host runtime evidence

The remote-built CLI uses only the Phoenix HTTP API. No local Go/Elixir compilation, real user-session prompting, global service activation, automatic merge or deployment was performed.

- Full 20-target remote acceptance: https://carverauto.buildbuddy.io/invocation/76cfaa7c-dc47-41ea-923c-1f0f603896fd
- Public CLI scenarios including supplied protocol1 wire fixtures: https://carverauto.buildbuddy.io/invocation/22bd9b57-4f69-4257-8ea7-c77bc4648ea8
- Focused checks after durable service writes and canonical doctor validation: https://carverauto.buildbuddy.io/invocation/94de22f5-0eb6-4670-b63e-ddaa03b6cdbb
- Native lifecycle/socket fixture, unsupported TUI profile and oversized frame: https://carverauto.buildbuddy.io/invocation/9b5b3d7c-5d7c-4e68-ad40-d1603f406486
- Darwin arm64 remote binary used in live proof: https://carverauto.buildbuddy.io/invocation/5433870a-2728-41e9-8db0-846c059ba6f6

Actual Pi0.99.2 isolated RPC model runs are recorded in `worker-pi-live.json` and `worker-pi-busy-live.json`. Idle wake, exact received/handled receipts, busy dedicated tool-return preserving original content, generation retirement, stale identity rejection and explicit epoch2 rebind passed. These use invented HTTP API contracts. They do not establish real packaged Phoenix interoperability. First-release automatic support requires an explicitly selected `exclusive-rpc` profile and one wake owner. TUI occupied composer/approval states remain unsupported; native contract fixtures verify refusal when occupied/unknown. Existing user's sessions were untouched.

Installed Herdr0.9.0 protocol22 lacks expected occupant/composer guard fields; automatic prompt is disabled. The named conformance server was inspected and stopped without input. Installed Codex/Claude/Grok/Muse/AGY sessions are manual/unsupported for this runtime; no universal automatic claims are made.

Packaged Phoenix plus host interoperability and controlled failed-PR → reminder → connector/session restart → repaired qualifying head proof remain separate release gates. OpenSpec joint tasks3.2–3.4 remain open. Merge order is collector → server → worker. Captain/coordinator owns rollout.

## Maintainability review

Ripwire identified new complexity in the explicit dispatch state machine, native lifecycle and CLI registration. The external-I/O journal boundary and atomic file publication were extracted; remote public-interface tests cover their behavior. Lifecycle closures intentionally retain one generation owner. Remaining complexity follows explicit cancellation, custody, protocol and uncertainty branches rather than new generic abstractions.

Two reported preexisting regressions are understood: `config.Actor.Validate` is still called at `internal/cli/root.go`; a new batch method with the same name confuses the name-based graph. `worker.delay` repeats the small context-cancellable timer idiom used by the private client retry helper; exporting transport internals only to share that idiom would widen the contract. Neither finding was silently suppressed. Public subprocess tests provide coverage beyond the static name graph.

Archify source, standalone HTML, delivery receipt, light/dark browser captures and image review are stored under `docs/architecture/supervised-worker.*`. Browser layout checks and separate human-style image inspection passed. No screenshot substitutes for protocol or live session evidence.

## Published server contract acceptance

[Fresh packaged API/host proof and named isolated Pi evidence](worker-packaged-api.md)
close the host acceptance gap after the server shipped. The live Pi model proof
and real packaged API proof remain distinct. Captain-gated production enrollment
and the controlled failed-PR/reminder/repaired-head demonstration remain open.
