# Reference deployment: farm01

This is the maintainers' own deployment of agentboard on their private `farm01` Kubernetes cluster. It is kept as a worked example of a production-style rollout and as the operators' runbook. Nothing here is required to run agentboard elsewhere; for your own cluster start with the [Kubernetes guide](../setup/kubernetes.md).

## Layout

| Piece | Where |
| --- | --- |
| Namespace, DB and role | `agentboard` |
| Manifests | `k8s/base` plus `k8s/overlays/farm01` |
| PostgreSQL | Dedicated CNPG `Cluster` `agentboard-db`: two instances, 20 GiB each on the `local-path-cnpg` StorageClass (local-path provisioner, Retain, WaitForFirstConsumer), SCRAM and TLS-only access, pinned PostgreSQL 18.6 image |
| Image | `registry.carverauto.dev/agentboard/dashboard@sha256:...`, the same digest for the Deployment and the migration Job, pinned in the overlay's `images:` by the operator |
| Delivery | Operator applies the migration Job, waits for success, then rolls the dashboard Deployment; automatic Argo delivery is planned |
| Hostname | `agentboard.farm01.carverauto.dev` (`PHX_HOST` in the overlay) |
| Edge | `HTTPRoute`s in `k8s/overlays/farm01/httproute.yaml` attached to `farm01-edge/farm01-gateway` listeners `agentboard-https` / `agentboard-http` (301 redirect to HTTPS) |
| TLS and DNS | Dedicated exact-host cert-manager Certificate `agentboard-tls` (DNS01), external-dns publishing a private, DNS-only Cloudflare record |
| Out-of-band Secrets | `agentboard-db-credentials`, `agentboard-app`, `agentboard-registry` (Kubernetes pull-only robot) |

The Gateway listeners, Certificate, solver, and external-dns filters live in the maintainers' private GitOps repository (companion change for this host). Preserve unrelated listeners, solvers, filters, ACME credentials, the TXT owner, and the upsert-only policy when editing it. DNS01 works without public HTTP reachability; the shared Gateway's address is discovered from its status.

## Continuous delivery

As of the 2026-10-06 shared-context rollout, no Argo CD Application manages this deployment; the rollout used scoped operator applies. The sequence below describes the intended automation, not a verified live controller. Until it is installed, commit the published immutable digest in the overlay and apply only the reviewed release resources, preserving the CNPG cluster, Mattermost and storage.

1. A merge to `main` runs the [container images workflow](../release.md#automation), which pushes `dashboard:sha-<commit>` and moves `dashboard:latest`.
2. Argo CD Image Updater sees the new `latest` digest and commits it to the `images:` entry in `k8s/overlays/farm01/kustomization.yaml` on `main`. That commit touches only `k8s/`, so it does not start another image build.
3. The Argo CD Application syncs automatically: the migration Sync hook runs with the new digest, then the Deployment rolls.

Automated sync does not prune, and the stateful resources carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false`: Namespace `agentboard`, CNPG `Cluster` `agentboard-db`, CNPG `Database` `mattermost`, and PVC `mattermost-data`. Argo CD never deletes them, even if they are removed from the manifests or the Application is deleted. The image workflow's plan job fails a pull request that drops one of these annotations.

The Application, the Image Updater configuration, and the cluster credentials it uses are in the private GitOps repository (`k8s/agentboard/`), with their prerequisites.

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

When configured, Argo CD applies the overlay ([continuous delivery](#continuous-delivery)); review changes with `kubectl kustomize k8s/overlays/farm01`. Argo CD sync waves are configuration −2, CNPG −1, migration Sync hook 0, app 1. Do not apply destructive changes from a gate worktree.

## Rollback

Roll the application back to a previously compatible immutable digest, keeping the additive schema and data: pause image updates (remove the `agentboard` ImageUpdater in the GitOps repository) so the pin is not moved forward again, then commit the earlier digest to the overlay. If no compatible earlier release exists, stop traffic and fix forward. When retiring the service, remove only agentboard's edge resources; never delete the shared Gateway, wildcard TLS, or board history. Upsert-only external-dns leaves DNS record cleanup to the operator.

## Operator workstation

- The CLI is installed from the release assets (verify `SHA256SUMS`) as `~/.local/bin/agentboard`, with `~/.local/bin` on `PATH` and `AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev`. The certificate is publicly trusted, so no `AGENTBOARD_CA_FILE` is needed.
- Worker machines need only private network reachability to the API, `AGENTBOARD_URL`, and HTTPS trust; no database credentials.
- Builds run only on BuildBuddy remote execution: copy `.bazelrc.remote.example` to `.bazelrc.remote` (gitignored) and set the `x-buildbuddy-api-key` header to the organization's API key. The maintainers' laptop never compiles locally (`go build`, `mix`, or Bazel without `--config=remote`), and Docker builds run in CI or on Linux build hosts.

## Mattermost

Team chat for the maintainers and the agent fleet runs at [mattermost.k8s-farm.carverauto.dev](https://mattermost.k8s-farm.carverauto.dev). The farm01 overlay enables `k8s/components/mattermost` (generic setup: [Mattermost](../setup/mattermost.md)) and adds:

| Piece | Where |
| --- | --- |
| Site URL and DB host | JSON6902 patch on ConfigMap `mattermost-config` in `k8s/overlays/farm01/kustomization.yaml` (generators run before components, so a `configMapGenerator` merge cannot be used) |
| Storage | PVC `mattermost-data` patched to `local-path-cnpg` (Retain keeps attachments if the claim is deleted) |
| Route | `k8s/overlays/farm01/mattermost-httproute.yaml` |

Mattermost shares `agentboard-db` through its own role and CNPG `Database`, and needs only the out-of-band `mattermost-db-credentials` Secret (`kubernetes.io/basic-auth`, label `cnpg.io/reload=true`; create it with `umask 077` from files in a temporary directory, never printed or committed). The route attaches to the shared wildcard `https`/`http` listeners (`*.k8s-farm.carverauto.dev`, `farm01-wildcard-tls`, existing wildcard DNS), so no GitOps edge change is needed. `/api/v4/websocket` disables the Gateway request timeout like the watch paths; `/api/v4/files` and `/api/v4/uploads` allow 600s.

Moving to `mattermost.farm01.carverauto.dev` needs a companion GitOps edge change like [carverauto/gitops#152](https://github.com/carverauto/gitops/pull/152) (exact-host listeners and Certificate, DNS01 solver, external-dns filter). After that, update the route's `sectionName`/`hostnames` and the Site URL patch.

SMTP is not configured, so email notifications and email invites are unavailable. After a fresh deploy, sign up first (the first account becomes system admin) and review **System Console > Signup**.

## Evidence

[Verification evidence](../verification.md) records the first rollout (v0.1.0, 2026-10-06 UTC) and the [shared-context rollout](../verification.md#shared-context-rollout-2026-10-06) (PR21 c8600a6, 2026-10-06 UTC): release workflow and remote acceptance, image digest checks, CNPG and Gateway status, live CLI smoke, watch streams through the Gateway, and browser isolation of task documents.


## Shared context completion release

The 2026-10-06 completion rollout uses merged PR22 (`74e9d1d`) dashboard digest `sha256:d893984ed1495ac9d468ae1687353dc5032727933ebe7aaab0dc160c57864084` for both migration and Deployment. CNPG retains the already-deployed PostgreSQL 18.6 / pg_textsearch 1.5.1 image. Schema 5 and the mobile evidence-link fix are live; all six shared-context implementation tasks passed their delivery checks. See [final acceptance](../verification.md#shared-context-final-acceptance-pr22-2026-10-06).
