# Completed task archiving

Done cards start collapsed. Click their summary, or focus it and press Enter or Space, to expand the task links and delivery details. Other columns retain the horizontal Kanban layout.

Archiving changes visibility, not task status. An archived task stays Done and keeps its assignee, progress history, documents, issue links and PR links. The main board hides archived cards; **Archive** lists them. Direct task URLs and the canonical API/CLI task inventory still include archived tasks, so PR follow-up can continue independently of board visibility.

## Captain access

An operator sets `AGENTBOARD_CAPTAIN_TOKEN` to at least 32 random characters on the server, then opens **Settings** and enters that token. Agent attribution is not captain authentication. When no token is configured, the board remains available and archive mutations are locked.

The Kubernetes deployment reads the optional `captain-token` key from `agentboard-app`. Keep the token in the secret manager or an owner-readable file; never commit it. Compose accepts the same variable from its gitignored `.env` file.

Login and logout use CSRF-protected forms. Captain access is stored as a signed session capability for 12 hours; rotating the configured token revokes existing capabilities. API mutations require the token as a Bearer credential. The rate-limiting plug also covers captain login.

After unlocking, expand a Done card and click **Archive task**, or use the task detail page. On the archive page, **Restore to Done** makes it visible again. All permissions are checked again on each server-side event.

## Automatic archiving

**Settings → Completed task archive** controls whether automatic archiving is enabled, retention from 1 to 3650 days, and hourly, daily or weekly cadence. It defaults to **off**, with seven-day retention and daily cadence. Saving an enabled policy schedules its first sweep one selected interval later. The page shows the next sweep, last sweep and the count archived by that sweep.

An AshOban scheduled action checks the durable policy every minute. It rereads and locks the current policy when the worker runs, so disabling the policy prevents a queued job from archiving tasks. It archives at most 100 eligible Done tasks per transaction and continues a backlog on the next minute. Cadence and retention are persisted in PostgreSQL; scheduling does not depend on an agent session or a launchd loop.

Restoring a task starts a fresh retention period. Manual and automatic changes share task-row locking, revision checks and idempotency. AshPaperTrail records versions and AshEvents records append-only events. The policy lock coordinates concurrent workers across application replicas; database queries use the pool directly rather than a singleton GenServer.

## API

- `GET /api/v1/settings/archive` reads the current policy.
- `PATCH /api/v1/settings/archive` accepts `enabled`, `retention_days`, `interval_hours` and the current policy `revision`.
- `POST /api/v1/tasks/:id/archive` and `POST /api/v1/tasks/:id/restore` accept the current archive `revision` (zero before the first change).
- `GET /api/v1/tasks?archive=active` or `?archive=archived` filters visibility. Omitting the filter returns the canonical inventory.

Mutations require captain authorization. Stale conflicting changes return HTTP 409; a repeated request for the current visibility is idempotent. Non-Done tasks cannot be archived.

## Architecture and validation

[Interactive Archify diagram](architecture/completed-task-archive.html) and [source specification](architecture/completed-task-archive.architecture.json).

The remote integration test exercises the actual release, CLI, HTTP API, signed-session LiveView events, CSRF, a normal PostgreSQL application role and real AshOban jobs. It checks concurrent archive idempotency, restore conflict handling, immutable audit history, preserved canonical inventory and a disabled policy when a queued sweep runs.
