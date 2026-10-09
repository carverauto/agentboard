# Branch-flow overview preview

The first #185 implementation increment is a **read-only, busiest-only preview**
on `/prs`. It is off by default. It does not complete the full
[approved branch-flow design](../openspec/changes/add-pr-branch-flow/design.md).

## Presentation opt-in and rollback

An operator can opt a separately authorized deployment into the preview with
`AGENTBOARD_BRANCH_FLOW_ENABLED=true`. Unset it or set it to `false` to restore
the existing default-branch panel and PR table. This presentation flag does not
activate observation, cooperation, workflow intake, webhook delivery, routing,
or any schedule. No live flag was changed by this implementation.

The API/CLI `/api/v1/prs` contract is unchanged. The preview's reads reuse the
existing `Delivery.Reads` row projection, so CI qualification, mergeability,
repair responsibility, delivery and decision evidence remain owned by their
existing producers. No view action contacts GitHub or enqueues collection.

## What the preview delivers

- Global retained workflow failures stay above every repository/filter selection.
  Ten detailed runs fit one page; the oldest unresolved run remains visible on
  later pages. The count, owner, exact branch/head/run/attempt, UTC evidence time,
  age, deferred reason and bounded job/step/source links remain inspectable.
  No retained failures never establishes green branch health.
- At most five cards rank by tracked-open PR count, then canonical repository
  name. The counts are independent of table filters/pages. Up to three actual PR
  base/head relations appear per card in canonical PR order. Default/integration
  branch roles are not inferred from names or placement.
- The all-repository chooser searches twenty names per page. A repository with
  only retained terminal PRs remains eligible with zero open PRs; unknown
  lifecycle is separate. Disabled nonterminal states and ignored/queued workflow
  cues alone do not enroll a repository.
- Repository headings focus the filtered table. Separate exact base-ref and
  canonical PR links filter rows. The labeled search matches tracked PR numbers
  and retained base/head refs; it does not promise title search. Refs are
  case-sensitive, including slashes and Unicode.
- The four-column table keeps twenty-row paging, merged/closed choice, CI/merge,
  responsibility/repair and delivery/progress. Table, attention and chooser
  cursors are independently bound to their applicable filters. Invalid selections
  show an explicit error and clear/reset action; they never silently broaden the
  table. Links and form search preserve unrelated attention state.
- Busiest order stays fixed while the page is being used. An explicit “Apply new
  order” control prevents timer refreshes from moving keyboard focus. The native
  chooser disclosure preserves its open state. Refreshes are serialized and
  scheduled after each read completes, so no stale asynchronous read can replace
  a newer route and slow reads do not accumulate timers. Deliberate route patches
  are restorable with Back/Forward; search replaces its current history entry.

## Evidence and bounds

Reads run in a read-only repeatable-read database transaction, with a two-second
statement limit and bounded returned records. The read envelope identifies the
actual PostgreSQL snapshot, UTC read time, tracked coverage, per-section source
and selection, counts/errors and page cursors. Optional failed sections do not
remove global attention; failed reads cannot promote old evidence to current.
View-refresh time never replaces provider observation time.

Actual branch labels come only from a snapshot matching the canonical PR and
poll head/base/time/generation/ref. Missing or superseded metadata stays unknown.
There is no compare request, Git invocation, graph library or copied prototype
code. SQL is read-only; persisted mutations, audits and producer fences are
unchanged. Selected table rows reuse the authoritative `Reads` projection through a bounded
batch adapter. Polls, snapshots, latest repairs, waiting decisions and duplicate
existence are loaded in batches. Identical base/worker/delivery inputs are reused;
rich duplicate and worker projections retain their existing behavior. Default
API/list/detail reads and producer/effect-admission locks remain unchanged.

The preview additionally suppresses unproven passing/mergeable state and branch
labels when its exact PR/head/base/time/generation/ref snapshot proof is missing
or mismatched. It shows the reason, keeps retained failing state, owners and
obligations, and does not alter the original API or producer decisions.

## Still pending for #185

This increment does not implement captain pins/settings, audited configuration
CAS, provider repository-role metadata, the #114 configured-integration intake
extension or resolution-only recovery, risk-ranked card aggregates, focused
repository topology/popover, or per-row mini-trees. All are still tracked in the
[implementation plan](../openspec/changes/add-pr-branch-flow/tasks.md).

The preview explicitly labels pins/settings and integration health unavailable.
Ahead/behind numbers remain unavailable until #169 supplies qualified exact-pair
persisted counts. No invented `main`, `staging`, healthy branch or numeric count
stands in for those dependencies. No new migration is allocated by this slice.

Actual browser keyboard, screen-reader, mobile/zoom/theme and perceptual
acceptance remain pending. See [verification](verification/branch-flow-overview.md)
for exactly which executable checks ran and which did not. Landing this preview
must not close #185 or be treated as rollout authorization.
