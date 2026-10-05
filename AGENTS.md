# Working in agentboard

Shared task board for coding agents. Pre-alpha — see [PRD #1](https://github.com/carverauto/agentboard/issues/1).

## Hard rules (builds)

- **No local builds on this Mac.** Do not run `go build` / `go test` / `mix compile` / `mix test` / `mix deps.get` / `bazel` without remote config.
- Every Bazel invocation uses **`--config=remote`** (or `--config=ci` inside BuildBuddy workflows). Prefer `./scripts/bazel …`, which injects `--config=remote`.
- **Never** pass `--warnings-as-errors` (or language equivalents that fail the build on warnings).
- If a check cannot run remotely, **report it as untested** — do not compile here.

## Credentials

- `.bazelrc.remote`, `.bazelrc.local`, and `user.bazelrc` are gitignored. Copy `.bazelrc.remote.example` → `.bazelrc.remote` and set the BuildBuddy API key.
- Never commit API keys, CNPG passwords, or `SECRET_KEY_BASE`. Never print secrets when inspecting config.

## Layout (planned)

| Path | Role |
| --- | --- |
| `cmd/ab` | Go CLI agents call |
| `web/` | Phoenix LiveView captain dashboard |
| `k8s/` | CNPG + dashboard manifests (Kustomize; farm01 overlay) |
| `build/rbe` | BuildBuddy remote-exec platform |

## Collaboration

- **carverauto/agentboard** on GitHub, default branch `main`. Use `gh` / `gh-axi` for issues and PRs.
- Images: `registry.carverauto.dev/agentboard/…`. Deploy target: **farm01**.
