# Design

## Context

See proposal.md for motivation. Original proposal baseline was main 5cf25aba; approved implementation starts from freshly fetched main 5595a136. The existing CLI in internal/cli/decisions.go requires --task, --gate and a findings file for all kinds. Decisions.request/2 locks the task before lookup and mutation, deduplicates by unique task/gate, blocks the owned task, and preserves verbatim payload. Answer already retries idempotently on exact answer and answering actor, delivering one message/event/wake. Open and answered requests hold the lease; applied/withdrawn/superseded clear it.

BoardLive currently loads waiting=open+answered pages of 20 and renders DecisionPanel below all columns. A page length cannot provide a total count. The main OpenSpec spec inventory is empty; the shipped add-decision-requests change remains the compatibility baseline. Schema20 limits kind and status through database checks. The source launcher validates Treehouse3.1.2 physical isolation but does not check decision CLI capabilities.

## Goals / Non-Goals

**Goals:** one durable intake for all captain questions; exact, bounded, truthful visibility independent of Kanban pagination; attributed recovery of informal asks; compatible retry/answer and wake custody.
**Non-Goals:** GH145 policy-rule automation, Mattermost decision delivery, autonomous merges, deployment or token provisioning, interpreting credentials in public questions, releasing ambiguous wake reservations, sweeping another seat's claims. Implementation follows captain approval; merge and rollout remain captain-owned.

## Decisions

### 1. Universal CLI forms preserve the existing API

Support request TASK and the existing --task TASK form. If both are present they must agree. Kinds are ask_user_gate, approval, merge, policy, credential, scope plus retained blocked_decision/other. Ask-user gates require explicit stable gate and a regular bounded UTF-8 findings file, preserving its content verbatim. Non-gate kinds default to approval, allow gate/findings omission, and use empty findings when omitted. CLI and server validate the same byte limits; unknown kinds fail visibly. Credential questions describe a needed capability or custody path, never include secrets.

Explicit-gate requests retain task/gate idempotency and changed-content conflict. Non-gate requests use a server-authoritative normalized-question identity: Unicode NFC, trim and collapse the Unicode whitespace set, preserve case, punctuation and wording. The digest is SHA256 of the canonical UTF-8 question, scoped by task. Raw question is retained verbatim. Equivalent spelling/whitespace retries return the original request; changed kind/options/findings conflict rather than overwrite. Use a shared versioned normalization contract and executable cross-language cases, not independent loose regular expressions. Task lock serializes all mutations before dedupe, preserving owner checks and one request event.

Retained answered/terminal matching requests are returned without reopening or holding a task. A deliberate re-ask uses explicit --new after terminal disposition with a new generation under the task lock; retry --new binds a supplied stable client request key. This avoids a retry resurrecting a closed question. Existing gate callers do not gain --new implicitly. A genuinely changed normalized question can create a new request normally.

### 2. Keep the display derived; make required durable additions explicit

No waiting-lane table. Add nullable question identity/normalization version, request generation or client retry key, optional expiry, and promotion source metadata only if needed by the universal protocol; use existing task events for promotion attribution where possible. Extend the existing kind constraint. Old gate rows remain valid and their keys/immutable history are never rewritten. Enforce active normalized-key uniqueness with the task lock and, where compatible, a partial database uniqueness constraint over open/answered; historical closed generations remain retained.

New kinds and expiry cannot honestly be added without changing schema20's constraints. Recommend a narrowly additive migration for those durable contracts, while keeping the list entirely derived. Coordinator task_order 1347 reserves migration 29 after captain approval. PR140 merged at main 5595a136 with required schema 28; its test-only higher-schema stamp 29 moves to 30. The migration uses GREATEST(version,29) and preserves higher deployed values. An alternative alias-only CLI could avoid migration but would lose exact requested kind/expiry semantics; it is not the recommended design.

### 3. One waiting read model supplies rows and counts

Add a read-only waiting endpoint or equivalent Decisions waiting read model, reused by board and navigation. Primary count = open formal requests + unfiled captain asks, excludes answered. Both count and bounded oldest-first pages use one consistent database read snapshot and the same owner/repo scope; the independent Kanban status filter does not hide captain questions. Rows sort by (waiting_since, source_type, stable source ID). Filter-bound opaque cursors reject changed scope; exact total is separate from page length. Cap bodies, return links/attribution, escape verbatim text, retain requester-stale and held-claim labels.

Answered formal requests move immediately to a collapsed Awaiting seat ack subsection with separate count. Closed/applied/withdrawn/superseded records leave both sections. On read failure retain last known rows but label unavailable and count unknown; never render a green or zero state. Board header/nav show the same scoped count, then Waiting on captain, then existing Kanban columns. Keep theme tokens, full Tailwind v4 class names, responsive containment and keyboard controls.

### 4. Informal asks are evidence, not authority

For each nonterminal task take the latest relevant owner update (task status/progress) or task-tagged owner message by timestamp then stable event/message ID, excluding automatic bookkeeping, doc notices and coordinator reminders. A row qualifies when that latest meaningful body has a leading waiting on captain or CAPTAIN DECISION: marker (case/space normalized for recognition), or a narrowly explicit captain request marker on a blocked task. Do not treat every blocked card, bare word captain, a negated request or quoted old question as a captain decision. Broader language classification is outside this deterministic change.

Latest newer non-captain owner progress retires the inferred ask. A formal open/answered request on the same task suppresses the derived row; task completion/cancellation clears it. A matching terminal formal decision with its retained promotion source suppresses the old source so an answered ask cannot reappear. Unfiled entries show their source body verbatim, task/PR/seat, age and Needs captain (no decision filed). They grant no hold, no answer authority and no wake. No direct messages from unrelated tasks or captured private pane data are ingested.

### 5. Promotion is explicit and compare-and-set

Owner can file from the source normally. Coordinator CLI decision promote TASK requires protected captain capability, source type/ID plus task revision/source freshness and an explicit bounded question/kind/options. Re-read source, live owner and latest meaningful body under task lock; stale source or changed owner refuses. Preserve source verbatim as findings and store promoting actor/provenance separately from the requester (the live task owner); never impersonate the seat. Duplicate promotion returns the prior record. No owner/claim -> refuse and require existing audited claim recovery first. Optional captain-only board Promote uses exactly the same reducer and preconditions. Existing answer/recommend/supersede commands remain the supported path, never pane/chat prose alone.

### 6. Capabilities guard the real resolved CLI

Advertise CLI capabilities/build identity and server minimum decision-intake contract in meta/doctor. Schema numbers remain database compatibility, not a proxy for CLI capabilities. Modern CLI reports a warning to stderr (structured diagnostics in JSON) on general check-in if decision support is below the server-required level. Seat launch/check probes the exact resolved executable for decision commands and read-only compatibility metadata before acquiring a new lease or permitting editing. An old binary missing doctor/decision is detected by help/version/meta probes and refuses with a concrete release installer/checksum hint. A failed network/compatibility probe is unavailable, not success. Do not auto-upgrade or overwrite binaries/token files; preserve context and stop with a reported dependency. CLI upgrades can precede server changes; old flag-style decision clients remain supported.

### 7. Clearing and expiry preserve the existing hold/wake contract

Answer commits already idempotent on decision/answer text plus authority; retain exact equality and one message/event/wake. Answered rows clear from the primary count but remain held until seat ack or audited supersede. UI never equates an answer with physical wake delivery.

Expiry is operator-configured and disabled by default. Permit bounded explicit request expiry only for non-gate requests and never retroactively reinterpret a captain answer. A configured maintenance reducer may supersede an open merge request when retained authoritative PR terminal evidence matches its bound PR, or when its explicit expiry passes. It re-reads request/task under locks, writes close_reason and actor/provenance through the normal audited lifecycle, and creates no answer/wake. No remote provider I/O inside the transaction; stale/unavailable evidence cannot expire a record. Other ask-user gates remain explicit captain recovery. Withdrawn/applied/superseded are terminal; expired entries are represented by audited superseded status with a reason, preserving old status constraints. A retained terminal source prevents derived-row resurrection.

### 8. One protocol in every overlay

Update skills/agentboard, ask-user-escalation and codex/claude/grok/herdr/muse/pi/opencode/cursor/omp overlays and setup guide: any captain authority question requires decision request, notify coordinator with ID and links, heartbeat on owned task, then stop dependent work. No prose-only fallback unless the API/CLI is unavailable and its exact blocker is recorded; an informal fallback remains unstructured and confers no hold. Explicit authorized parking/assignment routing remains captain-controlled. GH145 consumes canonical decisions/updated_at and must not redefine request normalization or supersede precedence in this change.

## Risks / Trade-offs

- Marker detection misses natural-language questions → version guard and universal mandatory filing; label inferred rows honestly and support promotion.
- Retry identity hides changed options → exact payload conflict, retained raw text and explicit generation for deliberate re-ask.
- Large task history causes slow read → indexed latest relevant source selection, bounded returned bodies/pages, exact aggregate count; no task-by-task network scans.
- Automated expiry releases a hold unexpectedly → default off, non-gate restriction, bound PR evidence, lock/re-read and audited reason; no inferred answer.
- Pending migration collision → coordinator allocates the next free number after approval and before code; no migration in this proposal.
- Old CLI cannot self-warn → launcher probes before work and reports concrete upgrade; keep old API forms compatible.
- Public artifacts leaking live requests → use only invented mock cards and generic identifiers, no secrets/private specs or captured data.

## Migration Plan

After captain approval, reserve an available schema version, add additive columns/constraints with monotonic GREATEST, deploy compatible CLI/skills first, then server/launcher guard and derived read model. Preserve historical gate requests and audit/version tables; add higher-schema and legacy-gate fixtures to existing release-schema/decision owners. Expiry remains off unless separately configured. Roll back read/UI changes with a compatible image; preserve new history and avoid destructive down migrations. Remote-only behavioral proof, final-head Archify/OpenSpec docs and full native no-mistakes noyes/current-head green CI precede review. Captain handles merge and rollout.
