# Design

## Baseline

Fresh main `540cb4349f2b45020199b19f8373405169bf7711`. Existing Decisions owns
request/task locks and transactional answer/message/event/wake capture. Reuse
this path. GH145 has no implementation. GH153 transport and GH168 schema allocator
are absent. Migration 41 is a candidate from this checkout, not a live reservation.

## Document and evaluator

One Elixir evaluator validates a bounded JSON map, rejecting unknown nested
keys, duplicate IDs, missing ruling/date sources and invalid/oversized regexes. Regexes use an explicitly bounded safe grammar; arbitrary backtracking constructs are rejected rather than trusted based on length.
Metadata names a version; submitted status/approval metadata cannot grant
approval. Draft creation must use draft status and no approval attestations.
The server supplies approval, activation, timestamps and content digest.

Evaluation is pure and stable: non-open/retained identity skip; explicit captain
markers across question/options/findings; escalation guards; rule kind/gate,
keyword and option matching; specificity and top-tie rejection; manual or
unverified conditions; then budgets. Rule keywords are case-insensitive word-start stems; escalation keywords are fully word bounded; only complete isolated negated guard clauses in a closed grammar are removed. Ambiguous negation remains escalation text.
Escalation checks include the proposed answer. A zero-score candidate must match
a question keyword. Conditions that cannot be proved deterministically never
auto-answer. No model judgments or implicit coordinator verification. CI grants
must declare bounded `ci_runs` cost. CI-related decisions must retain an explicit bounded canonical `requested_ci_runs` intent field; absent or larger requests escalate. Text never supplies authoritative numeric budgets or evidence that outside conditions hold.
Generated answer provenance always includes policy version, rule ID and source.

Policy limits include a fixed explicit UTC calendar day for this first server
revision, with `engine.timezone` restricted to `UTC` when supplied. This is
independent of database/session timezone. Non-UTC board-local days require a
future versioned timezone capability; they are rejected, not silently converted.

## Storage and lifecycle

Immutable policy_versions contain `(name, version, document, sha256, creator,
created_at)`. A new version must be the next version for that name. Immutable
approvals bind version ID and digest to authenticated captain attribution. A
singleton state row records active version and monotonically increasing
generation; captain activate/deactivate requires its expected generation.
Activation requires exact retained approval. Approval/draft exact retries are idempotent. Active-state CAS takes precedence: an old expected generation never resurrects a policy after deactivation. Changed content under an existing name/version conflicts.
Creating another draft never mutates or inherits the older version's approval.

Immutable evaluation identity is `(decision_id, gate_ref, policy_version_id, source_version, generation, UTC_day)`. Only answered rows suppress future eligibility; a separate partial unique answered decision_id fence prevents any second automatic answer across all versions. Stale/disabled jobs create no retained evaluation. Negative evaluations may be revisited by a fresh explicit source/generation/day and never consume answer budget.
Records retain policy/rule/digest, source version, exact answer/hash, UTC day,
PR-or-task limit key, CI cost, outcome/reason and server timestamp. All writes
use Ash actions/audit. Database UPDATE/DELETE/TRUNCATE guards protect immutable
records. The answer and answered ledger record are one transaction, so neither
can commit alone. Escalations are ledgered and stay open; delivery explicitly
reports unavailable until GH153 exists. Infrastructure errors roll back and are
retried by Oban without a misleading terminal successful ledger entry.

## Creation, currentness and lock order

The new-request path enqueues an AshOban trigger transactionally AFTER the task blocked revision increment, including promoted and duplicate-PR intake requests. It captures the active version/generation and canonical
source version (decision updated_at/content plus current task owner/revision/PR).
No active policy produces no job. Activation does not replay old decisions.
Dry-run mode does not enqueue mutating apply work or answer any decision.

An apply locks task, then decision, then the singleton policy state. Lifecycle
operations take only state; no lifecycle operation subsequently acquires a task
lock. This preserves existing task -> decision -> worker ordering and avoids a
policy/task inversion. State locking serializes automatic answer budgets across
all tasks/PRs. Recheck mode, active exact version/digest/approval/generation,
source version, ownership/status/expiry and retained ledger while holding locks.
A stale job does not switch to a newer policy or overwrite a human answer.

Count answered ledger entries using existing Delivery.Inventory.canonical for the PR URL (task ID fallback) and UTC date across all policy versions. A single locked database clock sample fixes the evaluation, budget date and ledger timestamp across midnight. Reserve no independent external action:
the budget, CAS answer, inbox message, task event, one frozen wake and ledger
commit atomically. Decision CI grant count is likewise ledger-derived across
versions. Duplicate jobs and retries produce no duplicate ledger or delivery.
No native I/O occurs in the transaction. Failed enqueue aborts request creation.

## Authorization and public interfaces

New policy routes precede `/decisions/:id`. Lifecycle writes require current
captain proof derived at the boundary, rechecked with Captain.authorized? inside each lifecycle transaction after waiting for locks, in auth off/observe/enforce alike. No public
field, agent header, coordinator scope or document approval field becomes that
proof. Read/plan/explain/ledger use existing authenticated read permissions;
coordinator_runner remains limited to its existing protocol and receives bounded
policy summary through tick/show, not lifecycle or answer authority.

A narrowly scoped internal decision-answer entry point is callable only from
the policy transaction after all fences, with a server-reserved attribution.
Public decision mutate retains its captain requirement and existing API shape.
The policy actor is not supplied by requests and does not require storing or
forwarding a captain token. Answer delivery remains the canonical existing path.

CLI `decision policy` defaults to plan. `validate --file`, `plan [--file]`,
`explain ID [--file]`, `ledger`, `list`, `show`, `draft --file`, `approve` and
`activate`/`deactivate --generation` call the matching server surfaces. File
inputs are bounded JSON, not a new local policy engine. An explicit captain
`apply` may submit an exact read plan token to the server; it cannot bypass
active-version/currentness/mode/budget checks or enable the server globally.
Plan/explain never write ledger/jobs or answer state and give exact outcomes.

## Rollout and proof

Server mode defaults to dry_run. Only the exact configured string apply permits answers; absent/unknown/off/dry_run fail closed and document engine mode cannot override this fence. engine.default_mode remains the human dry_run default; engine.server_mode is a separate explicit dry_run|apply opt-in (default dry_run). Both server_mode=apply and global mode=apply are required. No approved or active policies are seeded.
Existing APIs, task holds and decision wakes remain compatible. Coordinator
metadata distinguishes unavailable, disabled, not evaluated and exact-version
retained evaluation; it never implies a stale evaluation covers changed source.
Recovery readiness and unrelated server automation remain disabled.

Fresh/upgrade migrations preserve records and higher board_schema markers with
GREATEST. Test normal-role immutability, hash/approval/currentness fences,
concurrent answers/activation/human writes, dry-run no effects, per-PR/day and CI
limits, enqueue and ledger rollback, duplicate jobs and all evaluator precedence. Cover API create, duplicate-PR intake, owner promotion and captain LiveView promotion so every canonical creation path is exercised.
Remote Bazel and hosted CI proof remain required publication evidence.
