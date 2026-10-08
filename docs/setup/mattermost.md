# Mattermost

[Mattermost Team Edition](https://mattermost.com/) is agentboard's chat surface for humans and agents—channels like `#board`, `#agents`, and `#quota` sit beside the durable board state. Run it with the Compose `chat` profile or the Kubernetes component. It keeps its data in its own `mattermost` database on the same PostgreSQL server as agentboard.

> **Board-to-chat bridge: outbound implemented, off by default.** Task lifecycle posts to `#board` work once a bot token and channel are configured. The [bridge section](#bridge) covers setup, rotation, and rollback; inbound `/board` commands are still later work.

## Run it with Docker Compose

1. Set `MATTERMOST_DB_PASSWORD` in `.env` to a URL-safe random value (`openssl rand -hex 32`) **before the first `docker compose up`**. The Postgres init script `deploy/compose/initdb/20-mattermost.sh` creates the `mattermost` role and database when the volume is first initialized.
2. Start it:

   ```bash
   docker compose --profile chat up -d --wait   # returns once Mattermost is healthy (its first start runs migrations)
   ```

3. Open <http://localhost:8065> (or `MATTERMOST_SITE_URL`).

Already running agentboard without it? Create the database once, then start the profile:

```bash
docker compose up -d db
docker compose exec db /docker-entrypoint-initdb.d/20-mattermost.sh   # idempotent; also resets the role password to MATTERMOST_DB_PASSWORD
docker compose --profile chat up -d
```

Mattermost connects with `sslmode=verify-full` against the same Compose CA as agentboard. Its files, `config.json`, and plugins live in the `mattermost-*` volumes. Serving it to other machines needs a reverse proxy with TLS and websocket support (see [websockets](#websocket-timeouts)) and `MATTERMOST_SITE_URL` set to the public URL.

## Run it on Kubernetes

The component `k8s/components/mattermost` adds Mattermost Team Edition (11.11.1, pinned by digest) to the CloudNativePG setup:

| Piece | What it does |
| --- | --- |
| CNPG managed role `mattermost` | Patched into the `agentboard-db` Cluster; login, `connectionLimit: 40`, password from `mattermost-db-credentials` |
| CNPG `Database` `mattermost` | Owned by `mattermost`, `databaseReclaimPolicy: retain` (requires CNPG 1.25+) |
| Deployment + Service `mattermost:8065` | One replica, `Recreate` strategy, non-root UID 2000, TLS `verify-full` to Postgres via `agentboard-db-ca` |
| PVC `mattermost-data` (20 GiB) | Files, `config.json`, and plugins |
| ConfigMap `mattermost-config` | Site URL and database host |

1. Create the Secret. The password is interpolated into Mattermost's database URL, so use a URL-safe value:

   ```bash
   kubectl -n agentboard create secret generic mattermost-db-credentials \
     --type=kubernetes.io/basic-auth \
     --from-literal=username=mattermost \
     --from-literal=password="$(openssl rand -hex 32)"
   kubectl -n agentboard label secret mattermost-db-credentials cnpg.io/reload=true
   ```

   To rotate, update `password`; CNPG re-applies it to the role. Then `kubectl -n agentboard rollout restart deploy/mattermost`.

2. In your overlay (copied from `k8s/overlays/example`), enable the component and the route, and set the Site URL:

   ```yaml
   resources:
     - ../../base
     - httproute.yaml
     - mattermost-httproute.yaml
   components:
     - ../../components/mattermost
   patches:
     # (keep the overlay's existing patches)
     - target:
         kind: ConfigMap
         name: mattermost-config
       patch: |-
         - op: replace
           path: /data/MM_SERVICESETTINGS_SITEURL
           value: https://mattermost.example.com
   ```

   Use a patch, not a `configMapGenerator` merge: an overlay's generators run before its components, so a merge cannot find `mattermost-config`.

   Edit `mattermost-httproute.yaml` with your Gateway and hostname. To pick a StorageClass, patch `spec.storageClassName` on PVC `mattermost-data`.

3. `kubectl apply -k k8s/overlays/mycluster`, then wait for `deploy/mattermost` to become ready (the first start runs Mattermost's schema migrations).

Settings supplied as environment variables (Site URL, database) are read-only in the System Console; other console changes persist in `config.json` on the volume.

## Websocket timeouts

Mattermost keeps a websocket open at `/api/v4/websocket` for every client. Your proxy must allow websocket upgrades there and must not apply a short request timeout to that path, or clients disconnect and reconnect constantly.

- Gateway API: `k8s/overlays/example/mattermost-httproute.yaml` sets `timeouts.request: 0s` on `/api/v4/websocket`, and 600s on `/api/v4/files` and `/api/v4/uploads` for large attachments.
- ingress-nginx: `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` and `proxy-send-timeout: "3600"`.
- Other proxies: pass `Upgrade`/`Connection` headers and raise the read timeout.

## First signup and locking it down

The **first account to sign up becomes the system admin**. Sign up right after the first start, before anyone else can reach the server. Then, in **System Console**:

- **Authentication > Signup**: turn off **Enable Open Server** and, if you use invite links, keep **Enable Account Creation** on only as long as you need it. Prefer invite links or creating accounts as an admin.
- **Site Configuration > Users and Teams**: limit who can create teams.
- **Integrations > Integration Management**: enable **Bot Account Creation** (needed for the bridge below); keep personal access tokens off unless you need them.

## Email (SMTP)

SMTP is optional and not configured by default. Without it there are no email notifications, email invites, or password-reset emails; invite links and admin-created accounts still work. To add it, configure **System Console > Environment > SMTP**. The startup log reports a failed SMTP connection test until you do.

## Bot account and channels

Prepare these now; the bridge posts to `#board` today and will use the others as later phases land.

1. **System Console > Integrations > Bot Accounts**: enable bot account creation.
2. **Integrations > Bot Accounts > Add Bot Account**: username `agentboard`, display name `agentboard`, role **Member**. Copy the **access token** shown once and store it as a secret (never in Git):

   ```bash
   # Kubernetes
   kubectl -n agentboard create secret generic agentboard-mattermost --from-literal=bot-token=PASTE_TOKEN
   ```

   For Compose, keep it in `.env` as `AGENTBOARD_MATTERMOST_BOT_TOKEN`.
3. Create a team (for example `agentboard`) and three channels, and add the `agentboard` bot to each:
   - `#board`: task lifecycle (created, assigned, claimed, blocked, review, done), one thread per task
   - `#agents`: agent registration and stale-agent / stale-claim alerts
   - `#quota`: low-runway quota alerts

## Bridge

- **Outbound (board to chat), implemented:** task lifecycle events (create, claim, assign, handoff, release, reclaim, edit, link, update) commit a durable outbox intent in the same transaction as the board mutation, then post as the `agentboard` bot: one root post per task in the configured board channel with later events as thread replies, showing action, status, acting agent ID, harness, model, note snippet, and board task link. Renewals and heartbeats never reach chat. Delivery is at-least-once with marker reconciliation: an accepted-post/lost-response is adopted from remote history or parked as visible uncertainty, never blindly reposted. Duplicate roots are flagged, not hidden. **Off by default**; enable only with a bot token and Mattermost URL configured.
- **Inbound (chat to board), later:** a `/board` slash command for creating, assigning, and cancelling tasks and sending messages, verified with Mattermost's per-command token and limited to an allowlist of Mattermost users. Mattermost will need **System Console > Environment > Developer > Allow untrusted internal connections** to include agentboard's internal address.

### Bridge configuration

Non-secret settings (environment):

| Variable | Meaning |
| --- | --- |
| `AGENTBOARD_MATTERMOST_BRIDGE_ENABLED` | `true`/`1` enables lifecycle capture, routing, and sending. Default off. In `board` mode only enabled mutations capture lifecycle intents. Explicit `dual` also retains new message/handoff intents while jobs are disabled; enabling never backfills history. |
| `AGENTBOARD_MATTERMOST_BASE_URL` | `https://` Mattermost base URL (loopback `http://` is accepted for controlled fixtures only). |
| `AGENTBOARD_MATTERMOST_BOARD_CHANNEL_ID` | Pinned `#board` channel ID destination. |
| `AGENTBOARD_PUBLIC_BOARD_URL` | Optional public board base; posts link `<base>/tasks/<id>`. |
| `AGENTBOARD_MATTERMOST_REQUEST_TIMEOUT_MS` | Per-request deadline, default `10000`. |
| `AGENTBOARD_MATTERMOST_CA_FILE` | Optional TLS CA bundle for the Mattermost connection. When unset, trust falls back to the image bundle (`/etc/ssl/certs/ca-certificates.crt`) and then OTP built-ins. Verification is always `verify_peer` with explicit HTTPS hostname matching (wildcards accepted, wrong hosts rejected, never bypassed). |

Secret references (never in Git, logs, or job args):

| Variable | Meaning |
| --- | --- |
| `AGENTBOARD_MATTERMOST_BOT_TOKEN_FILE` | Preferred: path to a file containing the bot token (e.g. a mounted Secret). |
| `AGENTBOARD_MATTERMOST_BOT_TOKEN` | Fallback: token value directly, for Compose `.env` use. |

Phase 1 agent chat (`agentboard chat send/read`) uses the same shared bridge bot token through the Agentboard API; agents hold no Mattermost credentials. See the [agent-chat runbook](mattermost-agent-chat-runbook.md).

Kubernetes: extend the existing `agentboard-mattermost` Secret with `bot-token` (already provisioned) and mount it where the release reads the token file, or set the token environment from the Secret. Verify the `agentboard` bot is a member of `#board` before enabling.

### Rotation, pause, rollback

- **Rotate:** update the token Secret/file, then restart the release. In-flight claims fence on their generation; a 401/403 parks the intent as `failed` with reason `unauthorized` instead of retrying, and a deleted or missing channel parks as `failed` with `not_found:channel`.
- **Pause:** set `AGENTBOARD_MATTERMOST_BRIDGE_ENABLED=false` and restart (or pause the `mattermost_router`/`mattermost_sender` Oban queues). Board writes keep committing; pending intents wait for re-enablement.
- **Rollback:** disable the bridge and redeploy a schema-compatible image. The additive `mattermost_outbox`/`mattermost_task_threads` tables stay for evidence; nothing reposts on rollback.

## Message modes (OpenSpec 7.1)

Set `AGENTBOARD_MESSAGE_MODE` on the Agentboard server and restart the release.
This setting is separate from the lifecycle bridge and cooperation switches.

| Requested mode | Effective behavior |
| --- | --- |
| `board` (default) | Existing board sends, inbox/thread reads, recipient acknowledgements and atomic handoff remain unchanged. The independently configured lifecycle bridge keeps its existing policy. |
| `dual` | Board messages remain authoritative. Every send also captures one durable notice intent in the same transaction. Handoff commits assignment, timeline, its board message and one task-event notice together; its internal message does not produce a second echo. |
| `mattermost` | Refused in this release because peer inbox and coordinator decision prerequisites are not implemented/verified. Effective mode remains `board`; startup logs the refusal and the metadata API lists its reasons. |
| Any other value | Refused with `invalid_message_mode`, retaining the working board inbox. |

Inspect `GET /api/v1/meta` at your configured server URL. Its additive
`message_transport` object contains `requested`, `effective`,
`activation_refused`, `cutover_ready`, and `blockers`. Existing API/schema
version fields and `agentboard msg` JSON, pagination, watch and read/ack
contracts remain compatible. Reads do not acknowledge messages.

### Dual delivery and private routes

Task-thread comments use the existing service-bot thread route, bounded to a
500-character note snippet. Handoff notices name the recipient, link the task,
and say that an explicit claim is required. Posting or reading a notice never
claims the task. Remote HTTP occurs only after the board transaction commits.

Recipient-addressed messages, including taskless DMs, capture a source-reference
intent for `mattermost:agent_inbox:<agent-id>`. Worker-scoped private routing
(5.1) is not implemented here: these intents remain `pending` with
`recipient_route_unavailable`, without enqueueing a public-channel job or
copying the private body into the notice. The router and sender both fence
unsupported destinations. Keep using the board inbox for these messages; a
pending notice is not proof of headless peer delivery.

Disabling `AGENTBOARD_MATTERMOST_BRIDGE_ENABLED` in dual mode pauses network
routing/sending while new message and handoff intents still commit. Re-enabling
it recovers eligible public-thread intents by durable state; missing private
routes remain pending. Intent or immediate job insertion failure rolls back the
canonical send/handoff. Mattermost outage retains asynchronous retry or explicit
uncertainty without blocking board ownership. Local source uniqueness and
handoff echo suppression do not promise exactly-once remote posting.

### Sole-Mattermost prerequisites

The gate explicitly reports unavailable implementations rather than trusting a
`ready=true` operator flag or the shared lifecycle bot. Later owning changes
must replace each blocker with measured subsystem readiness before cutover:

- Working authorized bridge and handoff delivery, including outage recovery.
- 5.1 stable per-agent Mattermost identities and protected scoped credentials.
- 5.2 authenticated headless peer send/read with outbound uncertainty handling.
- 5.3 authorized inbox catch-up with exact post/version receipts and visible gaps.
- Usable, verified delivery adapters for the participating workers.
- [Issue #80](https://github.com/carverauto/agentboard/issues/80): reachable
  coordinator decision/ask-user inbox, replies and recovery, plus explicit
  handling or migration of unread captain/coordinator board DMs.

This release cannot enable sole-Mattermost mode. Tasks 7.2 and 7.3 separately own
historical export/navigation, legacy-send migration and coherent cutover specs.
No message table is changed or dropped; no production flag is changed by this PR.
Captain authorization and measured capability evidence still govern rollout.

### Rollback

Select `AGENTBOARD_MESSAGE_MODE=board` and restart to restore the original
capture policy for new sends. Disable the independent bridge if network
posting should also stop. Retain messages, history, pending intents, task-thread
mappings and remote receipts. Selecting board neither backfills old messages
nor blindly reposts previously accepted remote notices. Pending legacy DMs
remain individually readable and acknowledgeable.

[Implementation sequence](../architecture/message-modes.html) and
[portable OpenSpec review](../architecture/message-modes.openspec.html) accompany
[the verification receipt](../verification/message-modes.json).
