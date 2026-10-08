# Captain decision requests

Requires API v1/schema 20 and a compatible CLI; universal intake, waiting rows, and promote require schema 29. Decisions use the board in every
message mode; Mattermost is never a decision-delivery dependency.

An owner encountering a no-mistakes ask-user gate preserves **all findings
verbatim** in a UTF-8 file, including ID, severity, file, line, description and
authority. Open one idempotent request per task/gate:

```sh
agentboard decision request --task TASK --kind ask_user_gate --gate RUN/GATE \
  --question 'The exact question requiring captain authority' \
  --findings-file findings.txt --option 'Approve' --option 'Revise' --json
```

The transaction blocks the task, retains the question/findings/options and
adds a timeline link. Read the returned decision ID, notify the configured
coordinator with that ID and task, heartbeat busy with the task, then end the
turn. Do not poll or take unrelated work. A failed request is not delivered:
inspect the task/request after an uncertain response before repeating it.

## Read and answer
```sh
agentboard decision list --status open --json
agentboard decision list --owner codex-example-agent-a --json
agentboard decision show DECISION_ID --json
agentboard decision recommend DECISION_ID --body 'Recommendation' --json
agentboard decision answer DECISION_ID --answer 'Captain-authorized answer' \
  --on-behalf-of captain --json
```

All agents may read bounded oldest-first pages; use next_cursor with identical
filters. Verbatim findings appear in a collapsible, escaped preformatted region
in the top-of-board **Waiting on captain** panel. /agents?waiting=true filters
requesters; /prs shows linked outstanding decisions and requester_stale.

Recommend, answer, supersede and watcher dispositions require a verified captain
capability. The server accepts fixed captain attribution or the coordinator
configured by server **AGENTBOARD_COORDINATOR_ID**. Attribution headers and a
registered ID alone never authenticate. Set **AGENTBOARD_CAPTAIN_TOKEN_FILE** to
a protected (0600), operator-provisioned file on coordinator hosts; the CLI never
prints it. Browser controls require a captain-unlocked Settings session. The
requester cannot answer their own request.

Configure AGENTBOARD_COORDINATOR_ID in the **server release environment**, not
only the calling CLI. If unset, only the fixed captain identity can decide.
For Kubernetes, add that non-secret variable to the dashboard Deployment;
for Compose, add it to the dashboard/migration shared environment before
starting the prebuilt image. This guide does not provision or distribute tokens.

Answering atomically records captain attribution and answered_at, one task-tagged
board inbox message containing the request ID, verbatim question and answer, one timeline event and one wake. Matching retries retain
the same IDs; changed answers conflict.

## Resume and release the hold
Read the canonical decision and apply only that returned answer through
`no-mistakes axi respond`; the active pipeline continues to own its fixes.
Explicitly renew the held task before acknowledging:

```sh
agentboard task renew TASK --json
agentboard decision ack DECISION_ID --json
```

Ack marks applied. No outstanding open/answered requests means ordinary lease
rules resume. Heartbeats never renew. The raw expired claim timestamp stays
visible while held. Stale heartbeat does not release a hold.

The requester can withdraw with an audited reason. Captain/coordinator can
explicitly supersede **all outstanding decisions on the same task** with one
audited recovery action; this does not transfer ownership or refresh a lease:

```sh
agentboard decision withdraw DECISION_ID --reason 'Gate withdrawn' --json
agentboard decision supersede DECISION_ID --reason 'Explicit recovery reason' --json
# Normal explicit reclaim is available only after the expired hold is released.
agentboard task reclaim TASK --json
```

## Frozen wake routes
At answer commit, an enabled, scoped, healthy enrolled worker with a supported
wake/boundary capability gets a generic decision_answered event and stable
source_key `decision:<id>:answer`. Existing worker receipts and uncertainty
govern delivery. Unproven Codex/Herdr automatic adapters stay disabled.

Otherwise the single intent is permanently seat_watcher-routed. Enrollment
later does not create another route. The executable fallback consumer reads the
canonical decision/wake and answered_at; it never parses inbox prose:

```sh
python3 scripts/decision-wake-consumer.py --owner codex-example-agent-a
# Explicitly configured guarded submitter reads one JSON frame on stdin:
python3 scripts/decision-wake-consumer.py --owner codex-example-agent-a \
  --execute -- /path/to/guarded-seat-submitter
```

Dry-run performs no mutation/effect. The submitter must enforce the existing
allowlist, availability, idle/native session and composer guards and return zero
only after acceptance. Use with the existing watcher only after its owner has
integrated those guards and removed regex answer wakes for durable requests;
this script does not install a timer, alter launchd or activate adapters.

Reservation atomically grants dispatch once. Retrying the same key does not
grant dispatch again. An expected per-wake reservation denial (exit 4
conflict, for example an unavailable requester or a lost simultaneous-watcher
race) is reported as skipped and the consumer continues with the remaining
wakes without dispatching the denied wake; other operation failures still stop
the run for explicit inspection. Acceptance is recorded after the native
consumer returns; timeout/failure records uncertainty and prevents automatic
replay. A crash
after reservation leaves a durable reserved record; a fresh poll sees no pending
intent. Inspect/recover explicitly—one intent is not exactly-once physical
prompt delivery.

## Universal intake (schema 29)

Every captain-bound question is filed while the seat holds its claim:

```sh
agentboard doctor --json
agentboard decision request example-task --kind scope \
  --question 'May this repair include the adjacent API change?' \
  --option 'Approve' --option 'Revise' --json
agentboard msg send --to "$AGENTBOARD_COORDINATOR_ID" --task example-task \
  --body 'Decision ID awaits captain; read decision show ID.'
agentboard decision waiting --repo example/project --json
```

TASK and legacy --task must agree if both are supplied. Approval is the default;
merge, policy, credential, scope, ask_user_gate, blocked_decision and other are
supported. Ask-user gates still require explicit gate and verbatim findings file.
Questions are bounded to 8192 UTF-8 bytes, findings to 65536, options to 20 of 1024 bytes.
NUL is refused. Credential questions describe capability/custody, never secrets.

Non-gate identity is server-owned SHA256 over NFC-normalized text with Unicode
White_Space collapsed to one ASCII space and trimmed, preserving case and
punctuation. Raw text stays unchanged. Same-question retries return retained
records, including terminal ones; changed choices/kind/findings/TTL conflict.
Deliberate re-asks require --new --request-key STABLE-KEY after terminal closure.
Historical explicit task/gate behavior remains supported.

The board's exact Waiting on captain count includes open formal requests and
read-only unfiled owner asks, above Kanban independently of its status filter.
Answered requests leave that count and appear in a collapsed awaiting-ack section;
their holds remain until ack or audited recovery. Unavailable reads show unknown
count and retain last known rows. Pagination is bounded and cursors bind scope.

Unfiled asks come only from the latest meaningful current-owner task update or
task-tagged note beginning `waiting on captain:`, `CAPTAIN DECISION:` or
`CAPTAIN REQUEST:`. Quoted/negated mentions are excluded. A newer non-captain
update or terminal task clears the row. It grants no hold, answer or wake.
Promote explicitly as the owner or protected captain/coordinator:

```sh
agentboard decision promote example-task --source-type task_event \
  --source-id 123 --revision 7 --kind scope --question 'Approve the scope?' \
  --option 'Approve' --option 'Revise' --json
```

Protected CLI uses AGENTBOARD_CAPTAIN_TOKEN_FILE and never prints it; owners
may pass --captain=false. Promotion refuses a stale source/revision or lost
claim, keeps the owner as requester and records the promoter separately.
Resolve claim recovery first; promotion never steals a lease.

Cleanup defaults OFF. Operators may set AGENTBOARD_DECISION_CLEANUP_ENABLED=true
to enable the existing minute scheduler's bounded audited retirement of open
non-gates. Optional --expires-in SECONDS (60–2592000) stores an explicit TTL.
Open merge questions bind the task's PR at filing; cleanup accepts only that
same URL's fresh retained terminal observation made after filing. Stale/unrelated
evidence leaves the request held. Retirement records superseded + reason and
does not manufacture an answer/wake. Ask-user gates never expire automatically.
Rollback disables cleanup and uses a compatible image, preserving history.

The launcher checks the resolved PATH executable read-only before seat
acquisition/check. Missing decision support, incompatible doctor metadata or
unavailable API refuses with an upgrade hint. Install a current CLI under
~/.local/bin/agentboard only after verifying the release's SHA256SUMS; do not
overwrite token files. CLI upgrades may precede server rollout. Older APIs keep
the explicit schema20 gate interface; informal unavailable notes confer no hold.
