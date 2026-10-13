# Fleet helper pilot on farm01

Operator runbook for `add-fleet-helper` task 6.1: one fleet on farm01 goes from
dry run to live with `max_seats` 2. A helper (a chat bot, or the captain CLI
until helper tokens ship) files three issues on a sandbox repository. Two seats
launch in Herdr on the operator's Mac, claim the cards and open PRs. After
merge, reap waits until the card is done or released, Herdr has reported the
pane idle for `reap_after` (default 30m), the seat owns no open, assigned,
in-progress, blocked or review task, it has no unread message, and its checkout
has landed. Then `agentboard seat reap --apply` (or the seat-ops timer) closes
the pane and returns its lease, and the daemon reports the intent `closed`.
The pilot pool has to be in that Mac's `treehouse_roots` or the lease is never
read.

Every step that changes farm01, GitHub or the Mac is the captain's call. Stop at
any step that does not match what this page says and record the difference.
Nothing in the pilot is a coordinator: the server assigns and launches; seats
coordinate through the board, Mattermost and Context.

Generic setup lives in [work intake](../setup/intake.md),
[backlog refill](../setup/fleet-refill.md), [seat spawn](../setup/seat-spawn.md)
and [fleet seat supply](../setup/fleet-host.md). This page adds only the farm01
values and the order.

## Values

| Name | Pilot value |
| --- | --- |
| Board | `https://agentboard.farm01.carverauto.dev` |
| Sandbox repository | `carverauto/app-testing` (private; captain confirms before step 3) |
| Fleet | `pilot` |
| Host ID | `HOST_ID`, a slug the captain picks for the Mac (for example `build-mac`) |
| Seats | `claude-app-testing-seat-1` (harness `claude`), `codex-app-testing-seat-2` (harness `codex`) |
| Seat source checkout | `~/src/app-testing` |
| Seat pool root | `/Volumes/Build/app-testing-seats-v3` (Treehouse v3.1.2, separate from the agentboard pool) |
| Daemon allowlist | `~/.config/agentboard/fleet/pilot-harnesses.json` |
| Captain capability | `AGENTBOARD_CAPTAIN_TOKEN_FILE` (0600) |

The allowlist's `repo` and `root` apply to every seat the daemon launches, so
the pilot uses its own allowlist file and leaves the agentboard one alone.

## 1. Release

The Mac's installed CLI is 0.2.0 and has none of the fleet commands. Publish
v0.4.0 only after a separate release-bump pull request is on main, following
[the release process](../release.md). That pull request changes every `v0.3.0`
and `0.3.0` release pin in the tree, passes `//:acceptance` remotely, and
merges before the tag. Find the pins with:

```sh
git grep -n '0\.3\.0' -- .github/workflows scripts build web/mix.exs internal/cli/root.go build/integration
```

`8dae47b` still carries those pins, so tagging it fails the release job
before a draft exists. Wait for the helper-access lane (helper tokens and
`fleet status`) and intake import when the pilot should use them.

Tag the merged bump commit. Pushing a `v*` tag publishes images through
[`.github/workflows/images.yml`](../../.github/workflows/images.yml) (`sha-<commit>`
and `v0.4.0`). That workflow is separate from the manual `release.yml` run.

```sh
git fetch origin
git tag v0.4.0 <bump-commit> && git push origin v0.4.0   # also starts images.yml
gh workflow run release.yml -f tag=v0.4.0                # agentboard-release environment
gh release edit v0.4.0 --draft=false --prerelease        # after the draft exists and you have reviewed it
agentboard version                                        # 0.4.0 on the Mac, after installing the release binary
```

Record the dashboard digest from the release notes.

## 2. Roll farm01 with every new flag off

```sh
agentboard admin rollout registry.carverauto.dev/agentboard/dashboard@sha256:DIGEST \
  --overlay k8s/overlays/farm01/kustomization.yaml \
  --image registry.carverauto.dev/agentboard/dashboard \
  --deployment agentboard-dashboard --namespace agentboard \
  --migration-job k8s/base/migration.yaml --migration-job-name agentboard-migrate \
  --cnpg-cluster agentboard-db \
  --record-out docs/verification/farm01-v0.4.0-rollout.json
agentboard meta --json   # schema_version 47 (48 if helper access shipped)
```

Check: intake routes answer 404 `intake_disabled`, `fleet refill status` and
`fleet supply status` show no activations, and the board is otherwise
unchanged.

## 3. Turn on intake, refill and seat supply

Create the intake GitHub token: a fine-grained token with Issues read/write on
the sandbox repository only. Store it as Secret `agentboard-intake-github`
(key `token`) out of band, and mount it as a file. Add to the overlay:

```yaml
# k8s/overlays/farm01/dashboard-intake-token.yaml (listed under patches:)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentboard-dashboard
spec:
  template:
    spec:
      containers:
        - name: dashboard
          volumeMounts:
            - name: intake-github
              mountPath: /etc/agentboard/intake
              readOnly: true
      volumes:
        - name: intake-github
          secret:
            secretName: agentboard-intake-github
```

and to the `agentboard-config` literals:

```yaml
      # Captain-approved YYYY-MM-DD: fleet helper pilot (add-fleet-helper 6.1).
      # Rollback: set the three *_ENABLED values to false.
      - AGENTBOARD_INTAKE_ENABLED=true
      - AGENTBOARD_INTAKE_REPOSITORIES=carverauto/app-testing
      - AGENTBOARD_INTAKE_GITHUB_TOKEN_FILE=/etc/agentboard/intake/token
      - AGENTBOARD_REFILL_ENABLED=true
      - AGENTBOARD_SEAT_SUPPLY_ENABLED=true
```

Apply the reviewed overlay and restart the dashboard. The flags alone do
nothing: no fleet is activated yet.

## 4. Seats, scopes and the loadout

Register each seat identity once (kind `seat`, its real harness and model) and
give it a managed scope on the sandbox repository, then save the fleet. Both
writes require `AGENT_ID`, `AGENTBOARD_HARNESS` and `AGENTBOARD_MODEL`. Leave
off `--backend herdr` here: that flag renames the calling pane, so a captain
inside Herdr would name their own pane after the seat and the later launch
would fail. The seat names its pane when it registers with `--backend herdr`
from its own tab.

```sh
for seat in \
  claude-app-testing-seat-1:claude:claude-opus-5-5 \
  codex-app-testing-seat-2:codex:gpt-5.5
do
  id=${seat%%:*}; rest=${seat#*:}; h=${rest%%:*}; model=${rest#*:}
  AGENT_ID=$id AGENTBOARD_HARNESS=$h AGENTBOARD_MODEL=$model \
    agentboard agent register --kind seat
  AGENT_ID=$id AGENTBOARD_HARNESS=$h AGENTBOARD_MODEL=$model \
    agentboard agent scope set "$id" --repo carverauto/app-testing --revision 0 --json
done
```

`pilot-loadout.json` (scope revision 1 after the step above):

```json
{
  "revision": 0,
  "idempotency_key": "pilot-initial-1",
  "seats": [
    {"seat_id": "seat-1", "agent_id": "claude-app-testing-seat-1", "harness": "claude",
     "desired_host_id": "HOST_ID", "desired_model": "claude-opus-5-5", "desired_effort": "high", "scope_revision": 1},
    {"seat_id": "seat-2", "agent_id": "codex-app-testing-seat-2", "harness": "codex",
     "desired_host_id": "HOST_ID", "desired_model": "gpt-5.5", "desired_effort": "high", "scope_revision": 1}
  ]
}
```

```sh
agentboard fleet loadout set pilot --file pilot-loadout.json --json
```

Registration does not set `last_heartbeat`. `agentboard agent list` shows both
seats `stale=true` immediately. A seat that has never heartbeated is not live,
so seat supply launches it. Refill assigns nothing until that seat heartbeats
from its own tab, so step 7's would-assign list stays empty. Seat supply still
records two `dry_run` would-launch intents.

## 5. The Mac as a fleet host

```sh
mkdir -p -m 700 ~/.config/agentboard/fleet
git clone git@github.com:carverauto/app-testing.git ~/src/app-testing
mkdir -p /Volumes/Build/app-testing-seats-v3   # first launch-seat creates the v3 pool
agentboard fleet host set HOST_ID --launch-cap 2 --token-file ~/.config/agentboard/fleet/host.token
```

`~/.config/agentboard/fleet/host.token` must exist and be mode 0600. Enrollment
saves the host before it writes that file, and a failed write still exits 0.
A later `host set` with the same launch cap and no `--rotate-token` issues no
token. If the file is missing, re-run:

```sh
agentboard fleet host set HOST_ID --launch-cap 2 --rotate-token \
  --token-file ~/.config/agentboard/fleet/host.token
```

Add the pilot pool to `treehouse_roots` in
`~/.config/agentboard/seat/config.json` ([seat reap](../setup/seat-nudge.md)).
Keep the file's other fields, and keep the existing agentboard pool on the
list. Lease return reads only listed roots, so a missing pilot root leaves
that lease held after the pane is gone.

```json
{
  "treehouse_roots": [
    "/Volumes/Build/agentboard-seats-v3",
    "/Volumes/Build/app-testing-seats-v3"
  ]
}
```

`~/.config/agentboard/fleet/pilot-harnesses.json` (0600, owned by you):

```json
{
  "version": 1,
  "launcher": "/Users/YOU/src/agentboard/scripts/launch-seat",
  "repo": "/Users/YOU/src/app-testing",
  "root": "/Volumes/Build/app-testing-seats-v3",
  "workspace": "fleet-pilot",
  "harnesses": {
    "claude": {"model": "claude-opus-5-5", "argv": ["claude", "{brief_text}"]},
    "codex": {"model": "gpt-5.5", "argv": ["codex", "{brief_text}"]}
  }
}
```

One pass by hand, before any activation. It must report nothing to do:

```sh
AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev \
  agentboard host fleet serve --host-id HOST_ID \
  --token-file ~/.config/agentboard/fleet/host.token \
  --harnesses ~/.config/agentboard/fleet/pilot-harnesses.json --once
```

Install `~/Library/LaunchAgents/com.agentboard.fleet-host.plist`. launchd
expands neither `~` nor `$HOME`, so the binary, token file and harness
allowlist are absolute. `ProgramArguments` starts with the CLI
`agentboard version` just printed (`~/.local/bin/agentboard` on this Mac).
`PATH` includes that directory and Herdr (`/opt/homebrew/bin` when Homebrew
installed it). The URL is the farm01 board, not the example in
[fleet seat supply](../setup/fleet-host.md#launchd-macos).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agentboard.fleet-host</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOU/.local/bin/agentboard</string>
    <string>host</string><string>fleet</string><string>serve</string>
    <string>--host-id</string><string>HOST_ID</string>
    <string>--token-file</string><string>/Users/YOU/.config/agentboard/fleet/host.token</string>
    <string>--harnesses</string><string>/Users/YOU/.config/agentboard/fleet/pilot-harnesses.json</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AGENTBOARD_URL</key><string>https://agentboard.farm01.carverauto.dev</string>
    <key>PATH</key><string>/Users/YOU/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/YOU/Library/Logs/agentboard-fleet-host.log</string>
  <key>StandardErrorPath</key><string>/Users/YOU/Library/Logs/agentboard-fleet-host.log</string>
</dict>
</plist>
```

Load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agentboard.fleet-host.plist`.
It must run in your login session to reach the Herdr server.

## 6. File three issues

With helper tokens shipped, issue a helper token to the chat bot and have it
call `POST /api/v1/intake`. Until then the captain CLI files the same request:

```sh
agentboard intake file --request-key pilot-1 --repo carverauto/app-testing --title "..." --body "..." --priority 2
agentboard intake file --request-key pilot-2 --repo carverauto/app-testing --title "..." --body "..." --priority 2
agentboard intake file --request-key pilot-3 --repo carverauto/app-testing --title "..." --body "..." --priority 3
agentboard intake status REQUEST_ID   # until each item is created with an issue_url
```

Pick three small, independent tasks a seat can finish in one PR.

## 7. Dry run

```sh
agentboard fleet activate pilot --mode dry-run --requested-seats 2 --max-seats 2 --claim-deadline 30m
agentboard fleet supply status pilot --json   # empty until the next seat-supply minute
agentboard fleet refill status pilot --json   # no seat heartbeats yet, so no would-assign pairs
```

Activate does not write launch intents. The two `dry_run` would-launch rows
appear on the next seat-supply minute, and nothing is reserved. Wait at least
one minute and re-read `fleet supply status` until they are there. An empty
status before that pass is not a mismatch. Refill's would-assign list stays
empty. Confirm on the board and in Herdr that nothing changed: no assignment,
no task order, no tab. Leave it for at least two refill passes (two minutes).

## 8. Live

```sh
agentboard fleet activate pilot --mode live
```

Expected, in order (record a timestamp for each):

1. On the next seat-supply minute, `fleet supply status` shows two `pending`
   intents, then `reserved` by `HOST_ID`. An empty status in that first minute
   is not a mismatch.
2. Herdr workspace `fleet-pilot` gains tabs `claude-app-testing-seat-1` and
   `codex-app-testing-seat-2`; each runs `launch-seat`, leases a worktree under
   `/Volumes/Build/app-testing-seats-v3` and starts its harness.
3. Intents move to `launched` with pane and lease identity.
4. Each seat registers from its own pane and then heartbeats. Refill assigns
   one card per live seat per pass and sends a `task_order`; the third card waits.
5. Each seat claims within the 30 minute deadline (a miss returns the card and
   is counted in `fleet refill status`).
6. Each seat opens a PR and links it to its card. The third card goes to the
   first seat that finishes or has queue room.
7. After the captain merges, the card stays in review until it is done or
   released. Once Herdr reports the pane idle for `reap_after` (default 30m),
   the seat owns no open, assigned, in-progress, blocked or review task, it
   has no unread message, and its checkout has landed, `agentboard seat reap
   --apply` closes the pane and returns its lease from the pilot pool in
   `treehouse_roots` (step 5). The [seat-ops timer](../setup/seat-nudge.md#schedule)
   does the same on its interval. Without `--apply`, reap is a dry run and
   closes nothing. The daemon then reports the intent `closed`.

## 9. Record and close

Write `docs/verification/farm01-fleet-pilot.json` with the timeline above,
`fleet supply status` and `fleet refill status` snapshots at dry run, first
launch and close (plus `fleet status` if helper access shipped), every manual
step, and anything that needed the captain. Tick 6.1 in
`openspec/changes/add-fleet-helper/tasks.md`.

## Stop or roll back

| Goal | Action |
| --- | --- |
| Stop new launches on the Mac | `agentboard fleet host set HOST_ID --launch-cap 0` |
| Stop assignments and launches for the fleet | `agentboard fleet deactivate pilot` (running seats, claims and intents stay) |
| Free a stuck seat | `agentboard fleet supply abandon pilot INTENT_ID --reason "..."` after checking the pane by hand |
| Stop the daemon | `launchctl bootout gui/$(id -u)/com.agentboard.fleet-host` |
| Turn the features off | Set the three `*_ENABLED` literals to `false` and restart |
| Roll the server back | Pin the v0.3.0 digest per [rollback](reference-farm01.md#rollback); schemas 45–47 are additive |
