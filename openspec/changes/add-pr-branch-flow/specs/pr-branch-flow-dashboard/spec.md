## ADDED Requirements

### Requirement: Retained workflow failures remain globally prominent
The dashboard SHALL retain a global oldest-red-first Branch attention region above repository selection in every overview and focused view. It SHALL preserve unresolved workflow evidence and routed accountability independently of pins, table filters, pagination and graph visibility. It SHALL show observation/feed limitations, absolute UTC timestamps, elapsed ages, collection errors, total-or-explicitly-partial counts and bounded access to every retained failure.

#### Scenario: Oldest red repository is outside the strip
- **WHEN** the oldest unresolved workflow failure belongs to a repository outside the five displayed cards and another repository is selected
- **THEN** the global oldest failure, its repo/branch/workflow, red-since time, routed owner and source link remain prominently visible with a link to focus that repository

#### Scenario: More failures than the attention page limit
- **WHEN** more than ten retained failures exist
- **THEN** only ten detailed runs are rendered on a page, the total or explicit lower bound and next-page control are shown, and the oldest global failure summary remains visible on later pages

#### Scenario: No feed or old failure evidence
- **WHEN** no qualifying feed exists or a retained unresolved red run has stale/deferred collection
- **THEN** absence of other failures is not green and the retained run stays red with its stale/deferred qualification and last observation age

#### Scenario: Branch selection does not acknowledge an obligation
- **WHEN** a user filters, unpins a repository, hides graphs, changes pages or exits a focused view
- **THEN** no workflow obligation is resolved, hidden from global attention, or treated as handled

### Requirement: Bounded pinned-and-busiest repository overview
The overview SHALL render at most five repository cards with eligible captain pins in persisted order followed by busiest tracked repositories, using tracked-open PR counts over the full local inventory and canonical repository name as the tie-breaker. It SHALL expose all remaining repositories through a searchable twenty-row paginated overflow chooser and explicitly label tracked/incomplete coverage. No card or view SHALL imply every GitHub PR is tracked.

#### Scenario: Pins and busiest fill coexist
- **WHEN** two eligible repositories are pinned and more repositories are tracked
- **THEN** the first two cards follow pin order and up to three unpinned repositories fill by tracked-open count descending and canonical name ascending

#### Scenario: Table page differs from repository inventory
- **WHEN** a user pages or filters the twenty-row PR table or shows terminal PRs
- **THEN** repo totals and busiest ranking remain based on the independent tracked-open inventory rather than the visible table page

#### Scenario: Overflow repository selected
- **WHEN** a user chooses a repository from the +N-more chooser
- **THEN** that repo's focused heading and filtered table open without modifying pins and the overflow count represents distinct repos outside the displayed strip

#### Scenario: Retained terminal PRs remain in repository inventory
- **WHEN** a repository has only merged/closed retained poll states, which the producer normally disables
- **THEN** it remains eligible with zero tracked-open PRs; disabled nonterminal states alone and ignored/queued workflow cues do not establish eligibility

#### Scenario: Inventory empty or count read incomplete
- **WHEN** no repositories are tracked or aggregate counts cannot be read completely
- **THEN** the view respectively shows an honest empty state or explicitly unavailable ranking with deterministic alphabetical fallback, never invented branches or zero counts

#### Scenario: Refresh changes busiest order during keyboard use
- **WHEN** a newer snapshot changes ranking while keyboard focus or an open chooser is inside the strip
- **THEN** the focused element stays in place and updated ordering is offered explicitly or applied after focus leaves without stealing focus

### Requirement: Node selection filters the existing table
The strip SHALL provide separate accessible repository-focus links and branch/PR node filter links. Branch nodes SHALL filter by the selected repository and exact observed base ref; PR nodes SHALL filter by canonical PR identity. Selected filters SHALL be visible, clearable, validated and represented in the URL. Invalid selections SHALL not broaden silently to all repositories.

#### Scenario: Direct default-base PR is selected
- **WHEN** a user selects the default-branch node
- **THEN** the table includes matching tracked PRs targeting that exact branch, rather than assuming all PRs target the configured integration branch

#### Scenario: Repeated selection and clearing
- **WHEN** a user clicks an already selected node twice and then clears its filter
- **THEN** repeated selection is idempotent and the explicit clear action removes that filter while retaining other applicable route state

#### Scenario: Fork branch identity collides
- **WHEN** two PR heads have the same ref name in different head repositories
- **THEN** their canonical PR identities and displayed fork context remain distinct and selecting one never selects the other

### Requirement: Focused topology expresses observed relationships
The focused view SHALL show exactly one selected repository, configured trunk roles and actual persisted PR base-to-head relationships. It SHALL identify configured roles separately from observed ancestry, omit invented commits/merge paths, and page at twenty PR relations with at most forty-two endpoints and forty connectors. Equivalent text relationships SHALL use the same data and pagination.

#### Scenario: Multiple actual bases and no integration configuration
- **WHEN** PRs target the default branch, a feature branch and an unknown branch and no integration role is configured
- **THEN** each known relationship retains its actual base and the view neither invents staging nor routes every PR through the default branch

#### Scenario: Configured integration is not ancestry evidence
- **WHEN** a default and integration role are displayed without verified ancestry
- **THEN** their visual connection is explicitly labeled configured role and cannot imply completed promotion, merge or a commit DAG

#### Scenario: Topology exceeds one page
- **WHEN** more than twenty tracked PR relations exist or a selected relation's parent is off-page
- **THEN** explicit paging and labeled continuation endpoints appear without recursively fetching/rendering all ancestors

#### Scenario: Branch missing or malformed relationship
- **WHEN** branch metadata is absent, a branch is deleted, or inferred relation layout would cycle
- **THEN** the view retains a truthful text relation/unknown explanation without synthesizing ancestry or health

### Requirement: PR detail popover retains provenance and accountability
One keyboard-operable non-modal PR detail panel SHALL present head/base identity, independently qualified CI/merge/divergence, observation time/age, defer/error reason, provider evidence, immutable submitter and distinct repair responsibility. It SHALL support explicit Close and Escape, meaningful focus restoration and ordinary full-detail links. Historical repairs SHALL not imply a current conflict or completed work.

#### Scenario: Inspect stale conflicting PR
- **WHEN** the selected PR has retained conflict evidence but a newer expected base or old observation
- **THEN** the panel shows stale qualification, the exact observed pair, expected tip, last observation age and retained rebase follow-up without claiming current verified conflict/cleanliness

#### Scenario: Signal resolved but repair still open
- **WHEN** the producer marks the conflict signal resolved while the repair task remains open
- **THEN** the panel identifies both facts independently and does not complete the task

#### Scenario: Dismiss while detail response is pending
- **WHEN** the user presses Escape or Close before a panel read completes
- **THEN** the late response cannot reopen the panel and focus returns to the invoking node or stable repository heading

#### Scenario: Switch repository or PR rapidly
- **WHEN** the user selects PR A, then PR B or another repository before A's response returns
- **THEN** A's result cannot replace B's panel or reopen a panel in the newly selected repository

#### Scenario: No retained title or owner
- **WHEN** PR title or immutable submitter metadata is unavailable
- **THEN** the panel labels the missing field explicitly rather than inferring it from mutable task ownership or prototype fixtures

### Requirement: Per-PR glyph and bounded expandable mini-tree
Each table row SHALL retain the existing four-column semantics and show an optional compact actual-base-to-head glyph, independent CI/conflict labels and qualified numeric divergence or explicit unavailability. A disclosure SHALL expand one subordinate four-column-spanning row with at most four deduplicated endpoints and text/evidence equivalents. It SHALL not suppress existing ownership, delivery, decisions, deferred age or progress fields.

#### Scenario: Counts unavailable but provider says behind
- **WHEN** only qualitative mergeable_state behind is persisted
- **THEN** the row says Behind base; count unavailable and does not synthesize a numeric count

#### Scenario: Expand and close with keyboard
- **WHEN** a user activates the disclosure, then presses Escape or its Close control
- **THEN** aria-expanded and aria-controls identify the drawer and closing restores focus to that row's disclosure

#### Scenario: Page or refresh removes expanded PR
- **WHEN** paging, filtering or a refreshed lifecycle removes the expanded canonical PR from the table
- **THEN** the drawer closes with a polite announcement and focus moves to an appropriate stable table/pagination control

#### Scenario: Head changes while drawer stays open
- **WHEN** a new head/base pair arrives for the same expanded PR
- **THEN** the drawer remains associated with that PR but old evidence is immediately de-qualified and no old count remains labeled current

### Requirement: Race-safe navigation and paginated state
The dashboard SHALL preserve canonical repo/node/search/terminal filters across pagination and restore them with browser Back/Forward. Deliberate route changes SHALL invalidate obsolete read generations and transient panels. Refreshes SHALL not create history entries, reset the user's page or apply results for a previous selection. Invalid/expired filter-bound cursors SHALL require an explicit page reset rather than cross-filter paging.

#### Scenario: Old refresh after filter change
- **WHEN** a five-second refresh started for repo A completes after selection changed to repo B
- **THEN** generation and route-fingerprint checks discard it and B's filters/table remain intact

#### Scenario: Paging and terminal toggle
- **WHEN** a filtered user chooses Next, Previous, or Show merged/closed
- **THEN** paging retains all relevant filters and the terminal change resets only the affected table cursor while global attention remains unchanged

#### Scenario: Back and Forward after dismissal
- **WHEN** a user closes a panel, navigates to another selection, and uses Back/Forward
- **THEN** URL filters/pages are reconstructed without resurrecting the dismissed panel/drawer or allowing its late response to steal focus

#### Scenario: Old search response arrives last
- **WHEN** a debounced search or topology page request is superseded by a newer query/page
- **THEN** only the newest matching request generation may update that section

#### Scenario: Projection read fails or connection resumes
- **WHEN** a read fails or a disconnected LiveView reconnects
- **THEN** retained results are explicitly last-known/degraded until reread against the restored route and never promoted to fresh/green by reconnection alone

### Requirement: Color-independent accessible bounded presentation
All states and relationships SHALL be understandable through visible text and labeled symbols independent of color. Controls SHALL be keyboard reachable with visible focus, labeled inputs, selected/disclosure state and text alternatives. Graph visibility changes, mobile reflow and reduced-motion preferences SHALL not hide global failures or authoritative row information. Rendering SHALL stay within the documented surface limits.

#### Scenario: Keyboard-only and screen-reader traversal
- **WHEN** a user navigates the strip, chooser, topology, popover and drawer without a pointer
- **THEN** purpose, selection, relationships, state and age are announced without duplicate graphic/text focus stops or hover-only details

#### Scenario: Narrow screen, zoom or graph-hidden mode
- **WHEN** the viewport is 320px wide, zoom is 200%, or the user hides graphs
- **THEN** textual relationships and all important failure/ownership fields remain available with labeled scrolling and no unbounded node mounting

#### Scenario: Large fixture and live updates
- **WHEN** the retained inventory contains 1,000 repos and 10,000 PRs and refreshes occur
- **THEN** card, topology, drawer and table DOM counts stay capped and live announcements report meaningful changes rather than every timer tick
