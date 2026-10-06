# Verification evidence

All compilation, application tests, dependency compilation, and packaging run through `./scripts/bazel` on BuildBuddy remote execution. No Go/Mix application build or test runs on this Mac. PostgreSQL integration uses a disposable loopback PostgreSQL 18.3 fixture with SCRAM, a generated CA and CA-signed server certificate, verified TLS, temporary data, and process cleanup; it never uses farm01 credentials or data.

## Application acceptance

[Full M1–M3 public-boundary acceptance](https://carverauto.buildbuddy.io/invocation/4bff2355-d9b1-495b-85ae-49ea24e14982) passed on 2026-10-05. The packaged Phoenix release and real Go CLI exercised registration with Codex/Claude/shell identities, metadata/URL edits and generated IDs, concurrent claim conflict, model provenance, status edges, explicit renewal and expired recovery, per-task row-lock independence, task/event and handoff rollback, keyset pagination, independent heartbeat/lease freshness, messages and recipient-only acknowledgement, full snapshots larger than 100 rows, startup races, listener reconnect, actual HTTP transport interruption with offline writes, stream cleanup/cancellation, schema 5/6 quota ingestion/raw retention/idempotence/ordering/uncertainty, and quota stream recovery.

The real HTTP/WebSocket LiveView boundary exercised all read-only routes, escaping/safe links, feed filters, unchanged task history and message read state, notification/fallback updates, and retained-data unavailable state during an actual database outage. Health stayed live while readiness failed. This is functional UI evidence, not a browser visual/accessibility audit.

[Go client/CLI and rate-limiter checks](https://carverauto.buildbuddy.io/invocation/0087980d-4144-4fe3-a2db-62d8ec75d351) passed: verified HTTPS/private CA behavior, 429 Retry-After seconds/date handling and bounded cancellable retries, rejected redirects, no replay of uncertain writes, exit codes, request/stream capacity and atomic admission. The full acceptance also drove the real API into 429 and verified no valid task write committed after throttling.

[Packaged migrations/schema checks](https://carverauto.buildbuddy.io/invocation/ef2c5d8d-c16c-4a2f-8185-7bf2f5d510a7) passed additive schema 1–3 migration and repeat migration, append-only constraints, TLS behavior and assets. Test PostgreSQL 18.3 is distinct from the confirmed CNPG 18.6 image; production operator/image compatibility remains a rollout check.

## Farm01 read-only prerequisite observations

Observed 2026-10-05 through the existing `farm01` kubeconfig, without applying configuration or reading secret contents:

- `farm01-edge/farm01-gateway`: Accepted and Programmed; existing listeners Accepted/Programmed/ResolvedRefs. Current private address is **192.168.7.10** (older repository comments name a different private range). Discover the reconciled address at rollout; do not hardcode the historical VIP.
- Existing `farm01-wildcard` Certificate Ready=True. Historical revoked-token comments do not describe current wildcard readiness.
- `default/external-dns`: one ready replica, service + gateway-httproute sources, existing three domain filters, TXT owner `external-dns-farm01`, TXT registry, upsert-only.
- CNPG operator running in `cnpg-system`.
- **StorageClass `local-path-cnpg` is absent**. Existing classes are `local-path` and `scylladb-local-xfs`; neither silently replaces the selected class.
- No CNPG Cluster in namespace `agentboard`; agentboard Certificate/listeners/routes and application smoke are not deployed or verified.
- The confirmed PostgreSQL tag resolves to `sha256:94aa172fc7ce295d482f5fe8bcf8d1e3423f30c15ba40c7d34114b68dc152b0a` in GHCR.

Application rollout, new Certificate readiness, agentboard Gateway/route conditions, DNS, HTTPS/redirect, production DB TLS/CA, storage provisioning, secrets, and trusted-network exposure remain untested until the release/operator procedure is authorized and its prerequisites exist.

## Release packaging

[Nonroot OCI-rootfs startup/migration/assets/probes](https://carverauto.buildbuddy.io/invocation/7556d8f7-ad9f-4ab6-8d3c-fbe3f5b038b9) passed. The remote test exports the real validated OCI layers and runs in chroot as UID/GID 10001 with app/config paths unwritable and writable /tmp. Remote device creation is unavailable, so /dev/null is a fixture file; actual container device/read-only mounts remain rollout checks. This test exposed and verified the fix for root/app layer directory permissions.

[Cross-platform CLI package checks](https://carverauto.buildbuddy.io/invocation/33ac5656-d53c-413c-9534-51cccf82685f) passed format/checksum checks for all four binaries, native Linux amd64 and pinned QEMU Linux arm64 execution. The companion image test in that earlier invocation failed before the permission fix; its later passing invocation is linked above. Darwin runtime execution is untested.

GitOps companion is [draft PR #152](https://github.com/carverauto/gitops/pull/152). Kustomize rendering, normalized preservation checks, and shell syntax passed. It has not been merged or applied. Artifact publication, workflow credentials, immutable registry availability and live rollout remain prerequisites.

Final application/configuration checks in [BuildBuddy](https://carverauto.buildbuddy.io/invocation/0f60578e-1be6-4bc6-8247-14500e92df63) passed all eight application targets after CLI cleanup, the human expired-claim label, and DATABASE_URL precedence over deliberately invalid split fields. Its bare workflow-tool check failed because the pinned image has no Bazel driver; release automation now installs pinned Bazelisk/GitHub CLI explicitly. [Corrected workflow-tool check](https://carverauto.buildbuddy.io/invocation/e841aa31-05a1-4515-b322-6c770cfdc670) passed in that pinned image.

[Release-artifact aggregate](https://carverauto.buildbuddy.io/invocation/6497269d-2412-44fa-9b02-cfdde7560f7f) passed for the CLI archive, OCI layout/digest, OTP archive and manifests. After the TLS startup guard, the [remote digest rebuild](https://carverauto.buildbuddy.io/invocation/702bdbe4-43c5-4f57-96c4-17246e6e9478) produced `sha256:e67b703253ffd06cc66b11951d9905be25528fab179cb932bed11e9e001f8829`, now shared by the farm01 application and migration Job. It is not yet published to Harbor.

The [packaged TLS guard regression](https://carverauto.buildbuddy.io/invocation/36a7da37-32fb-4847-9fc9-3bb8ce29017d) passed remotely: TLS-downgrading DATABASE_URL settings refuse startup without printing credentials. The [post-guard nonroot image startup check](https://carverauto.buildbuddy.io/invocation/16c5b56f-3302-4b84-acc8-8c1f9d125a57) also passed, including valid DATABASE_URL precedence over deliberately invalid split connection fields.

After refreshing the pin, the real Kustomize render was parsed and checked: both Deployment and migration Job resolve to the rebuilt digest, with namespace `agentboard`, selected `local-path-cnpg` storage and read-only containers preserved. GitHub currently reports a passing GitGuardian check; application build and runtime evidence comes from the linked BuildBuddy invocations.

Structural review split CLI command construction and stream consumption into private helpers, with public CLI/watch recovery checks passing afterward. The analyzer reported no major regression to existing code, and still flags new-code complexity in retry/watch state machines, command construction and schema/HEEx declarations; this is not a claim of zero new debt. OTP/Phoenix callbacks and dynamic context dispatch are supported by runtime tests rather than treated as removable dead code from a name-based call graph.

## Documentation and CLI release preparation (2026-10-05)

The captain selected `agentboard`, avoiding ApacheBench's `ab`; artifacts target Linux/Darwin amd64/arm64 and installation at `~/.local/bin/agentboard`. Full remote acceptance [d2f4b69c-6d57-482a-950a-eedeb658a95d](https://carverauto.buildbuddy.io/invocation/d2f4b69c-6d57-482a-950a-eedeb658a95d) passed all 10 targets after the documentation feature. Its public HTTP/CLI integration covers live-owner and expired-owner rejection, canonical retries, atomic attributed events/revisions, the 100-version bound, UTF-8/NUL/size rejection, immutable storage, metadata-only output, viewer/download links and CSP response semantics. Actual browser isolation and the final wrapper runtime remain rollout checks until recorded below.

The `publish-task-documentation` proposal automatically opened in Lavish using Agentboard's CSS tokens; the captain replied “looks good” and ended the review. The portable export has no unresolved local assets or nested frames. Archify passed nine deterministic checks, plus bounded browser containment/behavior checks and separately recorded image-capable review; see [visual evidence](architecture/task-documentation.visual-review.md).

GitOps [PR #154](https://github.com/carverauto/gitops/pull/154) persists `local-path-cnpg` with Retain/WaitForFirstConsumer. Live CNPG has two healthy PostgreSQL 18.6 instances and two Bound 20 GiB volumes. The exact-host Certificate is Ready and both Agentboard Gateway listeners have Accepted/Programmed/ResolvedRefs true at private address `192.168.7.10`. App migration, image publication, HTTPRoutes/DNS/HTTPS and live API/CLI smoke are still pending; task 6.7 stays incomplete until those checks pass. Secrets were provisioned only into the protected release environment and Kubernetes, using scoped Harbor robots; no values are in Git or this evidence.

The remotely built Darwin ARM64 CLI was checksum-verified and installed at `~/.local/bin/agentboard`; it executed `version` successfully as `0.1.0` on this Mac (SHA256 `49d653f327817c63a9749fded45abaea430abf3c08e28a4bc22c21dcc2541dd3`). Final remote formatting/package invocation [42ede39c-d352-452a-85a1-d4492b7b13dd](https://carverauto.buildbuddy.io/invocation/42ede39c-d352-452a-85a1-d4492b7b13dd) produced no formatting changes and dashboard digest `sha256:d1fc696a605fd10a0f704745f4b3103cce1fac53ecb521d977d7931c0c227df6`, now pinned in the farm01 overlay. Workspace canonical, Codex and captain skill links were installed without replacing existing workflows.

After removing the extra EOF blank line from the three new Elixir files, remote release-artifact rebuild [c021512d-315c-46e4-9401-dd3d30659719](https://carverauto.buildbuddy.io/invocation/c021512d-315c-46e4-9401-dd3d30659719) produced dashboard digest `sha256:213d5a68d1316fae4803fc77a5461024a3541743b0c98e8f630db3307d06f16b`, now pinned in the farm01 overlay; the d1fc digest above is historical preparation evidence for the pre-fix source. Image publication and live rollout remain operator steps.
