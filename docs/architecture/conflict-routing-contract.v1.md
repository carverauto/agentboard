# Conflict routing integration contract v1

This contract supplements the approved `add-server-conflict-routing` proposal. It is a typed integration contract, **not a declaration of shipped runtime or native adapter support**. Coordinator ruling: board messages 1645/1646. Schema32 remains reserved for #169.

## Owners

| Boundary | Owner | Consumer |
| --- | --- | --- |
| Conflict order, current-pointer resolver and base fences | #169 | #156 wake reservation; #122 delivery selector |
| Sole worker/inbox delivery election | #122 | #169 and existing accountability |
| Board-message wake capture, reservation and currentness | #156 | Host worker |
| Shared repository-seat eligibility | #169, reused by #170 | Conflict deadline and idle-seat refill |
| Native publication/custody proof | Capability prerequisite; upstream support unresolved | #169 publication grants |

## Typed order reference

`conflict-order-ref.v1.schema.json` is the machine-owned envelope below. Canonical `Delivery.PullRequest.id` is a SHA256 **64-hex string**, not a UUID. Ref strings also require Git ref-format validation at the publisher; the schema does not establish Git validity.

The current-order resolver must verify the order ID and revision are still current, unresolved and unsuperseded; the repair still targets the named recipient; and both default-tip and actual target-base identities match canonical watched evidence. A non-default-target PR keeps its evaluation base distinct from the default tip. A missing resolver is `unsupported/manual`, never assumed current from message prose.

## One canonical message and one delivery selector

The proposed per-version cooperation key is `conflict-order:<order_id>:<order_revision>`. #122 owns the authoritative worker/inbox election and supplies the module/signature before integration. #169 must not implement a second selector.

The selector creates or adopts exactly one canonical `Board.Message` for that key. The source is the returned message: `source_kind=board_message`, `source_id=Message.id`, `source_version=Message.created_at` in RFC3339, and `reason=unread_dm`. A structured `order_ref` carries the typed reference; never reconstruct currentness from the human summary.

An informational fallback uses `kind=note`. Sending a `task_order` still requires existing ACTIVE-recipient admission; no fallback bypass. Worker mode requires an enrolled, registered, unpaused, live worker covering the repository. Missing fallback recipient is undeliverable, retained visibly. Existing receipts suppress a second native prompt on late enrollment. Persisting an inbox message is not proof of native delivery.

## Lock order and transaction ownership

Conflict paths acquire `BaseWatch -> PullRequest -> PollState` before availability admission, candidate agent rows in stable ID order, repair task, current order, source-election/message, and worker/subscription/binding/delivery/intent. Generic source paths begin at their admission/source locks, then message and worker. A caller already holding a worker lock must defer bootstrap or lift it; it must not acquire a source or base lock beneath that worker.

The selector's source-election advisory lock precedes its source/message/worker writes and remains held to transaction commit. Both capture and late enrollment use it. Canonical order, message and wake capture commit together; provider and native I/O run outside locks. Tests must exercise both fallback/bootstrap interleavings and retained receipts, not only sequential marker lookups.

## Shared eligibility v1

Apply effective availability ACTIVE, registered seat kind, nonretired, current configured server liveness, no outstanding captain hold, repository permission/capability, and queue below policy. RESERVED and out-of-service seats are excluded. Repository capability must be explicit; a shared GitHub login establishes no seat permission.

Default queue limit is **2**, configurable; count assigned, in_progress, blocked and review follow-up cards, excluding terminal and archived cards. Candidate order is shortest queue, oldest assignment time, then full stable agent ID. Recheck under shared admission plus the candidate row lock before assigning; concurrency must not exceed the limit. The repair operation never changes a source-card lease. #170 must call this evaluator instead of maintaining another predicate.

## Native capability boundary

Wake delivery, a board assignment, possession of Git credentials or `axi sync` do not transfer native branch custody. Installed No-mistakes v1.84.0 has same-owner guarded recovery; a supported pre-open admission callback and cross-seat custody-transfer receipt have not been proved.

Before reassigned writes, require an authoritative native adapter to bind original run, repository and branch, preserved pipeline head, custody generation, live repair claim, expected remote head and fresh base. It must prove the original publisher is terminal/quiesced and every unpublished fix is preserved. Active original monitors continue their own fix/revalidation. Missing, divergent, replayed or unavailable proof escalates and issues no write grant.

The server must never mint a supported custody receipt from caller claims or a fixture. Executable native adapter acceptance, including two-publisher races and failure recovery, is required before enabling reassigned branch writes. A pre-push hook alone cannot gate native `host.CreatePR/UpdatePR`; that upstream integration remains an explicit capability prerequisite.

## Evidence status

Message-envelope ownership agreements are in board messages 1613, 1625, 1628 and 1645. #156 identified and corrected the canonical PR-ID type in 1660/1662. Exact #122 selector API and both consumers' acknowledgment of this artifact remain pending. Native support is unresolved (coordinator question 1663). Runtime tasks remain unchecked until their actual tests pass.
