# Conflict routing integration contract v2

This contract supplements the approved `add-server-conflict-routing` proposal. It is a typed integration contract, **not a declaration of shipped runtime or native adapter support**. Captain decision `aca78ca8-4587-438c-babd-f33065d0bb37` (board msg1725, 2026-10-09) approves the worker Event/Delivery versus inbox Message amendment to the prior msg1645/doc176 source contract. Schema32 remains reserved for #169. The order_ref machine schema remains v1; only the delivery-source contract advances to v2.

## Owners

| Boundary | Owner | Consumer |
| --- | --- | --- |
| Conflict order, current-pointer resolver and base fences | #169 | #156 wake reservation; #122 delivery selector |
| Sole worker/inbox delivery election | #122 | #169 and existing accountability |
| Typed inbox capture and coordinated existing-worker source contract | #156 with #122/#169 | Host worker |
| Shared repository-seat eligibility | #169, reused by #170 | Conflict deadline and idle-seat refill |
| Native publication/custody proof | Capability prerequisite; upstream support unresolved | #169 publication grants |

## Typed order reference

`conflict-order-ref.v1.schema.json` is the machine-owned envelope below. Canonical `Delivery.PullRequest.id` is a SHA256 **64-hex string**, not a UUID. Ref strings also require Git ref-format validation at the publisher; the schema does not establish Git validity.

The current-order resolver must verify the order ID and revision are still current, unresolved and unsuperseded; the repair still targets the named recipient; and both default-tip and actual target-base identities match canonical watched evidence. A non-default-target PR keeps its evaluation base distinct from the default tip. A missing resolver is `unsupported/manual`, never assumed current from message prose.

## One selected source and one delivery selector

The per-version cooperation key is `conflict-order:<order_id>:<order_revision>`. #122 owns the authoritative worker/inbox election through its supplied `Agentboard.Cooperation.Runtime.fallback(event, recipient_ids, actor, opts \\ [])`. #169 does not implement a second selector. Its documented outcomes remain `{:disabled|:worker, Event}`, `{:adopted|:sent, Message}` or an undeliverable disposition. Disabled is not proof of delivery.

| Selected mode | Canonical retained source | Existing delivery path |
| --- | --- | --- |
| Healthy worker | Event and its Delivery | Normal bounded worker frame and exact Delivery receipts; no second Message or inbox wake |
| Inbox fallback | One canonical Board.Message | #156 typed Message capture; no extra worker frame or independent delivery |
| No resolvable recipient | Visible undeliverable source disposition | No fabricated recipient, prompt or receipt |

Inbox identity stays `source_kind=board_message`, `source_id=Message.id`, `source_version=Message.created_at` in RFC3339, and `reason=unread_dm`. Worker identity stays the existing Event ID/source_key and Delivery ID in the normal frozen worker payload. Do not relabel an Event as a board_message or invent a conflict wake enum. The existing worker item currently lacks `order_ref`; the agreed amendment requires a bounded closed reference projected from an authoritative retained Event-to-order relation into that same item. That relation and projection are implementation work, not a shipped API or second deliverable source.

Both paths carry the unchanged closed `conflict-order-ref.v1.schema.json`. #169 owns its canonical resolver; #122 and #156 must agree the actual capture/projection interface before wiring. Check current pointer/revision, unresolved state, named recipient and repair assignment, and watched default/target identities. Superseded frozen batches/intents are refused. Never derive authority from human summary text or caller-provided references. A missing resolver/projection is unsupported/manual.

An informational fallback uses `kind=note`. Sending a `task_order` retains ACTIVE-recipient admission. Worker mode requires an enrolled, registered, unpaused, nonrevoked and live worker covering the repository. Exact-prior source/receipts suppress a second native prompt on late enrollment. Persisted sources and delivery receipts establish notification evidence only; neither grants native custody or branch publication.

## Lock order and transaction ownership

Conflict paths acquire `BaseWatch -> PullRequest -> PollState` before availability admission, candidate agent rows in stable ID order, repair task, current order, source election, selected Event or Message, and worker/subscription/binding/delivery/intent. Generic source paths begin at their admission/source locks, then message and worker. A caller already holding a worker lock must defer bootstrap or lift it; it must not acquire a source or base lock beneath that worker.

The selector's source-election advisory lock precedes its source/message/worker writes and remains held to transaction commit. Producer election uses it. Worker-first late enrollment must not re-elect or take this advisory lock: bootstrap captures the existing immutable source and uses exact-prior ensure_delivery/receipts, as audited in #122 event3058. Canonical order and selected source/capture commit together; provider and native I/O run outside locks. Tests must exercise both fallback/bootstrap interleavings and retained receipts, not only sequential marker lookups.

## Shared eligibility v1

Apply effective availability ACTIVE, registered seat kind, nonretired, current configured server liveness, no outstanding captain hold, repository permission/capability, and queue below policy. RESERVED and out-of-service seats are excluded. Repository capability must be explicit; a shared GitHub login establishes no seat permission.

Default queue limit is **2**, configurable; count assigned, in_progress, blocked and review follow-up cards, excluding terminal and archived cards. Candidate order is shortest queue, oldest assignment time, then full stable agent ID. Recheck under shared admission plus the candidate row lock before assigning; concurrency must not exceed the limit. The repair operation never changes a source-card lease. #170 must call this evaluator instead of maintaining another predicate.

## Native capability boundary

Wake delivery, a board assignment, possession of Git credentials or `axi sync` do not transfer native branch custody. Installed No-mistakes v1.84.0 has same-owner guarded recovery; a supported pre-open admission callback and cross-seat custody-transfer receipt have not been proved.

Before reassigned writes, require an authoritative native adapter to bind original run, repository and branch, preserved pipeline head, custody generation, live repair claim, expected remote head and fresh base. It must prove the original publisher is terminal/quiesced and every unpublished fix is preserved. Active original monitors continue their own fix/revalidation. Missing, divergent, replayed or unavailable proof escalates and issues no write grant.

The server must never mint a supported custody receipt from caller claims or a fixture. Executable native adapter acceptance, including two-publisher races and failure recovery, is required before enabling reassigned branch writes. A pre-push hook alone cannot gate native `host.CreatePR/UpdatePR`; that upstream integration remains an explicit capability prerequisite.

## Evidence status

Captain decision aca78ca8 is approved; v2 applies that source amendment. Messages1703 (#156) and1711 (#122) supply the actual Message-only versus Event/Delivery boundary; this document replaces the old both-mode Message requirement without claiming consumer implementation. The same 64-hex PR ID and closed order_ref schema acknowledged in doc176 remain unchanged. #122 retains its active native pipeline custody, including worker-health fixes. Joint owner acknowledgment of this v2 source/capture contract and actual executable integration proof remain pending; task1.1 stays unchecked. Native PR-admission/cross-seat custody support remains unresolved under separate decision `fd4961ff-f367-42ad-9c72-153161c73d23`. Runtime remains incomplete (2/19). Production routing stays disabled; no grants, publication run, PR or cutover has been initiated.
