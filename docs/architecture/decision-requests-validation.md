# Decision request verification

Final acceptance including the verbatim-question inbox regression: [26b8190b](https://carverauto.buildbuddy.io/invocation/26b8190b-7c60-4bbf-a932-b4251af5223c), 29 passing targets. The new inbox assertion failed on the omitted-question implementation (cfcced45) and passed after correction.

Earlier remote acceptance: [10a814a5](https://carverauto.buildbuddy.io/invocation/10a814a5-e04d-4888-9c01-9cd59a7473be), 29 passing targets including availability and terminal merge disposition. Final extended decision proof: [2f3777b1](https://carverauto.buildbuddy.io/invocation/2f3777b1-84e6-4bed-b38f-6d22897a0768), including protected captain browser answer/recovery. Final consolidated CLI compatibility table: [84890e3b](https://carverauto.buildbuddy.io/invocation/84890e3b-a26e-45af-925a-e1d7d6cef96e). All Bazel commands use scripts/bazel with remote configuration; assets and release were compiled remotely.

## Architecture artifact

Specification SHA256: `91dee16bc4171cda246b75e43bf157b0c639ade924bfcb66b40a002f50b8102b`.
HTML SHA256: `69f2707e694f7d5f381febb1fccb3c1b6e12c19e583f9237bcf911a9cf438058` (708217 bytes).
Deterministic: 9/9 showcase, zero composition errors/warnings.
Automated browser: passed exact delivered HTML at 1440×900, 1600×1000, 1920×1080, 2048×1320, with light/dark endpoint captures. Artifact-bound receipt: decision-requests.visual-check.json.
Perceptual review: passed after an image-capable review of all four endpoint theme screenshots; nodes, labels, routes and ownership/delivery cards remain readable and contained. This is separate from the automated receipt, whose visualReview remains pending by design.

## Product rendering

The packaged remote fixture retains actual connected LiveView render payloads and server-generated HTML/CSS as undeclared outputs. An isolated local browser uses the pinned Phoenix LiveView JavaScript Rendered serializer to display those payloads with the remotely compiled product CSS, without a live API or session. Both the secondary Waiting on captain panel and /prs were inspected at 1440×900 in light/dark: document scrollWidth equals 1440; verbatim findings are escaped, stale labels and linked tasks are visible. Retained panel/prs PNGs use invented actors only. The wrapper reported BROWSER_ERROR on several screenshot calls despite writing the requested files; the saved bytes were read and visually inspected independently. Functional connected-session proof remains the remote integration test, rather than these static visual snapshots.

## Deployment boundary

The consumer defaults to dry-run and creates no timer. No live native prompt or unproven automatic Codex/Herdr adapter is claimed. Coordinator message846 supplies the required shared host-watcher integration contract; that host remains coordinator-owned. One frozen intent is not exactly-once physical prompt delivery. Protected credential provisioning and deployment remain operator actions.
