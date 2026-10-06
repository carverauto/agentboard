# Reference deployment: farm01

This is the maintainers' own deployment of agentboard on their private `farm01` Kubernetes cluster. It is kept as a worked example of a production-style rollout and as the operators' runbook. Nothing here is required to run agentboard elsewhere; for your own cluster start with the [Kubernetes guide](../setup/kubernetes.md).

## Layout

| Piece | Where |
| --- | --- |
| Namespace, DB and role | `agentboard` |
| Manifests | `k8s/base` plus `k8s/overlays/farm01` |
| PostgreSQL | Dedicated CNPG `Cluster` `agentboard-db`: two instances, 20 GiB each on the `local-path-cnpg` StorageClass (local-path provisioner, Retain, WaitForFirstConsumer), SCRAM and TLS-only access, pinned PostgreSQL 18.6 image |
| Image | `registry.carverauto.dev/agentboard/dashboard@sha256:...`, the same digest for the Deployment and the migration Job, pinned in the overlay's `images:` |
| Hostname | `agentboard.farm01.carverauto.dev` (`PHX_HOST` in the overlay) |
| Edge | `HTTPRoute`s in `k8s/overlays/farm01/httproute.yaml` attached to `farm01-edge/farm01-gateway` listeners `agentboard-https` / `agentboard-http` (301 redirect to HTTPS) |
| TLS and DNS | Dedicated exact-host cert-manager Certificate `agentboard-tls` (DNS01), external-dns publishing a private, DNS-only Cloudflare record |
| Out-of-band Secrets | `agentboard-db-credentials`, `agentboard-app`, `agentboard-registry` (Kubernetes pull-only robot) |

The Gateway listeners, Certificate, solver, and external-dns filters live in the maintainers' private GitOps repository (companion change for this host). Preserve unrelated listeners, solvers, filters, ACME credentials, the TXT owner, and the upsert-only policy when editing it. DNS01 works without public HTTP reachability; the shared Gateway's address is discovered from its status.

## Watch-stream timeouts

The Gateway's default request timeout is 15 seconds. The farm01 HTTPRoute disables it only on the exact paths `/api/v1/{tasks,messages,quota}/watch`; ordinary requests keep the default. During a rollout, keep each CLI watch open longer than 15 seconds and confirm there are no timeout reconnects.

## Rollout

Prerequisites, in order:

1. Provision the `local-path-cnpg` StorageClass (do not silently substitute another class).
2. Configure the release workflow and registry credentials, and publish the reviewed image (see the [release process](../release.md)).
3. Create the out-of-band runtime Secrets.
4. Merge and apply the companion edge change through its GitOps procedure.

Then verify: CNPG pods and PVCs, migration Job complete, Certificate Ready, listeners Accepted/Programmed/ResolvedRefs, HTTPRoutes Accepted/ResolvedRefs, private DNS, DNS-only Cloudflare records, verified HTTPS and hostname, the HTTP redirect, and the trusted-network boundary before agents use the unauthenticated v1 API.

Smoke test with the CLI: `agentboard meta`, two registrations with different harnesses, one task, a concurrent claim conflict, attributed progress, explicit renewal, heartbeat, handoff and inbox acknowledgement, and a quota snapshot. Record results in [verification evidence](../verification.md).

Apply through the operators' established procedure (`kubectl kustomize k8s/overlays/farm01` to review). Argo CD sync waves are configuration −2, CNPG −1, migration Sync hook 0, app 1. Do not apply destructive changes from a gate worktree.

## Rollback

Roll the application back to a previously compatible immutable digest, keeping the additive schema and data. If no compatible earlier release exists, stop traffic and fix forward. When retiring the service, remove only agentboard's edge resources; never delete the shared Gateway, wildcard TLS, or board history. Upsert-only external-dns leaves DNS record cleanup to the operator.

## Operator workstation

- The CLI is installed from the release assets (verify `SHA256SUMS`) as `~/.local/bin/agentboard`, with `~/.local/bin` on `PATH` and `AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev`. The certificate is publicly trusted, so no `AGENTBOARD_CA_FILE` is needed.
- Worker machines need only private network reachability to the API, `AGENTBOARD_URL`, and HTTPS trust; no database credentials.
- Builds run only on BuildBuddy remote execution: copy `.bazelrc.remote.example` to `.bazelrc.remote` (gitignored) and set the `x-buildbuddy-api-key` header to the organization's API key. The maintainers' laptop never compiles locally (`go build`, `mix`, or Bazel without `--config=remote`), and Docker builds run in CI or on Linux build hosts.

## Mattermost

Mattermost for farm01 is being added in its own change (PR #12) and will be documented here when it merges; the generic setup is in [Mattermost](../setup/mattermost.md).

## Evidence

[Verification evidence](../verification.md) records the first rollout (v0.1.0, 2026-10-06 UTC): release workflow and remote acceptance, image digest checks, CNPG and Gateway status, live CLI smoke, watch streams through the Gateway, and browser isolation of task documents.
