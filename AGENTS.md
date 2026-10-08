# Working in agentboard

Shared task board for coding agents. Pre-alpha. Start with the [README](README.md); design history is in [PRD #1](https://github.com/carverauto/agentboard/issues/1) and `openspec/`.

## Hard rules (builds)

- **No local builds on the maintainers' workstations.** Do not run `go build` / `go test` / `mix compile` / `mix test` / `mix deps.get` / `docker build` / `docker compose build` / `bazel` without remote config there.
- Every Bazel invocation uses **`--config=remote`** (or `--config=ci` inside BuildBuddy workflows). Prefer `./scripts/bazel …`, which injects `--config=remote`.
- **Never** pass `--warnings-as-errors` (or language equivalents that fail the build on warnings).
- Docker images are built and smoke-tested by the `Docker images` GitHub workflow (or on a disposable Linux build host), not on a maintainer laptop.
- If a check cannot run remotely, **report it as untested** — do not compile locally.

## Credentials

- `.bazelrc.remote`, `.bazelrc.local`, `user.bazelrc`, and `.env` are gitignored. Copy `.bazelrc.remote.example` → `.bazelrc.remote` and set the BuildBuddy API key; copy `.env.example` → `.env` for Docker Compose.
- Never commit API keys, database passwords, bot tokens, or `SECRET_KEY_BASE`. Never print secrets when inspecting config.

## Layout

| Path | Role |
| --- | --- |
| `cmd/agentboard`, `internal/` | Go CLI agents call |
| `web/` | Phoenix API and LiveView dashboard |
| `k8s/` | Kustomize base, example overlay, optional components, maintainers' `farm01` overlay |
| `docker-compose.yml`, `Dockerfile`, `Dockerfile.cli`, `deploy/compose/` | Docker Compose stack and images |
| `build/` | Bazel integration tests, release packaging, BuildBuddy remote-exec platform |
| `skills/` | Agent workflow skills |
| `docs/setup/` | User-facing setup guides |

## Collaboration

- **carverauto/agentboard** on GitHub (public), default branch `main`. Use `gh` / `gh-axi` for issues and PRs.
- Keep user-facing docs generic (placeholders such as `agentboard.example.com`). Maintainer-environment details belong in [docs/deploy/reference-farm01.md](docs/deploy/reference-farm01.md).
- Cross-agent artifacts travel as a durable PR or HTTPS URL plus `agentboard context publish --kind FACT` (URL + `sha256` in the summary), never Treehouse-slot-local paths. Mattermost is for talk; cite the PR/URL/Context entry in `msg send` bodies.

## Dashboard styling

Use **Tailwind CSS v4** for dashboard styles. The CSS-first entrypoint is `web/assets/app.css`; register template sources explicitly and keep utility names complete in HEEx. Bazel and Docker compile the same pinned standalone CLI. Preserve the Kanban layout and existing theme tokens. Release assembly fingerprints CSS/JS through Phoenix; link assets using `AgentboardWeb.Endpoint.static_path/1`. Never compile assets on this Mac.

## Starting the next PR

Fetch `origin/main` before starting a new feature or rollout branch, and create
the branch from that freshly fetched ref. Before publishing, check it still
merges cleanly with current `main`. Preserve pipeline-owned fixes through the
reported No-mistakes custody flow; let its active CI monitor resolve conflicts
and revalidate rather than hand-rebasing an active run.

## Agentboard seat isolation

Every implementation seat must use a disposable, persistently leased **Treehouse
v2.0.1** linked worktree. The primary checkout is for inspection and explicit
launcher invocation only. A branch, Herdr pane, container, or backend tag does not
establish worktree isolation. Do not implement, branch, commit or push from the
primary checkout. Start seats with [scripts/launch-seat](scripts/launch-seat);
install the checksum-pinned tool with [scripts/install-treehouse](scripts/install-treehouse).

Before editing, and again in each ship brief, require `pwd -P` and
`git rev-parse --show-toplevel` to resolve to the exact expected disposable
worktree root in `AGENTBOARD_SEAT_WORKTREE`. The launcher also checks the common
Git directory, linked-worktree registration and a settled cwd before delivering
the brief and starting the native harness. Primary, source, foreign-repository,
subdirectory, missing or mismatched cwd means **STOP**: report the isolation
failure and mark the owned task blocked after verifying the current claim.
Resume only in a correctly leased task worktree. Keep the lease through PR review
and green CI; return it explicitly only after preserving all work and coordinating
cleanup. Never prune or return another seat's worktree.

The launcher gate and the generated STOP brief both remain mandatory. Optional
SessionStart/turn-end checks are structural backstops, not replacements, and are
not installed automatically. See [seat isolation setup](docs/setup/seat-isolation.md)
for native argv, versioned pool, lease and recovery details. No fleet automation,
Herdr prompt delivery or merge authorization is implied.
