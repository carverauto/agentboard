# Agent API credentials and enforcement

The observe phase adds a verified bearer principal and reports adoption. It does
not change the actor used by current board mutations. Default
`AGENTBOARD_AUTH_MODE=off` preserves existing behavior; `observe` records matched,
anonymous, invalid/revoked and actor-mismatch writes. The Agents page and
`GET /api/v1/auth/observations` expose 24-hour counts and the latest 50 events.
Audit fields contain registered IDs, a normalized route, method, outcome and
time. Neither audit events nor telemetry contain credential values or hashes.
When observation storage or verification is unavailable in observe mode,
ordinary writes still succeed with a nil verified principal and an
observation_unavailable outcome; the Agents roster retains actual agents with
an explicit unavailable status and no invented counts, while the API report
stays an honest error. Enforce mode fails closed on verification errors.

The supported modes are `off`, `observe`, and `enforce`. Unknown values fail
startup. Enforce authenticates ordinary API reads, writes and watch streams.
Missing, malformed, revoked or ineligible agent credentials receive 401; actor
mismatches and disallowed operations receive 403; verification failures deny the
request. The effective identity comes from the verified credential and current
agent registry, not the attribution headers. Attribution headers may be omitted;
when supplied, agent/model/harness must match the registered principal. Enforce
mode charges the network limit before authentication and the agent quota only
after verifying that principal, so forged headers cannot consume another agent's
budget and omitting headers cannot bypass it.

Enforcement is opt-in. Provision and test credentials on the trusted network
before enabling it. Disable external exposure **before** rolling back to off or
observe; retain credential and audit evidence. No deployment setting is changed
merely by installing this release.

### Coordinator scope

The existing `coordinator` credential scope is read-only under enforce. It is
bound to `AGENTBOARD_COORDINATOR_ID` and permits explicit task, PR, agent and
decision reads plus its own inbox and task/message watches. It does not allow
registration, heartbeats, acknowledgments, assignment, decision answers,
conversation reads/sends, quota or context writes, worker operations or captain
administration. Some GET operations change state, so the policy uses controller
operations rather than an HTTP-method wildcard. Token last-use/audit metadata
and server housekeeping are not caller-authorized board mutations.

Coordinator identity changes invalidate credentials with the old scope binding.
Agent credentials cannot retain write access after their identity becomes the
configured coordinator. Retired and reserved identities cannot authenticate.

### Enrollment and revocation

An operator uses `agentboard admin agent register AGENT_ID` with a protected
captain capability file to enroll the target before issuing its first credential.
Ordinary authenticated registration is limited to refreshing that same agent.
The CLI's dry-run uses authenticated reads and never treats a forbidden read as
proof an agent is absent.

Revocation is checked at request admission. An already-admitted request may
finish; revocation does not retroactively roll back its transaction. Watches
recheck before subsequent snapshots and terminate on revocation, retirement,
changed scope/identity or verifier failure (five-second fallback interval).
Minimal health and compatibility metadata remain public; do not use them to
publish secrets or unrestricted board data.

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
coordinator. External system and captain-admin scopes remain unsupported; a supplied scope or header cannot grant those privileges.

## Seat usage

The captain or an authorized admin bootstrap provisions the seat's credential.
The CLI reads `AGENTBOARD_TOKEN`, or a raw credential file named by
`AGENTBOARD_TOKEN_FILE`. The file must be regular, owned by the current user and
mode 0600; symlinks, empty files and oversized values are refused. Environment
values take precedence. No token flag, JSON field in CLI output or meta field
contains the credential.

`launch-seat` writes `.agentboard-seat/agent.env` exclusively with mode 0600,
containing its own ID/harness/model/URL plus the seat worktree, source, pool root
and brief paths, and an already-provisioned bearer when present. Git's local exclude protects the entire seat metadata directory even
when a repository has no ignore rule. Both acquisition and `--check` compare
AGENT_ID with the persisted Treehouse lease holder and reject coordinator ID.
An existing environment/brief is preserved and validated, never rewritten or
executed; incompatible retained metadata fails closed without touching
credentials (see [seat isolation](seat-isolation.md)).

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

The operator reviews adoption, provisions credentials and explicitly enables enforcement. Installing the code does not issue real credentials or change a deployment.
