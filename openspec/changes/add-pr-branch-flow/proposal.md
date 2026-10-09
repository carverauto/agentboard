# PR branch-flow visualization

## Why

The `/prs` default-branch health panel preserves important failure accountability,
but does not show how tracked PRs relate to their actual base branches. Captains
need a bounded cross-repository overview, a focused repository view, and a compact
relationship in every PR row without losing retained red workflow obligations.

This is the **proposal-only** deliverable for [#185](https://github.com/carverauto/agentboard/issues/185).
All three phases are reviewed together. **Implementation requires explicit
approval of this proposal; opening or merging a documentation PR is not approval.**

## What Changes

1. **Repo strip:** up to five repo cards, captain-pinned order followed by busiest
   tracked repositories, a searchable paginated overflow chooser, and branch/PR
   node filters for the existing table. A global, oldest-red-first attention area
   remains above the strip, independent of pinning and filtering.
2. **Focused topology:** default and explicitly configured integration branches,
   actual PR base-to-head relationships, accessible text equivalents, and one
   keyboard-operable PR detail popover. The graph is schematic, not commit history.
3. **Per-PR glyphs:** textual `base → branch`, independent CI/conflict labels,
   ahead/behind counts when backed by current persisted evidence, and an expandable
   mini-tree. The four-column table, repair ownership, delivery state and UTC
   progress remain intact.

Shared prerequisites are a bounded database-only projection; captain settings;
repository/ref identity and evidence provenance; and an explicit extension of
workflow intake for configured integration branches. Existing intake ignores
non-default branches, so an integration label alone cannot imply staging health.
Numeric divergence remains unavailable until the #169 producer supplies the
specified persisted count contract. The UI never calculates it or requests it
from GitHub.

## Capabilities

### New Capabilities

- `pr-branch-flow-dashboard`: the three visual phases, global failure visibility,
  navigation, accessibility and bounded presentation.
- `branch-flow-projections`: persisted-data contracts, source/currentness fences,
  workflow intake prerequisite, pagination and provider-budget boundaries.
- `branch-flow-settings`: captain-authorized pinned order and explicit integration
  role configuration with audited, revision-checked saves.

### Modified Capabilities

None. These additive capabilities preserve the existing PR CI dashboard contract
in `adopt-ash-and-monitor-pr-ci`, including independent conflict evidence and
unknown/stale states.

## Impact

Future implementation touches `PRLive`, `Delivery.Reads`, existing delivery
producers/resources, captain Settings, dashboard styles and tests. Required schema
changes are described, not allocated or implemented. Reuse #114 workflow
accountability and #169 conflict/base-watch projections; do not change repair
routing, cooperation, leases or worker execution.

No product code, dependency, schedule, runtime setting or migration is changed by
this proposal. No simulation controls, GitHub calls during rendering, new graph
library, automatic merge/rebase action, or full commit-DAG reconstruction is in
scope. Original static review mockups are linked from [design.md](design.md);
they use invented fixtures and do not reproduce the prototype's code or assets.
