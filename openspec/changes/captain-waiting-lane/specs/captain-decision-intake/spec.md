## Purpose

Make every captain-bound question durable and visible, while preserving explicit authority, task ownership and reliable answer delivery.

## ADDED Requirements

### Requirement: Universal captain question filing
Seats SHALL file any approval, merge, policy, credential, scope or ask-user question through a durable decision request and notify the coordinator with its ID. Non-gate forms SHALL accept positional task or compatible --task syntax without gate/findings flags. Ask-user gates MUST retain their gate and verbatim findings. Secrets MUST NOT be included.

#### Scenario: General policy question
- **WHEN** a live task owner files a policy question using the positional form with no findings file
- **THEN** one open policy decision blocks that task and returns an ID for coordinator notification

#### Scenario: Missing ask-user findings
- **WHEN** a seat files an ask-user gate without gate reference or findings file
- **THEN** the command refuses without changing the task

### Requirement: Normalized question retry identity
Non-gate requests SHALL deduplicate by task and versioned normalized question. Normalization SHALL use Unicode NFC, trimmed collapsed Unicode whitespace, preserving case and punctuation. The first raw question SHALL remain verbatim; changed kind, findings or options MUST conflict. Exact retries SHALL retain original request/event IDs.

#### Scenario: Equivalent whitespace retry
- **WHEN** the owner repeats the same question with equivalent Unicode composition or whitespace
- **THEN** the original decision is returned without duplicate history or raw-question replacement

#### Scenario: Changed choice set
- **WHEN** a retry uses the same normalized question but different options
- **THEN** it conflicts and preserves the retained choices

#### Scenario: Retry after acknowledgement
- **WHEN** the owner retries a retained matching request after it was applied
- **THEN** the retained terminal result is returned and the task is not blocked again

### Requirement: Explicit deliberate re-ask
A deliberate re-ask of a terminal non-gate question SHALL require an explicit new generation with a stable client retry key. Concurrent retries MUST produce one new request. Existing explicit-gate callers SHALL retain their task/gate identity and changed-content refusal.

#### Scenario: Deliberate second approval
- **WHEN** an owner explicitly re-asks a closed question using a new generation and retries the same key
- **THEN** one new request exists while the original remains retained

### Requirement: Compatible seat preflight
Read-only metadata/diagnostics SHALL expose CLI and server decision capabilities. The launcher MUST refuse work when the resolved CLI lacks required decision support or compatibility cannot be verified, with an upgrade hint. General modern CLI check-ins SHALL warn on incompatible capabilities without printing credentials. Existing request flags MUST remain usable.

#### Scenario: Pre-schema20 binary
- **WHEN** the launcher resolves a CLI lacking the decision command
- **THEN** it refuses before acquiring a new lease or authorizing editing and identifies the required verified upgrade

#### Scenario: Unavailable server
- **WHEN** preflight cannot verify server compatibility
- **THEN** it reports unavailable and does not claim a successful check

### Requirement: Top-of-board waiting visibility
Waiting on captain SHALL precede Kanban columns and show open formal plus unfiled rows oldest first, with exact count, age, seat/task/PR links and the same scoped nav count. Counts MUST be independent of page length and use the same owner/repo scope as rows. Unavailable reads MUST be labeled unknown.

#### Scenario: More rows than one page
- **WHEN** thirty-two outstanding rows exist and the bounded page displays twenty
- **THEN** the lane and navigation show thirty-two with a valid next-page control

#### Scenario: Answer immediately removes primary item
- **WHEN** the captain answers an open decision
- **THEN** primary waiting count decreases and the answered entry appears only in the collapsed awaiting-ack section

### Requirement: Read-only unfiled ask recovery
A latest meaningful owner update or task-tagged message with an explicit captain marker SHALL derive a Needs captain (no decision filed) row when no active formal decision covers that task. Rows MUST retain escaped source body and attribution, confer no lease hold or wake, and avoid negated, quoted or unrelated captain mentions.

#### Scenario: Marked blocked update
- **WHEN** the latest owner update on a blocked task starts with CAPTAIN DECISION: and no formal decision exists
- **THEN** an unstructured source-linked row appears without a held claim

#### Scenario: Newer non-captain progress
- **WHEN** a newer meaningful owner update removes the request or the task becomes terminal
- **THEN** the unfiled row disappears

#### Scenario: Resolved promoted source
- **WHEN** a formal decision promoted from that source is answered or terminal
- **THEN** the old source cannot reappear as an unfiled question

### Requirement: Attributed guarded promotion
Promotion SHALL require the live owner or authenticated captain/coordinator capability and fresh source/revision checks. It MUST retain source findings and promoting provenance separately from the requesting owner. Stale source, changed ownership or missing live claim MUST refuse without impersonation or implicit reclaim.

#### Scenario: Coordinator promotion
- **WHEN** an authorized coordinator promotes a fresh owner-authored ask
- **THEN** one formal request replaces the derived row, retains the owner as requester and records the coordinator as promoter

#### Scenario: Source changed during promotion
- **WHEN** a newer owner update arrives before promotion commits
- **THEN** promotion refuses and creates no request or hold

### Requirement: Audited cleanup
Applied, withdrawn and superseded entries SHALL leave waiting sections. Expiry SHALL default off, apply only to configured non-gate requests, and record audited supersede reasons. Bound merge requests MAY be retired only from authoritative matching terminal PR evidence; stale evidence MUST retain the request.

#### Scenario: Merged bound PR
- **WHEN** configured cleanup verifies the bound merge request's PR is terminal
- **THEN** it supersedes that open request with a retained reason and emits no answer or wake

#### Scenario: Unavailable terminal evidence
- **WHEN** PR evidence is unavailable or belongs to another URL
- **THEN** cleanup retains the open request and hold

### Requirement: Preserve answer authority and delivery
Answer, recommend and supersede SHALL retain verified captain capability and coordinator attribution requirements. Exact answer retries MUST retain one message/event/wake and reject changed answers. Answered requests MUST retain the claim hold until ack or audited supersede. Decision delivery MUST remain independent of Mattermost and policy automation.

#### Scenario: Duplicate authorized answer
- **WHEN** the same authorized answer is repeated after a lost response
- **THEN** its original answer, message, event and wake IDs are returned

#### Scenario: Spoofed captain attribution
- **WHEN** a caller supplies captain attribution without verified capability
- **THEN** no decision mutation or delivery occurs
