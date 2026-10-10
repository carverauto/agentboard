# Verification

Baseline: `8cdaf4409d7600c86ea3dd10d1fae3a03193f3f9` (PR208 merged).
Execution: explicitly authorized assistant-VM linked worktree, physical cwd and
Git top-level both `/workspace/shared/agentboard-codex-native-queue`. This is not
Treehouse lease or board enrollment evidence. No native process was started.

## Passed

- Standalone `node build/integration/codex_queue_test.mjs internal/nativequeue/codex/transport.mjs` with Node v24.19.0.
- Node syntax checks for transport, journal and fixtures; shell syntax check for the wrapper.
- `git diff --check` and path-scope guard: no shared worker/bridge, web/admission, schema or deployment changes.
- Synthetic request/response correlation, immutable caller fences, bounded attributed source pointers and method allowlist.
- Journal-before-add with injected write, rename, file-fsync and directory-fsync failures; accepted/lost response and late callback; one-add retry boundary.
- Visible acceptance rename cannot bypass durability: each historical reader performs its own file+directory fsync and inode check, including a competing reader before the writer's directory fsync. Persistent sync failures refuse acceptance until durability is established.
- Present `null`, `false`, `0`, empty string and other non-object/corrupt journal roots cannot masquerade as an absent attempt or authorize another add.
- Exact positive queue correlation, edited/deleted/duplicate items, complete and incomplete offset pagination, malformed unrelated input and every valid pinned native input variant.
- Busy/unknown native inspection, wrong identity/version/schema/recipient and stale callbacks; retained acceptance remains historical evidence only.
- Private root/file protection, symlink/hardlink/foreign/unprotected evidence, root replacement and trusted ancestor custody including safe sticky ancestors.
- Separate synthetic processes competing for one attempt and SIGKILL after native insertion preserve custody and never issue a second add.

## Review corrections

Independent review identified visible-but-not-durable acceptance reads, falsy
JSON roots being mistaken for missing records, and malformed unrelated list
items being ignored. Each was fixed with a focused regression. Ancestor custody
was hardened and the storage trust boundary made explicit. Independent re-review
found no remaining must-fix issue in the isolated core,
reproduced all three fixes and reran all 31 fixture groups. Reviewed source
SHA-256 prefixes: transport `566af3102173`, journal `8189944aec50`. This sign-off
does not cover a production client, native interoperability, remote aggregate
checks or activation. The reviewed implementation is authorized for a local
commit and draft-PR preparation; this report does not establish publication
or activation.

## Unrun / not proven

- Remote Bazel target and aggregate acceptance: `.bazelrc.remote` and remote
  credentials are absent. No local Bazel fallback was attempted.
- Installed Codex 0.162.0 schema/export, actual server/profile, native queue,
  composer, approval or crash conformance. Source inspection is not live proof.
- Packaged runtime integration, owner election/admission, consumer canonical
  source recheck, explicit received/handled receipt wiring and enrollment.
- Production activation, credentials, native/Mac execution, board writes,
  schedules and deployment remain outside this change. Publication is handled
  separately after the authorized local commit; it is not a verification result.

## Publication preparation

On 2026-10-10, a fresh fetch confirmed `origin/main` remained at the baseline
above. All 31 synthetic fixture groups, module and shell syntax, whitespace
and exact path-scope checks were rerun before the authorized local commit.
Remote Bazel and native interoperability limitations remain unchanged.
