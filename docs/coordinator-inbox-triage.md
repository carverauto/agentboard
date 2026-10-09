# Coordinator inbox classification (shadow only)

This first #186 slice records explicit note intent and a read-only audit. It does
not automate the coordinator inbox. It supports only `off` (the default) and
`shadow`. Neither mode changes existing Mattermost notifications, #122 delivery
selection, #156 wake capture/reservations, unread receipts, assignments or leases.
There is no background classifier, backfill, webhook or scheduler.

## Configuration

The captain capability is required for both reads and writes of
`/api/v1/settings/coordinator-triage`, even when ordinary API authentication is
`off`. GET returns `configuration`; an absent configuration is
`{"mode":"off","coordinator_id":null,"revision":0}`.

PUT replaces the exact object `{mode, coordinator_id, revision}`. `revision` is
the last observed nonnegative revision. Supported modes are `off` and `shadow`;
`active` is rejected. Shadow requires the exact registered, non-retired recipient.
Off permits a null coordinator. Changes are audited and serialized against
capture; a stale revision conflicts. Configuration does not register an agent,
issue a credential, enroll a worker or change the configured API-auth coordinator.
If coordinator-scoped API credentials are used, their independent configured
identity must already match the selected inbox.

Only newly created direct `kind=note` messages addressed to this coordinator are
captured in shadow. Task comments, other inboxes and task orders are unchanged.
New-source admission holds its configuration snapshot from before Message
insertion through commit. Each record retains that capture/configuration revision. Rotating configuration
does not reclassify retained messages. There is no historical activation API in
this slice. An old message is never recovered from an ID watermark or replayed
into a new channel.

## Explicit input

`POST /api/v1/messages` accepts optional `triage` on notes. Its exact shape is the
[version-1 schema](../openspec/changes/add-coordinator-inbox-triage/contracts/message-triage-v1.schema.json).
The four required fields are `version` (integer 1), `category`, `attention` and
`source`. Unknown keys, versions, invalid source variants and metadata exceeding
4 KiB serialized JSON are rejected before a Message is created, including in off
mode. Explicit null metadata is invalid; omit `triage` for legacy input. Off
validates supplied metadata but does not retain a triage record.

Categories are `status`, `ci`, `conflict`, `next_work` and `needs_judgment`.
`attention` is `routine` or `captain`. Captain attention alone normalizes the
class to `captain_addressed`; recipient identity, text, mentions, markers and
model output never determine classification.

The CLI supports `msg send --triage '{"version":1,"category":"status","attention":"routine","source":null}'`.
The new input, exact reads and state filters require the new server schema;
legacy commands retain their existing compatibility floor. CLI validation rejects
unknown/duplicate keys, coercions and malformed references before HTTP.

## Truthful dispositions

- Taskless status with null source is `recorded` / `informational_only`, with no
  task or repository inferred. A taskful status must reference the exact matching
  task event and revision. That validates an informational reference, not a route.
- Missing legacy metadata is `unclassified` and `blocked` / `metadata_missing`.
- Missing/mismatched canonical evidence is `blocked` with a bounded reason code.
- Matching CI/conflict event claims remain `blocked` / `untrusted_source`.
  Sender-supplied IDs and fallback markers cannot establish the server producer
  association. This slice does not call the #122 selector or adopt its result.
- An exact retained assignment claim stays `blocked` / `route_unavailable`.
  Missing assignment is visible. No work is picked, assigned, claimed or woken.
- Explicit judgment/captain intent with valid available context is
  `escalation_pending` / `transport_unavailable`. This is retained intent only.
  No signed event has been created or delivered. Missing #153 remains a blocker.

Record identity is the canonical Message ID. Creation, initial disposition and
Ash action audit commit with that Message transaction. Exact capture replay returns
the retained row; changed metadata conflicts. Classification/source claims and
disposition history reject database update/delete/truncate. Read-time task/repo
fields come from the canonical Message/task. `currentness=not_evaluated` makes
clear that source admission and native current-order checks have not run.

`provenance.authentication` distinguishes enforced authenticated attribution from
legacy/unverified attribution. Observe mode does not establish authority.
`source_authority=unverified` never promotes metadata into a server producer proof.

## Read without acknowledgment

- `GET /api/v1/messages/:id`, or `agentboard msg show ID`, reads the exact source.
- `GET /api/v1/messages/:id/triage`, or `agentboard msg triage ID`, returns the
  record and append-only history, or `triage:null` for uncaptured messages.
- Existing message lists include a `triage` projection and support
  `triage_state=recorded|blocked|escalation_pending|unresolved` (`--triage-state`
  in the CLI). Unresolved includes blocked and pending records. Filters bind the
  existing `(created_at,id)` cursor. Start a new traversal to see late commits
  before a previous cursor; no numeric-ID commit-order assumption is made.
- The Messages dashboard has the same filter and displays shadow class,
  disposition and reason separately from the existing Read/Unread badge.

All reads preserve the source's unread/read provenance. Only the existing explicit
`msg read ID` operation acknowledges a message. Projections always say
`delivery.state=not_attempted` and `handling.state=not_inferred`. These describe
triage's own effects; retained legacy wake/delivery may independently exist.
Coordinator-scoped credentials can exact-read only their own addressed messages;
ordinary agent/private-network access follows existing board policy. Captain
configuration never becomes an ordinary agent/coordinator write.

## Deferred work and operational gates

Server-owned #122 producer associations, #156 exact wake adoption/channel fencing,
#169 currentness, reconciliation, signed #153 enqueue/retries/dead letters,
active-mode admission, historical activation cohorts and live parity/cutover proof
are deferred. There are no dead letters in this slice because it does not submit
transport work. Do not retire the inbox sweep or infer native handling from a
shadow record. Deployment, enabling shadow in production and any later active
mode require separate explicit operational approval.
