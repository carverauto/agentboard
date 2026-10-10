# Branch-flow overview preview

The #185 implementation provides a bounded `/prs` preview with **captain-managed
repository pins**. The presentation is off by default. It does not complete the full
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
- At most five cards show eligible captain pins in their saved order, followed
  by unpinned repositories ranked by tracked-open PR count and canonical name. The counts are independent of table filters/pages. Up to three actual PR
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
- Pin/busiest order stays fixed while the page is being used. An explicit “Apply new
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
code. Projection SQL is read-only; the separate explicit captain settings save
writes only display configuration and its immutable audit/receipt. Producer fences
are unchanged. Selected table rows reuse the authoritative `Reads` projection through a bounded
batch adapter. Polls, snapshots, latest repairs, waiting decisions and duplicate
existence are loaded in batches. Identical base/worker/delivery inputs are reused;
rich duplicate and worker projections retain their existing behavior. Default
API/list/detail reads and producer/effect-admission locks remain unchanged.

The preview additionally suppresses unproven passing/mergeable state and branch
labels when its exact PR/head/base/time/generation/ref snapshot proof is missing
or mismatched. It shows the reason, keeps retained failing state, owners and
obligations, and does not alter the original API or producer decisions.

## Captain repository pins

Settings → PR branch flow offers a searchable twenty-repository chooser and an
ordered list of at most five pins. Use the checkbox, Move up/down and Remove
controls to prepare a draft, then Save. Search and pagination preserve that draft.
Only a verified captain capability can save; browsing `/prs` remains read-only.
The editor holds the expected revision, actor and idempotency key server-side.
Close, Escape, Reload and navigation protect unsaved edits with a discard prompt;
there is no autosave. Reopening reads persisted truth rather than recovering an
old draft against a newer revision.

Saves serialize on a dedicated configuration lock and compare the expected
revision. Captain expiry/token rotation is checked again after taking the lock
and immediately before the write. A stale revision preserves the draft and asks
for an explicit reload. Configuration, version history, audit events and an
immutable exact-request receipt commit together. Replaying the same key and
request returns its original receipt without another write; changed content with
that key conflicts. An uncertain save must be reconciled read-only before a retry
of the same key/request. Reconciliation reports the original committed revision
separately when another editor has since saved a newer current revision.

Pins use exact canonical lowercase `owner/repository` paths from local tracked
inventory. They do not enroll repositories, affect workflow intake, change
schedules or resolve retained red. A repository that leaves inventory remains
stored and visible as unavailable in Settings. It is omitted from the next strip
ranking, with the vacancy filled from eligible repositories. Remove or replace
that unavailable pin explicitly before saving; it is never silently remapped.
There is no provider repository-ID/rename feed, so disappearance detection does
not establish that GitHub renamed a repository.

Settings and inventory are read from the same repeatable-read projection
snapshot. A settings read failure visibly degrades pin ordering, preserves
last-known cards where available and never asserts that saved pins are empty.
When only counts fail, eligible pins precede a bounded alphabetical fill labeled
as a fallback. A Settings chooser reads shared inventory directly without loading
attention, PR details or provider data.

Migration `20261008003700` adds only display configuration, immutable versions and
receipts. Logical schema 37 uses `GREATEST`, preserves higher schema markers and
performs no operational backfill. This was a proposed code allocation after a
read-only migration inventory, not an atomic live-board reservation. Presentation
rollback retains all pin settings, history, receipts and delivery evidence.

## Still pending for #185

This increment does not implement provider repository-role metadata, the #114
configured-integration intake extension or resolution-only recovery, risk-ranked
card aggregates, focused repository topology/popover, or per-row mini-trees. All
remain tracked in the [implementation plan](../openspec/changes/add-pr-branch-flow/tasks.md).

Integration health remains unavailable. Ahead/behind numbers remain unavailable
until #169 supplies qualified exact-pair persisted counts. No invented `main`,
`staging`, healthy branch or numeric count stands in for those dependencies.

Actual browser keyboard, screen-reader, mobile/zoom/theme and perceptual
acceptance remain separate from protocol/render tests. See the
[overview verification](verification/branch-flow-overview.md) and
[pins verification](verification/branch-flow-pins.md) for exact checks and limits.
Landing these increments must not close #185 or be treated as rollout authorization.
