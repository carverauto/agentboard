# Implementation and proof

The original proposal review is historical approval evidence; its original
digest remains in `approval.md`. The optional effective-availability
specification amendment was explicitly authorized after that review.

The first slice implements an explicitly activated, exclusive stdio bridge for
Codex 0.160.1, an ephemeral native thread, protected scoped state/check-in and
exact receipt tools, owned installation, and generation-fenced durable native
attempt evidence. The server adds the optional effective-availability map
without changing the protocol revision or requiring a migration. It resolves
the current registered Agent, preserving the existing map.

## Completed checks

- Remote executable wire acceptance covers bounds, immutable fences, pause and
  availability refusals, busy/approval waits, exact tools, correlated acceptance,
  fast completion, lost/error/disconnected acceptance, restart and non-replay.
- Public CLI acceptance covers adapter/harness admission, scoped state and
  owned installation while retaining existing Pi and Claude contracts.
- Packaged Phoenix + Go host + production bridge acceptance covers real
  provisioning/bind/doctor, current registered-model availability, map
  preservation, frozen submission with no implicit receipts, and explicit
  check-in/received/handled receipts while unavailable. Its native model peer
  is synthetic.
- Separately authorized disposable installed-model conformance ran Codex
  0.160.1 with its default model and existing login, the production bridge and
  remotely built Go host against a synthetic loopback scoped API. Seventeen
  checks passed, including actual model check-in and exact received/handled
  tools, admission/busy refusal, journaled native acceptance and replacement
  identity refusal. No authentication file was copied. The owned native child,
  bridge, synthetic API, profile and temporary state were cleaned up.
- Modified Go files and the new Elixir block match remote formatting output.
  OpenSpec strict validation and whitespace checks pass.

The installed-model exercise does not prove the real server's admission or
receipt persistence; the separate packaged test owns that boundary. Lost
native acceptance is covered by executable fixture transport faults, not
claimed as an installed-model fault injection.

## Delivery gates

Native no-mistakes review, current-head CI and PR-bound document delivery remain
required before this slice is ready for captain review. Production enrollment,
activation and canary rollout require separate authorization. Existing TUI,
desktop, daemon and Herdr sessions remain manual; this slice has no interactive
approval UI or automatic tool-return delivery.

The implementation architecture source and standalone HTML are in
`docs/architecture/codex-worker-implementation.*`. The original portable
proposal review is retained separately and must not be mistaken for current
implementation proof.
