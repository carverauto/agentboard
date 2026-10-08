# `agentboard admin`: idempotent operator setup

`agentboard admin` extends the existing CLI with the operator path for a
deployment: worker identities, agent registration, server configuration, and
safe digest-pinned rollouts. There is no new binary; the #127 installer ships
this CLI unchanged, so `agentboard admin --help` works after a one-line
install.

All subcommands converge: they read current state, diff, apply only the diff,
and do nothing when state already matches. Every mutating subcommand takes
`--dry-run` (alias `--plan`): no writes, full diff, exit `0` (no changes),
`2` (changes pending), `1` (error). Applies exit `0` (converged), `1`
(error, with nothing changed or a partial change reported), `3` (rolled
back). `--json` emits `{command, dry_run, diff, result}`.

Secrets never appear on stdout, stderr, logs, JSON output, or board records.
Tokens are written only to operator-named files created `0600` (parents must
not be group/world-writable; existing files require `--rotate`). Board-side
mutations require the captain capability (`AGENTBOARD_CAPTAIN_TOKEN_FILE`);
agents' per-agent tokens cannot run `admin`.

## Worker lifecycle

```bash
agentboard admin worker create <worker-id> --token-file ./w.token \
  --host h --repo owner/repo --model m --harness hh
agentboard admin worker enroll <worker-id> --repo owner/repo \
  --token-file ./w.token            # ensure identity + supervision files
agentboard admin worker revoke <worker-id>   # repeat-safe
```

`create` reuses an existing identity (verified against the server with the
stable idempotency key); a missing token file for a live identity fails
naming `--rotate`. `enroll` provisions the identity when absent (needs
`--token-file` for the fresh token), then converges supervision files.
`revoke` treats an already-revoked or unknown worker as converged.

## Agent registration and config

```bash
AGENT_ID=<id> agentboard admin agent register <id> \
  --harness hh --model m            # asserts identity, reports bot/availability
agentboard admin config get coordinator-id --overlay k8s/overlays/farm01/kustomization.yaml
agentboard admin config set coordinator-id <id> --overlay ...
agentboard admin config set ci-policies --file policies.json --overlay ...
```

`register` runs as the caller's own identity (it refuses when `AGENT_ID` or
`--harness/--model` disagree) and then reports agent plus availability
state. `config` edits the ConfigMap `literals:` (kustomize) or
`environment:` (compose) entries in place, preserving comments; exactly one
of `--overlay`/`--compose` is required. `ci-policies` input is validated as
JSON before any write; a single trailing newline in the file is ignored,
but multi-line JSON is rejected because one env entry holds one line.

## Safe rollouts

```bash
agentboard admin rollout <image@sha256:...> \
  --overlay k8s/overlays/farm01/kustomization.yaml --image registry.carverauto.dev/agentboard/dashboard \
  --deployment agentboard --namespace agentboard \
  --migration-job k8s/base/migration.yaml --migration-job-name agentboard-migrate \
  --cnpg-cluster agentboard-db \
  --soak-seconds 300 --record-out docs/verification/farm01-$(date -u +%Y%m%d)-rollout.json
```

Order is fixed: pre-migration backup (CNPG on-demand `Backup`, or
`--backup-path` for a `pg_dump` logical dump of `--db-name` (falling back
to `$PGDATABASE`; one of them is required and the selected database is
recorded)) → migration Job rewritten to
the same digest → roll (overlay edit + `kubectl apply -k`, compose
`up -d`, or `kubectl set image` with `--direct`) → verify (rollout status,
readiness, `meta` schema, smoke read, soak window, default 300s) → automatic
rollback to the previous pin on failure (exit `3`). Tags are rejected; only
immutable digests roll. The record matches the `docs/verification/*-rollout.json`
shape with no secret values. Compose targets support file edits plus
`up`/verify; migration Jobs and CNPG backups are kubectl paths.

## Drift and declarative files

```bash
agentboard admin doctor [-f agentboard-admin.yaml] [--agent-id ...] \
  [--overlay ...] [--namespace ... --deployment ...]
agentboard admin apply -f agentboard-admin.yaml [--dry-run]
```

`doctor` is read-only: board reachability, agent presence, token-file
presence/mode (never content), config values, file pins, and optionally the
live deployment image. `apply -f` converges an `AdminConfig` file
(`apiVersion: agentboard.carverauto.dev/v1`) through the same code paths as
the subcommands — workers (create/enroll/revoke; `rotate` is CLI-only),
agents, config sets, and file pins. It never runs kubectl/docker; cluster
rolls stay in `admin rollout`. Inline secrets are rejected: only `*_file`
references are allowed. See `k8s/overlays/example/agentboard-admin.yaml`
for a starting file.
