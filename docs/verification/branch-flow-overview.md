# Branch-flow overview verification

## Scope

First, default-off product increment for #185, based on freshly fetched main
`a46cca5bb93109fe9afd0acce2bc546bd94b8292`, then rebased onto
`c723301` including merged #197 and Docker Hub authentication #199. The only
rebase conflicts were additive test manifests; both suites were retained.
Captain approval covers #186 followed by #185. No schema identifier is allocated.

The authorized narrower increment is documented in [branch-flow.md](../branch-flow.md):
bounded persisted inventory/overview, exact table filters, independent paging and
global retained-red attention. Busiest-only cards are explicitly a preview, not
an implementation of the pending captain-pinned contract. The design's broader
shared settings/intake/topology/glyph/count work remains open.

Implementation and checks use the disposable assistant Linux VM and an ordinary
linked worktree under the explicitly granted Git workflow exception. No maintainer
computer, live board, worker, provider setting, credential, schedule, merge or
deployment was changed. No live product opt-in occurred.

## Verification status

Checks run in the disposable Linux VM (not remote Bazel):

- Go unit tests, race tests and vet passed. A current-source CLI was built for
  packaged integration checks; VCS stamping was disabled after the toolchain's
  automatic VCS status lookup failed.
- 136 ExUnit tests passed, including eight route cases and eight component/event
  cases. Production compilation, Tailwind CSS, esbuild JS and release assembly
  passed. Existing unrelated compiler warnings were not promoted to errors.
- The new normal-role PostgreSQL/HTTP/LiveView suite passed before optimization
  and again after the fresh-main rebase. The final optimized suite also passed
  in an America/Chicago session with append-only source-proof regression fixtures.
  Its fixture-only Oban supervisor was stopped to prevent unrelated Cron inserts
  at minute boundaries from contaminating read-mutation digests. It exercises exact Unicode/slash/case filters; cross-repository and
  malformed selection rejection; independent/invalid cursors; terminal/unknown/
  disabled inventory; retained oldest red outside the strip; repeated selection,
  search, reset, terminal toggle, refresh, route-history reconstruction and rejoin;
  ranking stability; partial database failure/restoration; real query plans and
  bounded DOM/read results. Provider requests and producer/business/job mutation
  digests remain unchanged through read interactions.
- The rollback-only rich parity fixture compares all row fields across twenty
  PR scenarios, including absent/policy-unknown/stale/terminal/mismatched evidence,
  resolved/active repairs, duplicates, worker health, twenty-three decisions and
  twenty-three delivery events. Batched and original detail projection have zero
  differences, including reverse/repeated inputs and latest-resolved semantics.
- Workflow intake/recovery, PR conflicts/base revision fences, CI accountability
  and merged coordinator-triage regression suites passed with the rebased release.
  The conflict suite requires its declared observation flag and UTC fixture;
  initial invocations with missing flag/non-UTC setup failed, then the original
  unmodified suite passed on a fresh UTC fixture. No product change was made to
  mask those harness conditions. Final post-batching conflict, CI-accountability
  and coordinator-triage suites all passed as well.

Independent read-only review found and verified fixes for stale table counts/
cursors after failed navigation and unproven branch metadata surviving the exact
snapshot guard. Final review found no remaining blockers in this preview scope.
All 231 production/configuration/asset/test/migration files checked against the
build workspace matched the final source. Formatting, whitespace, Python syntax
and local documentation-link checks passed.

The test targets are
`//web:branch_flow_test`, `//web:branch_flow_live_test` and
`//build/integration:branch_flow_test`; all are registered in `//:acceptance`.

The real integration suite uses disposable certificate-verified TLS PostgreSQL
with a non-superuser application role, the packaged production release, a local
TLS provider spy and the pinned LiveView renderer. It covers actual database reads,
HTTP and WebSocket routing/render diffs, rather than pretending rendered HTML is
a browser accessibility test. Fixtures are synthetic.

## Explicit limitations

- Remote Bazel/BuildBuddy execution is unavailable without `.bazelrc.remote` and
  authorized BuildBuddy credentials. No local Bazel fallback is used.
- The VM prohibits AF_UNIX socket creation, blocking installed Chromium's
  process-singleton socket. Browser viewport/theme/zoom screenshots, keyboard
  and screen-reader interactions are unrun. Protocol navigation and semantic
  HTML tests do not replace those checks.
- Read-only dependency batching reuses the existing qualification functions;
  it does not implement #169 producer/effect-admission/currentness ownership.
  Rich duplicate/worker/delivery projectors can add queries. The fixture ceiling
  below is not a universal request-cost guarantee. Hosted runtime performance is
  not established.
- OpenSpec CLI, Archify and Lavish artifacts/tool validation and authorized
  task-document uploads remain unavailable. No claim that these requirements
  are completed is made.
- Docker image builds, hosted current-head CI and rollout checks are separate
  publication/deployment stages. Presentation and integration intake activation
  remain separate explicit operator decisions.

## Per-request read budget

These are complete individual dashboard refreshes, not totals over the suite.
The initial preview made 207 database calls: 160 repeated per-row reads, 26
savepoint commands, five setup/transaction calls and sixteen other reads. Its
small/large timings were about 92/167 ms. That cost was reviewed and optimized
before publication.

In the first optimized run:

- Small preview: 67 calls, 156 returned SQL rows, 29.316 ms
- 1,028-repository / more-than-10,000-PR preview: 81 calls, 156 rows, 66.599 ms
- Unmodified legacy list on the same fixtures: 167 calls, 115 rows,
  65.793/68.194 ms

The small/large difference is six versus twenty distinct named-base identities
on the bounded twenty-row table page. Those reads still call the authoritative
base projector. The synthetic suite explicitly caps this scenario at 85 calls,
checks every SELECT/CTE with EXPLAIN ANALYZE/BUFFERS, and verifies five cards,
fifteen relations, twenty table rows, twenty chooser rows and ten attention rows.
These timings are individual VM samples, not P95 or hosted production claims.

Proposed performance gate before separately authorized rollout: exercise at least
ten concurrent five-second refresh clients with representative rich twenty-row
pages, publish per-request query counts and P95/max latency, and demonstrate P95
below one second with no statement over the existing two-second statement budget.
This gate, actual-browser accessibility and deployment verification remain open;
the preview is not advertised as fully production-ready.

The final full-suite rerun reproduced 67/81 calls and 156 returned SQL rows, with
small/large timings of 26.808/85.860 ms. Corresponding legacy-list samples were
167 calls and 79.797/86.657 ms. Rich parity again returned twenty compared rows,
zero differences and a confirmed rollback. Provider/request and business/job
digests remained unchanged. These final samples include the exact-source guard,
metadata-clearing regression, explicit relation ordering and failed-route reset.
