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

### Coordinator scopes

The existing `coordinator` credential scope is read-only under enforce. It is
bound to `AGENTBOARD_COORDINATOR_ID` and permits explicit task, PR, agent and
decision reads plus its own inbox and task/message watches. It does not allow
registration, heartbeats, acknowledgments, assignment, decision answers,
conversation reads/sends, quota or context writes, worker operations or captain
administration. Some GET operations change state, so the policy uses controller
operations rather than an HTTP-method wildcard. Token last-use/audit metadata
and server housekeeping are not caller-authorized board mutations.

Schema 39 adds the separate, explicitly requested `coordinator_participant`
scope. Default issuance for the configured coordinator still selects
`coordinator`; existing credentials are not promoted. A participant credential
requires an immutable `channel_ids` grant of 1–20 distinct channel IDs. Each ID
is 1–128 ASCII letters, digits, underscores or hyphens. Empty, duplicate or
malformed grants are rejected; `agent` and `coordinator` scopes reject nonempty
grants. Changing the grant requires a new issue/rotation, not an in-place edit.

Under enforce, a participant retains the coordinator's allowed reads and adds:

- Its own heartbeat, accepting only `status` and `task` with the existing
  busy/idle and owned-task checks. `backend`, profile/registration changes,
  availability and quota writes remain forbidden; heartbeat never renews a lease.
- Explicit acknowledgment of board messages addressed to itself. List/show
  recipient isolation and immutable first-handled attribution remain enforced.
- Generic chat send/read and its own coverage in a granted channel, intersected
  with the current global channel policy and verified shared-bot membership.
  An empty global allowlist never widens the credential's nonempty grant.
  Diagnostics expose only its own non-secret bot/override status, not channel
  discovery or another identity's history.
- The typed decision reply, receipt read and explicit reconciliation described
  in [coordinator decision round-trip](coordinator-message-roundtrip.md).

All unlisted operations remain denied, including task create/claim/renew/update,
assignment/handoff, decision request/answer/recommend/supersede/ack, context and
settings writes, credential administration and worker administration. The
participant bearer cannot fetch or acknowledge protected worker sources; those
still require separately provisioned, current worker receipt capabilities.
Conversely, a worker receipt is not a general chat credential. Canonical decision
answering remains captain-only. Do not distribute a captain capability to make
an ordinary participant operation work.

Coordinator identity changes invalidate credentials with either scope binding.
Agent credentials cannot retain write access after their identity becomes the
configured coordinator. Retired and reserved identities cannot authenticate.

Every typed decision-conversation endpoint additionally requires
`AGENTBOARD_AUTH_MODE=enforce` and an actually presented, verified bearer.
`off` and `observe` fail closed for those endpoints; their legacy endpoint
behavior is unchanged. Installing this release never changes the auth mode.

### Enrollment and revocation

Schema 40 adds the separately and explicitly issued `coordinator_runner` scope
for [coordinator attention revision 1](../coordinator/protocol.md). It accepts no
channel grants and adds no permissions to existing coordinator or participant
tokens. Its entire protected allowlist is non-consuming tick, exact decision
source read, append-only handling ack and own bounded heartbeat, all through
the dedicated `/api/v1/coordinator` surface in enforce mode. It does not inherit
chat, task mutations, decision answers or captain/worker operations. Default
coordinator issuance remains `coordinator`; production provisioning and identity
handoff require separate explicit authorization.

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

Only after separate operator approval of participant identity and channel scope,
the captain can explicitly issue a participant credential (schema 39):

```sh
agentboard agent token issue "$AGENTBOARD_COORDINATOR_ID" \
  --scope coordinator_participant --channel APPROVED_CHANNEL_ID \
  --out /protected/coordinator-participant.token
```

Repeat `--channel` for additional approved channels. Rotation uses the same
explicit `--scope coordinator_participant` and complete `--channel` grant with a
new `--out` path. Omitting the scope does not preserve participant scope: the
configured coordinator's default remains read-only `coordinator`. Metadata
lists include `channel_ids`, never the credential or its hash. Issuance alone
does not configure the typed route, enroll a worker, activate inbound delivery,
or establish native wake support.

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
reserved server identities; both coordinator scopes belong only to the configured
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

Schema 39 adds immutable participant channel grants and metadata-only decision
conversation intents. It preserves old credentials, board messages and uncertain
remote-send evidence. Its CLI refuses older schemas without attempting issuance
or a typed conversation mutation. See the [round-trip runbook](coordinator-message-roundtrip.md)
for routing, separate capability custody, exact source handling and rollback.

The operator reviews adoption, provisions credentials and explicitly enables enforcement. Installing the code does not issue real credentials or change a deployment.
