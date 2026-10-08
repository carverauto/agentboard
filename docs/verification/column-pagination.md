# Column pagination verification

Issue: https://github.com/carverauto/agentboard/issues/56

## Remote behavior

All builds, tests and asset compilation used `./scripts/bazel` remote execution.
Fixtures were invented through the public CLI and a disposable TLS PostgreSQL
instance; no production data was exported or production database mutated.

- Baseline [9f406577](https://carverauto.buildbuddy.io/invocation/9f406577-b3ef-4bf0-bee0-fe109fd3aa4c): real LiveView Done header was 20 for 41 matching tasks, failing the intended total assertion.
- Fixed [582dcf55](https://carverauto.buildbuddy.io/invocation/582dcf55-0b6e-42ea-a046-41df9aee1f74): paging, board API and archive suites passed.
- Final [d9bef396](https://carverauto.buildbuddy.io/invocation/d9bef396-e28a-4fd2-93e8-e3c732d493b5): all three suites passed after header-level controls and bounded count reads. Formatter-only whitespace was applied afterward; native No-mistakes revalidation is still required before publication.

The paging test opens a real LiveView WebSocket. It verifies total41/page20,
independent Done/Open advancement, Prev restoration, final-page boundaries,
invalid events, repository/owner filter resets and retention of all seven lanes.
A narrow decoder consumes the pinned Phoenix rendered wire protocol so assertions
inspect generated public HTML, not implementation strings. Archive/API companion
suites exercise retained read-only, update/fallback, archive and outage contracts.

## Browser scope

Exact server-rendered first/second/last page output and remotely compiled CSS
were captured by the integration test. Chrome inspected the second-page snapshot
at 1440x900 and 390x844 in light/dark themes. No page-level horizontal overflow;
all seven lanes remain, narrow horizontal scrolling is confined to the existing
lane container, totals and controls are readable. Stable Next Done button can
receive focus. Separate image inspection passed for desktop and narrow captures.
These are offline rendered-product snapshots; clicking/navigation is proven by
the remote WebSocket test, not by the offline browser. Persistence of focus across
a live DOM patch was not independently browser-driven.

The screenshot wrapper reported BROWSER_ERROR despite writing valid PNG files;
files were inspected independently. Emulation resets unspecified viewport fields,
so final captures explicitly set both viewport and theme. Invalid earlier captures
are not used as evidence. This is supplementary manual product-browser evidence,
separate from the clean Archify automated receipt.

## Archify delivery

Architecture source references code commit1cf97599af846676d346c7dc21b7a2a6a7059466.
Deterministic showcase9/9, zero composition errors/warnings. Two focused geometry
repairs moved diagnosed route labels; source frozen after acceptance.

- specification SHA256: ce269d96e74e654d3a8fbbbb701bc3226925ef6d4c8adcb17cc8bada5523efba
- standalone HTML SHA256: 7f8d08c3e6b1b096c44de31a577a4afb042d18597ae480fc0becbe0e27141e30
- automated browser: passed at1440x900,1600x1000,1920x1080,2048x1320 with light/dark captures.
- perceptual review: passed after image inspection at1440 light and2048 dark; readable composition, clear routes, balanced vertical space.

## Structural review and delivery

Ripwire ref-pair quality delta found four minor verbosity rows, no gating
regression; churn is unavailable in this measurement. Name-based graph traversal
cannot discover the Python HTTP/WebSocket coverage, so zero indexed tests is not
claimed as proof. The real remote suites supply that boundary evidence.

Native review, final PR/full-head documentation upload and GitHub CI receipts
remain publication steps. Captain owns merge and deployment. No migration or
runtime flag changes are part of this work.
