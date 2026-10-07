# Historical frozen-batch recovery evidence

PR #51 completed the supervised runtime and was merged outside this agent's
session. Its exact reviewed head `33fb0737310259723a86353e5d2514afdad78ef9`
passed nine GitHub checks, with the publishing job skipped for a pull request.
All 20 remote acceptance targets also passed:
https://carverauto.buildbuddy.io/invocation/cc3e5012-e5f8-4318-86ba-b04bcf98395f.

A subsequent consumer review found that historical reconciliation compared the
attempt, batch ID and payload hash, but did not require the original frozen
dispatch generation and delivery membership. A positive answer without a batch
also retired the journal. The public remote-built CLI reproduced all four cases
on the merged baseline: different generation, different membership, missing
batch, and a replay answer for another generation. Each incorrectly reported
`reconciled` instead of retaining the journal:
https://carverauto.buildbuddy.io/invocation/7fd14261-577e-47a7-bc32-268e4b8d13dc.

The consumer now requires the canonical original frozen batch before accepting
either positive answer. A table-driven public CLI regression asserts the retained
journal, degraded report, original reconcile fences and absence of any native
adapter call or result/receipt write. Existing resolved and unresolved cases use
the server's full-batch envelope. All 15 host scenarios plus the client and native
adapter targets passed after the fix:
https://carverauto.buildbuddy.io/invocation/b565e235-dff9-4482-8a82-de0cb77cec60.

The full 20-target remote acceptance suite passed with the correction:
https://carverauto.buildbuddy.io/invocation/e95baa21-1aaa-4fe7-8732-1c0bb949fd25.
The edited runtime matches the remote formatter artifact from
https://carverauto.buildbuddy.io/invocation/15b5f349-e931-47b3-ae6b-69b6737b8342.
The scoped Ripwire quality delta reported no worsening or new public surface.

The original PR-linked architecture and approved historical proposal remain
readable in the sandbox viewers at
https://agentboard.farm01.carverauto.dev/documents/65 and
https://agentboard.farm01.carverauto.dev/documents/66. This consumer correction
does not add an adapter or activate a service.

Real packaged Phoenix interoperability still awaits the published server.
The controlled failed-PR, reminder, restart and repaired-head release proof remains
open. No local build or user-session prompting was performed for this correction.
