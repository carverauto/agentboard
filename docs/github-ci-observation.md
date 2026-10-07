# Current-head GitHub observations

This stage implements runtime task 1.3. It collects sampled **head-only** CI evidence through the existing Ash poll action. Observation remains default-off; a live CI repair loop is not deployed. Configured head-policy recovery, repair obligations and scoped worker delivery are implemented separately in the opt-in server runtime; see [server accountability](server-accountability.md). Verified merge/test refs, BuildBuddy correlation and richer Actions diagnostics remain their separate approved gates.

## Collection and interpretation

Each per-PR job commits its 120-second reservation before calling GitHub. The collector reads PR head/base/lifecycle, pages check suites for that exact head, pages each suite's runs with `filter=all`, and pages commit statuses. Enumerating suites avoids the ref-level check-run endpoint's 1,000-suite coverage cutoff. It then rereads PR metadata: changed head, base or lifecycle makes the result incomplete. Returned runs with another head are rejected, not attributed to the current revision.

Check-run contexts are grouped by provider app ID and exact name; statuses use their exact context. Numeric provider IDs select the newest retained attempt and deterministically order equal-time attempts, including queued reruns with no start time. Completion time does not let an older late-finishing failure supersede a newer attempt. Older attempts remain in the snapshot. This context normalization is not proof of workflow identity, required policy or merge-ref applicability; those richer policy/attempt contracts remain pending.

Complete current-head failed conclusions (`failure`, status `error`, `timed_out`, `cancelled`, `action_required`, `startup_failure`) produce `failing`; otherwise a latest nonterminal attempt produces `pending`. A clean, empty, skipped or neutral set remains `unknown`: this stage has no policy that can certify `passing`. A security-only success cannot satisfy a missing acceptance check. These observations cannot authorize task completion or resolve a repair obligation.

A completed collection appends one immutable Ash `CISnapshot` keyed by canonical PR/generation and atomically updates its PollState projection. The final Ash update filters the live attempt UUID, generation, enabled bit and database-clock lease expiry. A superseded response cannot append a snapshot or replace current evidence. Meaningful head/base/state/lifecycle changes participate in PaperTrail/AshEvents; unchanged sampling timestamps and scheduler reserve/defer calls do not create repetitive audit versions. The snapshot itself retains each complete sample. A failed audit insert rolls back both snapshot and projection. Task/link/submission history is untouched.

Provider errors append no successful snapshot and retain last-known evidence with a durable `last_error` and retry time. Consumers must display the degraded/unknown observation separately from the prior state; old successful evidence is never a fresh passing certification. `policy_unknown` on a complete sample explicitly records the absent policy. Observation freshness and the planned dashboard are later reads, not inferred from a heartbeat.

## Bounds and provider isolation

- At most 32 HTTP requests and 90 seconds per collection, ten pages per endpoint, 100 items per page, 500 total normalized attempts, and 240,000 encoded attempt bytes. Any exhausted bound, duplicate provider IDs or incomplete/inconsistent pages yields incomplete evidence.
- Mint 1.11.0 owns a passive HTTP/1 connection in the job process. TLS verifies the destination certificate/hostname. Each request has a ten-second deadline including connection time, a five-second connect bound, a 16 KiB parser header-section bound and a streamed 1 MiB body bound, including chunked/error responses. Connections close on every exit. No redirects, automatic retries, singleton HTTP manager or SQL GenServer is added.
- Each actual request, including metadata rereads and additional pages, acquires a shared PostgreSQL GitHub token after the reservation commits. The seeded window is 60 requests/60 seconds across replicas; the separate BuildBuddy window remains 30 admissions/60 seconds. These are conservative server pacing bounds, not claims about provider quota entitlement.
- 429, primary exhaustion/reset and secondary 403 establish a provider-wide nondecreasing cooldown. Retry-After/reset are lower bounds with a 60-second minimum fallback. Other PRs cannot send during that deadline, including after supervisor restart. A PR defer is at most seven days; a longer provider deadline remains authoritative and another check-in still sends no request. Authentication denial defers five minutes; ordinary unavailable/incomplete results defer one minute. No sleep or provider I/O holds a database lock.
- A complete observation remains due in 60 seconds. Scheduler backlog, shared budget, provider cooldown and collection bounds can delay that; this stage promises no fixed detection/delivery SLA. No PR is automatically unmonitored because it was green or its source task ended. Lifecycle is stored separately; the later policy/obligation stages own final terminal reconciliation and disposition.

## Configuration and source safety

`AGENTBOARD_PR_OBSERVATION_ENABLED=false` is still the default. Keep it off until the first-release live proof. `GITHUB_TOKEN` is server-only, loaded from a namespace Secret at rollout; the CLI receives neither it nor database credentials. The collector reads PR metadata, Checks and commit statuses, so the eventual credential must have repository access and read scopes for those endpoints. Real entitlement and Agentboard acceptance-check publication are still rollout gates.

`AGENTBOARD_GITHUB_API_URL` defaults to `https://api.github.com`; only an explicit HTTPS origin without userinfo/query/fragment/path is accepted. `AGENTBOARD_GITHUB_CA_FILE` can supply an operator CA bundle; the default is the pinned CAStore bundle. Provider text cannot choose the authenticated destination. Next-page links are checked against that configured origin/path/page, then the next URL is constructed locally. Advertised details/log URLs are never fetched. Bounded query-free HTTPS GitHub/BuildBuddy source links are retained; other links are omitted. Stored names containing the configured token are rejected, and raw provider bodies, credentials and request headers are not error/audit output. No log excerpts or model interpretation are delivered here.

## Verification and remaining scope

The primary remote fixture drives the packaged release's public Ash poll action against invented HTTPS provider data and real TLS PostgreSQL. It owns wire pagination/revision/attempt truth, bounds and shared HTTP cooldown; sibling fixtures own scheduling, reservations and legacy board behavior. Live provider entitlement, old-image rollback and a real failed PR returning to a worker remain first-release acceptance, not claims derived from fixture success.

The quality scan reports module growth in PollState/Polling, six pagination accumulator parameters and a small DateTime parser idiom shared with quota. They retain the resource/action, reservation and pagination boundaries rather than exporting a quota helper or splitting modules to satisfy a length metric. Dynamic Ash actions/migration callbacks marked as unused are exercised remotely. This is a recorded tradeoff, not a claim of a clean quality scan.

See [the collector architecture](architecture/github-ci-observation.html), [reservation/scheduling contracts](ci-polling.md), and [the approved runtime checklist](../openspec/changes/align-agensh-worker-runtime/tasks.md). The portable proposal remains the immutable approved planning snapshot; current progress lives in Markdown.


The [full 19-target remote acceptance](https://carverauto.buildbuddy.io/invocation/ba9ffc78-3106-4bc0-bbdd-44b101eecadb)
passed with 14 executed targets and five unchanged cached targets. The final
collector fixture passed in 26.2 seconds, covering wire/TLS bounds, pagination,
latest attempts, complete-head failure/unknown evidence, shared cooldown,
audit rollback and replacement-generation rejection. Earlier remote failures
exposed unsupported OTP 28.1 httpc bounds, a fixture CA-chain error, schema SQL
quoting and a scheduler/quiescence race; these were corrected before this pass.
The final transport uses the pinned passive Mint client rather than unsupported
httpc cap options. No real provider or active worker delivery is claimed.


The source-bound Archify delivery passed 9/9 showcase checks with zero errors
and warnings. Automated browser containment passed at 1440x900, 1600x1000,
1920x1080 and 2048x1320; separate perceptual image review covered 1440 light and
2048 dark. One diagnosed relationship-label placement correction was needed.
Viewer interactions are not covered by that image review. Retained receipts
are beside the HTML in `docs/architecture/`.
