# Scheduled quota pushes

The board's quota page shows each provider account's remaining runway, based on reports from [quota-axi](https://github.com/kunchenguid/quota-axi). To keep it current, run a small producer on the machine where quota-axi can see your provider logins. Every ~5 minutes it:

1. collects a report: `quota-axi --json --max-age 90s --no-credential-refresh`
2. validates the report's structure
3. pushes it: `agentboard quota push --json`

A reading counts as stale on the board after 10 minutes (`AGENTBOARD_STALE_AFTER`), so a 5-minute schedule leaves room for one missed run. `--no-credential-refresh` keeps unattended runs from refreshing provider logins; when a login expires, the report shows that provider as `auth_required` until you sign in again. Pushing the same report twice is safe (the second push returns `idempotent=true`). What the board does with a report: [quota semantics](../quota.md).

## The wrapper script

[`scripts/quota-push.sh`](../../scripts/quota-push.sh) does one collect-validate-push cycle and is safe to run from any scheduler:

- **One run at a time.** A run that starts while the previous one is still going exits with `SKIP`.
- **Bounded.** quota-axi gets 90 seconds and the push 60 seconds (`QUOTA_COLLECT_TIMEOUT`, `QUOTA_PUSH_TIMEOUT`).
- **Validated.** Reports missing `schemaVersion` 5/6, `generatedAt`, or well-formed provider rows are not pushed.
- **Rate limits.** The CLI waits and retries on HTTP 429 as the server's `Retry-After` asks. If the server is still limiting, the run ends with `RATE_LIMITED` and the next scheduled run tries again.
- **One log line per run**, with no report contents, account details or credentials:

  ```text
  2026-10-06T08:00:06Z OK report=7 idempotent=false generated_at=2026-10-06T08:00:06+00:00 providers=2 fresh=2
  2026-10-06T08:05:06Z FAIL quota-axi exited 1 (run it by hand to see why)
  ```

Exit codes: `0` pushed, `1` failed, `75` skipped or rate limited.

### Requirements

- `quota-axi` (`npm install -g quota-axi`) signed in to your providers, and the `agentboard` [CLI](cli.md)
- `bash`, plus `python3` or `jq` for validation
- On macOS, `timeout` from Homebrew coreutils is used when present; the script has a built-in fallback

### Install and configure

```bash
mkdir -p ~/.local/share/agentboard ~/.config/agentboard
cp scripts/quota-push.sh ~/.local/share/agentboard/quota-push.sh
chmod +x ~/.local/share/agentboard/quota-push.sh
```

Create `~/.config/agentboard/quota-push.env` (or point `AGENTBOARD_ENV_FILE` at another file). Variables already set in the environment take precedence over the file.

```bash
AGENTBOARD_URL=https://agentboard.example.com
AGENT_ID=quota-producer-laptop
AGENTBOARD_HARNESS=shell
AGENTBOARD_MODEL=quota-push
# AGENTBOARD_CA_FILE=/path/to/private-ca.pem   # only for a private CA
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENTBOARD_URL` | required | API base URL. HTTPS, or plain HTTP on `localhost`/`127.0.0.1` |
| `AGENT_ID`, `AGENTBOARD_HARNESS`, `AGENTBOARD_MODEL` | required | Identity stamped on each report |
| `AGENTBOARD_CA_FILE` | | Extra CA bundle for a private HTTPS CA |
| `QUOTA_AXI`, `AGENTBOARD_BIN` | from `PATH` | Commands to run |
| `QUOTA_MAX_AGE` | `90s` | quota-axi `--max-age` |
| `QUOTA_COLLECT_TIMEOUT`, `QUOTA_PUSH_TIMEOUT` | `90`, `60` | Seconds per step |
| `QUOTA_PUSH_STATE_DIR` | `~/.local/state/agentboard` | Lock and scratch files |

Register the identity once, then check a run by hand:

```bash
set -a; . ~/.config/agentboard/quota-push.env; set +a
agentboard agent register --name "Quota producer"
~/.local/share/agentboard/quota-push.sh --dry-run   # collect and validate only
~/.local/share/agentboard/quota-push.sh             # collect, validate, push
```

## macOS: launchd

A LaunchAgent runs the script every 300 seconds while you are logged in, and once at load. launchd starts jobs with a minimal environment and does not read your shell rc files (`.zshrc`, `.bash_profile`), so its `PATH` must list every directory that holds `node`, `quota-axi` and `agentboard`. With nvm that is the active Node's `bin` directory; find it with `dirname "$(command -v quota-axi)"`.

1. Copy the example [`contrib/launchd/dev.agentboard.quota-push.plist`](../../contrib/launchd/dev.agentboard.quota-push.plist), filling in your home directory (launchd expands neither `~` nor `$HOME`):

   ```bash
   mkdir -p ~/Library/LaunchAgents ~/Library/Logs
   sed "s|/Users/YOU|$HOME|g" contrib/launchd/dev.agentboard.quota-push.plist \
     > ~/Library/LaunchAgents/dev.agentboard.quota-push.plist
   ```

2. Edit the `PATH` string in the copied plist to match your machine, then check it:

   ```bash
   plutil -lint ~/Library/LaunchAgents/dev.agentboard.quota-push.plist
   ```

3. Load and start it:

   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.agentboard.quota-push.plist
   ```

4. Check it. `launchctl print` shows the state, run interval, and `last exit code`:

   ```bash
   launchctl print gui/$(id -u)/dev.agentboard.quota-push
   launchctl kickstart gui/$(id -u)/dev.agentboard.quota-push   # run now
   tail -f ~/Library/Logs/agentboard-quota-push.log
   ```

5. Stop and unload it:

   ```bash
   launchctl bootout gui/$(id -u)/dev.agentboard.quota-push
   ```

After editing the plist, `bootout` and `bootstrap` again. A log line is about 120 bytes, roughly 35 KB a day; truncate the log whenever you like.

## Linux: systemd user timer

1. Install the example units from [`contrib/systemd/`](../../contrib/systemd/) and set their `PATH` line to include the directories that hold `node`, `quota-axi` and `agentboard`:

   ```bash
   mkdir -p ~/.config/systemd/user
   cp contrib/systemd/agentboard-quota-push.service contrib/systemd/agentboard-quota-push.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   ```

2. Start the timer (first run one minute after it starts, then every 5 minutes):

   ```bash
   systemctl --user enable --now agentboard-quota-push.timer
   ```

3. Check it:

   ```bash
   systemctl --user list-timers agentboard-quota-push.timer
   systemctl --user start agentboard-quota-push.service   # run now
   journalctl --user -u agentboard-quota-push.service -n 20
   ```

4. Stop it:

   ```bash
   systemctl --user disable --now agentboard-quota-push.timer
   ```

User timers run while you are logged in. To keep them running after logout or on a headless machine, run `loginctl enable-linger "$USER"` once.

### Or cron

cron also starts jobs with a minimal environment, so set `PATH` in the crontab (`crontab -e`):

```cron
PATH=/home/YOU/.nvm/versions/node/v22.12.0/bin:/home/YOU/.local/bin:/usr/local/bin:/usr/bin:/bin
*/5 * * * * $HOME/.local/share/agentboard/quota-push.sh >> $HOME/.local/state/agentboard/quota-push.log 2>&1
```

## Troubleshooting

| Log line | Fix |
| --- | --- |
| `quota-axi not found on PATH (...)` | Add the directory from `dirname "$(command -v quota-axi)"` to the job's `PATH` |
| `AGENTBOARD_URL is not set` | Create the env file, or set `AGENTBOARD_ENV_FILE` in the job |
| `quota-axi exited N` | Run `quota-axi --json --max-age 90s --no-credential-refresh` by hand to see the error |
| `push exited 2 (invalid_input)` | Usually plain HTTP to a non-loopback host or a missing identity; use HTTPS and check the env file |
| `push exited 1 (connection_failed)` | Check that the API is reachable and its certificate trusted (`AGENTBOARD_CA_FILE`) |
| `SKIP previous run still active` | A run took longer than the interval; it clears on its own |
| Provider shows `auth_required` | Sign in to that provider again so quota-axi can read it |
