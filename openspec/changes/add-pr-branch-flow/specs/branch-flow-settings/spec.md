## ADDED Requirements

### Requirement: Captain-managed bounded repository display settings
Settings SHALL provide a captain-only explicit save for at most five unique ordered canonical pinned repositories and nullable exact integration refs for locally tracked repositories. Search SHALL be paginated at twenty repositories; integration roles SHALL be editable without pinning. Pins SHALL affect display only and neither setting SHALL enroll arbitrary GitHub repositories or alter schedules/cooperation. Provider default-ref metadata SHALL be read-only.

#### Scenario: Save ordered pins and unpinned integration role
- **WHEN** an authorized captain pins eligible repos in an explicit order and configures an integration ref for another tracked repo
- **THEN** the saved pin order and independent role configuration are retained with actor/revision and no new repository is enrolled

#### Scenario: Exceed cap or duplicate repository
- **WHEN** a save includes six pins, duplicated canonical repos, an untracked repo, or invalid ref input
- **THEN** the save is rejected atomically with a field-specific explanation and the unsaved draft remains available

#### Scenario: Integration equals known default
- **WHEN** a supplied integration ref equals the currently verified default
- **THEN** the save rejects the redundant role; if the default later changes to an existing integration ref, the view deduplicates it and warns without deleting historical evidence

#### Scenario: Pinned repository becomes unavailable
- **WHEN** a persisted pin leaves eligible inventory or is renamed
- **THEN** Settings shows the stale pin for explicit repair, the strip fills the vacant eligible slot by ranking and no unrelated repository silently assumes the pin identity

### Requirement: Authorized atomic revision-checked configuration changes
Every configuration mutation SHALL recheck current captain authority, validate server-held expected revisions and apply the intended change atomically through audited resource actions. Concurrent edits SHALL not silently overwrite one another. Uncertain outcomes SHALL be reconciled from persisted revision before retry. Viewing or cancelling configuration SHALL never write it.

#### Scenario: Two settings editors save concurrently
- **WHEN** another editor changes a revision after this editor loads
- **THEN** the stale save is rejected, its local draft is preserved and Reload is explicit rather than an automatic overwrite

#### Scenario: Captain capability expires
- **WHEN** the capability expires after the editor opens but before Save
- **THEN** no configuration write occurs and the UI explains that captain authorization is required

#### Scenario: Double submit or uncertain response
- **WHEN** a user repeatedly presses Save or the accepted save response is lost
- **THEN** duplicate in-flight submission is prevented and a revision reread reconciles whether the intended save occurred before any retry

#### Scenario: Cancel or leave with unsaved changes
- **WHEN** the user closes or navigates away from a dirty editor and confirms discarding where prompted
- **THEN** only the local draft is discarded and persisted pins/intake configuration is unchanged

### Requirement: Settings navigation and intake effects are explicit
Settings SHALL distinguish pin display changes from integration-intake scope changes, explain the latter beside Save, and preserve pending edits against late loads or saves. Dismissal and Back/Forward SHALL not reopen an editor. A save that already committed SHALL be reported truthfully on the next reread without implying cancellation undid it.

#### Scenario: Late load after repository switch
- **WHEN** the user switches repository editors before an older load returns
- **THEN** the older response cannot replace the new repository's draft or focus

#### Scenario: Save commits after user leaves
- **WHEN** a save is accepted server-side but the user navigates before its response arrives
- **THEN** the response does not reopen the editor and the next explicit visit reads the actual committed revision

#### Scenario: Integration role removal
- **WHEN** the captain saves a removal of an integration ref
- **THEN** the confirmation context explains future scoped-intake eligibility changes and existing retained red obligations stay visible and unresolved
