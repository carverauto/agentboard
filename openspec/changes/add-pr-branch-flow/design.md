# Design: honest, bounded branch flow

## 1. Decision and reading order

Status: **proposed; implementation not approved**. Scope: all three phases of
[#185](https://github.com/carverauto/agentboard/issues/185) in one design.
Read this document with the normative specs, [tasks](tasks.md),
[verification](verification.md), and the original mockups below.

### Review mockups

These are original static schematics, authored for this proposal from the product
contract and supplied visual-review findings. Every repository, PR, SHA, count,
owner and timestamp in them is an invented fixture. They are not screenshots of a
running implementation, observed GitHub results, or licensed copies of the
throwaway prototype. They demonstrate layout and states, not working controls.

- [Phase 1: overview, global retained-red attention, pin chooser and overflow](mockups/01-overview.svg)
- [Phase 2: focused repository and detail popover](mockups/02-focused.svg)
- [Phase 3: existing table, glyph and expanded mini-tree](mockups/03-pr-glyph.svg)

The source visual review found a four-column `/prs` baseline; a main/integration
fork sketch; a capped-card/focused-trunk concept with PR popover; and collapsed
row glyphs. This proposal supplies missing age/provenance, pin/overflow behavior,
expanded drawers, text alternatives, dismissal and keyboard behavior. Unexplained
dotted return edges and simulation controls are excluded. The generic prototype
README/metadata supplies no additional product requirements. The proposal author
did not access the original image files; this attribution distinguishes supplied
visual findings from the original drawings authored here.

## 2. Verified current implementation

Baseline: freshly fetched main `1ea2d332d7b3a7fc70970d266f0172d54c9e9dbd`,
2026-10-09. Source paths below describe that revision, not future #169 scope.

| Source | Available now | Boundary relevant to this proposal |
| --- | --- | --- |
| `web/lib/agentboard_web/live/pr_live.ex` | Five-second database refresh; list/detail; four columns; budget, deferred age, repairs, worker delivery and progress | No repo/node filter, topology, drawer, pin chooser or integration settings |
| `web/lib/agentboard/delivery/reads.ex` | 20 PR rows plus one sentinel; id cursor; optional terminal rows; current CI/merge projection | No total-repo projection; table pages cannot define repo totals. Existing record expansion is not suitable for unbounded graph reads |
| `delivery/github.ex`, `ci_snapshot.ex` | Persisted snapshot payload has `head_ref`, `head_repo`, `base_ref`, mergeability and attempts; exact head/base SHAs | `Reads.ci_projection` does not yet expose head refs/repo. Numeric ahead/behind and PR title are not collected. No required-check policy proof is inferred from successful checks |
| `delivery/base_monitor.ex`, `base_watch.ex`, `polling.ex` | Named-base watches; expected tip, revisions and invalidation; fenced PR snapshot writes | Watches are enrolled from tracked PR bases. A default/integration branch with no such evidence need not have a current tip |
| `delivery/rebase.ex`, `rebase_follow_up.ex` | Independent conflict signal, immutable submitter routing, gated follow-up | UI consumes this source; does not implement all future deadline/reassignment behavior requested in #169 |
| `delivery/workflow_github.ex`, `workflow_monitor.ex`, `workflow_run.ex` | Canonical workflow collection; per-run retention; same-workflow/branch recovery watermark; oldest-first unresolved failures (51-row read cap) | Intake rejects non-default branch runs. A green watermark resolves obligations; it does not prove current branch health or webhook coverage |
| `web/lib/agentboard_web/live/settings_live.ex` | Existing captain capability and revision-checked settings patterns | No persisted pin order, integration-role config or complete watched-repo registry |

`Reads` currently considers observations older than 180 seconds stale and rejects
mismatched expected-base evidence. Preserve its qualification rather than deriving
new truth from colors. The collector currently returns unknown when required-check
policy is unknown, even if observed checks are successful. A fresh `mergeable`
label therefore remains independent of unknown CI.

Related contracts: [#114](https://github.com/carverauto/agentboard/issues/114),
[#169](https://github.com/carverauto/agentboard/issues/169),
[conflict accountability](../../../docs/architecture/pr-conflict-accountability.md),
and [PR CI dashboard](../adopt-ash-and-monitor-pr-ci/specs/pr-ci-dashboard/spec.md).
Issue #169's requested future behavior is not evidence that it is implemented.

## 3. Invariants across every phase

1. **Retained red is a durable obligation.** An unresolved workflow remains red
   even when its collection is old or deferred; add a stale/deferred qualifier,
   never silently downgrade it to a reassuring gray or green. A later success
   only clears obligations under the existing same-repo/branch/workflow ordering.
2. **Unknown is never green.** No feed, disabled observation, missing policy,
   unknown branch tip, old SHA, incomplete collection, expired evidence, missing
   counts and no matching PRs are distinct explanations, not successes.
3. **One truth source.** Shared persisted projections qualify table, strip,
   topology and drawer. Conflict/behind state comes from #169's existing
   producer family. Workflow state comes from #114's producer family.
4. **No provider I/O on view interaction.** Mount, refresh, filter, search, expand,
   hover, focus, popover, pagination, Back/Forward and Settings reads query only
   local retained state. No fetch or poll is scheduled by these interactions.
5. **Selection cannot hide branch incidents.** The global attention region is
   present in overview and focused views, regardless of table filters, terminal
   toggle, chosen pins, repo overflow, topology collapse or graph text mode.
6. **Read-only work views.** No repair, order, merge, rebase, simulation, agent
   message, lease change or workflow rerun is triggered by exploration. Only the
   explicit captain Settings save mutates proposed display/intake configuration.

## 4. Phase 1: overview and repo selection

Page order: title → GitHub budget/degraded read notice → **Branch attention** →
repo strip → optional focused topology → labeled table controls → four-column
PR table → independent pagination. Keep the budget cooldown and collection-age
language from the current page.

### Branch attention

Always render a heading, observation enabled/disabled state and this qualification:
“Retained workflow obligations. A webhook feed is required; absence of failures
does not verify green.” Put the oldest unresolved failure first across all repos
and branches, not the currently selected repo. Show 10 rows by default using a
new bounded read, total outstanding count, earliest red age, and a next-page link.
When more exist, say “Showing 10 of N retained red runs; more failures remain.”
A separate persistent first-failure summary stays visible on later attention pages.
If a total read fails, use “at least N” and “count unavailable,” never zero.

Every visible run retains repo, branch, workflow, conclusion, exact head SHA,
run/attempt, red-since UTC and age, observed-at UTC/age, routed owner or missing
coordinator/captain-queue explanation, source tasks, last collection error and
available bounded failed-job/step source links. Multiple runs of one workflow
remain inspectable. A repo omitted from the strip has an “outside strip” label and
an ordinary link to focus that repo. A filter may add context, never remove the
unfiltered failure summary or silently mark obligations resolved. Resolved-run
history remains available through evidence links, not erased by the visualization.

### Watched universe and ranking

“Watched repos” means the **locally tracked delivery inventory**, not every
repository on GitHub: canonical repositories with enabled tracked PR poll states **or** retained terminal
PR states (`merged`/`closed`, normally disabled) **or** admitted retained workflow
observations. Disabled nonterminal states alone and queued/ignored workflow cues
without admitted branch evidence do not establish eligibility. Enabled records
with unknown lifecycle remain eligible but contribute only to the separate
unknown-lifecycle count. Configured roles must refer to that inventory. Unresolved workflow obligations remain in the
attention region even if a repository later leaves active inventory. If a broader
watch registry lands later, integrate it explicitly; do not silently expand this
proposal to org-wide discovery.

Desktop cap is **five** cards. At narrower widths the same bounded five cards
reflow/scroll in a labeled region, with a visible overflow affordance; responsive
layout must not mount every repo. Pinned eligible repos appear in captain order
(maximum five). Fill remaining slots by exact count of locally tracked **open**
PRs descending, then canonical `owner/repo` ascending. Unknown lifecycle does not
count as open; show an unknown-lifecycle count separately. Busiest counts are
computed over the inventory, independent of table page/filter and terminal toggle.
Do not imply coverage of untracked GitHub PRs. Label all counts “tracked.”

The separate “All repositories” control clears repo/node selection. A `+N more`
chip counts distinct eligible repos outside the five displayed cards, not PRs. It
opens a labeled repo chooser (20 rows/page) with search, canonical repo names,
tracked-open counts and red/unknown labels. Choosing an overflow repo enters its
focused view without changing pin order or silently displacing a pin. Its selected
repo heading remains visible even when it has no strip card. Zero repos gets a
truthful empty state with no invented main/staging branches.

Refresh may update labels and rank the next strip snapshot but cannot move/remove
the element holding focus. While focus or an open chooser is inside the strip,
retain its ordering and expose “Repository order updated” with an explicit apply
control. On leaving the region, apply the new ranking without stealing focus.

### Card and node actions

Each card contains a distinct “Open topology for owner/repo” link and separate
node links; never nest interactive controls. Clicking a branch node filters the
PR table to that exact base ref within that repo. Clicking a PR offshoot filters
to that canonical PR id. Clicking the card heading focuses the repo and filters
its table; it does not pretend that all feature branches pass through staging.
Show selected filter chips with individually named clear buttons and the matching
tracked row count. Clicking an already selected node is idempotent; clearing is
explicit, not a surprising second-click toggle.

Mini-tree limit: two trunk roles (default + optional integration) and three PR
offshoots per card. Offshoots prioritize current conflicts, CI failures, unknown/
stale, then other open PRs; ties use canonical PR id. Additional offshoots become
“+N tracked PRs” linking to the filtered table. A red or conflicting item outside
these nodes is still represented by card-level aggregate counts. Text states and
shapes accompany color. A branch without qualifying evidence reads “health
unknown,” not “healthy.”

## 5. Phase 2: focused repository topology

One repository is focused at a time. Its heading, “Back to all repositories,”
tracked coverage count and snapshot age precede a horizontally laid-out schematic.
Default and configured integration trunks have explicit role labels. An integration
role is **configured**, not inferred from the name `staging`, a PR title, line
position or branch color. Default branch name is validated provider metadata;
`main` is not hardcoded. No integration configured means a default trunk plus
actual PR bases. Missing default metadata means “Default branch unknown.”

Edges express **observed PR target relationships**: base → PR head. A PR targeting
main branches directly from main. A PR targeting staging branches from staging.
A PR targeting another feature branch shows that exact target (including a stacked
PR when the identities match); it is not rewired through staging. The default-to-
integration relationship is labeled “configured role,” not proven ancestry or a
merge/promotion path. Cycles or missing/deleted branch identities render as listed
relations with an explanation rather than a fabricated ancestry DAG. No return
edge implies a completed or scheduled merge. Dots identify observed ref endpoints,
not invented intervening commits; show a shortened SHA with accessible full SHA.

Read 20 PR relations/page in stable canonical-id order, with explicit next/previous
controls and “showing X–Y of N tracked open PRs.” Each relation has at most its
head and base reference endpoints; draw at most 42 branch/PR endpoints (two role
trunks plus two per relation) and 40 relationship/role connectors on a topology
page. Reuse identical ref nodes where exact identities match. An off-page parent
uses a labeled continuation endpoint and link; never load its ancestry recursively.
The text relationship list uses the same page/ordering and data. Unknown topology
is a useful result, not an invitation to run Git commands.

### Detail popover

Selecting a PR node opens one anchored non-modal detail panel with a named close
button and `role=dialog` / labeled heading, without requiring hover. It contains:
PR number and provider link; title only if collected by the approved same-request
metadata extension (otherwise “Title not retained”); head repo/ref/SHA; base repo/
ref/SHA and expected tip; current CI, merge and numeric-count qualification;
observed-at UTC and elapsed age; defer/error reason; failure source links;
immutable submitter/source task; CI responsible/repair; rebase responsible/repair;
and current delivery/progress link. Do not collapse these distinct identities to
an ambiguous “agent.” A retained repair can be open after conflict clears; preserve
“Conflict signal resolved; repair completion is explicit.”

Open moves keyboard focus to the panel heading/first useful control; Tab follows
the document order (no modal focus trap); Escape or Close dismisses it and returns
focus to the invoking PR node if still present, otherwise the focused-repo heading.
Pointer outside dismissal also restores context without hijacking the clicked
control. Clicking another PR replaces the panel and invalidates the prior request.
Repo switch, table/topology paging, filter changes or route changes close it.
Background refresh may update its currentness label but cannot reopen a dismissed
panel or change its selected PR. Deleted/off-page nodes close with a polite
announcement. Navigating to a full PR detail remains an ordinary link, not a
second hidden panel.

## 6. Phase 3: row glyph and expanded mini-tree

Keep the existing four columns: **Pull request / head**, **CI / mergeability**,
**Responsible / repair**, **Delivery / progress**. Place a compact glyph in the
first cell: textual `actual-base → actual-head`, including fork owner/repo when
needed, `ahead N / behind M`, and independent text/glyph status markers. The CI
and conflict columns remain authoritative and readable if glyphs are hidden.
Unavailable counts say “Ahead/behind unavailable”; stale numbers are “Last known
+N / −M; stale” with source pair/time, never presented as current. `mergeable_state
= behind` alone yields “Behind base; count unavailable,” not an invented integer.

A named disclosure button with `aria-expanded`/`aria-controls` opens a subordinate
full-width table row using one cell with `colspan=4`. Allow one drawer at a time,
keyed to canonical PR id, with at most four distinct endpoints: known default,
configured integration, actual base and actual head (deduplicated). It contains
that PR's observed base → head relationship, optional role context clearly labeled,
full text equivalent, CI/conflict/count provenance and relevant evidence links.
Do not traverse its full parent history or claim the refs are an ancestor chain.

Same-row click toggles; opening another row closes the previous. Escape or explicit
Close returns focus to the disclosure button; closing via the button keeps focus
there. A PR that leaves the current table page closes its drawer, announces why,
and restores focus to the nearest stable table heading/pagination control.
Background refresh preserves the open PR by id and immediately de-qualifies old
head/base data. Hiding glyphs closes drawers and restores focus. At small widths,
text alternatives stay visible and table scrolling remains labeled/keyboard
reachable. No existing ownership, decision-wait, poll age or UTC progress field
may disappear merely to make room for the glyph.

## 7. Shared URL, paging and race contract

Proposed route state on `/prs`: `repo` (canonical owner/repo), `node_kind`
(`base` or `pr`), `node` (exact ref or canonical id), `view` (`overview` or `repo`),
`show_terminal`, `cursor`, `topology_cursor`, `attention_cursor`, and optional
`q` (table ref/PR-number search, maximum 120 characters). Repo chooser search is
separate ephemeral state and searches repo names only. Table search is visibly
labeled “Search tracked PR number or branch”; title search is not promised.

Node validation requires a selected repo. Unknown repo/id, mismatched PR ownership,
overlong refs/cursors and malformed search input return a clear invalid-filter
state; never broaden a rejected filter to all repos. Strings are escaped and
branch refs remain case-sensitive; URL-encode names with slashes. Canonical repo
identity is normalized using the existing inventory rules. Do not identify refs
by a short label alone; forks may share names.

Use `push_patch`/equivalent with one canonical route per deliberate navigation;
refresh never adds history. Search debounces and replaces its current history
entry, while committed repo/node/terminal/page changes push a restorable entry.
Repo/node/search/terminal changes reset table cursor; repo/node changes also reset
topology cursor. Attention paging is independent and does not change table filters.
Previous/Next controls retain every applicable filter and a filter-bound opaque
cursor (existing unscoped id cursor is extended). Invalid/expired cursor shows a
reset-page action; it cannot accidentally page a different filter. Browser Back/
Forward reconstructs the exact filter and page, closes transient panels/drawers,
and does not resurrect dismissed content. Going back from full `/prs/:id` detail
restores its source filtered URL. Ephemeral topology/glyph visibility preferences
are local session choices; they never alter monitoring or persist captain settings.

Every asynchronous projection load captures a monotonically increasing view
request generation plus normalized route/filter fingerprint. A result applies
only if both still match; closing a popover/drawer increments its own generation.
Treat topology, table, attention and settings requests as distinct identities.
Head changes invalidate a popover response even when PR id remains the same.
Refresh coalesces while one read is running; no queue of five-second refreshes.
Late responses after Close, Escape, repo switch, page/filter/search change, Back/
Forward, disconnection or newer selection cannot restore obsolete UI. Failed
reads keep last-known data clearly degraded and never qualify it as fresh/green.

## 8. Persisted projection and producer contracts

All names below are **proposed interfaces**, not existing fields/APIs. Implement
through audited Ash actions where state is persisted; bounded read queries may
join resources but may not add raw SQL mutation paths. Choose migration identifiers
at implementation time after inspecting current main. No migration number is
reserved by this proposal.

### A. Shared read envelope

A `BranchFlow` read service extends/reuses `Delivery.Reads` instead of a second CI
engine. Each bounded response includes `as_of` UTC, `projection_revision`,
`settings_revision`, `coverage=tracked_inventory`, local read/degradation errors,
per-section page metadata, and a normalized selection fingerprint. Snapshot
consistency covers counts, rows and source revisions read in the same database
transaction; age is evaluated against server time. Refresh timestamps are not
observation timestamps. Batch preload the selected rows' existing projections,
not N provider or deep detail requests per graph node.

Repo summary: canonical repo id; tracked-open and unknown-lifecycle totals; retained
red count/oldest red time; conflict/failure/unknown aggregates; configured roles;
pin position; bounded nodes; `has_more` and source/currentness metadata. A count
query is an indexed database aggregate, not a fetch of every PR into application
memory. If exact totals exceed a database statement budget, return explicit
partial/unavailable totals with a retry affordance; never silently sort a partial
count as busiest. Use deterministic alphabetical fallback with “ranking unavailable.”

PR relation: canonical PR id/url/number; base repo+ref+SHA; head repo+ref+SHA;
`expected_base_sha`; snapshot id/generation/observed_at; existing qualified
`ci_state`, `merge_state`, `mergeable_state`, `fresh`; independent divergence
object; defer/error; source task/submitter and repair links. Expose head fields
from the matched persisted snapshot, never a latest payload whose head/base does
not match the poll state. Missing/title-sanitized data stays absent. Retain the
current provider metadata collector's sanitization and bounded labels/URLs.

### B. Repository role metadata

Add an audited repository display/intake configuration keyed by canonical repo:
nullable `integration_ref`, `revision`, updated-at and actor; board-level settings
hold unique ordered `pinned_repositories` (maximum five). These are separate from
provider-derived metadata. Persist observed `default_ref`, canonical repository
identity, metadata observed-at and source generation from existing validated
repository responses in the workflow producer; preserve both before/after metadata
checks. Allocate a repository-scoped monotonically increasing observation generation
before metadata collection, and conditionally commit only the still-current
repository generation. Per-run generations cannot fence two different collectors
writing shared repository metadata. A slower old-default collection must not
overwrite a newer accepted default from another run; invalidation conservatively
leaves metadata unknown/stale until a current collection commits. If a future existing producer also collects that metadata, it writes the
same source contract. A user-entered ref never establishes that it exists or is
healthy. No extra render-time or periodic repo metadata request is introduced.

### C. Integration workflow intake prerequisite

Before showing an integration run as health evidence, extend #114's existing
background intake to accept **only** the provider's verified default ref or the
captain-configured integration ref for that exact repository, plus the narrow
resolution-only exception below. Do not allow all branches. Record the config
revision/accepted role and validated repository/ref
identity with the run observation. The worker captures configuration at reservation
and rechecks it at commit together with existing run generation, lease, repository
and before/after provider fences. A changed integration role cannot admit a late
run as evidence for the new role. Previously ignored queued runs are not replayed
implicitly; only a new authorized normal intake cue may requeue them.

Keep repository/run dedupe, attempt ordering, immutable attribution and same
repository/**branch**/workflow green watermarks. A staging success never resolves
main's red run; main success never resolves staging's. A configuration edit does
not delete or resolve any retained run. Historical red on a removed integration
ref or formerly-default ref remains globally visible as “previously watched branch.” To avoid stranding
that obligation, an existing normal intake cue may admit a **success only** for an
exact retained unresolved `(repository, branch, workflow_id)` key even when the ref
is no longer a current role (including a renamed default). Recheck that unresolved key under the existing
workflow-health serialization lock at commit and persist `resolution_only`
provenance. A success must advance that key's ordered watermark; an exact replay
is a no-op. This exception can advance only that key's recovery watermark and
resolve its ordered older runs; it cannot establish current role health, admit
new failures, notify/reroute work or enroll a branch. Once the key has no unresolved
obligation, other noncurrent-role cues are ignored. No new polling schedule is
created; without a subsequent success cue, the obligation remains honestly red.
Notification labels
must identify the actual branch; existing cooperation gates and owner/coordinator
routing remain unchanged. Intake consumes the existing validated cue, collection,
shared admission/cooldown and bounded request paths, not a new dashboard poller or
schedule. No webhook provisioning, cooperation enablement or runtime rollout is
part of this documentation change.

Branch summary health is red when any retained obligation for that branch exists.
Otherwise display “No retained red; current health unknown.” A latest successful
run may be shown as a historical success with workflow, head and observed-at, but
not a green whole-branch label. A future whole-branch passing state requires
persisted complete workflow policy/coverage plus current-tip verification; that
verification is outside this proposal. This avoids adding a fictitious green
state merely to match a colored concept sketch.

### D. Ahead/behind from #169, not a second calculation

Current #169-related producers expose qualitative `behind`, mergeability, head/
base and expected-tip state, not numeric divergence. Define the consumer contract
with that producer's owner **before implementation approval is exercised**:

- keyed by canonical PR, head repo/ref/SHA, base repo/ref/SHA and expected base tip;
- nullable nonnegative `ahead_count` and `behind_count`, measured as commits unique
  to head and base respectively, not changed files or check counts;
- `observed_at`, source snapshot/generation, source kind/evidence link and
  `complete` flag; count omission reason when unavailable;
- qualifies as current only for the exact current head, named base, expected tip
  and producer generation, within the existing freshness window and with complete
  collection; a force push, base advance or retarget invalidates it immediately.

The #185 UI and projection never shell out to Git, infer counts from a drawing,
query a compare API, or calculate from `mergeable_state`. If #169 does not supply
this contract yet, display “Ahead/behind unavailable” in all phases and keep the
numeric-count acceptance task open. Any producer enrichment requiring new provider
requests needs its own explicit budget/admission agreement under #169; no silent
increase to request caps or cadence is authorized by this UI proposal. All three
visual phases may be implemented after approval with truthful unavailable states;
full numeric-count delivery remains a named dependency, not a feature falsely
marked done. Repo-card default/integration divergence is likewise unavailable
unless that exact ref pair has producer evidence; summing PR counts is forbidden.

### E. Evidence and limits

Freshness is field-specific. Retained red remains an unresolved obligation;
current CI/conflict/count qualification uses the existing current-head/base rules.
A fresh database snapshot can contain stale provider observations. Never make a
stale green dot bright again because the five-second view refresh succeeded.
Preserve policy-unknown, provider-null/computing, no feed, observation disabled,
budget cooldown, overdue progress and collection errors as distinct explanations.

| Surface | Bound |
| --- | --- |
| Repo strip | 5 cards; 2 role trunks + 3 PR offshoots/card |
| Repo chooser / Settings search | 20 repos/page; pin list maximum 5 |
| Global retained-red attention | 10 runs/page + persistent oldest summary; max 10 failed jobs × 10 failed step labels/run, preserving existing collector bounds |
| PR table | 20 rows/page + 1 query sentinel |
| Focused topology | 20 relations/page; at most 42 endpoints and 40 connectors |
| PR detail panel | 1 open; at most 10 failed attempts in summary with “more” detail link |
| Row mini-tree | 1 open; at most 4 distinct endpoints |
| Inputs | ref ≤255 bytes; search ≤120 characters; route cursor ≤200 bytes; canonical repo/PR identity validation |

Database read timeout/row-cost budgets must be measured on 1,000 repos and 10,000
tracked PR fixtures, with query plans/indexes verified during implementation.
DOM/payload cardinality stays bounded independent of that fixture size. Never
preload all observations, commit lists, job logs or worker histories for cards.
Counts/lists explicitly describe tracked coverage, truncation and failures.

## 9. Captain settings and concurrency

Add “PR branch flow” to existing Settings. Anyone allowed to read `/prs` may use
local filters; only an authorized captain capability may save global pins or
integration roles. No authentication redesign or client-supplied authority.

The chooser searches the tracked repo inventory with 20-row pages. It exposes
checkbox pin state, a selected-order list with labeled Move up/down buttons,
a maximum-five explanation, and one optional integration-ref field per selected
repository editor. Integration roles may also be configured on an unpinned repo
through search; pinning is not required for health intake. Default branch is
read-only provider metadata. Same-as-default integration config is rejected if
the verified default is known; if it later becomes default, show one default
node and a configuration warning without deleting evidence.

Save is explicit and atomic with expected settings/config revisions and an audit
actor. Validate unique canonical eligible repos, maximum pins, bounded/case-sensitive
refs and unchanged current captain authority at the write boundary. Stale revision
returns a conflict with the user's unsaved draft preserved; Reload is explicit.
Repeated save of the same intended revision is idempotently recognized or returns
current state; never creates duplicate pins. Expired authorization leaves no write.
Closing/cancelling/back navigation discards the local draft only, with a dirty-draft
confirmation where needed. No hidden autosave. Newer edits/navigation cannot be
overwritten by a late load/save response. A save accepted after navigation remains
an actual persisted change but must not reopen the dismissed editor; reread on the
next deliberate visit. Disable duplicate in-flight Save; reconcile uncertain
outcomes from persisted revision before retrying.

Removing/renaming a watched repo does not substitute another repository in its
pin slot silently. Show an unavailable pin warning in Settings, omit it from
eligible strip cards, and fill the vacancy using ranking; preserve the stale pin
until captain repair. Pin changes alter display only; integration changes affect
only the explicit scoped intake and resolution-only recovery described above and must say so beside Save.
Neither action enrolls a new GitHub repository, changes schedules or acknowledges
red workflow obligations.

## 10. Accessibility and visual system

Use existing Tailwind v4 CSS-first assets and light/dark theme tokens. Prefer
semantic HTML links/buttons with simple SVG decoration and text relationships;
no graph framework or canvas dependency. Every node exposes role/repo/ref and
state plus age in an accessible name; the same facts appear as visible text.
Use distinct symbols/shapes with labeled legend: failure, pending, unknown, stale,
merge conflict and qualified mergeable. CI and conflict are separate signals.

SVG is decorative (`aria-hidden`) when an equivalent visible HTML relationship
list exists; otherwise supply an accessible title/description and text fallback.
Do not duplicate interactive focus stops in graphic and equivalent list. Native
Tab/Shift+Tab, Enter/Space, visible focus and explicit Close/Escape work without
pointer hover. Menus/dialogs announce purpose/state; controls meet 44px touch-target
intent without requiring a large graph. Polite live announcements report meaningful
selection/state changes only, not every polling tick. Use real headings/table
headers, labeled search and scroll regions, `aria-expanded`, `aria-controls` and
selected-state indicators. Verify contrast, 200% zoom, reduced motion, long names,
320px viewport, no animation requirement and a graph-hidden textual mode.

## 11. Delivery, approval and rollback

One proposal contains shared prerequisites and all three phases. After explicit
approval, implement data/settings first, then strip, focused topology and glyphs
in reviewable increments while retaining the whole contract. Each stage has
remote product tests and browser interaction checks; landing a partial stage does
not close #185. Numeric counts remain gated on #169 evidence. Integration health
remains unknown until the scoped #114 extension is tested and operationally ready.

Use an off-by-default presentation rollout flag during implementation, without
changing the observation/cooperation flags. Both old and new presentations consume
the same retained obligations. Rollback switches presentation back to the existing
health panel/table; it does not drop settings/evidence, resolve obligations, change
worker ownership or disable intake. Integration-intake activation and rollback
are separate explicit operational choices; retained red evidence survives either.

Rejected alternatives: hiding red repositories behind “busiest”; all-repo graph
rendering; hardcoded main→staging→feature ancestry; generating green from no red;
per-node GitHub compare calls; copying an unlicensed prototype; new routing code;
and a one-phase proposal that defers the remaining design. None satisfies #185.
