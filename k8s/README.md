# k8s/

Kustomize manifests for agentboard.

| Path | Purpose |
| --- | --- |
| `base/` | Namespace, ConfigMap, CloudNativePG Cluster, dashboard Deployment/Service, migration Job |
| `overlays/example/` | Starting point for your cluster: image, hostname, Gateway API route (placeholders) |
| `components/external-postgres/` | Optional: your own PostgreSQL instead of CNPG |
| `components/mattermost/` | Optional: Mattermost Team Edition on the CNPG cluster |
| `overlays/farm01/` | The maintainers' deployment ([reference](../docs/deploy/reference-farm01.md)) |

Secrets are never stored here. Create them before the first apply: `agentboard-db-credentials` (`username`, `password`), `agentboard-app` (`secret-key-base`, optional `database-url`), optionally `agentboard-registry` (image pull), and `mattermost-db-credentials` for the Mattermost component. CNPG creates `agentboard-db-ca`; with your own PostgreSQL you create it.

```bash
cp -r k8s/overlays/example k8s/overlays/mycluster   # edit the placeholders
kubectl kustomize k8s/overlays/mycluster             # review
kubectl apply -k k8s/overlays/mycluster
```

Walkthrough (secrets, ingress and stream timeouts, upgrades): [Kubernetes guide](../docs/setup/kubernetes.md). Mattermost: [guide](../docs/setup/mattermost.md). Release and image rules: [release process](../docs/release.md).
