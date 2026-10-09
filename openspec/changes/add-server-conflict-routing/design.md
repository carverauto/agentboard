# Design

## Context

See `proposal.md` for motivation and the two capability deltas for behavioral contracts. Baseline inspected: `dfbd2e6c3d1b60a3cda1f49f506b899c71327f64`.

| Existing boundary | Observed behavior | Extension |
| --- | --- | --- |
| `Delivery.Inventory.persist/4` and `Scheduling.linked/1` | Explicit task links enroll canonical PRs and enqueue immediate observation inside the submission transaction; discovery scans tasks with non-null `pr_url` | Retain this path; add durable branch binding and bounded registered-branch reconciliation for the null-link gap |
| `Delivery.BaseMonitor` | Durable branch watches, provider I/O outside transactions, generation/attempt leases, branch-before-PR locks and restartable 100-row invalidation pages already react to base changes | Reuse its revisions for sweeps and order fences; enroll the repository default ref separately when a PR targets a different base |
| `Delivery.Github` and provider admission | Complete, bounded head observations, metadata double-read, unknown mergeability and shared request credit | Add budgeted metadata/compare operations; keep unknown distinct from clean and redact all credentials |
| `Delivery.Rebase` / `RebaseFollowUp` | Dirty evidence creates a separate repair; deduplication is PR/head, cooperative notifications are feature-gated, any clean observation resolves retained signals | Add current-base orders, deadlines, selection and changed-head resolution; preserve legacy records |
| `Availability.admit/4` | Effective active/reserved/out-of-service policy and shared admission lock | Combine with liveness, waiting decisions, repository capability and queue limits; do not assume active means idle |
| `scripts/publication-guard` | Native task binding, live owner/lease and terminal/merged-branch fence; local native registry only | Add server-backed bindings and fresh-base verdicts; keep existing fences and native custody |

Existing default-branch failure handling lives in `WorkflowMonitor` / `WorkflowGithub`; it must remain separate from conflict episodes. No main OpenSpec capability inventory exists at this baseline. This planning PR changes no runtime flags, schema or deployed behavior.

## Goals / Non-Goals

**Goals:** Close publication and attribution gaps; bound the time before repair ownership changes; make every mutation attributable and replayable across multiple app pods; provide a custody-safe path to updating the same PR branch.

**Non-Goals:** A new Git host, blanket write credentials for the server, automated merge, a second PR for repair, a parallel wake daemon, or automatic theft/renewal of the source card lease. Schema ordinals and deployment are not changed by this proposal.

## Decisions

### 1. Extend durable delivery state; keep I/O outside database transactions

Use the existing Ash domains, PostgreSQL, AshOban and provider admission. Extend `RebaseFollowUp` with a current order pointer; retain an append-only order history with `(PR, default_ref, base_sha)` identity, triggering head, snapshot, revision, owner, deadline, selection reason and disposition. A current-pointer/partial uniqueness constraint prevents two live orders for one PR/ref. Preserve historical resolved records; backfill no invented deadlines or recipients.

Add a publication binding resource keyed by canonical head repository and exact branch, mapping to a task and binding generation. A binding survives lease release as attribution, but publication authorization always verifies the current live claim. Add short-lived, action-scoped publication/repair grants containing binding generation, head/base, holder, repair identity and native-custody receipt. These are authorization evidence, not credentials. Mutable projections use AshPaperTrail; mutations and dry-run evaluations use the existing AshEvents audit stream.

Provider work reserves credit and a bounded observation attempt, commits that reservation, calls GitHub, then commits only if its generation/head/base still match. Never await provider I/O while holding task/PR/agent locks. Reuse the existing branch-before-PR order; repair admission locks policy, candidate agent rows in stable ID order, then repair state/task. It does not lock or mutate source tasks. Publication binding uses the existing task-before-canonical-PR inventory path; it does not acquire a base lock underneath a task lock. Capture base evidence first and schedule a separate base-fenced reconciliation after linking. These paths must not introduce an inverse branch/task lock edge.

Alternative: a single coordinator/GenServer polling all PRs. Rejected because process-local ownership, mailbox serialization and restart gaps already have durable replacements here.

### 2. Distinguish publication authorization from retained tracking

`publish-seat` registers the owned card, head repository and branch before native publication. Its pre-push hook evaluates the exact ref SHA being pushed, not the caller checkout. Freshly fetch the actual repository default ref (not hard-coded `main` for other repos), compare ancestry and use a read-only Git merge-tree verdict. A current base admits; a clean but behind head warns and records evidence; a conflict refuses. A missing ref, shallow/incomplete history, failed fetch or indeterminate merge check refuses authorization with a retryable disposition. Do not alter an active gate worktree from the hook. The pipeline owns any needed rebase/retest through its normal custody flow.

The server validates the binding, live claim, canonical provider metadata, current base and requested action before granting PR open/update. Local Git evidence is attested workflow evidence, not a substitute for server GitHub observations once a PR exists. GitHub `mergeable: null` remains unknown and schedules a retry; do not infer clean from a successful API request or empty CI results. Provider 429s, Retry-After, secondary limits and the shared #115 budget defer work rather than causing retries in a hot loop.

Before a PR exists, GitHub compare/ancestry is not a conflict solver: a diverged branch can still merge cleanly. Pre-open admission records the controlled publisher's exact-ref merge-tree evidence plus independently checked head/default-tip identity; it does not claim a provider mergeability verdict exists yet. Once opened, authoritative GitHub PR observation replaces that provisional evidence. Short-lived action grants are checked again at the write boundary; offline or unverifiable grants do not authorize writes.

The PR cannot have a URL before it opens. A durable binding is therefore the pre-open prerequisite; a returned URL is acknowledged through an idempotent publication completion API which records `pr_url` and canonical inventory using a publication nonce. A crash after opening but before acknowledgment is repaired by polling the registered branch; one mapping is auto-linked, multiple/invalid mappings create an unlinked-PR finding. GitHub login alone cannot prove which agent authored a PR when agents share credentials: an agent-login match is only a signal to investigate, never sufficient for auto-linking.

For an already existing conflicting PR, refuse **publication authorization**, retain its submission/tracking evidence and immediately schedule conflict routing. A failed admission must not make the PR invisible. Keep the existing task-link response contract for retained metadata and add a separate explicit admission disposition; avoid a misleading failed HTTP response after secretly committing the link. Older clients can still link known PRs; they cannot use the new controlled publish path without an admission/binding receipt. Native publisher compatibility must be tested through a hook/adapter that covers PR open as well as push; a Git pre-push hook alone cannot gate `gh pr create` or guarantee URL recording.

Alternative: reject the entire metadata link and leave `pr_url` null. Rejected because it recreates the untracked conflicting-PR failure this work addresses. Native final-push checks have a distributed race with a moving GitHub ref; the server records the checked base and immediately reconciles later advances, rather than claiming an atomic lock on GitHub main.

### 3. One current conflict order per PR and current default tip

Reuse `BaseMonitor` invalidation. A signed webhook, when #153 exists, is a fast hint, not authoritative mergeability; it schedules the same budgeted branch/PR workers. The poller also notices any default-tip advance whether the causing merge was linked, or whether the advance was a direct push. PR-open discovery and link completion enqueue the same observation path.

Keep `default_tip_sha` distinct from the PR's actual `evaluation_base_ref` / `evaluation_base_sha`. For a non-default-target PR, a default-tip advance still fans out observation, but GitHub mergeability is fenced to its actual target watch; never relabel target evidence as proof against another branch. Actual target advances also invalidate evaluation. Canonical repository default-ref discovery handles repositories whose default is `staging`; the CLI must not assume every default is `main`.

Under the fenced PR transaction, definitive dirty evidence opens or updates a current repair order. Identity is `(canonical PR, default ref, base SHA)`, with a triggering head. Repeated evidence for that tip emits no second live order/message. A changed head still dirty updates observed evidence without stacking orders. A new tip supersedes the prior order and obsolete wake intent; keep the same open repair card where safe. Proposed default deadline: 45 minutes from the first dirty observation. A new tip does not indefinitely extend an already earlier deadline: use the earlier of the retained deadline and the new-tip deadline. Cleared/terminal episodes allow a later genuinely new episode.

Persist the order and the source selected by #122 in the same transaction. Its sole election uses the existing Event/Delivery and normal worker frame/receipt for an enrolled, registered, unpaused, live repository worker; otherwise it uses one canonical inbox Message, or retains an undeliverable disposition. Both paths carry the same closed `order_ref` and currentness checks. Delivery can retry but recipients see one logical order ID/version and one effect. Orders include PR URL, exact head/base, deadline and known conflicting files; GitHub does not always provide file-level conflict information, so missing files are labeled unknown, not fabricated.

Captain decision `aca78ca8-4587-438c-babd-f33065d0bb37` (2026-10-09, board msg1725) approves Event/Delivery in worker mode and Message in inbox mode, amending the earlier canonical-Message-in-both-modes contract. #122 still owns `Runtime.fallback/4`; #169 must not add another selector. #156's inbox capture keeps existing `unread_dm` / `board_message`, Message ID and created-at version. Worker delivery stays on its existing Event/Delivery path; do not fabricate a second Message, wake enum or frame to reuse the inbox API. The Event source must have a typed, authoritative relation to the current order, projected into its existing bounded frame. The exact consumer/capture interface remains subject to joint #122/#156 agreement and executable proof; approval of the design is not proof it is shipped.

Canonical reconciliation invalidates superseded order references on both paths and verifies recipient, repair assignment and watched default/target identities. Never infer version or authority from summary prose. Producer source election is locked before worker rows; worker-first late enrollment reuses the exact existing source/receipt without source-lock inversion or re-election. Exercise fallback/bootstrap interleavings, paused/revoked/stale workers, frozen old batches and exact-prior receipts. ACTIVE-recipient admission for `task_order` remains unchanged; informational fallback stays `note`. A delivery receipt is notification evidence, never native publication or custody authority. Owner agreement and actual transactional capture remain prerequisites in task1.1.

Resolution requires an authoritative observation of a different head from the triggering head, mergeable against the current watched base. A clean observation of the same head after the base changes is retained as `conflict_cleared_without_repair`, cancels obsolete instructions, and stops unnecessary pushes; it does not falsely award a completed repair. Closure/merge cancels remaining orders. A reply, task status change or green head checks alone never completes a conflict repair.

### 4. Repair ownership is separate from authorship and native branch custody

AshOban runs a persisted deadline action and reevaluates earlier when liveness, availability or a source-task decision changes. If the author is current, active and not waiting, assign the repair to that author initially. Stale means the configured server liveness policy, not an arbitrary host timer. An open/unapplied captain decision on a relevant source task excludes the owner; an unrelated decision still excludes a replacement seat from free-seat selection. At deadline any unresolved order is eligible for reassignment, including an author busy on other work.

Use one shared eligibility evaluator with #170: current heartbeat, active effective availability, no retirement, no outstanding captain hold, repository permission/capability, and queue below the configurable threshold. Proposed queue count covers assigned/in-progress/blocked/review follow-ups, excluding terminal/archive tasks; the threshold is policy data shared with refill, not a duplicated hard-coded constant. Choose shortest queue, then oldest assignment time, then stable full agent ID. Recheck eligibility and observed order revision transactionally before selection; serialize only admissions for the same candidate so two jobs cannot oversubscribe its queue.

Record the selection, atomically hand off/reclaim **only** the repair task through an explicit audited system capability, invalidate its old repair claim/grants, and send a new order/wake. Source task assignee, lease, submission actor, authorship and documents remain untouched. No eligible candidate creates one durable captain-lane escalation for that order/version/reason, refreshed on relevant state changes rather than spammed every minute.

An assigned repair is not permission to seize an active No-mistakes worktree. Before repair publication, require a host/native adapter receipt identifying repository, branch, original run, verified preserved head and custody generation. It must prove the old publisher is quiesced or terminal and all unpublished fixes are preserved; an unsupported or divergent custody handoff stops branch writes and escalates. It must not kill a foreign process, rewrite native refs, impersonate the original agent, or create a new PR. Active-monitor fixes can satisfy the order instead. #156/#150 currently describe wake work, not a landed custody-transfer API; the implementation must add and test this explicit handshake before enabling reassigned writes.

The new seat claims only the repair and obtains an action-scoped branch grant bound to its lease, the existing PR/head repository/ref and expected remote head. The task-scoped hook verifies this grant rather than replacing the original binding or pretending the repair owns the source task. Push uses native publication with compare-and-swap/force-with-lease against the exact observed remote head. Verify the current base immediately before the write. If author or old monitor resolves first, cancel the repair/grant and let stale remote-head checks refuse the losing push. A base/head move means reobserve and revalidate, never force past it. Credit the real rebaser only after a verified resolving head; completing the repair releases its claim normally.

Alternative: reassign the author's task or write with the author's identity. Rejected by the lease/authorship contract. Merely having Git push permissions does not prove native custody.

### 5. Dry-run and safe activation

A dedicated conflict-routing policy controls disabled/dry-run/apply, deadlines and shared queue settings. New mutation behavior defaults disabled. Dry-run reads the same canonical evidence and eligibility and writes only an audit evaluation; it sends no task order, assignment, claim, wake, publication grant or GitHub write. Provider observations and their normal observation audit remain independent. The existing observation/cooperation flags retain their meanings; disabling routing suppresses new mutations and revokes pending write grants without erasing evidence.

Expose ledger dispositions and deadline/rebaser on existing task/PR views, with links to the canonical PR, source card, repair and decision. Use existing Tailwind v4 tokens and responsive components; do not redesign the Kanban.

## Risks / Trade-offs

- Native custody handoff capability is not shipped by the current wake path → automatic repair assignment can run, but cross-seat branch writes require the explicit tested handshake; unsupported adapters escalate visibly.
- GitHub mergeability is asynchronous and base metadata can lag → reuse branch-watch fences and metadata rechecks; null, timeout and stale replies never satisfy a repair.
- Base churn can perpetually defer repair → preserve the earliest unresolved deadline and supersede versions without stacking orders.
- Shared tokens blur agent attribution → exact durable repository/branch/task bindings; ambiguity stays in a captain finding.
- Two seats can finish simultaneously → order/grant revisions plus exact remote-head CAS; preserve losing work and audit cancellation.
- Fresh-base refusal can block an offline worker → explicit retryable error and captain escalation; no bypass, credential reuse or local builds.

## Migration Plan

1. Recheck current main, schema ledger and concurrent #164/#170/#156 contracts. Schema 32 is reserved here; use additive migration `20261008003200` and `GREATEST(version,32)` only in the implementation PR. Reconcile the shared eligibility contract before runtime edits.
2. Add nullable current-order fields, new binding/order/grant resources and indexes; keep old follow-up snapshots and provenance readable. Backfill historical state as legacy, with no synthetic live deadlines or automatic assignments.
3. Validate remote contract tests, then deploy with new routing/publication policies disabled. Compare dry-run decisions to known farm01 conflict cases without changing their task ownership or flags.
4. Enable bound-publication completion/backstop, then author orders, then deadline reassignment. Enable reassigned writes only after the native-custody handshake passes for the installed adapter and captain approves cutover. Retire coordinator sweep only after parity is evidenced.
5. Rollback disables new policy and revokes outstanding grants while retaining ledger/bindings; old observation and default-branch CI accountability continue. Do not drop tables or rewrite old events.

No externally unresolved product decisions are silently deferred to implementation. The 45-minute deadline and eligibility threshold are configurable policy defaults; the reviewed proposal fixes the custody and tracking semantics. Adapter implementation details must satisfy these contracts rather than weakening them.
