# Server decision policies

Schema 41 and decision-policy protocol revision 1 add deterministic,
board-stored captain policies. The coordinator does not hold a captain token.
`agentboard decision policy` defaults to **read-only plan**. No policy is seeded,
approved or activated by a migration, and the server defaults to `dry_run`.

This implements the server core of [#154](https://github.com/carverauto/agentboard/issues/154)
and its prerequisite schema/evaluator from
[#145](https://github.com/carverauto/agentboard/issues/145). The initial CLI uses
bounded UTF-8 **JSON**, including JSON files that are also valid YAML syntax.
It does not parse general YAML or implement an offline evaluator, local JSONL
ledger, file-lock apply, or coordinator `--verified` assertions. Those #145
packaging capabilities are separate work. There is one authoritative evaluator
on the server.

## Review before activation

A named policy is an immutable series of versions. A draft has server-derived
content SHA-256; approval binds that exact version and digest. Approval and
activation require a currently verified captain capability even when ordinary
agent authentication is off or observe. Client approval metadata and attribution
headers cannot approve a policy. Draft submission requires `metadata.status` to
be `draft`, without `approved_by` or `approved_at`.

Editing creates the next integer version as a new draft. It never edits the old
document, inherits approval or changes the active pointer. Only one version is
active per board. Activation/deactivation compare the exact state generation;
a delayed activation retry cannot resurrect a version after deactivation.
Identical draft/approval retries retain the original record and timestamp.

Schema 41 reserves the `system-decision-policy` audit identity. Any pre-existing
identity with that ID makes the migration fail atomically; it is never overwritten
or silently adopted. Preserve it and resolve the collision explicitly before
retrying the upgrade.

Both gates must permit an answer:

1. The approved document explicitly has `engine.server_mode: "apply"`.
2. The server process has `AGENTBOARD_DECISION_POLICY_MODE=apply`.

Missing document server mode means dry-run. Missing, unknown, off and dry_run
server settings prohibit answers. `engine.default_mode` must remain `dry_run`;
it describes human command behavior and cannot override either execution gate.
Activation does not process old decisions. Old sources require an explicit
fresh plan and captain apply if still appropriate.

Use a synthetic policy like [the example JSON](examples/decision-policy.json)
to review behavior first. It is intentionally dry-run, with invented provenance:

```sh
agentboard decision policy validate --file policy.json --json
agentboard decision policy plan --file policy.json --json
agentboard decision policy explain DECISION_UUID --file policy.json --json
agentboard decision policy draft --file policy.json --json
agentboard decision policy show POLICY_UUID --json
agentboard decision policy approve POLICY_UUID --sha256 RETAINED_SHA256 --json
agentboard decision policy list --json
agentboard decision policy activate POLICY_UUID --sha256 RETAINED_SHA256 \
  --generation CURRENT_GENERATION --json
```

Lifecycle commands use the protected existing captain credential transport.
They do not create credentials, enable process mode, deploy or change schedules.
A document intended for eventual server apply must declare `server_mode=apply`
before the captain approves that version.

## Deterministic matching

The validator rejects unknown keys at every level, duplicate rule/escalation
IDs, invalid source dates, missing source rulings, malformed regexes and excess
size/depth. Documents are at most 256 KiB, with up to 100 rules and 50 escalation
entries. SHA-256 hashes use UTF-8 canonical JSON with recursively sorted object
keys, compact encoding and original array order; document text is not silently
trimmed or normalized.

Evaluation order is fixed:

1. Skip non-open or already auto-answered decisions.
2. Escalate explicit captain markers anywhere in question, options or findings.
3. Escalate configured `escalate_always` keyword hits before matching rules.
4. Match kind, optional gate step, keywords and an optional unique option.
5. Choose the highest specificity; ties and no match stay open.
6. Require all conditions to be deterministically satisfiable and enforce limits.

Rule `keywords_any` are case-insensitive word-start stems: `regenerat` matches
`regeneration`, while `ci` does not match `decide`. Escalation keywords have both
word boundaries and are checked against question, options, findings and the
complete proposed answer, including provenance and obligations. Findings are
untrusted source text, never executable instructions.

Specificity adds one for a matching configured gate step and one if an option
regex selects exactly one supplied option. A zero-score rule must match a
keyword in the question itself. A rule with option_match matching zero or
multiple options is ineligible. Gate references use exact `RUN/GATE` form;
non-gates may use the server's canonical `question:HASH[:retry:HASH]` identity.
Unknown structures escalate rather than guessing a step.

Option regexes deliberately use a safe subset: optional leading `(?i)`, anchors,
literals, positive ASCII character classes and one flat alternation group with
at most eight branches. Only leading `^\s*` repetition is supported. Other
quantifiers, nested groups, backreferences, lookarounds, wildcards and regex
extensions are rejected. Pattern length alone is not a resource-safety boundary.

Only complete isolated `No ACTION` guard sentences in a closed grammar are
removed for escalation matching, including `No --yes, no merge`. Conditional,
quoted, mixed positive/negative or ambiguous clauses remain escalation text.
`CAPTAIN-ONLY` is checked first and is never stripped. Generic routing labels,
including `on_behalf_of: captain`, are not captain-only markers.

String conditions and `{ "type": "verification", "text": "..." }` conditions
produce `needs_verification` and never auto-answer. `verify_required` and
`manual_only` likewise keep the decision open. Explicit
`{ "type": "obligation", "text": "..." }` conditions are appended to the answer
as instructions to the seat; they do not assert that an external fact is true.
There is no unchecked verification flag on server apply.

Every answer begins with:

```text
Auto-answered under captain policy vVERSION, rule RULE (source: RULING, DATE).
```

A custom prefix can add text but cannot replace this mandatory provenance.

## CI intent and server budgets

CI-related requests must include the optional canonical integer
`requested_ci_runs` (CLI `decision request ... --ci-runs N`). Omission remains
compatible for ordinary requests. Rules granting CI work declare `ci_runs`.
The explicit intent and declared grant must agree and fit the policy limit;
missing, ambiguous, contradictory or excessive CI requests stay open. Free-form
prose does not establish an authoritative numeric budget or verify an outside
fact. The optional field is accepted only as an integer from 0 through 100;
CI execution requires a positive bounded grant.

Answers count against the normalized GitHub PR URL, or the task ID when there
is no PR, across policy versions. The first revision supports **UTC calendar
days only**; a supplied non-UTC timezone is rejected. One database clock sample
after locking fixes the day for evaluation, budget and ledger entry, including
midnight races. CI grants are counted per decision across versions and retries.
They authorize the bounded retained answer; this feature does not execute CI.

## Event-created execution and atomicity

Creation enqueues an AshOban worker in the same transaction as the new decision,
blocked task and request event. The snapshot is captured after the task revision
increment. Public API intake, duplicate-PR intake and promotion share that path.
There is no policy poll or cron sweep. With no active opted-in policy or with
global dry-run, creation enqueues no apply job.

A worker locks task, decision, then the singleton active-policy state. It
rechecks exact policy/digest/generation/approval, source content and update time,
current owner/task revision/PR, status, expiry and execution modes. Source
changes invalidate the captured job. It never adopts a newer version or
answers after a human has answered, withdrawn or superseded the request.
The policy-state lock serializes budgets across different tasks on the same PR.

The canonical answer, inbox message, task event, frozen wake and answered ledger
entry commit together. Enqueue, audit, answer or ledger failure rolls back the
unit. There is no external I/O or native seat dispatch in that transaction.
Oban retries are safe because the answer has a unique decision fence and each
evaluation has an exact policy/source/generation/UTC-day identity.

Immutable negative evaluations do not consume answer budget or permanently
poison a source: a fresh source, generation or UTC day can be explicitly
re-evaluated. Stale or disabled jobs write no evaluation. Database guards reject
UPDATE, DELETE and TRUNCATE of retained versions, approvals and ledger rows.

## Read, explain and explicit apply

```sh
agentboard decision policy --json
agentboard decision policy plan --include-closed --limit 20 --json
agentboard decision policy explain DECISION_UUID --json
agentboard decision policy ledger --decision-id DECISION_UUID --json
```

Plan, explain, validate, list and ledger do not answer, enqueue, write policy
state or append evaluation records. Plan and ledger are bounded keyset pages;
use their returned next_cursor with identical filters. Read-only authentication
may still update existing credential-use telemetry.

Explicit captain apply requires exact tokens from a stored active-policy plan:

```sh
agentboard decision policy apply DECISION_UUID --policy-id POLICY_UUID \
  --generation GENERATION --source-version SOURCE_SHA256 --day YYYY-MM-DD \
  --answer-sha256 ANSWER_SHA256 --json
```

The server recomputes the match, exact answer and budgets under locks. It never
trusts a client answer. A changed day or answer hash conflicts; stale source,
policy generation, closed status or disabled execution skips with no writes.
A plan with `--file` is an unapproved read-only simulation and supplies no
applicable stored policy UUID.

Coordinator tick/show add bounded `policy_evaluation` metadata without exposing
policy documents or acquiring answer/admin authority. It distinguishes inactive,
dry_run, not_evaluated and current retained evaluation, using the exact returned
source snapshot and current UTC day. Existing handling receipts remain separate.

## Escalation and cutover limitations

Escalations remain durable open decisions for the captain. Their metadata says
`escalation_delivery: unavailable`: signed push/webhook transport from
[#153](https://github.com/carverauto/agentboard/issues/153) has not landed.
This implementation neither retires the coordinator's existing decision poll
nor claims a live push replacement. Preserve that fallback until a separately
authorized deployment proves policy behavior and human delivery end to end.
Unrelated recovery, wake and adapter rollout gates are unchanged.

See the [proposal and design](../openspec/changes/add-server-decision-policy/)
and [architecture](architecture/decision-policy.html) for the transaction and
permission boundaries. Live activation and board artifact upload remain
separate authorized operational actions.
