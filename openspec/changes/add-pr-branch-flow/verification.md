# Verification and approval state

## Scope and source baseline

Proposal-only work for [#185](https://github.com/carverauto/agentboard/issues/185)
on 2026-10-09. Initial source inspection used freshly fetched main
`1ea2d332d7b3a7fc70970d266f0172d54c9e9dbd`; the branch was then rebased to freshly fetched main
`d85b0dce620b8fa86aef3d4e15ce3e84cfac12c2` (merged #195). The intervening
change adds only the separate #186 proposal, leaving the inspected product
source unchanged. Only this OpenSpec directory is added.
No product source, dependencies, migrations, schedules, credentials, native runs,
board records or runtime settings are changed. All implementation and approval
checkboxes remain unchecked.

Read the exact #185 issue and its empty comment thread, plus
[#114](https://github.com/carverauto/agentboard/issues/114) and
[#169](https://github.com/carverauto/agentboard/issues/169). Inspected AGENTS,
repository workflow instructions, current PRLive/Reads, workflow intake/retention,
base-watch/poll/snapshot/conflict resources, captain Settings, current dashboard
CSS and the existing PR CI dashboard specification. Source facts are enumerated
in design.md. The supplied reference-image review informed design choices;
the original image files and prototype source were not accessed in this VM.
No prototype code/assets were copied.

## Independent review and corrections

A separate read-only reviewer compared source, issue scope and proposal and
rendered all three original SVGs. The review found and the proposal corrected:

1. Removed integration/formerly-default refs need a narrowly scoped resolution-only
   success intake path for exact unresolved repo/branch/workflow keys; otherwise
   the stricter allowlist would strand retained red indefinitely.
2. Terminal PR poll records are normally disabled. Inventory now explicitly uses
   enabled records **or** retained terminal records **or** admitted workflow
   observations; ignored cues and disabled nonterminal records alone do not count.
3. Shared default-ref metadata needs a repository-scoped monotonic generation;
   per-workflow-run generations cannot fence different concurrent collectors.
4. Mockups now distinguish configured-role connectors from observed PR relations,
   show specific PR offshoots, use a search matching both illustrated table rows,
   route graph connectors around labels and label the abbreviated oldest summary.

## Documentation checks

- Structural OpenSpec-format assertions: three declared new capability directories
  match their specs; 18 normative requirements use SHALL and have WHEN/THEN
  scenarios; 74 scenarios; all 34 approval/implementation tasks remain unchecked.
- Local Markdown links checked for existing targets; all three static SVGs parse
  as XML and have accessible title/description metadata, no script/event handlers,
  no external images/fonts/resources and no copied prototype code.
- Three original SVGs rendered to temporary PNGs with the already installed
  Inkscape and visually inspected at their native 1400px width. Text and controls
  are legible; retained red stays above each view; final routing avoids label
  collisions. These are static schematic checks, not application interaction or
  screen-reader tests. PNG previews are temporary verification outputs, not new
  product assets.
- Git staged whitespace checks passed and changed-path assertions confirmed only
  `openspec/changes/add-pr-branch-flow/` is added. All local Markdown links and
  structural assertions were rerun after the fresh-base rebase.

## Unrun / unfinished requirements

- The OpenSpec CLI is not installed or present in the available toolchain.
  `openspec validate add-pr-branch-flow --strict` was **not run**. Structural
  assertions are not described as equivalent strict CLI validation.
- Archify and Lavish tooling are absent. Required tool-authored source/HTML,
  portable review exports and durable task-document uploads remain unfinished.
  The original SVGs fulfill static review illustrations; they are not presented
  as Archify or Lavish output. No review session or document upload was opened.
- Installed Chromium could not start in this execution environment because its
  process-singleton socket was prohibited; a permitted launch retry had the same
  result. No Chromium browser check is claimed. Inkscape supplied the successful
  static render/visual check without installing dependencies.
- No product code changed, so no product build or remote product test suite ran.
  No live GitHub render/compare calls, workflow intake, native seat execution,
  browser interaction, accessibility runtime, database load or migration test was
  performed. The tests in tasks.md remain future implementation acceptance.

## Approval and dependency gates

Explicit implementation approval remains unrecorded. All three phases must be
reviewed together; a proposal/documentation PR merge does not satisfy that gate.
Integration health cannot be claimed until its scoped persisted #114 extension
is tested and activated. Numeric ahead/behind acceptance remains open until the
#169 producer supplies matching, current, complete exact-pair evidence under an
agreed budget contract. Unknown/unavailable fallbacks are specified, not waived
requirements. Migration identifiers are intentionally unallocated.

## Final preparation

Final proposal preparation fetched and rebased cleanly onto
`d85b0dce620b8fa86aef3d4e15ce3e84cfac12c2`; documentation assertions, static
SVG rendering/inspection and staged whitespace/scope checks passed. No product
behavior is claimed verified. The publishing workflow must independently establish
freshness immediately before publication and track checks for the exact published
head.
