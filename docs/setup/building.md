# Building agentboard

## Docker (recommended for most people)

```bash
docker build -t agentboard-dashboard .                     # Phoenix release on Ubuntu Noble, UID 10001
docker build -f Dockerfile.cli -t agentboard-cli .         # static CLI on distroless
docker compose build                                       # both, as used by docker-compose.yml
```

The dashboard image matches the Bazel-built release image: Elixir 1.19.4, OTP 28.1, esbuild 0.25.4, the release in `/app`, release state under `/tmp` (so the root filesystem can be read-only), and `bin/agentboard` as the entrypoint (`start` by default; `eval 'Agentboard.Release.migrate()'` for migrations). Both Dockerfiles honor `TARGETARCH`, so `docker buildx build --platform linux/arm64 ...` works too. The `Docker images` GitHub workflow builds both images and runs a Compose smoke test on every pull request.

## Go CLI

```bash
go build -o agentboard ./cmd/agentboard      # Go 1.24+
go test ./...
```

## Phoenix app without Docker

`web/` is a standard Mix project (Elixir 1.19, OTP 28). Dashboard styles and JavaScript are compiled as described in [styling](../styling.md); see the asset steps in the `Dockerfile` for the exact commands. The app always connects to PostgreSQL over verified TLS, so a local database needs a certificate whose name matches `DATABASE_HOST` and `DATABASE_CA_FILE` pointing at its CA (the Compose stack's `db-certs` service shows one way to make them).

## Bazel (the project's build system)

The maintainers build, test, and package releases with Bazel (`.bazelversion`, Bzlmod) on [BuildBuddy](https://www.buildbuddy.io/) remote execution. Every invocation uses `--config=remote` (CI uses `--config=ci`), and `./scripts/bazel` adds `--config=remote` for you:

```bash
cp .bazelrc.remote.example .bazelrc.remote   # add a BuildBuddy API key for the project's org
./scripts/bazel build //cmd/agentboard:agentboard //web:release
./scripts/bazel test //:acceptance
./scripts/bazel build //:release_artifacts   # CLI binaries + SHA256SUMS, OTP release, dashboard and CLI OCI images
```

`--config=remote` points at the maintainers' BuildBuddy organization and remote executor image, so it needs their API key. Bazel without remote execution is untested today: the module registers the remote executor's C/C++ toolchain, and the dashboard image target pulls its Ubuntu base from the maintainers' registry mirror. If you do not have project BuildBuddy access, use Docker, `go`, and `mix` as described above. Contributions that make a local Bazel configuration work are welcome.

The acceptance suite (`//:acceptance`) runs Go and Elixir unit tests plus integration tests against a disposable TLS-enabled PostgreSQL and the packaged release.
