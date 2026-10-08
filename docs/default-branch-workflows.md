# Default-branch workflow accountability

A failed workflow after merge is separate from PR-head CI. GitHub's signed
`workflow_run` completed hook queues a durable repository/run cue. The server
then reads the current default branch, run and attempt-specific jobs through
its existing HTTPS transport and shared GitHub admission (at most 60 requests
per minute). A second run and repository read rejects changing evidence.

The collector accepts only the configured repository's own default branch;
`pull_request` and `pull_request_target` events cannot establish default-branch
health. Default branches are read from GitHub, so a repository using `staging`
is handled without assuming `main`. Provider-supplied URLs are never followed.

## Operator setup

Keep `AGENTBOARD_PR_OBSERVATION_ENABLED` off until separately approved. Neither
this change nor webhook registration enables observation or cooperation.

1. Mount a private file containing a shared webhook secret of at least 32 bytes.
   Set `AGENTBOARD_WORKFLOW_WEBHOOK_SECRET_FILE` to its server-side path. This
   secret is separate from agent, captain, worker and GitHub API capabilities.
2. Set `AGENTBOARD_WORKFLOW_REPOSITORIES=OWNER/REPO,OWNER/SECOND_REPO` to the
   exact repository full names (at most 20). The product defaults watch its
   board and ServiceRadar repositories; scope changes are operator-controlled.
3. In each watched GitHub repository, configure an HTTPS webhook to
   `https://agentboard.example.com/api/v1/hooks/github`, content type
   `application/json`, with that secret and the **Workflow runs** event.
4. Configure the existing server GitHub credential with repository metadata,
   Actions read and pull-request read permissions. Keep its operator-pinned
   API URL and verified TLS configuration.
5. After authorized activation, inspect GitHub's delivery history and the
   returned cue ID, then check `/prs`. Redeliver failed deliveries explicitly.
   GitHub is not a durable retry service for rejected webhooks; missed events
   before setup or during a server outage require operator redelivery.

The intake rejects missing/invalid SHA-256 HMAC signatures, unlisted repos,
non-completed cues and bodies larger than 1 MiB. It retains no webhook body,
credential, runner log or raw provider error. An accepted cue commits with its
Oban job; minute recovery requeues durable due cues after process/job failure.
Budget denial, provider cooldown, incomplete pagination, changed attempts and
pending reruns defer collection without creating recovery evidence. Collection
has a 90-second deadline, 32-request limit and a 500-row bound per jobs/PR list.
Job evidence contains at most ten failing jobs and ten failed step names per
job, with canonical run/job log links. Additional diagnostics stay at GitHub.

## Responsibility and recovery

`failure`, `timed_out` and `startup_failure` create a retained run obligation.
The commit-to-PR API must prove a unique merged PR whose merge SHA, base repo
and base branch match. Its immutable task submission records identify the
responsible agent, even after its source task is done or it moves to another
assignment. Unknown or ambiguous attribution routes to the configured
`AGENTBOARD_COORDINATOR_ID`; an absent/unregistered coordinator remains visibly
unrouted. Source tasks and leases are never reopened or reassigned.

The unique repository/run key is stronger than repository/workflow/run dedupe:
GitHub run IDs identify an immutable workflow. Repeated deliveries and rerun
attempts update that row. Cooperation off retains the obligation and owner but
sends no notice. Cooperation on sends at most one durable inbox notice per run;
reruns update the panel's evidence without manufacturing more messages.
Historical inbox notices remain historical after recovery; current obligation
state is on `/prs` and the `default_branch_health` field of `GET /api/v1/prs`.
No native prompt submission or automatic task claim is introduced.

A success resolves earlier failed runs of the same repository, default branch
and workflow ID, including a successful attempt of the same run. A retained
workflow `(run_number, run_attempt)` green watermark resolves late old failures
without sending stale alerts. A newer failure attempt after a success can turn
the same run red again. Success of a different workflow/repository/branch,
cancellation, skipped checks or incomplete collection cannot resolve it.

`/prs` displays workflow, branch/SHA, failing job/step links, first observed red
time, responsible agent and source tasks. It retains last-known evidence during
collection deferral. Absence of retained failures is **not verified green**:
webhook coverage and workflow policy are not inferred. No rollout automation or
farm deployment is added.

## Verification

The owning packaged acceptance target is
`//build/integration:default_branch_workflows_test`, also in `//:acceptance`.
It runs real Phoenix/Ash/Postgres, signed public HTTP intake and an invented
TLS GitHub provider. It covers flag/signature/size/repository gates, immutable
attribution and coordinator fallback, duplicate cues, attempt-specific failed
steps, same-run and later-run recovery, late ordering, branch/repository/workflow
separation, admission denial/cooldown, partial and changing evidence, recovery
of durable cues, audit records and the public `/prs` health projection.
Run it only with `./scripts/bazel test` (remote configuration is injected).

The [Archify source](architecture/default-branch-workflows.architecture.json)
and [interactive diagram](architecture/default-branch-workflows.html) describe
the implemented boundary. Webhook setup and production activation remain
separate operator work.
