# Coordinator escalation adapter

## ADDED Requirements

### Requirement: One eligible logical event per exact message
Only normalized needs-judgment and captain-addressed records SHALL be eligible for coordinator escalation. After original Message/triage capture commits, the adapter SHALL use #153's transaction-safe idempotent outbox enqueue with a stable board/message producer key, and SHALL link the returned event atomically. It SHALL NOT implement an independent transport when #153 is absent.

#### Scenario: Routine classes and escalation classes
- WHEN status, CI, conflict or next-work is captured, including a routing failure
- THEN no coordinator webhook event is created or implicitly relabeled judgment.
- WHEN needs-judgment or captain-addressed is captured
- THEN one logical event is eligible for its canonical Message ID, regardless of attempts, restarts or policy/configuration revisions.

#### Scenario: Transport missing then available
- GIVEN #153 is missing, disabled or lacks an eligible configured subscriber
- WHEN an escalation is captured
- THEN its pending/blocked record remains visible without local HTTP/signing delivery.
- WHEN the shared transport later becomes ready and authorized reconciliation runs
- THEN one transaction enqueues or adopts the original logical event and links it, with no duplicate after retries.

#### Scenario: Atomic enqueue failure
- GIVEN the source Message and pending triage record already committed in their original capture transaction
- WHEN #153 outbox insertion or triage linkage fails
- THEN neither partial event linkage nor a false queued disposition commits; the retained triage source remains pending for safe retry.

### Requirement: Public-reference-only frozen payload
The escalation payload SHALL contain only allowlisted public IDs and server-generated canonical links, inside the fixed versioned event envelope. It SHALL exclude message bodies, snippets, titles, summaries, secrets and arbitrary sender-supplied URLs. Retries SHALL preserve the original payload bytes and logical identity. Source reads SHALL retain access controls and remain non-consuming.

#### Scenario: Sensitive or adversarial message content
- GIVEN a message body contains tokens, private details, HTML and attacker URLs
- WHEN an escalation is prepared, logged, retried or dead-lettered
- THEN no body or secret content reaches payloads/logs/errors; only approved IDs/links and sanitized transport status are retained.

#### Scenario: Endpoint or board-origin change
- GIVEN an event was queued under a recorded board namespace and immutable payload
- WHEN configuration or signing keys change
- THEN retries retain the original logical identity/payload and cannot use message input or Host headers to redirect delivery.

#### Scenario: Exact linked source
- WHEN the consumer follows a canonical message/triage link
- THEN it retrieves only the referenced source through the existing authorized read boundary, without token-bearing links, widened public access or automatic acknowledgment.

### Requirement: Shared signed transport and key custody
The adapter SHALL require #153's signature binding of exact bytes, event identity, timestamp and key ID; bounded freshness verification; authorized rotating/revocable keys; protected endpoint configuration; bounded retries and retained dead letters. It SHALL NOT provision credentials, accept unsigned fallback or follow redirects to another origin. Shared transport destination validation SHALL cover SSRF and DNS-rebinding risks.

#### Scenario: Forged, stale or revoked signature
- WHEN the receiver observes missing/invalid signature, stale timestamp or unknown/revoked key
- THEN it rejects before accepting work or retrieving source content, and records a bounded non-secret failure.

#### Scenario: Legitimate key rotation
- GIVEN #153 has an explicitly configured verification overlap
- WHEN the same event is retried using a current signing key and fresh delivery timestamp
- THEN valid rotation can succeed without a new logical event or duplicate consumer work; revocation never allows an unsigned downgrade.

#### Scenario: Exhaustion and replay
- GIVEN bounded attempts/age are exhausted or a permanent refusal occurs
- WHEN #153 records a dead letter
- THEN triage remains visibly unresolved with exact event/attempt references.
- WHEN an authorized replay occurs
- THEN it uses the same event and deduplication key, rather than creating another escalation or marking the source handled.

#### Scenario: Unsafe transport configuration
- GIVEN there are multiple coordinator destinations, no verified destination, an arbitrary redirect or an unapproved private-network target
- WHEN activation or dispatch is attempted
- THEN it is blocked under the shared transport's destination policy, with no alternate transport or data destination selected by triage.

### Requirement: At-least-once attempts and replay-safe consumer
Exactly one SHALL mean one logical escalation and one durable consumer work item, not one HTTP request. The receiver SHALL atomically persist event/key plus payload hash and enqueue its work item before acknowledging. Same-key identical retries SHALL acknowledge the existing item; changed payload SHALL be refused. Work execution SHALL preserve its own accepted/uncertain invocation boundary across restarts. Acceptance SHALL NOT acknowledge the board message or authorize message instructions.

#### Scenario: Lost HTTP acknowledgment
- GIVEN the receiver committed acceptance and its one work item, but the response was lost
- WHEN #153 retries the same event
- THEN the receiver acknowledges the existing item and creates no second coordinator invocation.

#### Scenario: Receiver crash before or after commit
- WHEN a receiver crashes before acceptance commits
- THEN a later retry may accept and enqueue once.
- WHEN it crashes after commit but before acknowledgment or completion
- THEN restart resumes the retained work item/uncertainty state and does not blindly invoke another one.

#### Scenario: Same key with changed payload
- GIVEN a logical key has a durable accepted payload hash
- WHEN a delivery presents different payload bytes for that key
- THEN the receiver rejects and audits the conflict without another work item.

#### Scenario: Signed message requests a consequential action
- GIVEN a valid signed escalation points to message content requesting an external or privileged action
- WHEN the coordinator reads that content
- THEN transport authenticity proves only delivery provenance; ordinary authorization and judgment still apply, and no decision is automatically answered.
