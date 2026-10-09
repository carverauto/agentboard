# Registered-branch publication recovery

A registered branch can identify its card after a publisher stops between GitHub PR creation and returning the URL. Recovery does not infer the actual publisher from either the binding creator or a shared GitHub login. It records the PR author as unknown until a separately verified native publication receipt supplies that evidence.

## Existing pipeline, bounded provider reads

The existing Discovery.reconcile_links Cron and delivery_discovery queue remain the sole root producer. An ordinary inventory sweep schedules a registered-branch phase when the dedicated recovery flag is enabled. Keyset binding cursors and repository/page continuations live in actual AshOban job arguments, rather than process memory.

Each binding job searches the exact target repository and head-owner/branch through at most ten pages of 100 open PRs, then re-reads the sole candidate's metadata. Repository, exact head ref, URL/number, open lifecycle and head SHA must agree. A full page requires another read; an incomplete capped branch search cannot auto-link. More than one matching open PR is a refusal. Every HTTPS request spends the existing shared GitHub budget, honors provider cooldowns, uses the operator-pinned destination and CA, and runs outside task/PR/agent locks.

A second phase scans up to ten pages per registered repository. Missing branch bindings produce an independent attribution card and a captain-lane decision; they never assign the PR to a guessed existing card. A terminal bound card remains immutable. A second PR from an already recovered branch produces an existing-URL finding. A repository search cap is retained as a finding instead of being reported as a complete search.

## Atomic tracking, truthful attribution

After provider reads, recovery locks the source task followed by the canonical PR key used by Inventory. It rechecks the dedicated flags, current repository, terminal state, existing URL and other cards referencing that PR.

A valid unique mapping records the URL, incremented revision and truthful system tracking event; enrolls canonical inventory with unknown submission attribution; schedules ordinary PR observation; and appends an AshEvents recovery disposition in one transaction. An audit failure rolls all those effects back and enters the ordinary Oban retry path. The binding's declared creator remains retained separately, even if the card has changed owners. Neither the original source claim nor its assignee, lease or lifecycle is transferred.

Ambiguity, an existing different URL, multiple cards or a changed repository retain a captain-lane decision and audit finding. Task locks and the existing decision identity make replay idempotent. Reconciliation creates no publication grant or native-custody receipt, and does not authorize a branch write.

TaskLink is immutable. Recovery intentionally records no author/source submission event. A future native completion adapter must append separately verified authorship evidence; it must not reinterpret the recovery system event as a worker's submission or overwrite retained unknown attribution.

## Runtime controls and limits

AGENTBOARD_PUBLICATION_RECOVERY_ENABLED defaults to false in runtime, Compose and the generic Kubernetes base. It requires inventory discovery and ordinary provider observation to be enabled independently. Disabling recovery fences queued jobs and tracking commits; it does not stop existing ordinary PR observation. No deployment, maintainer-overlay change or activation accompanies this checkpoint.

The backstop covers repositories with registered bindings, not every GitHub repository or login. Provider list pagination is not an atomic snapshot of GitHub: recovery records the identity/head it actually observed and ordinary observation reconciles later changes. An unavailable, changed or indeterminate candidate defers rather than inventing a clean mergeability verdict.

## Verification status

Remote public API/provider fixtures cover unique crash recovery, claim preservation and unknown authorship; multiple PR/card ambiguity; existing URL refusal; shared-login/unbound findings in the real captain API; full-page uniqueness; same-branch later-PR detection; retry without duplicate effects; and atomic audit failure. Legacy Cron/keyset discovery and release schema checks remain covered by their existing targets.

The full public fixture passes remotely at https://carverauto.buildbuddy.io/invocation/569f1137-eb6e-4484-9c6e-e4b6cbef9730, including the actual 61-second provider cooldown, persisted cursor across Oban restart, an observed early callback with no provider I/O, and disable/re-enable. Legacy discovery and release schema pass at https://carverauto.buildbuddy.io/invocation/27fc38fb-5fcd-4c99-b988-d46531acba19; that earlier invocation's restart-fixture case failed and is superseded by the complete 569f1137 receipt.

Intended regressions were observed before implementation: missing unique recovery (f329184d-0013-444d-acc4-bdf82f89f23a), missing shared-login/unbound finding (c42b27ab-29c0-4f91-b590-36a62a7bbd5b), and missing second-PR finding after a retained recovery (e762b977-848c-4920-a551-c07b03ac358a). Queue-startup fixture failures and invalid target names are not regression evidence.

The quality delta retains eight gating findings: three normalized helper/query clone pairs, an audit-writer clone and Discovery growth from 47 to 61 measured lines. It also reports new-module size and orchestration complexity. The private worker-lock helper and availability predicate have different domain contracts; their query-shaped similarity does not justify coupling publication discovery to those owners. Existing Reconciliation.page holds a transaction while visiting each row, so it cannot wrap provider I/O. No metric suppression or acknowledgement was added. These findings remain review obligations.

Compose and Kustomize actual consumers verify the dedicated flag defaults to false. No native No-mistakes publication is claimed by this checkpoint.

The accepted consumer Archify diagram remains unchanged. The supplemental recovery diagram is an undelivered draft: after two focused repairs, its detached-node context still projected below the 6px desktop readability threshold. No successful validation, delivery or browser acceptance is claimed for that draft.
