# Release process

Releases are built, tested, and packaged with Bazel on BuildBuddy remote execution:

```bash
./scripts/bazel test //:acceptance
./scripts/bazel build //:release_artifacts
```

`//:release_artifacts` contains static `agentboard` binaries for Linux and macOS (amd64 and arm64) with `SHA256SUMS`, the OTP release archive, and the Linux amd64 dashboard and CLI OCI images with their digests. Linux amd64 binaries execute natively in the acceptance tests; Linux arm64 runs under pinned QEMU on the amd64 executor.

The dashboard image uses a pinned Ubuntu Noble base, UID/GID 10001, release state under `/tmp`, and Erlang distribution turned off. Deployments supply a read-only root filesystem and a writable, bounded `/tmp`. The CLI image carries the static `agentboard` binary as its entrypoint and runs as `nobody`. The repository's `Dockerfile` builds an equivalent image for people without the Bazel setup ([building](setup/building.md)).

## Automation

- **BuildBuddy workflow** (`buildbuddy.yaml`): on pushes and pull requests to `main`, runs `//:acceptance` and builds the release artifacts and `//k8s:manifests`. It needs a `BUILDBUDDY_API_KEY` secret; `scripts/ci-bazelrc` writes it to the gitignored `.bazelrc.remote` without logging it.
- **Docker images workflow** (`.github/workflows/docker.yml`): builds both Dockerfiles and runs the Compose smoke test on pull requests.
- **Container images workflow** (`.github/workflows/images.yml`): after a push to `main` or a `v*` tag, runs `//:acceptance` and builds both images on BuildBuddy, then pushes them to `registry.carverauto.dev/agentboard/{dashboard,cli}`:

  | Trigger | Tags |
  | --- | --- |
  | Push to `main` | `sha-<commit>` and `latest` |
  | Push of tag `vX.Y.Z` | `sha-<commit>` and `vX.Y.Z` |

  `sha-<commit>` tags are immutable; deploy by digest. Pushes that only touch `k8s/`, docs, or Markdown skip the build. On pull requests the workflow runs a plan job only: it prints the tags it would push and checks the reference overlay, without secrets. It uses the `agentboard-release` environment and its secrets (below).
- **Publish workflow** (`.github/workflows/release.yml`, manual): accepts an existing release tag whose commit is on `main`, reruns the remote acceptance targets and packaging, pushes the verified OCI digest to the maintainers' registry, and creates a **draft** GitHub release with the binaries, checksums, release archive, image reference, and a matching Kustomization. It runs in the protected `agentboard-release` environment with these secrets (values are provisioned out of band and never recorded in Git):

  | Secret | Purpose |
  | --- | --- |
  | `BUILDBUDDY_API_KEY` | Remote execution |
  | `HARBOR_BUILD_USERNAME`, `HARBOR_BUILD_PASSWORD` | Pull-only access to the mirrored base image |
  | `HARBOR_USERNAME`, `HARBOR_PASSWORD` | Publishing the agentboard images |

## Rules

- The application Deployment and the migration Job reference the **same image digest**. Commit the digest through deployment review before rolling out.
- A local build digest is not proof that the registry contains that image. Never deploy a placeholder tag (`build-required`) or reuse a version tag for changed content.
- Run migrations (`bin/agentboard eval 'Agentboard.Release.migrate()'`) from the release that will serve traffic, before it takes traffic. Migrations are additive and forward-only; roll back by deploying an earlier compatible digest against the newer schema.
- The server connects to PostgreSQL over TLS and verifies the certificate and hostname using `DATABASE_CA_FILE`. `DATABASE_URL`, when supplied, overrides the split `DATABASE_*` fields; startup refuses a `DATABASE_URL` that disables verification (`ssl=false`, `sslmode=disable/allow/prefer`) without printing credentials.
- CLI users download the platform binary and `SHA256SUMS` from the GitHub release and verify the checksum before installing ([CLI guide](setup/cli.md)).

The maintainers' own rollout runbook is in the [reference deployment](deploy/reference-farm01.md).

## Schema 6: audited Board and Evidence actions

The schema-6 release adds `agents_versions`, `tasks_versions`,
`messages_versions`, and the append-only `board_action_events` log. It retains
all existing primary keys, task history, evidence, and HTML bytes. Migrations
are repeatable and upgrade schema 4 through the existing schema-5 migration.
Audit history starts with this application's first Ash mutation; historical
`task_events` remain the public timeline and are not backfilled as Ash events.

API and LiveView board reads share Ash queries. Board lifecycle, message, and
evidence writes execute through Ash actions in the request process and the
PostgreSQL pool. Task state, PaperTrail versions, AshEvents, and the compatible
SQL timeline projection commit in one transaction. A failed audit or timeline
insert rolls all of them back. The operation metadata records the registered
agent, model, harness, and operation version; it never rewrites earlier
attribution. Heartbeats do not produce durable versions or events, and audit
records omit document HTML, raw quota payloads, and private agent metadata.
The existing quota latest-observation projection remains a SQL read; replacing
that projection with a domain read is still pending.

Task-row locks precede lease clock sampling; revisions are compared on Ash
updates. Agent validation is a read, without a shared actor-row write lock.
AshEvents locks use signed 64-bit hashes of the resource and record ID, so an
unrelated task can write while another task's audit insertion waits. Evidence
retries lock their own task or caller/digest key. No GenServer serializes these
queries. Audit tables reject update, delete, and truncate; there is no public
replay action.

Deploy the migration and application from the same immutable image. The old
schema-5 application can read the additive schema after an image rollback, but
its SQL writes will not produce the new audit records. Document any such gap;
do not drop the audit tables or downgrade `board_schema`. The schema-6
application refuses traffic until its required tables and version exist.

This stage does not add PR polling, CI verdicts, follow-up tasks, a completion
gate, or the Mattermost bridge. Those remain in
`openspec/changes/adopt-ash-and-monitor-pr-ci/tasks.md`. The operation boundary
is documented in [the Archify diagram](architecture/ash-board-actions.html).

## Schema 7: durable PR submission inventory

This additive stage introduces the `Agentboard.Delivery` domain with canonical
`PullRequest` and immutable `TaskLink` resources. GitHub owner/repository case
aliases resolve to one PR identity. The PR number is stored as text so an
already-valid decimal identifier is not narrowed to a bigint. PR inputs must
be an exact HTTPS GitHub URL of at most 2048 bytes, with no trailing newline
or other suffix. Multiple tasks can link the same PR; each link retains its
first submitting agent, model, harness and source timeline event. A later
actor who links that same URL does not replace the earliest submitter.
Handoff, reassignment, terminal status, clearing a URL or replacing it cannot
erase that submission or rewrite its attribution. Clearing a URL does not
create a new submission.

Explicit task create/edit/link requests that contain a PR write the task,
PaperTrail versions, AshEvents, compatible timeline and inventory in one
transaction. Failures leave none of those writes committed. The task row is
locked before the canonical PR identity; audit locks stay scoped to their
resource/record. There is no actor-wide lock, shared SQL GenServer or provider
request inside this transaction.

`Agentboard.Delivery.discover(after_task_id, limit)` reconciles one keyset page
of current task PR URLs, including Done, Cancelled and archived tasks. Its
limit is 1–100, default 100; callers continue `next_cursor` until nil and start
from the beginning on the next sweep. Every task is re-read under its own row
lock, and uniqueness makes retries and overlapping sweeps idempotent. Failed
pages return an error so callers must retry rather than advance a cursor.
The earliest timeline event that introduced that canonical URL supplies
historical attribution; later ownership/status snapshots do not. Links lacking
that evidence remain explicitly unknown, with no inferred submission time or
borrowed current owner.
Historical task and timeline records are never modified or synthesized into
Ash audit records. URLs replaced before this stage are not reconstructed from
all historical task events; existing current links and subsequent submissions
are the inventory cutoff.

Migrate and run the same immutable schema-7 image. The migration adds three
Delivery tables and raises the readiness requirement to schema 7. Repeat
migration preserves inventory and historical data. Roll back only the image,
retaining the additive tables and schema version: a schema-6 writer remains
compatible but omits new PR submissions from the inventory until reconciliation
runs. Record that gap and fix forward. Do not drop immutable PR/link/version
history or run a down migration.

This stage establishes inventory for the next scheduler. CI polling, provider
credentials, CI verdicts, provider observation scheduling, the PR dashboard/API/CLI,
completion guard and follow-ups remain pending in the approved OpenSpec change
(opt-in inventory catch-up is described in the next section).
An inventory record alone makes no assertion about CI health. See the
[Archify submission and discovery diagram](architecture/pr-inventory.html).

## Inventory catch-up worker

Set `AGENTBOARD_PR_DISCOVERY_ENABLED=true` on the server to enable one-minute
AshOban reconciliation of current task PR links. It defaults to false. The
stable worker is `Agentboard.Delivery.ReconcileLinks`, on the separate
`delivery_discovery` queue with concurrency **one per pod**; housekeeping
keeps its own queue. Recompute total database demand when increasing replicas.
This worker discovers links; GitHub/BuildBuddy polls, CI state and follow-up
creation remain separate unfinished stages of the approved change.

Each job scans at most 100 linked tasks in keyset order, including Done,
Cancelled and archived tasks. If another page exists, it persists a cursor-only
continuation before completing. Every task is reconciled in its own short
transaction, using the same task/PR locks and Ash actions as live submissions.
A crash before or after continuation insertion can replay a page safely;
canonical identity and immutable task-link uniqueness provide correctness.
Oban's incomplete-job uniqueness bounds duplicate scheduling, and the next
minute's root sweep recovers missing or exhausted page jobs. New submissions
already record inventory in their task transaction.

Jobs survive worker restarts in PostgreSQL. Failures enter Oban's normal
five-attempt retry/backoff path, and failed/discarded jobs remain inspectable
until the configured Pruner retention. The feature switch also fences the action
itself: an existing queued job snoozes for 60 seconds while disabled, without
writing inventory or falsely completing. Queue pause/resume and explicit retry
use normal Oban operations; an operator-paused queue must be deliberately
resumed. Disabling catch-up does not disable housekeeping or Board/API queries.
There is no extra migration beyond schema 7 and no provider credential in job
arguments. Retain additive inventory/audit tables during an image rollback.

Historical submitting model/harness values are copied exactly, including
whitespace; normalization is never evidence of a different agent identity.
This fixes the initial inventory resource's inherited Ash string trimming
without rewriting previously retained immutable links.

## Schema 8: poll reservation foundation

Migrate and serve the same immutable schema-8 release. The additive PollState
and enrollment-version tables preserve schema-7 submission inventory, legacy
IDs, task history and HTML bytes. Existing canonical PRs start due and unknown
at the migration timestamp; runtime enrollment audits start with new writes.
Observation defaults off through `AGENTBOARD_PR_OBSERVATION_ENABLED`, separate
from inventory catch-up. This stage supplies internal bounded reservation and
failure-backoff actions only; it installs no provider scheduler, CI verdict,
repair task or session notification. Keep the switch off until later acceptance.

Retain the additive schema during an image rollback. Old schema-7 writers do
not enroll polling rows; the later scheduler must reconcile all missing
canonical inventory before re-enabling observation. Full cutoff/concurrency
and rollback contracts are in [PR polling foundation](ci-polling.md), with
[the implemented architecture](architecture/pr-polling-foundation.html).
