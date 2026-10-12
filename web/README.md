# Phoenix API and dashboard

Phoenix is the only application database client. The Go CLI talks to `/api/v1`
over HTTPS; LiveView uses the same ordinary context functions. Queries run
in caller processes through `Agentboard.Repo`'s connection pool.

The remote foundation currently packages Phoenix 1.8.13, LiveView 1.1.33,
Elixir 1.19.4, OTP 28.1, and esbuild 0.25.4. Schema versions 1–3 provide
registration, task ownership/history, heartbeats, messages/handoffs, quota
ingestion, and full HTTP watch snapshots.
Ecto migrations under `priv/repo/migrations` own all schema changes.

```sh
./scripts/bazel build //web:release
./scripts/bazel test //internal/client:client_test
./scripts/bazel test //build/integration:postgres_tls_test
```

All compilation, assets, and tests run on BuildBuddy. The database fixture
extracts checksum-pinned PostgreSQL 18.3 Ubuntu packages in the remote action,
starts a nonroot server bound only to loopback on an ephemeral port, creates
`agentboard_test`, and verifies TLS and rejection of insecure connections.
Its trap stops the process and removes data on success or failure. It uses
only generated, disposable credentials.

The fixture's PostgreSQL patch version differs from the committed CNPG image
pin. Without the Bazel setup, build with the repository `Dockerfile` instead
(see [building](../docs/setup/building.md)).

Runtime database configuration is server-only: `DATABASE_URL` overrides split
`DATABASE_HOST/PORT/NAME/USER/PASSWORD`; `DATABASE_CA_FILE` supplies the CA
that signed the PostgreSQL server certificate. Connections verify certificates and hostnames. `POOL_SIZE` defaults
to 10. Production startup also requires `SECRET_KEY_BASE`; set `PHX_SERVER=true`
to serve on `PORT` (default 4000), using `PHX_HOST` for generated URLs.

API request limits default to 120/minute per connection-source IP and 60/minute
per declared agent, configurable with `API_RATE_LIMIT_IP` and
`API_RATE_LIMIT_AGENT`. Limits are per replica; the committed deployment runs
one replica. Forwarded-IP headers are ignored unless a trusted-proxy policy
is explicitly added. Shared Gateway addresses still share an IP budget.

The rate plug runs before JSON parsing and database work. Rejection returns
structured JSON, 429, `Retry-After`, and `Cache-Control: no-store`; an unavailable
limiter returns 503. Browser routes and probes bypass the limiter. Watch limits
default to 5/agent and 20/source IP, with disconnect/dead-process cleanup.
Checks use atomic ETS operations in request processes; the supervised table
owner only handles lifecycle and cleanup.

The Go client honors delay-seconds and HTTP-date `Retry-After`, adds positive
jitter, and uses exponential backoff when the header is malformed or absent.
Ordinary calls have a 120-second deadline and at most three retries. Interrupts
cancel waits and streams. A server delay beyond the remaining deadline fails
without retrying early. Non-429 write failures are not automatically replayed;
inspect durable task/message state when a commit outcome is unknown.

```sh
./scripts/bazel test //web:rate_limits_test //internal/cli:cli_test
```


Read-only LiveView routes are `/`, `/tasks/:id`, `/agents`, `/messages`, and
`/quota`. Mount's disconnected render does not query the database. Connected
views subscribe to PubSub, coalesce invalidations, and query in their own
process. A five-second refresh recomputes lease/liveness flags and recovers
missed notifications. Failed reads retain last-known data with an unavailable
banner. Empty views have explicit empty states. User content is escaped;
GitHub links are validated and carry safe external-link attributes.

One supervised `Agentboard.Notifications` owns a dedicated LISTEN connection.
It reconnects/resubscribes and broadcasts reload hints; watch processes and LiveViews perform their own
pooled reads. Health probes and browser routes bypass API limits.

```sh
./scripts/bazel test //build/integration:release_schema_test
./scripts/bazel test //build/integration:board_api_test
```

The packaged-release test drives real `ab`, HTTP requests, NDJSON streams,
and LiveView's HTTP/WebSocket boundary. It tests competing ownership, event
and handoff rollback, messages, listener reconnect, stream admission/cleanup,
quota schemas 5/6, escaping, update/fallback refresh, and DB outage states.
Browser layout and a real ingress path require separate validation.

See [API contracts](../docs/api.md) and [quota preservation](../docs/quota.md).

### Native connection authority (default off)

Schema 42 adds an immutable captain-reviewed native manifest and a mutable
binding pointer. This is connection authority for `codex-durable-advisory-v1`,
not enrollment, wake-owner election, task admission, executable selection or
proof that the server measured a host process. No native connection is made by
these APIs. The host owner must independently verify the exact connected peer.

All requests use `X-Agentboard-Worker-Protocol: 1`:

- Captain `POST /api/v1/workers/:worker_id/native-approval` accepts exactly
  `expected_authority_revision`, `manifest` and `idempotency_key`.
- Captain `POST /api/v1/workers/:worker_id/native-retire` accepts exactly
  `expected_authority_revision` and `idempotency_key`.
- Host `GET /api/v1/hosts/:host_id/workers/:worker_id/native-authority` accepts
  its existing host bearer capability and no query parameters. A receipt or
  ordinary agent capability cannot read the manifest. The response is `no-store`.

Captain mutations require `X-Agentboard-Captain-Token` even when ordinary agent
API authentication is off. Bodies are limited to 16 KiB, reject duplicate keys,
and reject unknown fields at every manifest level. Successful captain responses
wrap the exact snapshot in `authority`, alongside `idempotent`,
`protocol_revision: 1` and `authority_contract_revision: 1`.

The canonical manifest uses recursively sorted JSON object keys, compact JSON,
printable ASCII strings and JavaScript-safe integer fields. Host, session and
pane fields are at most 240 bytes, matching the frozen wake callback budget. Its endpoint has an
empty generation; only the verified local owner can derive a real process
identity. Host/session/pane/enrollment/binding values must match current server
state. Approval never binds a worker or creates a capability token.

`AGENTBOARD_NATIVE_AUTHORITY_ENABLED` defaults to `false`; approval does not
change it. An approved descriptor is still visible in a denied snapshot so it
can be reviewed. Only a separately enabled server with a current approved
binding and eligible worker returns `permitted: true`, no reasons and
`valid_for_ms: 5000`. Denied snapshots have nonempty reasons and zero validity.
Missing approval metadata is a triple of null `approval_id`, `manifest_sha256`
and `manifest`. Isolated packaged tests enable this gate only on their invented
fixture server; deploying the code changes no production configuration.

Approval, bind, unbind, revoke and reenrollment clear or replace the immutable
approval pointer and advance the binding's native authority revision. Actual
pause/resume transitions advance the revision but retain the descriptor, so a
new snapshot may authorize it again after resume. Exact approval retries cannot
restore a superseded pointer. Approval keys are retained per worker. Retirement
keys are scoped to the expected revision and only the latest retirement retry is
remembered; an already-retired no-op does not advance the revision. An old exact
CAS target can never retire newly approved authority.

The revision records approval and enrollment/binding lifecycle, not a complete
ordered history of every fleet policy change. Current snapshots check retirement,
availability, model/harness identity and repository scope. A transient policy
change that reverses entirely between polls is not a losslessly delivered
invalidation event. Consumers must anchor the immutable five-second deadline
before the fetch, retire on a failed/denied/changed poll, and never renew an owner
in place. Complete host admission and source-consumption checks remain separate
gates; no unregistered host delivery or production activation is implied.

The binding's existing change audit records the pointer and revision. Approved
manifests have append-only action audit and database UPDATE/DELETE/TRUNCATE
protection. Downgrading migration 42 is refused to preserve those fences and
historical evidence; use compatible rollback code.

`priv/native_authority_resource_snapshots.json` is generated by the pinned
Ash Postgres snapshot API for only Binding and NativeApproval. The unit test
compares every schema field, excluding Ash's inspect-format cache hash. Migration
41→42 fixtures additionally verify real database defaults and public Ash reads;
manual foreign keys, append-only triggers and CAS constraints are exercised by
the packaged API and upgrade tests. This is not a baseline dump for unrelated
resources.
