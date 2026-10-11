# Verification

Implementation baseline: main `2b93dbfcb0923025ea93b3ab25eeb719d7edec91`.
Only an authorized assistant-VM linked worktree was used. No native Codex server,
real session, user computer, board credentials or deployment was accessed.

## Passed in the assistant VM

- All 106 in-memory client cases passed; 20 socket metadata fixture groups passed.
- In-memory Duplex HTTP upgrade with real pinned ws framing, initialization and
  exact-ID request/response state machine, plus queue transport/journal integration.
- Synthetic metadata validation for the official alias layout, ownership/modes,
  unsafe ancestry, replacement during discovery, lifetime rechecks and exact
  bigint inode identity above 2^53. No real protected daemon path was probed.
- Existing queue-core regression suite: all 31 fixture groups.
- Checksum-verified official Node v22.23.2 and existing Node v24.19.0 runs.
- ws 8.22.0 official npm tarball SHA256/SHA512/lockfile agreement, isolated runner
  packaging, addon disables, corrupt archive rejection, shell/JS syntax, YAML
  parsing and whitespace checks.

Independent read-only review reproduced and confirmed fixes for reentrant proof
revocation (identity retired before any pending work can be added), native
`emittedAtMs` notification compatibility, and exact inode stamps. Additional
regressions cover malformed framing/UTF-8/envelopes, fragmented aggregate bounds,
control traffic, approval nonresponse, HTTP headers/redirects/compression,
backpressure/deadlines, pending/request/notification/raw-byte budgets, no retry
and persistence of ambiguous add custody.

## Blocked or unrun

The required invented Unix listener was attempted once and failed with
`listen EPERM` at a disposable `codex-rpc-fixture-.../synthetic.sock` path. No
alternate socket path, escalation, user computer or environment bypass was used.
Default no-bind runs print this Unix gate as UNRUN; hosted CI and remote Bazel
set `CODEX_RPC_TEST_UNIX=1` so inability to execute it fails the target.

Hosted CI awaits authorized publication. Remote Bazel/aggregate acceptance is
unrun: the assistant VM has neither Bazel nor remote configuration/credentials.
No local-Bazel substitute was used. These omissions are not passed checks.

The shipped client requires owner proof and has no provider or runtime importer.
Actual connected-peer process identity, native build/experimental schema/profile,
recipient enrollment lifecycle, native initialization effects and queue add
behavior remain unverified. Source research and synthetic peers cannot close
these gates. Publication, owner agreement and live activation remain separate.

A final fresh-main fetch on 2026-10-11 confirmed the baseline remained unchanged.
The final no-bind suite passed using the hermetic runner and pinned Node 22.23.2;
Node 24.19.0 passed five consecutive 106-case runs. AF_UNIX was not retried after
the verified denial. Final module/shell syntax, YAML/package parsing and
whitespace checks passed.
