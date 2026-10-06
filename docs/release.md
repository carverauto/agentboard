# Release process

Releases are built, tested, and packaged with Bazel on BuildBuddy remote execution:

```bash
./scripts/bazel test //:acceptance
./scripts/bazel build //:release_artifacts
```

`//:release_artifacts` contains static `agentboard` binaries for Linux and macOS (amd64 and arm64) with `SHA256SUMS`, the OTP release archive, and the Linux amd64 dashboard and CLI OCI images with their digests. Linux amd64 binaries execute natively in the acceptance tests; Linux arm64 runs under pinned QEMU on the amd64 executor.

The dashboard image uses a pinned Ubuntu Noble base, UID/GID 10001, release state under `/tmp`, and Erlang distribution turned off. Deployments supply a read-only root filesystem and a writable, bounded `/tmp`. The CLI image carries the static `agentboard` binary as its entrypoint and runs as `nobody`. The repository's `Dockerfile` builds an equivalent image for people without the Bazel setup ([building](setup/building.md)).

## Automation

- **BuildBuddy workflow** (`buildbuddy.yaml`): on pushes and pull requests to `main`, runs `//:acceptance` and builds the release artifacts and `//k8s:manifests`. It needs a `BUILDBUDDY_API_KEY` secret; `scripts/ci-bazelrc` writes it to the gitignored `.bazelrc.remote` without logging it.
- **Docker images workflow** (`.github/workflows/docker.yml`): builds both Dockerfiles and runs the Compose smoke test on pull requests.
- **Container images workflow** (`.github/workflows/images.yml`): after a push to `main` or a `v*` tag, runs `//:acceptance` and builds both images on BuildBuddy, then pushes them to `registry.carverauto.dev/agentboard/{dashboard,cli}`:

  | Trigger | Tags |
  | --- | --- |
  | Push to `main` | `sha-<commit>` and `latest` |
  | Push of tag `vX.Y.Z` | `sha-<commit>` and `vX.Y.Z` |

  `sha-<commit>` tags are immutable; deploy by digest. Pushes that only touch `k8s/`, docs, or Markdown skip the build. On pull requests the workflow runs a plan job only: it prints the tags it would push and checks the reference overlay, without secrets. It uses the `agentboard-release` environment and its secrets (below).
- **Publish workflow** (`.github/workflows/release.yml`, manual): accepts an existing release tag whose commit is on `main`, reruns the remote acceptance targets and packaging, pushes the verified OCI digest to the maintainers' registry, and creates a **draft** GitHub release with the binaries, checksums, release archive, image reference, and a matching Kustomization. It runs in the protected `agentboard-release` environment with these secrets (values are provisioned out of band and never recorded in Git):

  | Secret | Purpose |
  | --- | --- |
  | `BUILDBUDDY_API_KEY` | Remote execution |
  | `HARBOR_BUILD_USERNAME`, `HARBOR_BUILD_PASSWORD` | Pull-only access to the mirrored base image |
  | `HARBOR_USERNAME`, `HARBOR_PASSWORD` | Publishing the agentboard images |

## Rules

- The application Deployment and the migration Job reference the **same image digest**. Commit the digest through deployment review before rolling out.
- A local build digest is not proof that the registry contains that image. Never deploy a placeholder tag (`build-required`) or reuse a version tag for changed content.
- Run migrations (`bin/agentboard eval 'Agentboard.Release.migrate()'`) from the release that will serve traffic, before it takes traffic. Migrations are additive and forward-only; roll back by deploying an earlier compatible digest against the newer schema.
- The server connects to PostgreSQL over TLS and verifies the certificate and hostname using `DATABASE_CA_FILE`. `DATABASE_URL`, when supplied, overrides the split `DATABASE_*` fields; startup refuses a `DATABASE_URL` that disables verification (`ssl=false`, `sslmode=disable/allow/prefer`) without printing credentials.
- CLI users download the platform binary and `SHA256SUMS` from the GitHub release and verify the checksum before installing ([CLI guide](setup/cli.md)).

The maintainers' own rollout runbook is in the [reference deployment](deploy/reference-farm01.md).
