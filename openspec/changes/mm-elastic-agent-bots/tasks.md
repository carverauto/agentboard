# Tasks

- [x] 1. Migration 17 `mattermost_agent_bots` table (agent_id unique, mm_user_id unique, username, display_name, encrypted token binary, state, timestamps); required bumped 15 to 17 with table presence check (code reads the table on every send path).
- [x] 2. `ash_cloak` dependency plus file-backed key ref in config; verify key material never enters repo, logs, or error output.
- [x] 3. `ElasticBots.ensure/1` lazy provisioning worker: short-name mapping (22-char, deterministic, collision-checked), team/channel joins, pending-row adopt under register races, Oban retry when MM is down.
- [x] 4. `post_as` token swap with shared-bot fallback; stale-token detection re-provisions without failing the send; props/header identical in both paths.
- [x] 5. `ElasticBots.retire/1` idempotent hook (disable bot, revoke token, never raises) wired to roster GC (#42, codex-agent-a-server); re-register reactivates with a fresh token.
- [x] 6. Diagnostics `bot` object (active/state/username, no secrets) plus runbook rotation and disable procedures.
- [ ] 7. Remote-only Bazel proof against stub MM: race-on-register single bot, 22-char/collision mapping, token-leakage sweep (logs/API/CLI/HTML), fallback parity, retire/reactivate, MM-down registration with late provisioning.
