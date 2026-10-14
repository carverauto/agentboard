# Work intake

Work intake lets any authorized HTTPS client file board cards and, optionally,
GitHub issues through one idempotent API: a chat bot, a person with the CLI,
or a script. Each item becomes an ordinary board card at once. When the item
asks for an issue, a server outbox creates it afterwards and links the card,
so a GitHub outage never blocks filing. Intake only files work. It never
claims, assigns or coordinates, and nothing about it depends on a client
staying connected.

Intake is off by default. While it is off, its routes answer 404
`intake_disabled` and its outbox does not run. With
`AGENTBOARD_AUTH_MODE=enforce`, a request that has not presented the captain
capability is refused with 403 before that disabled check. A captain still
receives 404 `intake_disabled`.

## Enable it

Set these on the server and restart it:

| Variable | Purpose |
| --- | --- |
| `AGENTBOARD_INTAKE_ENABLED` | `true` turns intake on (default `false`) |
| `AGENTBOARD_INTAKE_REPOSITORIES` | Comma-separated `owner/repo` list that intake may file into. Requests naming any other repository are rejected whole |
| `AGENTBOARD_INTAKE_GITHUB_TOKEN_FILE` | File holding the GitHub token used to create issues and read issues for import (re-read on each use, so rotation needs no restart). `AGENTBOARD_INTAKE_GITHUB_TOKEN` is the environment fallback |
| `AGENTBOARD_CAPTAIN_TOKEN` | Captain capability; every intake route requires it for now |
| `API_RATE_LIMIT_INTAKE` | Intake writes per minute per filer (default `30`) |

`AGENTBOARD_GITHUB_API_URL` and `AGENTBOARD_GITHUB_CA_FILE` are shared with CI
observation for GitHub Enterprise or a private CA. The intake token is separate
from the read-only `GITHUB_TOKEN` used for CI observation. Give it issue write
access to the intake repositories only. The server uses it to create an issue
and, after a create that may have reached GitHub, to list issues that this
same credential opened: it resolves the login once with `GET /user`, then
lists `creator=<login>` since that first create attempt (minus a small clock
skew), newest first, ten per page. Calls stay inside
`AGENTBOARD_INTAKE_REPOSITORIES`.

Without a token, issue items stay `pending` with `github_unconfigured` until one
is configured. Card-only items (`issue: false`) need no token.

## Who can file

Every intake route requires the captain capability (`Authorization: Bearer
<captain token>`), even when `AGENTBOARD_AUTH_MODE` is `off`. Cards are filed
and attributed as `captain`. Scoped helper credentials for chat bots are a
later change; until then a bot that files work holds the captain capability
and should be treated accordingly.

People in Mattermost can also file through the [`/board`
command](#mattermost-board-command) as a board identity the captain maps to
their Mattermost account.

## File from the CLI

The CLI reads the captain capability from a protected file
(`AGENTBOARD_CAPTAIN_TOKEN_FILE`, mode 0600):

```sh
export AGENTBOARD_CAPTAIN_TOKEN_FILE=~/.config/agentboard/captain.token
agentboard intake file --request-key bug-1 --repo example/project \
  --title "Fix login redirect" --body "Steps to reproduce..." --priority 1 --label bug
agentboard intake file --request-key notes-2 --repo example/project \
  --title "Card only" --no-issue
agentboard intake file --request-key batch-3 --file items.json
agentboard intake status REQUEST_ID
agentboard intake cancel REQUEST_ID [--item ITEM_ID]...
agentboard intake resolve REQUEST_ID ITEM_ID --action reconcile|abandon
```

`items.json` is an array of up to 10 items:
`[{"repository":"example/project","title":"...","body":"...","priority":2,"labels":["bug"],"issue":true}]`.

Re-run a command with the same `--request-key` after a timeout or lost
response: an equivalent payload returns the original request (`replayed:
true`) and files nothing new. A changed payload under that key is a conflict
(exit 4). `intake status` exits 5 while an issue is `uncertain`.

## Import existing issues

For an issue burndown, `intake import` turns open issues that already exist
into cards linked to them, so backlog refill can hand them out. It never
creates an issue. Name the issues, or take the first N open issues in
GitHub's list order (newest first) that are not on the board yet:

```sh
agentboard intake import --request-key burndown-1 --repo example/project --limit 10
agentboard intake import --request-key burndown-2 --repo example/project --label bug --limit 5
agentboard intake import --request-key pick-3 --repo example/project --issue 42 --issue 17 --priority 1
```

Named issues keep the order given; a list selection keeps GitHub's order.
Cards are created in that order with one priority, so refill offers them in
that order too. An issue already linked to a card that is not cancelled is
passed over. Pull requests are never imported. Named issues that are closed,
missing, transferred, pull requests or already on the board are listed as
`not imported` with the reason. A list selection reads at most 20 pages of
ten, starting at `--start-page` (the top of the list when omitted). The
result names the next page. Import again with that `--start-page` to
continue; a request that omits it starts again at the top of the list. If
the walk stops at the page bound, the result says so. An issue body over the
1 MiB response cap fails a named import with reason `too_large` and writes
nothing; a list page over that cap is re-read in smaller chunks, and one
issue that is still over the cap is passed over so the rest of the page can
be imported.

Import reads GitHub with the intake token before it writes anything. If
GitHub fails, nothing is created and the same `--request-key` can be retried.
A retry of a request that succeeded replays it without reading GitHub again.
Imported items show issue state `created` with reason `imported`, and
`intake cancel` takes back their cards while they are unstarted (the issue
stays open).

## Mattermost `/board` command

`/board` lets a person file and check intake from Mattermost. It calls the
same contract as the API, so scope, replay, rate limits and issue handling
are identical. It is unavailable while intake is off.

```text
/board file owner/repo "Title" [--body "Text"] [--priority N] [--label L]... [--issue|--no-issue]
/board status REQUEST_ID
/board help
```

A filing asks for a GitHub issue unless `--no-issue` is given. Double or curly
quotes group a word; inside quotes a backslash escapes the next character.
The reply links the card (when `AGENTBOARD_PUBLIC_BOARD_URL` is set) and says
whether the issue is pending; `/board status` shows the issue link once the
outbox has created it.

To set it up:

1. In Mattermost, create a custom slash command (Integrations → Slash
   Commands) with trigger word `board`, request method `POST` and request URL
   `https://agentboard.example.com/api/v1/hooks/mattermost/board`. Enable
   autocomplete if you like (hint: `file|status|help`).
2. Write the command's token to a file readable by the server and set
   `AGENTBOARD_MATTERMOST_SLASH_TOKEN_FILE` to its path
   (`AGENTBOARD_MATTERMOST_SLASH_TOKEN` is the environment fallback). The file
   is re-read on every request, so rotating the token needs no restart.
3. Register a board identity for each person who may file (for example
   `agentboard agent register --kind human` as that identity), then list them
   in `AGENTBOARD_MATTERMOST_SLASH_FILERS` as comma-separated
   `mattermost_user_id=agent_id` pairs. Mattermost user IDs are the 26-character
   IDs from the System Console or `GET /api/v4/users/username/NAME`. The server
   refuses to start on a malformed entry.

| Variable | Purpose |
| --- | --- |
| `AGENTBOARD_MATTERMOST_SLASH_TOKEN_FILE` | File holding the slash command's token |
| `AGENTBOARD_MATTERMOST_SLASH_TOKEN` | Environment fallback for the token |
| `AGENTBOARD_MATTERMOST_SLASH_FILERS` | `user_id=agent_id` pairs; unlisted users file nothing |

Cards and requests are attributed to the mapped identity, which sees only its
own requests in `/board status`. A retired identity, and reserved identities
such as `captain` and system agents, are refused. Each Mattermost invocation
has its own request key (from its `trigger_id`): a redelivered invocation
replays, and running the command again files again. Mattermost posts
`in_channel` replies in the thread the command was run from.

## Issue states

| State | Meaning |
| --- | --- |
| `none` | Card-only item |
| `pending` | Waiting for the outbox, or backing off after a transient failure (outage, rate limit, lost response). `last_error` says why |
| `creating` | An outbox job holds the item |
| `created` | The issue exists; `issue_url` is set and the card links it (unless the card was already linked elsewhere or finished, reported in `reason`). Imported items start here with reason `imported` |
| `uncertain` | Needs a decision: GitHub refused the issue (`rejected:422`, `rejected:403`, ...), more than one issue carries the item's marker (`duplicate_marker`, with `duplicate_issue_urls`), the bounded marker lookup could not finish (`marker_search_incomplete`, with any marker URLs already seen), or the repository left the intake list (`repository_out_of_scope`) |
| `abandoned` | Filer or captain stopped it; no further GitHub calls |
| `cancelled` | The card was cancelled before its issue was created. A pending or uncertain intent is cancelled with the card and is not returned to the outbox |

Each issue body ends with a hidden marker,
`<!-- agentboard-intake:ITEM_ID -->`. After any create that may have reached
GitHub, the outbox lists issues this credential created since that attempt
and adopts one issue carrying the marker before it creates again, so a lost
response never makes a second issue. The list is read until a short page
shows it is exhausted. Pull requests are not matches and do not count toward
the bound. The item parks `uncertain` with `marker_search_incomplete` when a
full page reaches 1000 issues, when the walk reaches 1000 pages, or when a
page exceeds the shared 1 MiB response body bound. A transient read failure
stays `pending` and
retries. Adopting an issue, reconciling, or backing off clears
`duplicate_issue_urls`.

To clear an `uncertain` item that was not cancelled, fix the cause on GitHub
(for example close the extra copy of a duplicate, or fix permissions), then
`resolve --action reconcile`. Reconcile scans for the marker first and only
then creates. A cancelled item is terminal; reconcile is refused. Use
`--action abandon` to stop an item that is still `pending` or `uncertain`;
the card stays.

`cancel` cancels the request's cards that are still open and unassigned. Cards
someone already took, and items whose issue is being created at that moment,
are reported under `skipped` and left alone. An issue that was already
created is not closed.

The full HTTP contract and error codes are in the
[API reference](../api.md#work-intake-schema-45).
