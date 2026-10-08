# Fair PR polling

An admitted PR poll owns its full bounded request allowance before any provider I/O. The shared GitHub budget stays at sixty charged requests per minute; allocation, request charging, rollover and refund use the same short PostgreSQL row lock. Network collection happens after those transactions commit.

## Admission and fairness

The collector reserves its existing hard maximum of 32 requests rather than estimating from the last suite count. This conservative allowance prevents newly added suites or pagination from partially consuming an undersized reservation. Insufficient allowance produces `budget_deferred` with zero provider requests. An eligible PR with an older observation (or registration when never observed) has priority; out-of-order dispatch yields `fairness_deferred` without spend. A live credit excludes its PR from a competing admission. The scheduler uses the same observation ordering.

Each HTTPS request consumes durable credit before connection. Completion returns unused credit; a killed collector's unused credit is reclaimed after its two-minute reservation lease. Used credit is retained. Active unused credit carries into a new minute before normal workflow/branch admission or another poll can use the refilled bucket. Refund is idempotent and cannot add credit to an unrelated window. Provider-enforced cooldown remains shared and may still interrupt collection; this change prevents local budget exhaustion from interrupting an admitted bounded poll.

## Conditional observations and cadence

ETag takes precedence over Last-Modified. A valid conditional304 reuses the complete cached representation and pagination metadata, and restores its charged request within the same window. A delayed304 from a previous window cannot mint new-window credit. Suite-list304 still leads to check-run requests, so changing pending CI is visible.

The cache is mutable private polling bookkeeping, never immutable CI evidence or a public read field. It is scoped to the operator-pinned API origin and credential digest, limited to64KiB per representation and512KiB total, and retains only routes from the completed current-head poll. Validators reject control characters and credential reflection; recursive response checks reject raw credential content, including JSON-escaped reflection. Cache updates bypass event/version capture. AshEvents may record the empty creation default; it never receives cached representations or validators.

A head, base, lifecycle or normalized check-state change resets cadence to60seconds; pending checks, computing mergeability and conflicts retain that cadence. Consecutive unchanged complete observations advance to120then300seconds. Explicit submission/link and existing base invalidation reset backoff. No new webhook registration is required. Merged PRs stay retired; closed PRs retain their existing hourly metadata-only reopen probe. The dashboard retains its existing180second freshness rule, so an observation can truthfully become stale during the five-minute stable interval.

## Dashboard and schema

List and detail reads expose remaining GitHub budget, provider cooldown and the age of an unresolved poll deferral. Successful observations clear deferral age. Migration28 adds bounded credit storage and private polling bookkeeping with a monotonic board schema update. Observation defaults and provider credentials are unchanged. This PR does not activate a deployment or merge a branch.

## Evidence

The primary owner is `build/integration/poll_budget_fairness_test.py`: packaged Phoenix and PostgreSQL, public CLI inventory, actual TLS provider requests and independent persisted budget assertions. All fixture identities, credentials and provider responses are invented. Eight open PRs with thirteen suites each receive observations within four simulated minute windows at the60cap. Those windows advance persisted eligibility/deadlines; this is a deterministic workload bound, not a claim about deployed wall-clock performance or provider availability.

- Initial zero-spend regression RED on production63c76bc: [b80359a9](https://carverauto.buildbuddy.io/invocation/b80359a9-a546-4333-855b-6c9c928e1b17).
- Minute rollover regression RED before carryover repair: [70334e03](https://carverauto.buildbuddy.io/invocation/70334e03-d1c5-4dc8-ac0e-47386d963784).
- Fairness and hostile collector sibling PASS, including8x13 workload, concurrent admission, crash refund and rollover: [587ff300](https://carverauto.buildbuddy.io/invocation/587ff300-7557-460d-a5a7-88e4b5830df1).
- Board API, polling and scheduler PASS: [9481c086](https://carverauto.buildbuddy.io/invocation/9481c086-7af1-45e5-918a-8ef798ef94b4). Its earlier fairness assertion failure was corrected against AshEvents' empty create default; cached bodies/validators remain forbidden.
- Migration/retained historical data and collector PASS: [a6368748](https://carverauto.buildbuddy.io/invocation/a6368748-5688-465c-b03a-aa142445cb3b).
- Final formatted owner/collector/migration suites **3/3 PASS**: [bea902c9](https://carverauto.buildbuddy.io/invocation/bea902c9-109a-48d0-8afe-be9797c27353), including stable300second-to-changed-head reset, Last-Modified and credential rotation.
- Remote source formatting PASS: [d826120a](https://carverauto.buildbuddy.io/invocation/d826120a-5413-41c3-9a29-74e0c371e380), artifact fetched via [53a230db](https://carverauto.buildbuddy.io/invocation/53a230db-e79a-4d9f-bc98-2a8426b703d5) and applied only to owned changed Elixir files, retaining one trailing newline.

All build/test/format execution uses remote Bazel. No workstation compilation or deployment proof is claimed. Native no-mistakes and current-head GitHub CI remain publication gates.

## Diagram validation

[Interactive diagram](pr-poll-budget-fairness.html) and [source](pr-poll-budget-fairness.workflow.json) reflect this implementation. Deterministic showcase delivery:9/9checks, zero errors/warnings. Automated browser checks: containment/readability pass at1440×900,1600×1000,1920×1080and2048×1320. Perceptual review: four endpoint light/dark screenshots inspected, passed with zero correction rounds. Separate receipts preserve those evidence boundaries; the diagram review is not a dashboard visual test.

## Structural review

The bounded ripwire quality loop removed duplicated validator/check-name predicates through one bounded text helper. Remaining reported gates are recent churn, increased module size and a short SQL-row traversal shared structurally with the scheduler. Provider admission retains budget/credit lifecycle together because allocation, carryover and refunds require one lock and invariant; introducing a cross-domain generic SQL traversal would obscure the ownership boundary. Migration callbacks are discovered by Ecto, despite static dead-code diagnostics. These are conscious tradeoffs, not a clean structural-metric pass; owner-boundary tests and native review provide the behavioral checks.
