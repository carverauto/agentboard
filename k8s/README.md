# k8s/

Kustomize layout for agentboard on farm01.

| Path | Purpose |
| --- | --- |
| `base/` | Namespace, CNPG Cluster, ConfigMap, dashboard Deployment/Service, migration Job, Mattermost (`mattermost.yaml`) |
| `overlays/farm01/` | farm01 storage class, immutable image selection, HTTPRoutes to `farm01-gateway` (`httproute.yaml`, `mattermost-httproute.yaml`) |

Secrets (`agentboard-db-credentials`, `agentboard-app`, `mattermost-db-credentials`, registry pull) are **not** in git.
Create them out-of-band before the first sync (see root README Deploy section).

Apply (captain / gitops only):

```bash
kubectl kustomize k8s/overlays/farm01
# Prefer Argo CD Application pointing at this overlay; do not apply from a gate worktree.
```

[Release/rollout guide](../docs/release.md) covers the shared app/migration digest, CNPG CA mount, companion GitOps edge and current missing storage prerequisite. The checked-in image reference must be published before deployment.

## Mattermost

Mattermost Team Edition (`mattermost/mattermost-team-edition:11.11.1`, pinned by index digest) is the chat surface for the captain and the agent fleet. It runs in namespace `agentboard` as a single-replica Deployment (`Recreate`), Service `mattermost:8065` and PVC `mattermost-data`.

| Piece | Where |
| --- | --- |
| Role `mattermost` (login, `connectionLimit: 40`) | `base/cnpg.yaml` `spec.managed.roles` on the existing `agentboard-db` Cluster |
| Database `mattermost` owned by `mattermost` | `base/mattermost.yaml` CNPG `Database` CR (CNPG 1.25+), `databaseReclaimPolicy: retain` |
| Files, `config.json`, plugins | PVC `mattermost-data` (20Gi, farm01 overlay: `local-path-cnpg`, Retain) |
| Site URL, DB host | `mattermost-config` ConfigMap, merged by the farm01 overlay |
| Route | `overlays/farm01/mattermost-httproute.yaml`: `https://mattermost.k8s-farm.carverauto.dev` |

DB access uses TLS `verify-full` against CNPG's `agentboard-db-ca`, the same as the dashboard. The pool is capped at 20 open connections (`agentboard-db` has `max_connections: 100`). Configuration changes made through the System Console persist in `config.json` on the PVC. Settings supplied by environment variables (Site URL, SQL) are locked in the console.

The route uses the shared wildcard listeners `https`/`http` (`*.k8s-farm.carverauto.dev`, `farm01-wildcard-tls`, existing wildcard DNS), so no GitOps edge change is needed. `/api/v4/websocket` disables the Gateway request timeout (same approach as the agentboard watch paths); `/api/v4/files` and `/api/v4/uploads` allow 600s. Moving to `mattermost.farm01.carverauto.dev` needs a companion GitOps edge change like [carverauto/gitops#152](https://github.com/carverauto/gitops/pull/152) (exact-host listeners and Certificate, DNS01 solver, external-dns filter). After that, update the route's `sectionName`/`hostnames` and `MM_SERVICESETTINGS_SITEURL`.

### Out-of-band Secret

`mattermost-db-credentials` (type `kubernetes.io/basic-auth`, label `cnpg.io/reload=true`):

| Key | Value |
| --- | --- |
| `username` | `mattermost` |
| `password` | Random URL-safe value (for example 64 hex chars). The Deployment interpolates it into the Postgres DSN, so it must not need URL escaping. |

CNPG sets the role password from this Secret. Create it before the role is reconciled, and never print or commit it:

```bash
umask 077; d=$(mktemp -d); printf mattermost > "$d/username"; openssl rand -hex 32 | tr -d '\n' > "$d/password"
kubectl -n agentboard create secret generic mattermost-db-credentials --type=kubernetes.io/basic-auth \
  --from-file=username="$d/username" --from-file=password="$d/password"
rm -rf "$d"; kubectl -n agentboard label secret mattermost-db-credentials cnpg.io/reload=true app.kubernetes.io/name=mattermost
```

To rotate it, update the Secret's `password`. CNPG re-applies the role password. Then restart `deploy/mattermost`.

### First signup

The first account to sign up becomes the system admin. Sign up right after a fresh deploy, then review **System Console > Signup** (open server, invite-only). SMTP is not configured, so email notifications and invites by email are unavailable until it is.
