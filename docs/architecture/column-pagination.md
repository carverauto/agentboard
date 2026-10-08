# Kanban column pages

The column heading is the total number of matching tasks, not the number of
cards on the current page. Each lane loads at most 20 cards and has its own
Prev/Next buttons immediately below the heading. Paging Done leaves the other
lanes visible and at their selected pages. Archive uses the same page controls
for archived Done tasks.

Repository, owner and label predicates apply to both counts and pages. Changing
filters resets all lane histories. Push notifications and the periodic fallback
refresh retain the selected cursors; a failed read retains the last cards and
cursor history and shows the existing unavailable notice. Reloading the page
starts from page one. Paging state belongs to the connected LiveView, not the URL.

Counts use Ash over the same filtered task query as the keyset page. Counts and
cards are current-state reads, not a frozen snapshot: concurrent edits may move
cards between pages. The API's opaque cursor ordering and watch contracts are
unchanged. Counts exclude archived tasks on the board and include only archived
Done tasks on Archive. No database migration, shared cursor process or cache is
needed. Database reads retain the existing bounded read timeout.

Buttons have stable IDs, clear accessible names, disabled boundaries and a live
page summary. The original Kanban geometry, Tailwind v4 theme tokens and compact
expandable Done cards are retained. On narrow screens only the existing lane
container scrolls horizontally.

[Explore the architecture](column-pagination.html). The JSON source and browser
receipt are retained beside the standalone HTML. See the
[verification receipt](../verification/column-pagination.md) for proof and limits.
