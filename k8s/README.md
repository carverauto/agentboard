# k8s/

Kustomize layout for agentboard on farm01.

| Path | Purpose |
| --- | --- |
| `base/` | Namespace, CNPG Cluster, ConfigMap, dashboard Deployment/Service, migration Job |
| `overlays/farm01/` | farm01 storage class, image tags, HTTPRoute to `farm01-gateway` |

Secrets (`agentboard-db-credentials`, `agentboard-app`, registry pull) are **not** in git.
Create them out-of-band before the first sync (see root README Deploy section).

Apply (captain / gitops only):

```bash
kubectl kustomize k8s/overlays/farm01
# Prefer Argo CD Application pointing at this overlay; do not apply from a gate worktree.
```
