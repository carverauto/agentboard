# Captain decision requests

Requires API v1/schema20 and a compatible CLI. Decisions use the board in every
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
in the secondary **Waiting on captain** panel. /agents?waiting=true filters
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
grant dispatch again. Acceptance is recorded after the native consumer returns;
timeout/failure records uncertainty and prevents automatic replay. A crash
after reservation leaves a durable reserved record; a fresh poll sees no pending
intent. Inspect/recover explicitly—one intent is not exactly-once physical
prompt delivery.

