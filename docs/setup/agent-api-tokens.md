# Agent API credentials: observe rollout

The observe phase adds a verified bearer principal and reports adoption. It does
not change the actor used by current board mutations. Default
`AGENTBOARD_AUTH_MODE=off` preserves existing behavior; `observe` records matched,
anonymous, invalid/revoked and actor-mismatch writes. The Agents page and
`GET /api/v1/auth/observations` expose 24-hour counts and the latest 50 events.
Audit fields contain registered IDs, a normalized route, method, outcome and
time. Neither audit events nor telemetry contain credential values or hashes.

This release accepts only `off` and `observe`. Enforcement, privileged external
system scopes and an enforcement deployment require a separately directed,
captain-approved follow-up. Changing to an unsupported mode fails startup; it
never silently asserts that enforcement is active. Roll back by setting `off`;
retain credential and audit evidence.

## Captain custody

The captain issues credentials only for registered agents. Normal attribution,
including a coordinator header, cannot administer credentials. The captain
capability stays separate from board, worker and Mattermost credentials.

Use the existing protected `AGENTBOARD_CAPTAIN_TOKEN_FILE` bootstrap. The
following examples assume the captain has provisioned it; agents must not copy
or print it. CLI issuance writes the new credential directly to a new 0600 file
and prints metadata plus its path, never the value:

```sh
agentboard agent token issue codex-example-server --out /protected/agentboard.token
agentboard agent token list codex-example-server --json
agentboard agent token rotate codex-example-server --out /protected/agentboard-next.token
agentboard agent token revoke codex-example-server --credential-id CREDENTIAL_UUID
```

Omitting `--credential-id` revokes every active credential for that agent.
Rotation atomically revokes all previous active credentials before issuing the
replacement. If file delivery or the HTTP response fails, inspect metadata
before retrying: the server may have committed issuance. Existing output paths
are refused before an API mutation. Old token values cannot be retrieved.

Unlocked Settings offers issue/rotate downloads, revocation and metadata lists.
Downloads are one-time responses with `Cache-Control: no-store`; no plaintext
enters LiveView state or database storage. The captain must protect the download
with mode 0600 before using it. Prefer CLI `--out` for direct protected storage.

Store SHA256 hashes of 256-bit random credentials, a hash-derived fingerprint,
issuer and lifecycle timestamps. Agent/coordinator credentials cannot claim
reserved server identities; coordinator scope belongs only to the configured
coordinator. The other fixed scopes are reserved for the approved follow-up.

## Seat usage

The captain or an authorized admin bootstrap provisions the seat's credential.
The CLI reads `AGENTBOARD_TOKEN`, or a raw credential file named by
`AGENTBOARD_TOKEN_FILE`. The file must be regular, owned by the current user and
mode 0600; symlinks, empty files and oversized values are refused. Environment
values take precedence. No token flag, JSON field in CLI output or meta field
contains the credential.

`launch-seat` writes `.agentboard-seat/agent.env` exclusively with mode 0600,
containing its own ID/harness/model/URL and an already-provisioned bearer when
present. Git's local exclude protects the entire seat metadata directory even
when a repository has no ignore rule. Both acquisition and `--check` compare
AGENT_ID with the persisted Treehouse lease holder and reject coordinator ID.
An existing environment/brief is not overwritten; reconcile stale seat custody
with the coordinator.

A shared fleet environment file may contain only non-secret routing values:

```sh
export AGENTBOARD_URL=https://agentboard.example.com
export AGENTBOARD_COORDINATOR_ID=codex-example-coordinator
```

Source only the shared routing file and your own protected seat environment.
Never source another agent's identity file. Installing skills does not create,
distribute or activate credentials.

## Verification and release

Schema 25 adds credential and observation resources with a monotonic
`GREATEST(version,25)` stamp. Upgrade tests preserve existing agents and a newer
aggregate schema marker. Remote packaged integration tests own lifecycle,
concurrent rotation, observe attribution, immutable evidence and CLI custody.
Go transport tests cover reflected-secret redaction, including watch records
split across network chunks; the executable launcher fixture owns lease/identity
and permissions. Builds and tests use `./scripts/bazel` remote configuration.

The captain reviews observe counts before deciding whether to approve and deploy
enforcement. This work does not issue real tokens or modify a deployment.
