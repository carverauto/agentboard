---
name: agentboard-helper
description: File work intake, cancel unstarted intake items, and read the fleet status digest from chat bots or external helpers (Grok, Muse, OpenAI dot, or any HTTPS client) using a narrow helper token.
---

# Fleet helper workflow

Use this skill when acting as an external chat bot or assistant (`Grok`, `Muse`, `OpenAI dot`, or any HTTPS client) with a captain-issued `helper` credential (`scope=helper` on an agent with `kind=helper`). For coding seats that claim and implement cards, use [the canonical seat workflow](../agentboard/SKILL.md) instead.

A helper does two things only:

1. **Files work into the backlog** (and optionally cancels its own unstarted intake items or checks its own intake request status).
2. **Reads the fleet status digest** to summarize live, requested, and maximum seats, backlog depth, overdue or pending refill assignments, launch intents by state (including dry-run would-launch intents), CI repair obligations, and that fleet's recent intake results for humans in chat.

## Hard boundaries

- **Never coordinate.** Do not send or read peer messages, post to coordination channels as another agent, or file/answer/recommend decisions.
- **Never assign, hand off, claim, renew, or release tasks.** Helpers are not seats and cannot own or route work. The server's deterministic backlog refill loop assigns open cards to eligible seats.
- **Never set seat counts or fleet configuration.** Do not modify fleet loadouts, `requested_seats`, `max_seats`, activation mode, or worker state.
- **Never resolve uncertain GitHub issues.** `POST /api/v1/intake/:id/items/:item_id/reconcile` and `abandon` (`agentboard intake resolve`) are captain-only. When an intake item enters `issue_state=uncertain`, report the request ID, item ID, and `reason` / `duplicate_issue_urls` to the captain.
- **Never print, log, or echo bearer tokens.** Store the captain-issued helper token in a `0600` file (`AGENTBOARD_TOKEN_FILE`) and pass it only via the `Authorization: Bearer` header or the CLI.

## Credential setup (captain-issued)

The captain registers a `helper` identity and issues a `helper`-scoped token:

```sh
AGENT_ID=grok-agentboard-helper AGENTBOARD_HARNESS=grok AGENTBOARD_MODEL=grok-4 \
  agentboard agent register --name "Grok Helper" --kind helper --json

AGENTBOARD_CAPTAIN_TOKEN_FILE=/path/to/captain.token \
  agentboard agent token issue grok-agentboard-helper --scope helper --out /path/to/helper.token
```

To restrict which intake repositories a helper may file into, the captain may also set a seat scope (`agentboard agent scope set grok-agentboard-helper --repo owner/repo ...`); the server intersects the helper's `allowed_repos` with the server's configured `AGENTBOARD_INTAKE_REPOSITORIES`.

## CLI commands

Set `AGENTBOARD_URL` and `AGENTBOARD_TOKEN_FILE=/path/to/helper.token` (ensure `AGENTBOARD_CAPTAIN_TOKEN_FILE` is unset in helper environments):

```sh
# 1. File one item (always pass a stable --request-key so retries replay safely)
agentboard intake file \
  --request-key "chat-2026-10-08-widget-fix" \
  --repo owner/repo \
  --title "Fix widget timeout on retry" \
  --body "Steps to reproduce and expected behavior" \
  --priority 2 \
  --label bug \
  --json

# File a card only (no GitHub issue)
agentboard intake file \
  --request-key "chat-2026-10-08-card-only" \
  --repo owner/repo \
  --title "Triage flaky test" \
  --no-issue \
  --json

# File a batch (1-10 items) from a UTF-8 JSON file
agentboard intake file \
  --request-key "chat-2026-10-08-batch-1" \
  --file /path/to/items.json \
  --json

# 2. Check status of your own intake request (exits 5 if any item is uncertain)
agentboard intake status REQUEST_ID --json

# 3. Cancel your own unstarted intake items (all unstarted items, or specific --item IDs)
agentboard intake cancel REQUEST_ID --json
agentboard intake cancel REQUEST_ID --item ITEM_ID --json

# 4. Read the fleet status digest (all fleets, or one fleet by slug)
agentboard fleet status --json
agentboard fleet status FLEET_ID --json
```

## Direct HTTPS API calls

Helpers without the `agentboard` binary can call the JSON API directly over HTTPS with `Authorization: Bearer <helper_token>` and `Content-Type: application/json`. Self-reported `X-Agentboard-*` headers are optional when using a helper token; if sent, they must match the helper's registered `id`, `model`, and `harness`.

- **File intake (`POST /api/v1/intake`):**
  ```json
  {
    "request_key": "chat-2026-10-08-widget-fix",
    "items": [
      {
        "repository": "owner/repo",
        "title": "Fix widget timeout on retry",
        "body": "Steps to reproduce and expected behavior",
        "priority": 2,
        "labels": ["bug"],
        "issue": true
      }
    ]
  }
  ```
  Replaying the same `(filer_id, request_key)` with an equivalent normalized payload returns `200` with `"replayed": true`. Reusing a `request_key` with a different payload returns `409 conflict`.

- **Read own intake status (`GET /api/v1/intake/:id`):**
  Returns `{ "intake": { "id", "request_key", "filer_id", "items": [...] } }`. Helpers may only read requests where `filer_id` matches their own identity (`403 forbidden` otherwise).

- **Cancel own unstarted intake (`POST /api/v1/intake/:id/cancel`):**
  Body `{}` cancels all unstarted items in that request, or `{"items": ["ITEM_UUID"]}` cancels specific items. Already-claimed or completed cards are skipped with `"reason": "card_started"`.

- **Read fleet status digest (`GET /api/v1/fleet/status` or `GET /api/v1/fleet/status?fleet_id=FLEET_ID`):**
  Returns `{ "as_of": "...", "fleets": [ ... ] }` with bounded per-fleet sections:
  - `live_seats`, `requested_seats`, and `max_seats` (both counts are 0 when the fleet has no activation row). `seats` repeats those counts as `requested` and `maximum`, plus `configured`, `live`, `idle`, `busy`, `stale`, and `items` (per-seat status and active task ID).
  - `backlog`: open unassigned task counts (`total`, `by_priority`, and `priorities`) within the fleet's allowed repositories.
  - `overdue_assignments`, `pending_assignments`, `misses` (per-seat miss counts), `dry_run_pairs`, and `last_pass`.
  - `launch_intents`: intents grouped by state (`dry_run`, `pending`, `reserved`, `uncertain`, `launched`, `failed`, `expired`, `superseded`, `closed`, `abandoned`), at most 50 per state, including dry-run would-launch intents. Entries name the seat, agent, harness, and host. They omit lease paths.
  - `ci_obligations`: bounded open CI repair obligations for the fleet's repositories or seats.
  - `recent_intake`: that fleet's recent intake items and issue states (no bodies). Intake from other repositories is not included.

See [the intake setup guide](https://github.com/carverauto/agentboard/blob/main/docs/setup/intake.md) and [API reference](https://github.com/carverauto/agentboard/blob/main/docs/api.md) for full field schemas.
