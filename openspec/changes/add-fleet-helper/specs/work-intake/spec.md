# Work intake

## Purpose

Let any authorized client file work as board cards and, optionally, GitHub issues through one idempotent contract that does not depend on GitHub availability.

## ADDED Requirements

### Requirement: Intake flag defaults off
`AGENTBOARD_INTAKE_ENABLED` SHALL default off and SHALL fully disable intake. While it is off, `POST /api/v1/intake`, intake import, intake cancel, `GET /api/v1/intake/:id` and the Mattermost `/board` command SHALL be unavailable and SHALL create nothing. Intake SHALL NOT depend on a fleet or on a fleet's dry-run or live mode. A dry-run fleet SHALL NOT file issues, assign cards or open tabs through refill or seat supply.

#### Scenario: Flag off
- **WHEN** the intake flag is at its default and a client posts an intake request
- **THEN** the route is unavailable and no card or issue intent is created

#### Scenario: No fleet
- **WHEN** the intake flag is on and no fleet is activated
- **THEN** intake still accepts a filing for a captain-listed repository

### Requirement: Helper token even when agent auth is off
`POST /api/v1/intake`, intake import, intake cancel and `GET /api/v1/intake/:id` SHALL require a captain-issued helper token or the captain, including when `agent_auth_mode` is off. This requirement SHALL NOT change `agent_auth_mode` or the authentication of any other route. The Mattermost `/board` command keeps its own slash-token check.

#### Scenario: Open auth mode, no helper token
- **WHEN** `agent_auth_mode` is off and a caller without a captain-issued helper token or captain credential posts intake
- **THEN** the request is refused and nothing is created

### Requirement: Idempotent intake request
The server SHALL accept an intake request of 1 to 10 items with a request key. It SHALL create the intake record, each board card and, when the item's issue flag is true, each pending issue intent in one transaction. Normalization, used for both replay and conflict, SHALL be: repository as lowercased trimmed `owner/repo`; title and body trimmed; priority an integer; labels trimmed, deduplicated and sorted; issue flag a boolean. The same key with the same normalized payload SHALL return the original result; a changed normalized payload under that key SHALL be rejected as a conflict.

#### Scenario: Bot retries after a timeout
- **WHEN** a helper repeats an intake request with the same key and the same normalized payload, including a differently cased repository, reordered labels, or surrounding whitespace on title or body
- **THEN** it receives the original cards and issue states and no second card or issue is created

#### Scenario: Same key, different filing
- **WHEN** a helper repeats a request key with a different normalized title
- **THEN** the request is rejected as a conflict and the original cards are unchanged

#### Scenario: Repository outside the filer's scope
- **WHEN** an item names a repository the filer may not file into
- **THEN** the whole request is rejected and nothing is created

### Requirement: GitHub issue outbox
For items whose issue flag is true, the server SHALL create the issue outside the board transaction with a hidden body marker naming the intake item, then link the card to the issue. The outbox SHALL use a server token that can only create and search issues in intake repositories. After a lost response it SHALL search the repository for the marker and adopt a match only when exactly one issue carries it. A transient failure (timeout or unavailable) SHALL stay pending and be created after GitHub recovers. A definitive rejection, and a marker that matches more than one issue, SHALL stay uncertain with a reason and SHALL NOT be retried or linked to one of the matches. Any other unresolved create SHALL remain visibly uncertain until reconciled or abandoned.

#### Scenario: GitHub times out while filing
- **WHEN** GitHub times out or is unavailable during issue creation
- **THEN** the board cards exist immediately, the issue intents stay pending, and they are created and linked after GitHub recovers

#### Scenario: GitHub rejects the issue
- **WHEN** GitHub returns a definitive validation or permission rejection
- **THEN** the intent stays uncertain with that reason and is not retried

#### Scenario: Issue created but response lost
- **WHEN** GitHub stores one issue and the response is lost
- **THEN** recovery finds the single marker, links the existing issue and creates no duplicate

#### Scenario: Marker is not unique
- **WHEN** recovery finds two issues with the same intake marker
- **THEN** the intent stays uncertain with that reason and links neither issue

### Requirement: Import existing issues
`POST /api/v1/intake/import` SHALL turn existing open GitHub issues in one intake repository into board cards linked to those issues, without creating any issue. The caller SHALL name either 1 to 10 issue numbers, kept in the caller's order, or a list selection of up to 10 issues in GitHub's default open-issue order (newest first), optionally filtered by labels. Pull requests SHALL never be imported. An issue that is closed, missing, a pull request, or already linked to a card that is not cancelled SHALL be skipped and reported, never failed. A list selection SHALL pass over issues already on the board and take the next ones. It SHALL read at most 20 pages of 10 from an optional `start_page` (default 1, the top of the list) and SHALL return `next_page`, where the listing stopped, or null when the list is exhausted. `start_page` SHALL be part of the normalized request. Cards SHALL be created in the selected order with one caller-chosen priority. The same request key with the same normalized request SHALL return the original result without calling GitHub; a changed request under that key SHALL conflict. A GitHub failure SHALL create nothing. An issue body over the response cap SHALL fail a named import with a distinct non-retry reason and SHALL NOT fail a list import of the rest of that page.

#### Scenario: Captain asks for an issue burndown
- **WHEN** the captain imports the first ten open issues of an intake repository and three of them already have cards
- **THEN** cards are created for the next ten issues not yet on the board, in GitHub's list order, each linked to its issue, and no GitHub issue is created

#### Scenario: Captain names the issues
- **WHEN** the captain imports issues 12, 7 and 30, where 7 is closed and 30 is a pull request
- **THEN** one card is created for issue 12, and 7 and 30 are reported as skipped with their reasons

#### Scenario: Import retried after a timeout
- **WHEN** the caller repeats an import with the same key and request
- **THEN** it receives the original cards and skips without listing GitHub again, and no second card is created

#### Scenario: GitHub unavailable during import
- **WHEN** GitHub is unavailable while the import reads issues
- **THEN** the request fails and no card or intake record is created

#### Scenario: List window is only skips
- **WHEN** the first 200 open-list rows are pull requests or already linked and older open issues remain
- **THEN** the import reports bounded and `next_page`, creates nothing from that window, and a later import with that `start_page` cards the older issues without reading the skipped window

#### Scenario: One issue body exceeds the response cap
- **WHEN** a list page exceeds the response cap because one issue body is too large
- **THEN** that page is re-read in smaller chunks within the same 20-page window, the oversized issue is passed over, and the other open issues on the page can still be imported

### Requirement: Slash command over the same contract
The Mattermost `/board` command SHALL authenticate the slash-command token, map the Mattermost user to a captain-allowlisted filer, and call the intake and status contracts. It SHALL reply in the invoking channel or thread with card and issue links and SHALL refuse unmapped users without creating anything. It SHALL be unavailable while the intake flag is off.

#### Scenario: Human files from Mattermost
- **WHEN** an allowlisted user runs `/board file owner/repo "Title" --issue` while intake is on
- **THEN** one card and one issue intent are created under that user's filer identity and the reply links both
