# PR conflict accountability

[Interactive Archify workflow](pr-conflict-accountability.html) ·
[Portable approved OpenSpec refinement](pr-merge-conflicts-openspec.html)

A PR can have healthy CI and still conflict with its base. Named-branch watches
and normal PR polling collect those signals independently. The API and dashboard
show unknown/stale evidence honestly. Cooperation-on creates one rebase follow-up
per canonical PR/head, with immutable submission ownership or an explicit captain
queue. The original task, lease, current assignment and CI obligation are unchanged.

Implementation: `Delivery.BaseMonitor`/`BaseObservation` reserve branch work,
call the admitted GitHub HTTPS client outside transactions, and persist paged
invalidation. `Polling` fences snapshot/projection writes. `Rebase` atomically
records the repair, Ash audit/timeline, board inbox message and cooperation intent.
`Runtime.ensure_delivery` recovers signals for late enrollment using the existing
worker frame/receipt path. `Delivery.Reads` supplies `/prs`, API and CLI.

## Diagram receipt

- Specification SHA-256: `a790578014045abcc334f04645e12fa22bd7cf2acba9b6f914b7d3bbd275e955` (3,340 bytes).
- HTML SHA-256: `737010e62bb6715016bb028decb0b5302aed7cddf0d1e0e24b0f0a3b5470a715` (708,886 bytes).
- Deterministic delivery: 9/9 showcase checks, zero composition errors/warnings.
- Automated browser evidence: passed at 1440×900, 1600×1000, 1920×1080 and 2048×1320; light/dark endpoint captures passed.
- Perceptual review: passed for actual light/dark screenshots; readable labels, clear routes and contained cards. Manual viewer checks passed: search found Rebase task, focus opened its semantic passport and authored connections, and SVG export produced a downloadable vector artifact.
- Correction rounds: 0 perceptual corrections. One semantic layout correction in the fresh compact candidate removed a backwards main-path declaration. The earlier wide candidate failed readability and was stopped; it was never delivered.

## Remote evidence

Seven packaged-release suites executed and passed in BuildBuddy invocation
`59aabf1e-3486-4664-a5ee-e490af414d0f`: conflict, GitHub collection, polling,
scheduling, CI accountability, merge disposition and release migrations.
The conflict fixture covers 101 open PRs, discarded-page/restart recovery,
old PR/branch response fences, shared admission/cooldown, computing metadata,
unknown-owner routing, once-per-head inbox/worker-frame delivery, rollback and
original source preservation. Provider metadata and credentials are invented.

Negative control `1e859f2e-bc5b-44e1-b33f-132534ad5806` uses main's original
GitHub collector with the current fixture. It fails at the public detail assertion
that definitive `mergeable=false` / `mergeable_state=dirty` must be retained;
the repaired collector passes. The candidate collector was restored immediately
after the control. This is remote packaged-product proof; it does not claim a
production rollout or automatic delivery to a real harness.

Final formatted conflict and Go CLI suites passed in invocation
`fc85136e-9cd2-46d8-b6fa-61139e40ab0f`. The packaged `/prs` HTML and
remotely compiled CSS were inspected at 1440×900: page width equaled viewport
width, the existing four columns remained contained, and the conflict badge,
owner, follow-up and delivery state were readable. This is server-rendered
product evidence, not a live production observation.

The final Ripwire delta has 17 gating observations remaining: framework
callbacks/delegating wrappers and domain-specific reservation/enrollment shapes
are intentional; controller actions retain the established reply path, and
short-horizon churn reflects this rapidly changing subsystem. The measured
projection complexity and repeated worker-result dispatch were reduced before
the passing remote proof. No clean Ripwire verdict is claimed.
