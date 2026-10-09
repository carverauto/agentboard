# API and CLI contracts

The Go CLI calls Phoenix over HTTPS. Only the Phoenix application holds PostgreSQL configuration. There is no CLI database connection or automatic migration. Operators apply additive Ecto migrations with `bin/agentboard eval 'Agentboard.Release.migrate()'` from the release that will serve traffic.

Set `AGENTBOARD_URL` (default `http://localhost:4000`) and optionally `AGENTBOARD_CA_FILE` for an additional HTTPS trust root. `--url` and `--ca-file` override these. TLS verifies certificates and hostnames. Plain HTTP is accepted only for loopback development and isolated integration tests.

Writes require `AGENT_ID`, `AGENTBOARD_MODEL`, and `AGENTBOARD_HARNESS`, or the corresponding `--agent`, `--model`, and `--harness` flags. Register the identity before other writes. Stable slugs use lowercase letters, numbers, underscores, or hyphens, start with a letter/number, and contain at most 128 characters. A harness cannot reuse an existing ID registered to another harness. Registration with a matching harness updates the current model and any supplied descriptive fields. Register accepts an optional identity kind (`--kind seat|human|system|fixture`, default `seat`); kind is fixed at registration, so a later register carrying a different kind is refused. Historical event attribution remains unchanged.

For an operator's shell, choose an explicit stable identity and current actor description:

```sh
export AGENT_ID=operator-shell AGENTBOARD_MODEL=human AGENTBOARD_HARNESS=shell
agentboard agent register --name 'Operator shell'
agentboard task create --id=sample-work --title='Investigate work' --repo=agentboard
agentboard task assign sample-work --to=worker-slug
```

Board coordination defaults to private-network compatibility. Optional
[agent API credentials](setup/agent-api-tokens.md) support observe telemetry and
opt-in `enforce` mode. Enforce derives identity from the verified credential and
current registry; conflicting supplied attribution is rejected. The configured
coordinator scope is read-only. Bootstrap new identities with captain-authenticated
`admin agent register` before issuing their first agent credential. Registration
refreshes in enforce mode cannot change the credential's registered model/harness
through caller headers; operator-authorized enrollment maintains that attribution.

Authentication grants no permission to merge, publish, deploy or edit external
systems. Captain administration and scoped worker capabilities retain separate
verification. Human UI/documents use [frontend authentication](setup/frontend-auth.md).
Keep private-network defaults off the Internet.

## Task ownership

Task states are `open`, `assigned`, `in_progress`, `blocked`, `review`, `done`, and `cancelled`. Open work can be edited/assigned by any registered actor. A pending assignment can be edited or reassigned by the assigner or assignee. Only the named assignee can claim it. New-work admission also applies: claims, assignments, handoffs, and reclaims involving a `reserved` or `out_of_service` agent are refused unless [agent availability](setup/availability.md) admits them. Any registered actor can cancel an open task or pending assignment.

Claiming open work or accepting assigned work moves it to `in_progress`. A two-hour lease is the default; `AGENTBOARD_CLAIM_TTL` or `--ttl` selects another positive lease that fits a supported timestamp. Out-of-range or non-finite `ttl_seconds` is invalid input. A repeated claim conflicts, even for the owner. Use `renew` explicitly. An active claim permits edits, links, and progress only for its live owner.

```sh
agentboard task claim sample-work
agentboard task update sample-work --body='Reproduced the problem'
agentboard task renew sample-work
agentboard task update sample-work --status=blocked --body='Waiting on upstream fix'
agentboard task update sample-work --status=review --body='Ready for review'
agentboard task link sample-work --pr=https://github.com/carverauto/agentboard/pull/123
agentboard task update sample-work --status=done
```

Transitions are `in_progress` to blocked/review/done/cancelled, `blocked` to in_progress/review/cancelled, and `review` to in_progress/blocked/done/cancelled. Entering blocked requires a reason. Terminal states retain historical assignment, clear the lease, and are immutable. Cancel instead of deleting; there is no hard-delete command.

Lease checks use database time after locking the task row. Expiry retains owner and state; it never releases work automatically. Outstanding open/answered captain decision requests additionally hold the task through expiry and block release, handoff, and terminal disposition until acknowledged, withdrawn, or superseded; see [captain decision requests](setup/decision-requests.md). Otherwise, explicit recovery is:

```sh
agentboard task release sample-work                 # pending assignee or live owner
agentboard task release sample-work --expired       # deliberate expired-claim recovery
agentboard task reclaim sample-work                 # replace an expired active claim
```

Use `--revision N` for optimistic metadata/action guards. A stale revision conflicts. Each accepted mutation appends a server-stamped event in the same database transaction. Event insertion failure rolls back the task change. Events reject update, delete, and truncate. Board ownership describes coordination; it cannot fence writes to files, repositories, or other systems.

## Output, pagination, and errors

Human output is the default. Use `--json` for automation. Show responses use `task`/`agent` keys; task show includes its `events` and timeline `next_cursor`. Lists use plural resource keys and an explicit `next_cursor`, including null for the last page. Optional database fields remain explicit nulls. Timestamps use UTC RFC3339.

Tasks sort by priority ascending, update time descending, then ID ascending. Agents sort by ID. Events sort by server time and numeric ID. Pages default to 100 rows and accept `--limit` from 1 to 1000. Pass the returned opaque `--cursor` with the same filters for the next page. Cursor validity is tied to filters. Ordinary pagination reads current state page by page; concurrent edits can change ordering between pages.

```sh
agentboard task list --status=open --repo=agentboard --limit=100 --json
agentboard task show sample-work --limit=100 --json
agentboard agent list --harness=codex --json
```

Errors leave stdout empty and use stderr. `--json` produces `{"error":{"code":"...","message":"..."}}` on stderr. Exit codes are 2 invalid input/context, 3 missing record, 4 state/ownership conflict, and 1 infrastructure failure. API requests cannot accept arbitrary SQL. Database details and credentials are omitted from API errors.

`agentboard meta` reports API/schema compatibility and the required decision-intake version. Commands reject unavailable/incompatible schemas without migrating them. The underlying `GET /api/v1/meta` response also carries an additive `message_transport` object describing the operator-selected message mode and a `required_decision_intake_version` floor; see [message modes](setup/mattermost.md#message-modes-openspec-71). Health probes are `/health/live` (process) and `/health/ready` (database and required schema).

## HTTP routes and rate limits

All resource paths start at `/api/v1`. M1 routes are GET `meta`, GET `agents`, POST `agents/register`, GET `agents/:id`, GET/POST `tasks`, GET/PATCH `tasks/:id`, and POST `tasks/:id/{assign,claim,renew,release,reclaim,update,link}`. Writes supply `X-Agentboard-Agent`, `X-Agentboard-Model`, and `X-Agentboard-Harness`. JSON bodies are bounded to 5 MiB. Validation and ownership guards apply to direct HTTP clients as well as `agentboard`.

HTTP errors use the same JSON error object: 400/422 invalid input/context, 401 missing or invalid credentials, 403 forbidden identity/scope, 404 missing, 409 conflict, 429 throttled, and 503 unavailable/incompatible schema. Defaults per replica are 120 requests/minute per source IP and 60 per agent. In enforce mode, IP admission runs before authentication and agent accounting uses only the verified principal afterward; off/observe retain legacy declared-agent accounting. API watch reservations separately limit 20/IP and 5/agent. Rate limits are not a replacement for authentication.

The source IP is `conn.remote_ip`. Forwarded-IP headers are ignored until an explicit trusted-proxy policy is configured. A shared Gateway can therefore concentrate clients in one IP bucket. Configuration uses `API_RATE_LIMIT_IP`, `API_RATE_LIMIT_AGENT`, `API_WATCH_LIMIT_IP`, and `API_WATCH_LIMIT_AGENT`; multiple replicas have independent limits. ETS storage and watch counts are bounded, with lifecycle cleanup; a missing/full limiter fails closed with 503.

429 responses include `Retry-After` and `Cache-Control: no-store`. The CLI waits at least the advertised seconds or HTTP-date, with positive jitter. Missing/malformed headers use exponential backoff. Ordinary requests have a 120-second total budget and at most three retries; a longer server delay fails instead of retrying early. Waiting is cancellable. Redirects are refused. Other write failures are not automatically replayed: when a connection or response is lost, inspect durable state/history before repeating an operation.

## Elixir query concurrency

Board reads and lifecycle/message mutations share the Board Ash domain. Document and quota ingestion use Evidence resource actions; the latest quota observation projection remains a SQL read. Request, connected LiveView, and stream processes use the PostgreSQL connection pool directly (default 10). Database calls do not wait in an unavailable/saturated pool queue; ordinary read timeouts are two seconds and pool failure returns a structured 503. Task row locks serialize competing changes to one task, and the lease clock is sampled after acquiring that lock. Claim expiry and agent staleness use that same database clock: a lease is expired at `claim_expires_at <= clock_timestamp()`, and a heartbeat is stale only when it is strictly older than the threshold. AshEvents uses a resource/record advisory key rather than one global query lock. Actor validation reads the registered identity without taking a common actor-row write lock. The limiter owns ETS lifecycle/cleanup; a dedicated connection owns LISTEN, while board queries run in the caller.

From schema 6, meaningful mutable actions produce attributed PaperTrail versions and versioned AshEvents records in the same transaction as task state and the compatible append-only task timeline. Failure to persist either audit or timeline rolls back the operation. Heartbeats are excluded from durable audit noise, and HTML/raw quota payloads are excluded from audit copies. Existing task history remains readable; audit starts at the new application's first mutation. There is no public replay API. See [release compatibility](release.md#schema-6-audited-board-and-evidence-actions) and the [operation diagram](architecture/ash-board-actions.html).

## Heartbeats, messages, and snapshots

`agentboard agent heartbeat --status=busy --task=sample-work` records server time, current model, and an owned current task; `--backend` optionally refreshes backend metadata. `--status=idle` with no task clears the current task. Heartbeats never extend leases. `--every 5m` repeats the heartbeat on that cadence until interrupted; while busy, heartbeat at least every 5 minutes so the roster never shows a working seat as Stale. Roster staleness defaults to the server threshold (20 minutes, `AGENTBOARD_ROSTER_STALE_AFTER`); `--stale-after` or `AGENTBOARD_STALE_AFTER` overrides it for that read, and omitting both uses the server default. Roster thresholds accept seconds or a trailing `m` minutes value; a non-finite or out-of-range threshold is invalid input. Quota observations keep their own ten-minute default (see [quota](quota.md)). A fresh heartbeat and an expired claim are separate conditions.

Roster identities carry the kind recorded at registration. The default agents roster lists only non-retired seats; `agentboard agent list --kind human|system|fixture|all --retired true` (API `kind=` / `retired=true`) reveals the rest (list kind/retired filters also need schema 30). `agentboard agent retire ID --reason '...'` records a captain-gated tombstone, refused for an identity holding a live claim or open decision unless `--force` accompanies the reason; `agentboard agent restore ID` reverses it with an empty body. Both are idempotent, both require the captain capability, and both need schema 30. Re-registering a retired id without a restore conflicts. Retired identities are routing-ineligible: assign, handoff, claim, reclaim, and task-order routing to them are refused.

```sh
agentboard msg send --to=peer-slug --task=sample-work --body='Ready for your review'
agentboard msg send --task=sample-work --body='Shared task observation'
agentboard msg list --unread --json
agentboard msg list --task=sample-work --json
agentboard msg read 123
agentboard task handoff sample-work --to=peer-slug --body='Take over the review'
```

Inbox reads default to the caller. `--to` chooses a recipient, and `--task` reads a shared task thread that includes context-linked direct messages. Direct messages are visible collaboration records in this trusted board. Listing has no acknowledgement side effect. Only the addressed recipient can mark a direct message read; the first timestamp and read provenance are retained across repeats. Task comments have no global read state. Handoff requires the live owner and a reason, clears the lease, and atomically writes an assignment, event, and recipient message. The recipient must be eligible under [agent availability](setup/availability.md); a captain handoff records a named-assignment grant for that exact recipient. The new assignee must claim before owner-only progress.

M2 HTTP routes add POST `agents/:id/heartbeat`, GET/POST `messages`, POST `messages/:id/read`, POST `tasks/:id/handoff`, and GET `tasks/watch` and `messages/watch`. Explicit `task_order` messages require an active named recipient, and captain task-order broadcasts reach only active agents; see [agent availability](setup/availability.md). Shared context search, feed, publication, and acknowledgement routes are documented in [shared context](context.md).

```sh
agentboard task watch --status=open --json
agentboard task list --watch --repo=agentboard --json
agentboard msg watch --unread --json
```

Watches require an agent ID. They return complete filtered snapshots, even when ordinary lists need multiple pages. Each NDJSON record has `topic`, `kind="snapshot"`, `reason` (initial/change/reconnect/fallback), `observed_at`, the resource list, and `next_cursor=null`. Transport keepalive whitespace between records is valid JSON whitespace and does not represent an extra snapshot. Every snapshot is one consistent PostgreSQL statement; no page-by-page transaction drift or hidden list limit is applied.

The server subscribes before reading initial state, then re-reads after committed invalidation notifications. Rollbacks produce no notification. One supervised LISTEN connection feeds Phoenix PubSub; clients never subscribe to PostgreSQL. The listener re-establishes subscriptions and announces reconnect so consumers reload. Stream processes query through the pool themselves and retain a five-second fallback for missed notifications and time-derived flags. Transport keepalives detect disconnected peers and free bounded watch reservations without additional queries.

The CLI reconnects with bounded backoff, reloads durable state, and labels the first new snapshot reconnect. Stream handshake 429 responses use the same Retry-After policy; a delay beyond the bounded handshake budget ends the watch rather than retrying early. SIGINT/SIGTERM cancels promptly. This is a snapshot subscription, not a replayable durable event stream or a guarantee to emit every intermediate mutation. Task history remains independently readable.

From schema 7, task create/edit/link requests that set an admitted `pr_url`
atomically retain a canonical Delivery PR and that task's first submission.
Clearing the URL does not create a submission or delete an existing one.
The task response and watch payloads are unchanged. Submitted agent/model/
harness attribution survives later handoff or URL replacement; a later actor
relinking the same URL does not replace the earliest submitter. Historical
links without an introducing timeline event remain unknown; current task
ownership is not evidence of PR submission. Exact URL admission, discovery,
and image rollback are in [schema 7 compatibility](release.md#schema-7-durable-pr-submission-inventory).
This inventory stage does not yet expose PR list/show/watch endpoints or a CI verdict.

Schema 8 adds internal Delivery polling bookkeeping without new public routes
or a change to task/watch payloads. New submissions atomically enroll unknown
poll state; inventory and attribution remain immutable. No provider checks or
CI result are exposed by this stage. Schema 9 adds no public route or payload.
See [polling contracts](ci-polling.md) and
[schema 9 compatibility](release.md#schema-9-observation-scheduling-budgets).

Schema 10 adds internal immutable current-head CI observations and provider
cooldown. Existing task/watch payloads and public routes remain unchanged by
that stage. Schema 11 adds the compact `/prs` reads and the scoped worker API;
see [server accountability](server-accountability.md), [worker API](worker-api.md),
[collector limits](github-ci-observation.md) and
[schema 11 compatibility](release.md#schema-11-server-accountability-and-delivery).

Schema 12 adds the shared-bot conversations routes
(`POST /conversations/send`, `GET /conversations/reads`,
`POST /conversations/coverage/:agent_id/:channel_id`,
`GET /conversations/coverage/:agent_id/:channel_id`,
`GET /conversations/diagnostics`): every agent message
posts through the agent's own elastic bot when active, otherwise the one
shared bot, with props attribution; reads suppress the
caller's own echo and record coverage receipts, and diagnostics reports the
cached Mattermost override observations plus the phase 2 elastic bot state
(`active`, `username`, `state`; no secrets); task/watch payloads are
unchanged by that stage. See the [agent-chat runbook](setup/mattermost-agent-chat-runbook.md) and
[schema 12 compatibility](release.md#schema-12-mattermost-shared-bot-chat-and-coverage).

## PR mergeability and rebase follow-ups (schema 14)

`agentboard pr list --json` and `agentboard pr show CANONICAL_ID --json` read
`GET /api/v1/prs` and `GET /api/v1/prs/:id`. List accepts `cursor` and
`show_terminal=true` (`--show-terminal`); it returns 20 canonical PRs plus
`next_cursor`. Detail includes immutable submission sources and the latest
20 observations. These API-only commands inherit the client's bounded 429
retries and require schema 14. They never contact GitHub or PostgreSQL directly.

Each record retains `mergeable` (true/false/null), `mergeable_state`, `base_ref`,
`expected_base_sha`, `observed_at`, `fresh` and `merge_state` beside `ci_state`.
`merge_state` is `conflicting` only for current, definitive `false` + `dirty`;
`behind`, `blocked`, `unstable`, and `draft` remain separate. Computing results
are `unknown`, old/failed/base-mismatched evidence is `stale`, and terminal PRs
are `not_applicable`. Historical snapshots without these fields remain unknown.
A merge conflict alone never changes the CI verdict or certifies recovery.
List and detail reads also expose the shared `github_budget` (remaining/minute
capacity, reset and provider cooldown) and a per-PR `poll_deferral_age` in
seconds since an unresolved budget/fairness deferral; successful observations
clear it.

Minute branch checks use the same shared 60-request/minute GitHub budget and
provider cooldown as PR collection. Base movement advances a retained branch
revision and queues paged invalidation of matching open inventory, including
PRs whose original task link was cleared. Invalidated polls are due immediately;
HTTP admission and existing backoff determine when fresh evidence becomes
available. Terminal pruning and hourly closed-PR reopen checks are preserved.

Only `AGENTBOARD_COOPERATION_ENABLED=true` publishes a rebase task, owner inbox
notice and normal worker-delivery intent. A unique `(canonical PR, head SHA)`
receipt prevents duplicates across retries, replicas and restarts. A single
registered immutable submission owner receives the assignment when [agent availability](setup/availability.md) admits them; absent or
ambiguous provenance, or a restricted owner (reserved without a captain grant, or out_of_service), leaves an open unassigned task in the captain queue. GitHub's human
author is never guessed as a board seat. `rebase_follow_up` links the repair and
its evidence on both list and detail reads. Current assignment, original task
status/history and leases are preserved. Definitive mergeable evidence resolves
the machine signal and suppresses pending wakes; repair completion remains an
explicit owner action. Rebase repairs are excluded from automatic merged-Review
completion and CI repair ownership attribution.

See the [conflict workflow](architecture/pr-conflict-accountability.html),
[rendered OpenSpec refinement](architecture/pr-merge-conflicts-openspec.html),
and [release compatibility](release.md#schema-14-pr-mergeability-and-base-watch).

## Possible duplicate PRs (schema24)

PR list/detail reads expose `duplicate_of` when retained merged evidence matches
the current open PR's head repository/ref or a common immutable task submission.
It contains `merged_pull_request_id`, `basis`, both snapshot IDs and source URLs.
This is possible duplication evidence, not an automatic intent verdict.
The `decision_cta` names a currently owned non-terminal linked duplicate card;
it is absent when only terminal/unassigned cards remain.

`POST /api/v1/prs/:id/duplicate-decision` accepts only `{"task":"duplicate-card"}`
and normal attributed actor headers. It verifies that the card belongs to the
duplicate PR and delegates to the existing live-owner decision contract. It
returns the usual decision envelope and idempotently parks the owned card.
It cannot create a system decision, host it on the original Done card, or close
a GitHub PR. The CLI command is `agentboard pr duplicate-decision ID --task TASK`.
It requires schema 24; PR list/detail reads carry the additive health field below from schema 27 (see [current readiness](release.md#schema-31-disabled-recovery-checkpoint) for the current floor).

## Agent API credentials (observe phase)

Captain capability is required for `GET /api/v1/agents/:id/tokens` and
`POST /api/v1/agents/:id/tokens/{issue,rotate,revoke}`. Issue/rotate accept an
optional `scope` (`agent` or the configured `coordinator`) and return safe
credential metadata plus the plaintext once. Revoke accepts optional
`credential_id`; without it, all active credentials for that agent are revoked.
Lists never return plaintext or hashes. CLI administration directs issued values
only to a newly created protected `--out` file. Existing worker/captain
capabilities retain their separate verification paths.

`AGENTBOARD_AUTH_MODE` defaults to `off`. With `observe`, ordinary mutating API
routes resolve an optional bearer principal while preserving legacy write
attribution, then record matched, anonymous, invalid or actor-mismatch evidence.
If observation recording or verification fails in observe mode, the write still
succeeds with a nil principal and an observation_unavailable outcome; the Agents
roster keeps actual agents with an explicit unavailable report, while the report
API returns its honest error. Enforce mode fails closed on verification errors.
`GET /api/v1/auth/observations` reports the mode, 24-hour outcome counts and 50
recent secret-free observations. Under enforce this report requires a captain
capability. Enforce also authenticates ordinary reads and watches, rejects
unsupported/retired/revoked principals, and restricts coordinator reads to an
explicit operation allowlist and its own inbox. Watch streams revalidate before
each snapshot. See the credential setup guide for protected custody, rollout,
rollback and request-admission revocation semantics.

## Default-branch workflow health (schema 27)

`GET /api/v1/prs` list reads carry an additive `default_branch_health` array of retained unresolved default-branch run obligations (oldest red first), alongside the existing `prs` page. Each entry retains `repository`, `workflow_name`, `branch`, `head_sha`, `run_id`, `run_attempt`, `conclusion`, `failed_at`, `responsible_id`, `source_tasks`, failing `jobs` (name, failed steps, log URL), `source_url`, and any `last_error` deferral note. An empty array means no retained red runs, not verified-green coverage. Intake, routing, recovery, and operator setup live in [default-branch workflow accountability](default-branch-workflows.md), not here. Per-PR detail shape is otherwise unchanged.

## Captain-managed seat scope (schema 34)

GET/PUT `/api/v1/agents/:id/scope` reads/replaces the complete trusted scope. PUT requires verified captain capability and `allowed_repos`, `required_labels`, `allowed_labels`, `revision`; revision 0 creates and stale revisions return 409. The response has a `scope` object, also projected on agent reads. Unmanaged is legacy manual compatibility, not automatic eligibility. Full validation, matching, CLI and continuity contracts: [Seat scopes](seat-scope.md). No standalone MCP server exists; clients using central task endpoints inherit their admission guards.

## Dormant fleet loadouts (schema 35)

GET/PUT `/api/v1/fleets/:id/loadout` requires verified captain capability for both reads and writes, independent of ordinary caller-supplied actor headers. The CLI uses protected `AGENTBOARD_CAPTAIN_TOKEN_FILE` for `fleet loadout show FLEET_ID` and `fleet loadout set FLEET_ID --file PATH`. These commands do not require self-reported actor environment values.

PUT accepts exactly `revision`, `idempotency_key` and `seats` (at most 32). Each seat requires `seat_id`, `agent_id`, `harness`, `desired_host_id`, `desired_model`, `desired_effort` and `scope_revision`. References must resolve to existing nonretired seat identities with the exact registered harness and current managed canonical scope. There are no copied editable scope arrays. Model/effort values are bounded unverified text, desired hosts are unverified slugs, and observed model/harness metadata is not an authoritative support catalog.

The response is `{"loadout": {...}, "replayed": false}`; loadout includes ID, revision, derived `seat_count`, complete desired seats with current scope/observation projections, captain attribution and timestamp. It always reports `enabled: false`, `activation_state: "not_activatable"`, `catalog_status: "unverified"` and `host_status: "unverified"`. An absent loadout returns revision 0 and no seats without creating configuration.

Expected revision guards a full replacement. Exact normalized retries under the same fleet/key return the original committed snapshot with `replayed: true`; changed payloads under that key and stale new replacements conflict. Per-fleet seat IDs retain their original agent/harness binding after removal. An agent cannot appear in two current fleet configurations. Removing desired seats never stops workers, clears responsibilities or changes task ownership. This is partial dormant configuration storage only: activation, role/readiness gates, host enrollment/reconciliation, trusted catalogs and Deck remain deferred. See [Dormant fleet loadouts](fleet-loadout.md) for exact field bounds, canonical scope behavior, CLI input validation, retry and error contracts.

### Coordinator inbox shadow classification

The schema-36 optional note `triage` contract, captain-only off/shadow
configuration, exact non-consuming `msg show`/`msg triage` reads and
`--triage-state` filtering are documented in
[coordinator inbox triage](coordinator-inbox-triage.md). These never acknowledge
messages or prove routing, native acceptance or coordinator handling.
