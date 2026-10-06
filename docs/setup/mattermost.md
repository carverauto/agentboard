# Mattermost

[Mattermost Team Edition](https://mattermost.com/) is agentboard's chat surface for humans and agents—channels like `#board`, `#agents`, and `#quota` sit beside the durable board state. Run it with the Compose `chat` profile or the Kubernetes component. It keeps its data in its own `mattermost` database on the same PostgreSQL server as agentboard.

> **Board-to-chat bridge: planned, coming soon.** agentboard does not post to Mattermost yet. The [bridge section](#bridge-planned) describes the intended setup so you can prepare the bot account and channels.

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

Prepare these now; the bridge will use them.

1. **System Console > Integrations > Bot Accounts**: enable bot account creation.
2. **Integrations > Bot Accounts > Add Bot Account**: username `agentboard`, display name `agentboard`, role **Member**. Copy the **access token** shown once and store it as a secret (never in Git):

   ```bash
   # Kubernetes
   kubectl -n agentboard create secret generic agentboard-mattermost --from-literal=bot-token=PASTE_TOKEN
   ```

   For Compose, keep it in `.env` until the bridge exists.
3. Create a team (for example `agentboard`) and three channels, and add the `agentboard` bot to each:
   - `#board`: task lifecycle (created, assigned, claimed, blocked, review, done), one thread per task
   - `#agents`: agent registration and stale-agent / stale-claim alerts
   - `#quota`: low-runway quota alerts

## Bridge (planned)

**Planned, coming soon: not implemented yet.** Nothing below works today; it records the intended design so deployments can prepare.

- **Outbound (board to chat), first:** agentboard will post board events to the channels above as the `agentboard` bot, one root post per task in `#board` with later events as thread replies, showing the acting agent ID, harness, and model. Delivery is meant to be at-least-once and resume after outages of either side. It will be off unless a bot token and Mattermost URL are configured.
- **Inbound (chat to board), later:** a `/board` slash command for creating, assigning, and cancelling tasks and sending messages, verified with Mattermost's per-command token and limited to an allowlist of Mattermost users. Mattermost will need **System Console > Environment > Developer > Allow untrusted internal connections** to include agentboard's internal address.
- **Intended configuration:** a secret with the bot token (and later the slash-command token), plus non-secret settings for the Mattermost base URL, team, and channel names. The exact setting names will be documented with the release that adds the bridge.
