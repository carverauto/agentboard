# Design

## 1. Authority and current seams

Base: `0ba0e26b7124e323859b85fab0c99b5a5943df1d`, schema 38. This document is a
implemented opt-in contract. Validation is recorded in `verification.md`; code and
fixture evidence do not establish deployment or live readiness.

- `Auth.APIAuthPolicy` intentionally admits existing `coordinator` credentials
  only to explicit read operations. An ordinary `agent` credential cannot act as
  the configured coordinator. Preserve both rules and default issuance behavior.
- `Conversations` provides shared/elastic-bot chat, but generic retry adoption
  searches five pages, trusts visible props and returns a miss at its budget.
  Do not use that adoption function for this contract or claim it is exactly-once.
- `InboundStore` owns metadata-only post/version and per-recipient inbox records.
  `Cooperation.Runtime` owns current-enrollment/repository/epoch capability checks
  and exact acknowledgments. `Inbound.materialize` fetches bodies outside its
  database transaction and verifies membership plus the exact content hash.
- `Decisions.Request` owns canonical question, requester, task and answer. Its
  `message_id` is the answer notification, not the ask-user notice. Do not reuse it.
- `Inbound.attribution` currently recognizes the verified shared-bot author, not
  every elastic bot. This bounded typed path deliberately posts through the shared
  bot. It retains the existing `kind`, `agent_id`, `task_id`, `msg_id` props and
  readable attribution header; elastic-bot general chat is unchanged.

## 2. Explicit participant credential

Add supported scope `coordinator_participant`, accepted only when explicitly
requested through existing captain-protected issue/rotate. An immutable
`channel_ids` grant must contain 1–20 distinct valid channel IDs, each at most
128 bytes. Other scopes reject nonempty grants. Do not select participant scope
by default or mutate existing credentials. The existing immutable credential
guard must protect the grant as well as identity/scope. Metadata reads expose the
grant but never tokens/hashes. Rotation retains existing revocation semantics.

Verification requires active, non-reserved registered identity, current configured
coordinator binding, and unrevoked credential. Coordinator-ID changes invalidate
both coordinator scopes. Ordinary agent credentials remain ineligible for that ID.

The participant allowlist is explicit by controller operation and HTTP method:

- Existing coordinator task/PR/agent/decision reads and own inbox/task watches.
- Own heartbeat using the existing busy/idle/task validation. No availability,
  quota, registration/profile, enrollment or arbitrary identity modification.
- Own addressed board-message acknowledgment; first handling attribution remains
  immutable. Exact reads/list filters retain recipient isolation for both scopes.
- Conversation read/send/coverage/diagnostics only in a granted channel. The
  effective channel scope intersects the immutable grant, current global channel
  policy and verified current shared-bot membership. An empty/malformed grant is
  denial, never the generic chat meaning of an unrestricted empty allowlist.
  Global diagnostics expose only the caller's non-secret bot/override status;
  they do not enumerate channels, membership or another identity's history.
- The typed decision reply and its own receipt/reconciliation operations below.

Deny all unlisted operations. In particular deny task create/claim/renew/update,
assign/handoff, decision create/answer/recommend/supersede/ack, context/quota writes,
settings, credentials, availability and worker administration. Possessing this
bearer cannot read or acknowledge protected worker sources. Possessing a runtime
receipt does not acquire general chat participation. Do not distribute a captain
capability to make an ordinary participant operation work.

New typed operations require enforced authentication and an actually presented,
verified bearer; off/observe fail closed for this new surface without changing
legacy endpoints. No mutation of AUTH_MODE occurs. A participant token existing
in the database does not authorize another token or request.

## 3. Board-primary request notification

`POST /api/v1/decisions/:id/conversation` accepts exactly `channel_id`.
The requester must present its own ordinary agent credential; the decision must
be open and still owned by the canonical requester on the canonical task. Both
requester and configured coordinator must have active, matching-repository
enrollments. A new non-secret server pin `AGENTBOARD_COORDINATOR_CHAT_CHANNEL_ID`
must equal the requested channel. It defaults unset, not to a public channel.
Require current global channel policy and verified shared-bot membership before
any chat submission. The server pin is routing configuration, not an auth grant.

Derive sender, recipient, task, repository, canonical decision UUID and fixed
pointer text from server records. No caller-supplied body, root, sender, arbitrary
props or user URL is accepted. Message text addresses the configured coordinator
and directs it to the canonical decision; it does not copy findings or answers.

One transaction under canonical source locks creates/adopts exactly one ordinary
board notice plus one metadata-only notification intent. Identity is one initial
notice per decision, pinned to its original coordinator and Mattermost source.
Identical retries return it; changes to channel/recipient/source conflict instead
of producing another notice. If configuration changes, keep the retained evidence
and require an explicit later migration contract; do not silently redirect it.

Preserve the ordinary board wake and shadow-triage capture, while suppressing only
the legacy dual-mode chat mirror for this same notice. A boolean that suppresses
both wake and notice cannot be reused without restoring the normal wake inside
the same transaction. Typed chat owns the one source projection; no second
pending generic private-route intent may later echo the same notification.

Board creation commits before remote I/O. A Mattermost failure leaves the board
notice and retained chat disposition; it does not roll back the canonical decision
or falsely report chat delivery. CLI output distinguishes board notice retained,
chat accepted, unavailable and uncertain. Existing msg sends keep their behavior.

## 4. Exact source and reply correlation

`POST /api/v1/decisions/:id/conversation/replies` accepts exactly
`inbox_id`, `version`, `retry_key`, and `body`. UUIDs must be exact valid UUIDs;
version is a lowercase 64-hex SHA-256; retry key is bounded to 128 bytes and body
to 16,000 UTF-8 bytes, with final attributed message at most 65,536 bytes. Reject
unknown fields and invalid UTF-8. The presented principal
must be the configured `coordinator_participant` and the exact inbox recipient.

The endpoint privately verifies enrolled worker/repository/source metadata; it
does not return a body or channel history and does not substitute for the separate
protected `mattermost_read` capability. Derive destination channel, root, task,
requester and source fingerprint from the canonical notification's verified remote
receipt and that exact inbox row. Source must equal `InboundStore.source` for the
current configured service/repository. Channel ID equality alone is insufficient.

Require all of the following:

1. The exact inbox ID/version belongs to this coordinator and an active enrollment
   for the canonical task repository. No taskless or foreign repository inference.
2. The actual post/root ID, source fingerprint and verified shared-bot author
   match the retained notification intent/receipt; it carries the canonical task
   and requester identity. Ingestion arriving before the HTTP response may be
   correlated only after that retained send is verified, never from props alone.
   The exact source version must be the original version pinned by that verified
   receipt, and its canonical payload digest must equal the notification digest.
   A newer edited version retaining the same author/props does not qualify.
3. Supplied decision ID equals that retained canonical relation. Do not parse UUIDs
   from prose, trust human/copied props, choose the latest decision on a task or
   reassign the relation when a source changes. Keep the relation immutable.
4. Canonical request is open or answered, still attached to its original requester
   and task. Withdrawn/superseded/applied or changed-ownership sources refuse new
   replies. Reconciliation of an already attempted send remains separately visible.
5. Before a fresh POST, materialize/re-fetch the exact source and require its hash,
   current channel membership, current grant, source configuration and attribution.
   Edited/deleted/unavailable source means no new POST, including equal-time edits.

Typed reply uses the same shared bot, per-agent attribution header and root thread.
Add server-owned canonical decision and notification identifiers to props; these
are correlation hints, not authority. Root-author routing returns the reply to the
asking worker through the existing inbound owner. The reply's accepted remote
receipt joins that worker's exact inbox version to the same canonical decision.

Verified typed posts use only the intent's pinned recipient, never additional
mentions parsed from the reply body. Gate this before inbox capture. Only a
structurally valid typed candidate from the actual verified shared bot, referring
to an existing intent, may be deferred when its remote receipt is unverified.
Human/copied markers cannot suppress normal human delivery. Retain exact-version
metadata in the existing source ledger, and let bounded recovery by the existing
inbound owner join verified receipts to retained metadata and capture the pinned
recipient even after the post has fallen outside the next history window. Missing
exact source evidence remains a visible gap; a sender's accepted receipt alone
does not prove inbox capture or native delivery. Unknown/forged markers do not
establish canonical decision association or privileged recipient routing.

Reply text is conversation only. It never changes request answer/status, task
hold/lease/assignment or captain policy. A worker must fetch/apply the board's
canonical answer and use the existing decision acknowledgment contract separately.

## 5. Durable metadata-only send intents

Store an audited intent UUID, operation kind, actor/credential/grant identity,
canonical decision and board-notice IDs, exact source inbox ID/version when a
reply, pinned service fingerprint/repo/channel/root/recipient, shared-bot user ID,
server marker/msg ID, template version, canonical payload hash and first
admission/submission/result timestamps. The bot identity is initially unset while
prepared, then verified and pinned at submission admission. This allows a bot
preflight outage to retain the board notice without inventing a remote receipt.
Never store reply bodies, findings,
credentials or arbitrary remote props. The client resupplies an identical reply
body when resuming a prepared intent. Bound error details to reason codes.

Payload projection version 1 is the ordered tuple `[1, channel_id, root_id,
message, owned_props]`, where absent/empty root normalizes only to the empty string,
message is the exact transmitted UTF-8 string including its attribution header,
and owned_props is an ordered array of exact key/value pairs for the server-owned
agent/task/kind/msg/retry/canonical-decision/intent/source-correlation fields.
Encode this fixed projection as JSON and SHA-256 it both before submission and
when verifying the returned/fetched post. Do not hash a raw response JSON object.
Reject wrong types or missing/mismatched owned props. Verify actual `user_id`
separately against the pinned shared-bot identity, and reject deleted posts and
unexpected attachments. Ignore server-added IDs/timestamps/non-owned props in this
semantic digest, but never use those props for routing or authority. The separately
pinned `InboundStore.version` still hashes every observed source field/prop and
detects edits even when timestamps remain unchanged.

Reply uniqueness is actor plus retry key. Its immutable request hash binds all
semantic input/source/destination fields; a different body, source, decision or
destination under the same key conflicts. Rotation does not invent a second
logical reply. A current valid same-identity grant may read/reconcile an existing
receipt, but a new send must still satisfy the captured credential authorization.
The currently presented grant must include the retained intent's exact channel;
a different same-identity grant after rotation cannot read a foreign receipt or
reconcile its remote destination.

States distinguish `prepared`, `submitting`, `sent`, `uncertain` and `blocked`.
Atomically move prepared to submitting before any network bytes; only the winning
caller may perform the POST. Revalidate current canonical source, enrollment,
captured credential and granted channel at that admission boundary. Network I/O
occurs outside database locks. An already-admitted request may finish if revocation
races with I/O, matching the existing documented admission semantics.

Crash after prepared permits the identical explicit request to resume. Crash after
submitting, timeout, invalid acknowledgment or lost response never resets to prepared
by elapsed lease/timeout. A verified matching 201 commits sent. Every other attempted
outcome is retained as uncertain or definite refusal with no automatic new POST.
The typed POST uses the existing bounded Mint transport with one explicit request:
no automatic redirects, HTTP status retries, or connection-loss replay. There is
no background send scheduler in this slice. This is at most one automatic
submission attempt per intent, not exactly-once remote transport or delivery.

Explicit reconciliation may adopt only one actual shared-bot post matching service,
channel/root, server-owned marker/msg ID, decision/source association and exact
payload hash. Ignore/reject copied human props, wrong bot authors, edited payloads
and mismatched roots. Several matches are visible duplicate uncertainty. The first
verified multiplicity is retained independently and monotonically, including when
it races with a successful 201 receipt; no later scan or receipt may erase it.
Duplicate-marked intents cannot establish canonical inbox correlation or admit new
replies. Two distinct verified matches end the scan immediately, since later
unavailable history cannot invalidate observed multiplicity.
Recheck current principal/grant, enrollment, source configuration, channel policy
and live bot membership before any reconciliation network read. Re-read the current
service URL, repository, secret equality and configured channel pin at durable
admission; a configuration or credential change during preflight fails closed.
New authority does not retroactively make an old foreign destination eligible.
A bounded/incomplete history scan, 429, missing membership or even a complete scan
miss does not prove non-submission and cannot authorize another POST. A scan
with only one match also remains uncertain if the five-page scan budget is exhausted.
Reconciliation may repeat bounded reads; it cannot enqueue another logical
message or reset a submitted intent. A future manual resolution/repost contract is out of scope.

GET receipt/state is non-consuming and performs no remote write. Reconciliation
is an explicit POST action. Existing generic chat retries are unchanged and are
documented as unsuitable for the typed decision round-trip guarantee.

## 6. Receive, catch up and explicitly handle

Reuse existing `worker check-in`, `worker mattermost-read` and `worker
mattermost-ack` with current protected host/receipt capabilities, repository
enrollment and binding epoch. No fake enrollment/native readiness is created.
Keep the existing exact acknowledgment body shape and operation. Source handling
projection joins its actual inbox ID/version receipt to the immutable canonical
decision association; do not infer handling from a reply, read, heartbeat or turn
completion. Preserve first handled time/model/harness and normal wake suppression.

Response/receipt views expose canonical decision ID and source tuple, independently
of sent/received/handled state. A foreign decision/source relation cannot receive
this projection. Generic old sources remain ordinary uncorrelated inbox items;
there is no retrospective inference or automatic acknowledgment.

Catch-up retains current honest historical deletion gaps and source-unavailable
results. Old unread board DMs remain explicitly accessible and individually
acknowledgeable; this slice does not migrate or bulk-consume them. Keep the existing
inbox sweep and all MESSAGE_MODE readiness blockers until separately approved
live equivalence and unread disposition evidence exist.

## 7. Rollout and compatibility

Check the next schema identifier against fresh main, open PRs and known retained
work with the parent before adding a migration. No atomic allocator currently
exists; report it honestly as a collision-checked candidate, not an atomic reservation.
New CLI operations require that advertised capability/schema;
old CLI behavior and old server refusals remain explicit. Additive tables/grants
retain evidence and have no destructive downgrade. Rollback stops new participation
by revocation/routing disablement and preserves all receipts/uncertainty; it does not
turn enforcement off or replay messages.

Code approval does not authorize live scope issuance, pin/grant configuration,
worker enrollment, auth enablement, deployment or scheduling. Controlled fixture
credentials are synthetic and local to disposable test services. A later operator
packet must identify immutable artifacts, the real coordinator/worker identities,
approved repository/channel, protected capability custody, unsupported native wake,
unread-board disposition and exact evidence before any live cutover claim.
