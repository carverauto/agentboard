# Proposal verification and readiness

## Artifact status

Proposal-only work on 2026-10-09, based on freshly fetched main
`1ea2d332d7b3a7fc70970d266f0172d54c9e9dbd` (PR #194).
The change adds only this OpenSpec proposal directory. No application, CLI,
build configuration, migration, credential, schedule, deployment or board
record is changed. No implementation, activation or retirement task is marked
complete. Historical quota parking on #186 is not an implementation decision;
current task assignment does not authorize operational cutover.

## Source verification

Read the exact GitHub issues [#186](https://github.com/carverauto/agentboard/issues/186),
[#153](https://github.com/carverauto/agentboard/issues/153),
[#122](https://github.com/carverauto/agentboard/issues/122), and
[#156](https://github.com/carverauto/agentboard/issues/156), plus issue comments
for #186/#153. Inspected repository instructions and the current implementations
cited in design.md. An independent read-only source review confirmed:

- Runtime.fallback remains the sole CI/conflict selector; exact-marker adoption
  is not authenticated classification provenance.
- Current late-enrollment tests retain the inbox Message and add one worker
  delivery. No immutable delivery-mode receipt is claimed here.
- Ops.send_message returns the real Message, and its false capture flag disables
  both Mattermost and wake capture; no canonicalMessage API exists today.
- #156 captures typed metadata but lacks #169 current-order resolution and
  proven #150 native admission. Capture is not physical delivery.
- #153 remains a missing dependency, not an existing signed coordinator path.

Independent proposal review identified four consistency gaps, all addressed in
this revision: off/shadow backlog cannot gain effects implicitly; an already
captured generic wake is excluded at reservation time under source/election
custody as well as at capture/reconciliation; Event-only delivery creates no
Message-ID triage row; and #153 enqueue is explicitly deferred, with pending
source capture separate from the atomic outbox/linkage transaction. The specs
also cover not_submitted returning an old intent to pending without erasing
channel exclusion.

## Checks performed

- Structural OpenSpec-format assertions: proposal sections and capability/spec
  directory names agree; all 14 normative requirements have SHALL and WHEN/THEN
  scenarios; 49 scenarios; all 26 implementation/approval tasks remain unchecked.
- JSON Schema Draft 2020-12 meta-validation of
  `contracts/message-triage-v1.schema.json` using available Python jsonschema.
- Contract examples: 9 valid fixtures accepted and 13 invalid fixtures rejected,
  covering every category, captain attention, null context where allowed,
  unknown/missing fields, forged body fields, malformed IDs, control characters,
  overlong task slugs, nonpositive revision and mismatched source kinds.
- Git whitespace validation of the staged proposal files with
  `git diff --cached --check`.

These are documentation/contract checks, not application or transport tests.
The schema is a proposed input contract; it does not prove source authority,
currentness, authorization or implementation availability.

## Unrun and blocked verification

- The OpenSpec CLI is not installed or present in the available toolchain.
  Therefore `openspec validate add-coordinator-inbox-triage --strict` was NOT run.
  Structural assertions are not a substitute claimed as CLI validation.
- Archify and Lavish tooling is absent. Their required source/rendered exports,
  browser/perceptual verification and durable document uploads remain unfinished;
  no generic HTML is presented as those tools' output.
- No product code changed, so product suites were not run. No local Bazel
  fallback was used. Implementation requires the remote tests listed in tasks.md.
- No #153 signed transport, real consumer, native host or live farm01 equivalence
  test was run. None can be claimed from this proposal or schema fixtures.

## Approval and dependency gates

The design defaults are specified; no user preference question is needed to
finish this proposal. Approval to implement remains unrecorded. Migration
allocation, source-owner interface agreement, #153 integration readiness and
separate operational activation/retirement decisions remain open tasks. The
local off/shadow classification/audit/visibility slice can proceed after its
implementation approval without claiming the transport or retirement complete.
