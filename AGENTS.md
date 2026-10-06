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

## Dashboard styling

Use **Tailwind CSS v4** for dashboard styles. The CSS-first entrypoint is `web/assets/app.css`; register template sources explicitly and keep utility names complete in HEEx. Bazel and Docker compile the same pinned standalone CLI. Preserve the Kanban layout and existing theme tokens. Release assembly fingerprints CSS/JS through Phoenix; link assets using `AgentboardWeb.Endpoint.static_path/1`. Never compile assets on this Mac.
