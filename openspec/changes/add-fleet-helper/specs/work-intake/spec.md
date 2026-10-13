# Work intake

## Purpose

Let any authorized client file work as board cards and, optionally, GitHub issues through one idempotent contract that does not depend on GitHub availability.

## ADDED Requirements

### Requirement: Idempotent intake request
The server SHALL accept an intake request of 1 to 10 items with a request key. It SHALL create the intake record, each board card and each pending issue intent in one transaction. The same key with the same normalized payload SHALL return the original result; a changed payload under that key SHALL be rejected as a conflict.

#### Scenario: Bot retries after a timeout
- **WHEN** a helper repeats an intake request with the same key and payload
- **THEN** it receives the original cards and issue states and no second card or issue is created

#### Scenario: Repository outside the filer's scope
- **WHEN** an item names a repository the filer may not file into
- **THEN** the whole request is rejected and nothing is created

### Requirement: GitHub issue outbox
For items that request an issue, the server SHALL create the issue outside the board transaction with a hidden body marker naming the intake item, then link the card to the issue. After a lost response it SHALL search the repository for the marker and adopt a match before any retry. An unresolved create SHALL remain visibly uncertain until reconciled or abandoned.

#### Scenario: GitHub unavailable while filing
- **WHEN** GitHub refuses or times out during intake
- **THEN** the board cards exist immediately, the issue intents stay pending, and they are created and linked after GitHub recovers

#### Scenario: Issue created but response lost
- **WHEN** GitHub stores the issue and the response is lost
- **THEN** recovery finds the marker, links the existing issue and creates no duplicate

### Requirement: Slash command over the same contract
The Mattermost `/board` command SHALL authenticate the slash-command token, map the Mattermost user to a captain-allowlisted filer, and call the intake and status contracts. It SHALL reply in the invoking channel or thread with card and issue links and SHALL refuse unmapped users without creating anything.

#### Scenario: Human files from Mattermost
- **WHEN** an allowlisted user runs `/board file owner/repo "Title" --issue`
- **THEN** one card and one issue intent are created under that user's filer identity and the reply links both
