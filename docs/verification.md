# Verification evidence

## Horizontal Kanban correction (2026-10-06)

The captain rejected the initial wrapped layout below. The final board keeps all seven lanes in one horizontal row. Above 1100px, fluid tracks, tighter gaps and card padding fit laptop/desktop widths without board scrolling. At smaller widths the board itself scrolls horizontally with readable 175px lanes; the page stays contained. Task IDs, owner names and long task titles wrap inside cards. No lane is hidden and no typography was reduced.

Remote [image startup 6a3e70f4](https://carverauto.buildbuddy.io/invocation/6a3e70f4-234e-451a-bad6-5ab351590e1b) passed; [packaging 282077f4](https://carverauto.buildbuddy.io/invocation/282077f4-f817-4d36-a885-aea1fe9c0138) produced `sha256:5aa2bcc10cccb6adaa3007887150745012e95aec9a9e997b4f294b17568e853c`, published as `kanban-1d0bc8a4064b`. Server dry-run and deployment-only apply succeeded, rollout completed, and one ready farm01 pod runs that exact digest. No migration was rerun and no v0.1.0 release asset was overwritten.

Chrome inspected the live served CSS without overrides at 11 widths from 320 to 1920px, including both sides of the 1100px breakpoint. All seven lanes share one row; page width equals viewport width throughout, and desktop board widths equal their scroll widths. At 320px, a temporary browser-only 200-character title/ID/owner probe remained contained. [Final geometry and image evidence](verification/farm01-kanban-board.json), [desktop screenshot](verification/farm01-kanban-desktop.png) and [mobile screenshot](verification/farm01-kanban-mobile.png) supersede the older wrapped-layout evidence. Image-capable visual review confirmed horizontal lane order and readable desktop cards, with contained horizontal navigation on mobile.


## Initial responsive board attempt — superseded (2026-10-06)

The seven fixed 235px columns previously scrolled 1735px inside a 1380px board at a 1440px viewport. Status lanes now wrap into rows with a 235px preferred minimum; narrow screens retain the existing single-column layout. Long task IDs, task titles, and owner names wrap within their cards (the title rule landed in-tree after the image pinned below and awaits rebuild/repin/redeploy). All seven status lanes remain accessible and repository/owner filters are unchanged.

Remote [acceptance bf87ac6e](https://carverauto.buildbuddy.io/invocation/bf87ac6e-7d57-471d-979c-351e9982d1fb) passed all 10 targets. Remote [packaging 01e620e0](https://carverauto.buildbuddy.io/invocation/01e620e0-7a1f-4412-9975-0a6c3ff4e955) produced dashboard digest `sha256:80e3947c9f7aab154fb7be940c2f3305ea4398d42142b6a6b0b4bf75759543d2`, published under `responsive-b7a1142966e9`; the v0.1.0 tag and CLI assets were not republished. A temporary project-scoped push credential was deleted after publication.

The farm01 overlay pins the new digest. Server dry-run and deployment-only apply succeeded; rollout completed with one ready pod running that exact image ID. No database migrations were needed or rerun. The prior image digest remains available for rollback through the overlay.

Chrome checked the live served application (without injected CSS) at 1920, 1440, 1280, 1024, 768, 700, 500, 390 and 320px. Both page and board fit their measured widths at every size; all seven lanes remained present. A temporary browser-only 200-character task ID and owner probe wrapped at 390px without overflow. [Geometry/runtime evidence](verification/farm01-responsive-board.json), [desktop dark screenshot](verification/farm01-responsive-desktop.png) and [mobile light screenshot](verification/farm01-responsive-mobile.png) record those checks. Visual inspection confirmed readable cards and wrapping header/filters. Remote checks ran through BuildBuddy; no application builds or tests ran locally.


All compilation, application tests, dependency compilation, and packaging run through `./scripts/bazel` on BuildBuddy remote execution. No Go/Mix application build or test runs on this Mac. PostgreSQL integration uses a disposable loopback PostgreSQL 18.3 fixture with SCRAM, a generated CA and CA-signed server certificate, verified TLS, temporary data, and process cleanup; it never uses farm01 credentials or data.

## Completed farm01 rollout (2026-10-06 UTC)

Agentboard v0.1.0 is live on the private LAN at [the dashboard](https://agentboard.farm01.carverauto.dev). The [delivery task](https://agentboard.farm01.carverauto.dev/tasks/agentboard-first-rollout) links the served [Archify architecture](https://agentboard.farm01.carverauto.dev/documents/1) and [portable OpenSpec review](https://agentboard.farm01.carverauto.dev/documents/2). The Lavish proposal review was approved and ended; the durable copy is served by Agentboard.

[Release workflow](https://github.com/carverauto/agentboard/actions/runs/37412361934) succeeded: [all ten acceptance targets](https://carverauto.buildbuddy.io/invocation/1619e523-4dd1-456d-bab1-63a190975626) passed (four executed, six cached), and [remote packaging](https://carverauto.buildbuddy.io/invocation/3f75be74-2a0f-4819-a307-0b5666b57c5f) produced `sha256:213d5a68d1316fae4803fc77a5461024a3541743b0c98e8f630db3307d06f16b`. Harbor, both rendered app/migration manifests, and the running container image ID match that digest. Every published CLI checksum passed; the installed Darwin ARM64 CLI matches its release asset and executes real HTTPS commands. No compilation ran on this Mac.

[Normalized runtime evidence](verification/farm01-runtime.json) records two healthy PostgreSQL 18.6 instances, two Bound 20 GiB local-path-cnpg volumes, completed additive migrations, API 1/schema 4, app readiness, exact-host Certificate Ready, accepted/resolved routes and ready Gateway listeners. DNS resolves to private `192.168.7.10` with Cloudflare proxying disabled and TXT owner `external-dns-farm01`; verified HTTPS and HTTP 301 redirect passed. Live container probing confirmed UID 10001, writable `/tmp`, and a root write rejected as “Read-only file system.”

[Live CLI smoke](verification/farm01-cli-smoke.json) passed distinct Codex/shell registrations, one-success/one-conflict concurrent claims, explicit renewal and heartbeat, attributed updates, handoff/inbox acknowledgement, an explicitly synthetic quota snapshot, idempotent documentation uploads, metadata-only reads and all five dashboard routes. Document download is attachment-only with sandbox CSP, nosniff and no-store.

Final watch validation exposed the Gateway's default 15-second request timeout interrupting NDJSON responses. The farm01 HTTPRoute now disables that timeout only for the three exact task/message/quota watch paths; ordinary requests retain their default. [Live stream evidence](verification/farm01-watch-streams.json) records each installed v0.1.0 CLI watch running for 45 seconds over public HTTPS with one initial snapshot, periodic fallback snapshots, no reconnects or stderr, and clean cancellation. The Gateway accepted/resolved the updated route after server-side dry-run validation. The delivery task's completion also reached CLI watch and LiveView through the change notification before this route fix. This is a manifest-only correction; the immutable release image and CLI assets are unchanged. Timeout semantics follow the [Gateway API contract](https://gateway-api.sigs.k8s.io/reference/api-types/httproute/#timeouts-optional).

[Actual Chrome isolation evidence](verification/farm01-browser-isolation.json) confirms inline scripts run in an opaque origin (`null`), parent DOM access fails, API fetch fails, and iframe `contentDocument` is null. The live Archify theme control switches between [dark](verification/farm01-archify-dark.png) and [light](verification/farm01-archify-light.png); an image-capable review found readable nodes/labels and no overlap. The [portable proposal at 500 px](verification/farm01-openspec-500.png) and wrapper fit without horizontal overflow.

Merged delivery/fixes: [app PR #3](https://github.com/carverauto/agentboard/pull/3), [ARC checkout PR #4](https://github.com/carverauto/agentboard/pull/4), [mirror authentication PR #5](https://github.com/carverauto/agentboard/pull/5), and GitOps [edge #152](https://github.com/carverauto/gitops/pull/152), [storage #154](https://github.com/carverauto/gitops/pull/154), [DNS #155](https://github.com/carverauto/gitops/pull/155). The protected release environment uses separate mirror pull-only and Agentboard publisher robots; Kubernetes uses its own pull-only robot. Credentials were provisioned out of band and are absent from this evidence.

ExternalDNS now selects the parent zone explicitly and runs pinned v0.16.1, avoiding v0.15.1's unconditional regional-hostname API call ([guarded implementation](https://github.com/kubernetes-sigs/external-dns/blob/v0.16.1/provider/cloudflare/cloudflare.go#L412)). It is Ready with no restarts. Existing unrelated agent-gateway TXT normalization warnings remain; its owner/content were preserved. Darwin AMD64 runtime execution remains untested. The v0.1.0 tag is unsigned after local GPG pinentry failed; checksums and registry/runtime digest matching are recorded separately in [release assets](verification/farm01-release-assets.json) and [build results](verification/farm01-release-build.json).

Both OpenSpec task sets are complete: implement-agentboard-v1 53/53 and publish-task-documentation 5/5. The sections below retain earlier preparation checkpoints; “pending,” “absent,” and old digests there describe historical state.

## Application acceptance

[Full M1–M3 public-boundary acceptance](https://carverauto.buildbuddy.io/invocation/4bff2355-d9b1-495b-85ae-49ea24e14982) passed on 2026-10-05. The packaged Phoenix release and real Go CLI exercised registration with Codex/Claude/shell identities, metadata/URL edits and generated IDs, concurrent claim conflict, model provenance, status edges, explicit renewal and expired recovery, per-task row-lock independence, task/event and handoff rollback, keyset pagination, independent heartbeat/lease freshness, messages and recipient-only acknowledgement, full snapshots larger than 100 rows, startup races, listener reconnect, actual HTTP transport interruption with offline writes, stream cleanup/cancellation, schema 5/6 quota ingestion/raw retention/idempotence/ordering/uncertainty, and quota stream recovery.

The real HTTP/WebSocket LiveView boundary exercised all read-only routes, escaping/safe links, feed filters, unchanged task history and message read state, notification/fallback updates, and retained-data unavailable state during an actual database outage. Health stayed live while readiness failed. This is functional UI evidence, not a browser visual/accessibility audit.

[Go client/CLI and rate-limiter checks](https://carverauto.buildbuddy.io/invocation/0087980d-4144-4fe3-a2db-62d8ec75d351) passed: verified HTTPS/private CA behavior, 429 Retry-After seconds/date handling and bounded cancellable retries, rejected redirects, no replay of uncertain writes, exit codes, request/stream capacity and atomic admission. The full acceptance also drove the real API into 429 and verified no valid task write committed after throttling.

[Packaged migrations/schema checks](https://carverauto.buildbuddy.io/invocation/ef2c5d8d-c16c-4a2f-8185-7bf2f5d510a7) passed additive schema 1–3 migration and repeat migration, append-only constraints, TLS behavior and assets. Test PostgreSQL 18.3 is distinct from the confirmed CNPG 18.6 image; production operator/image compatibility remains a rollout check.

## Farm01 read-only prerequisite observations

Observed 2026-10-05 through the existing `farm01` kubeconfig, without applying configuration or reading secret contents:

- `farm01-edge/farm01-gateway`: Accepted and Programmed; existing listeners Accepted/Programmed/ResolvedRefs. Current private address is **192.168.7.10** (older repository comments name a different private range). Discover the reconciled address at rollout; do not hardcode the historical VIP.
- Existing `farm01-wildcard` Certificate Ready=True. Historical revoked-token comments do not describe current wildcard readiness.
- `default/external-dns`: one ready replica, service + gateway-httproute sources, existing three domain filters, TXT owner `external-dns-farm01`, TXT registry, upsert-only.
- CNPG operator running in `cnpg-system`.
- **StorageClass `local-path-cnpg` is absent**. Existing classes are `local-path` and `scylladb-local-xfs`; neither silently replaces the selected class.
- No CNPG Cluster in namespace `agentboard`; agentboard Certificate/listeners/routes and application smoke are not deployed or verified.
- The confirmed PostgreSQL tag resolves to `sha256:94aa172fc7ce295d482f5fe8bcf8d1e3423f30c15ba40c7d34114b68dc152b0a` in GHCR.

Application rollout, new Certificate readiness, agentboard Gateway/route conditions, DNS, HTTPS/redirect, production DB TLS/CA, storage provisioning, secrets, and trusted-network exposure remain untested until the release/operator procedure is authorized and its prerequisites exist.

## Release packaging

[Nonroot OCI-rootfs startup/migration/assets/probes](https://carverauto.buildbuddy.io/invocation/7556d8f7-ad9f-4ab6-8d3c-fbe3f5b038b9) passed. The remote test exports the real validated OCI layers and runs in chroot as UID/GID 10001 with app/config paths unwritable and writable /tmp. Remote device creation is unavailable, so /dev/null is a fixture file; actual container device/read-only mounts remain rollout checks. This test exposed and verified the fix for root/app layer directory permissions.

[Cross-platform CLI package checks](https://carverauto.buildbuddy.io/invocation/33ac5656-d53c-413c-9534-51cccf82685f) passed format/checksum checks for all four binaries, native Linux amd64 and pinned QEMU Linux arm64 execution. The companion image test in that earlier invocation failed before the permission fix; its later passing invocation is linked above. Darwin runtime execution is untested.

GitOps companion is [draft PR #152](https://github.com/carverauto/gitops/pull/152). Kustomize rendering, normalized preservation checks, and shell syntax passed. It has not been merged or applied. Artifact publication, workflow credentials, immutable registry availability and live rollout remain prerequisites.

Final application/configuration checks in [BuildBuddy](https://carverauto.buildbuddy.io/invocation/0f60578e-1be6-4bc6-8247-14500e92df63) passed all eight application targets after CLI cleanup, the human expired-claim label, and DATABASE_URL precedence over deliberately invalid split fields. Its bare workflow-tool check failed because the pinned image has no Bazel driver; release automation now installs pinned Bazelisk/GitHub CLI explicitly. [Corrected workflow-tool check](https://carverauto.buildbuddy.io/invocation/e841aa31-05a1-4515-b322-6c770cfdc670) passed in that pinned image.

[Release-artifact aggregate](https://carverauto.buildbuddy.io/invocation/6497269d-2412-44fa-9b02-cfdde7560f7f) passed for the CLI archive, OCI layout/digest, OTP archive and manifests. After the TLS startup guard, the [remote digest rebuild](https://carverauto.buildbuddy.io/invocation/702bdbe4-43c5-4f57-96c4-17246e6e9478) produced `sha256:e67b703253ffd06cc66b11951d9905be25528fab179cb932bed11e9e001f8829`, now shared by the farm01 application and migration Job. It is not yet published to Harbor.

The [packaged TLS guard regression](https://carverauto.buildbuddy.io/invocation/36a7da37-32fb-4847-9fc9-3bb8ce29017d) passed remotely: TLS-downgrading DATABASE_URL settings refuse startup without printing credentials. The [post-guard nonroot image startup check](https://carverauto.buildbuddy.io/invocation/16c5b56f-3302-4b84-acc8-8c1f9d125a57) also passed, including valid DATABASE_URL precedence over deliberately invalid split connection fields.

After refreshing the pin, the real Kustomize render was parsed and checked: both Deployment and migration Job resolve to the rebuilt digest, with namespace `agentboard`, selected `local-path-cnpg` storage and read-only containers preserved. GitHub currently reports a passing GitGuardian check; application build and runtime evidence comes from the linked BuildBuddy invocations.

Structural review split CLI command construction and stream consumption into private helpers, with public CLI/watch recovery checks passing afterward. The analyzer reported no major regression to existing code, and still flags new-code complexity in retry/watch state machines, command construction and schema/HEEx declarations; this is not a claim of zero new debt. OTP/Phoenix callbacks and dynamic context dispatch are supported by runtime tests rather than treated as removable dead code from a name-based call graph.

## Documentation and CLI release preparation (2026-10-05)

The captain selected `agentboard`, avoiding ApacheBench's `ab`; artifacts target Linux/Darwin amd64/arm64 and installation at `~/.local/bin/agentboard`. Full remote acceptance [d2f4b69c-6d57-482a-950a-eedeb658a95d](https://carverauto.buildbuddy.io/invocation/d2f4b69c-6d57-482a-950a-eedeb658a95d) passed all 10 targets after the documentation feature. Its public HTTP/CLI integration covers live-owner and expired-owner rejection, canonical retries, atomic attributed events/revisions, the 100-version bound, UTF-8/NUL/size rejection, immutable storage, metadata-only output, viewer/download links and CSP response semantics. Actual browser isolation and the final wrapper runtime remain rollout checks until recorded below.

The `publish-task-documentation` proposal automatically opened in Lavish using Agentboard's CSS tokens; the captain replied “looks good” and ended the review. The portable export has no unresolved local assets or nested frames. Archify passed nine deterministic checks, plus bounded browser containment/behavior checks and separately recorded image-capable review; see [visual evidence](architecture/task-documentation.visual-review.md).

GitOps [PR #154](https://github.com/carverauto/gitops/pull/154) persists `local-path-cnpg` with Retain/WaitForFirstConsumer. Live CNPG has two healthy PostgreSQL 18.6 instances and two Bound 20 GiB volumes. The exact-host Certificate is Ready and both Agentboard Gateway listeners have Accepted/Programmed/ResolvedRefs true at private address `192.168.7.10`. App migration, image publication, HTTPRoutes/DNS/HTTPS and live API/CLI smoke are still pending; task 6.7 stays incomplete until those checks pass. Secrets were provisioned only into the protected release environment and Kubernetes, using scoped Harbor robots; no values are in Git or this evidence.

The remotely built Darwin ARM64 CLI was checksum-verified and installed at `~/.local/bin/agentboard`; it executed `version` successfully as `0.1.0` on this Mac (SHA256 `49d653f327817c63a9749fded45abaea430abf3c08e28a4bc22c21dcc2541dd3`). Final remote formatting/package invocation [42ede39c-d352-452a-85a1-d4492b7b13dd](https://carverauto.buildbuddy.io/invocation/42ede39c-d352-452a-85a1-d4492b7b13dd) produced no formatting changes and dashboard digest `sha256:d1fc696a605fd10a0f704745f4b3103cce1fac53ecb521d977d7931c0c227df6`, now pinned in the farm01 overlay. Workspace canonical, Codex and captain skill links were installed without replacing existing workflows.

After removing the extra EOF blank line from the three new Elixir files, remote release-artifact rebuild [c021512d-315c-46e4-9401-dd3d30659719](https://carverauto.buildbuddy.io/invocation/c021512d-315c-46e4-9401-dd3d30659719) produced dashboard digest `sha256:213d5a68d1316fae4803fc77a5461024a3541743b0c98e8f630db3307d06f16b`, now pinned in the farm01 overlay; the d1fc digest above is historical preparation evidence for the pre-fix source. Image publication and live rollout remain operator steps.

## Mattermost on farm01 (2026-10-06)

The additive resources were applied by hand, the same way the rest of `agentboard` is managed (kubectl client-side apply; no Argo CD Application targets farm01's `agentboard`). CNPG operator 1.25.0 provides the `Database` CRD. `kubectl diff` showed the only Cluster change was the new managed role. After that apply, both `agentboard-db` pods kept their UIDs and had zero restarts. Managed roles `agentboard` and `mattermost` are reconciled, the `mattermost` Database CR reports `applied: true`, and PVC `mattermost-data` is Bound on `local-path-cnpg`.

`mattermost/mattermost-team-edition:11.11.1@sha256:6ad5912b…aa85` (Team Edition build) is Ready with 0 restarts and logs `Server is listening on [::]:8065`. PostgreSQL shows database `mattermost` owned by `mattermost` with 211 `db_migrations` rows (max version 213), and all Mattermost connections use SSL. The role connection limit is 40. A second start loaded the persisted `config.json` from the PVC.

Both HTTPRoutes are Accepted/ResolvedRefs on the wildcard `https`/`http` listeners. `mattermost.k8s-farm.carverauto.dev` resolves to the Gateway's `192.168.7.10`. `https://…/login` returns 200 with the Mattermost web app over a verified Let's Encrypt `*.k8s-farm.carverauto.dev` certificate, and HTTP returns 301 to HTTPS. `/api/v4/system/ping?get_server_status=true` reports database and filestore OK. The client config reports the HTTPS Site URL, version 11.11.1 and `NoAccounts: true`. The `/api/v4/websocket` upgrade returns 101 through the Gateway. Unauthenticated sockets are closed by Mattermost after about 6s, both through the Gateway and direct to the Service. A long-lived authenticated websocket check needs the first account and remains a captain check. The agentboard dashboard stayed Ready (`/health/ready` 200, same pod, 0 restarts) and `agentboard-db` stayed healthy at 2/2.

Expected startup noise: Playbooks needs a Professional license and does not activate on Team Edition, and the SMTP connection test fails because no mail server is configured.


## Shared context rollout (2026-10-06)

Merged PR [#21](https://github.com/carverauto/agentboard/pull/21), commit `c8600a67e31e240df2ba39f534124dda7667a3c8`, passed the main [container publication workflow](https://github.com/carverauto/agentboard/actions/runs/37508880253), including full remote acceptance. The scoped migration Job `agentboard-migrate-c8600a6` completed before rolling `agentboard-dashboard` to immutable digest `sha256:d269d92f941538ecbdcf2f56bb03fd4a1d90ffef8a64c03e7abe373d4cbab497`. The new replica is Ready; HTTPS readiness and CLI metadata report schema 5.

CNPG remains healthy at two instances on PostgreSQL 18.6 with pg_textsearch 1.5.1. The API database role remains nonsuperuser. Migration preserved all pre-existing task events through ID 125 and documents through ID 43, verified by bounded content hashes. The existing Archify and portable OpenSpec HTML downloads retained exact bytes. Mattermost remains Ready and its HTTPS system ping reports OK.

The merged Darwin ARM64 CLI was cross-built remotely in [BuildBuddy](https://carverauto.buildbuddy.io/invocation/7f1704e1-d32d-4e45-aed2-16e4809e6798), checked against bundled SHA256SUMS, and installed at `~/.local/bin/agentboard` (SHA256 `c845117a3cf33b84d67c4ec21dcc3361f23e1ffdbb09c78a79e437dbc394991e`). All 11 bundled workflows were upgraded through the managed installer in `~/.agents/skills`. This installs skills and context guidance, not wakeup hooks.

Live HTTPS CLI checks published [a rollout fact](https://agentboard.farm01.carverauto.dev/context/1), retried it idempotently without a second entry, searched it with a positive BM25 score and backend `pg_textsearch-1.5.1`, read the catch-up feed without consuming it, explicitly acknowledged it twice, and confirmed the feed then excluded it. A [delivery summary](https://agentboard.farm01.carverauto.dev/context/3) retains the directed `supports` relationship to that fact and links to PR/task/commit/document evidence.

Actual Chrome search-form submission with blank optional filters passed. Connected LiveView search results fit both 1440px desktop and 390px mobile viewports. The seven-column Kanban still fits desktop with ten collapsed Done cards, and the quota summary and details remain available. Entry-detail evidence URLs exposed a mobile overflow (421px content at 390px viewport). The follow-up wrapping rule is a source fix requiring a new merged build and rollout; it is not part of the deployed c8600a6 image. Full rollout receipts and screenshots are retained in the operator's `~/agent-tools/agentboard-shared-context-rollout.json` and `agentboard-context-live-api.json`.


### Shared context final acceptance (PR22, 2026-10-06)

Merged commit `74e9d1daa75d9a602f0d3ff04bcf7e5bc9265e69` passed all 14 [remote acceptance targets](https://carverauto.buildbuddy.io/invocation/45724643-40c3-45cb-baf8-4ac38a14c05c), including context publication/retrieval and connected LiveView checks for escaped hostile text. The [Container images workflow](https://github.com/carverauto/agentboard/actions/runs/37519812870) and [Docker Compose smoke workflow](https://github.com/carverauto/agentboard/actions/runs/37519814006) passed. Migration Job `agentboard-migrate-74e9d1d` completed, then the dashboard rolled to `sha256:d893984ed1495ac9d468ae1687353dc5032727933ebe7aaab0dc160c57864084` with one Ready replica and schema 5.

Actual production Chrome checks now show `scrollWidth = clientWidth = 390` for both entry details and submitted search results with blank optional filters. Evidence URLs wrap with the deployed rule; the detail page also fits at 1440px. The fingerprinted stylesheet changed to `/assets/app-4b8254cfe9751583cf91f503eb0788dc.css`. No injected preview styles were used in this acceptance. The earlier mobile overflow is resolved and all six OpenSpec implementation tasks are complete.

Live HTTPS API-only CLI checks again passed publication, identical retries, directed provenance links, ranked BM25 search, repeat unread reads and idempotent explicit acknowledgements. Bounded pre-roll hashes remained identical for task events through ID 130, documents through ID 43 and context entries through ID 3. The Archify/OpenSpec downloads retained exact bytes. CNPG remains healthy at two instances; both application roles remain nonsuperuser and Mattermost HTTPS ping reports OK.

The new CLI OCI image is identical to the previously installed release (`sha256:2c65d5f24dc54e40ae0e176b433fa1aaed7bbd3b82bf26b4854ebd50a29fb8a5`), so no CLI rebuild/reinstall was needed. The installed Darwin binary checksum and all 11 managed global skill bundles were reverified. Skills provide retrieval/publication guidance; automatic worker wakeups and PR CI accountability remain the separate `adopt-ash-and-monitor-pr-ci` work.

Operator receipts and actual production screenshots are retained in `~/agent-tools/agentboard-shared-context-complete-74e9d1d.json` and `agentboard-context-{detail-mobile,search-mobile,detail-desktop}-74e9d1d.png`. This completion record and overlay pin touch no application source and do not require another application rollout.


## Audited Ash foundation rollout (PR27, 2026-10-06)

Merged PR [#27](https://github.com/carverauto/agentboard/pull/27), commit `2e89bb0cc13218deab1304db38b4536d16721e87`, passed all 14 [remote acceptance targets](https://carverauto.buildbuddy.io/invocation/5a2dc6d2-b7bc-4e84-aff2-0d0677832594) before the [publication workflow](https://github.com/carverauto/agentboard/actions/runs/37543466858) published dashboard digest `sha256:3bd61e8e7459a1430067b220d786305da4500c954927733ff3e68e45253da9a7`. A read-only registry credential verified the published commit tag against that digest without exposing its value. Both server dry runs succeeded, and the Deployment diff changed only the image pin. Scoped migration Job `agentboard-migrate-2e89bb0` completed before the dashboard rolled to the same digest. One Ready pod, its container image ID, HTTPS readiness and the installed API-only CLI confirm schema 6.

The [normalized receipt](verification/farm01-ash-foundation.json) records unchanged hashes for existing task events through ID 157, documents through ID 47 and context entries through ID 4. Live CLI lease renewal and progress updates produced matching task timeline entries plus PaperTrail/AshEvents records attributed to `codex-agentboard-rollout / gpt-6 / codex`. An identical Archify upload returned existing document 46 idempotently. Downloads of [Archify 46](https://agentboard.farm01.carverauto.dev/documents/46) and [portable proposal 47](https://agentboard.farm01.carverauto.dev/documents/47) retained the committed HTML bytes. Chrome opened the deployed task detail with its updated timeline, owner and documentation links. No new visual layout was introduced or audited by this backend rollout.

The installed CLI watched the live API through the Gateway for 45 seconds, receiving ten valid NDJSON snapshots with no stderr and clean cancellation. BM25 search returned a positive score using `pg_textsearch-1.5.1`. CNPG remains healthy with two instances, the application roles remain nonsuperuser, and Mattermost HTTPS ping reports database and filestore OK. Its configuration and storage were not changed. No application compilation or tests ran locally.

This is the first bounded Ash Board/Evidence stage. At that rollout the full delivery change was still in Review, including PR inventory. Canonical submission inventory is recorded in the next section and is not part of this deployed image. Providers, AshOban monitoring, CI dashboard/API/CLI, completion guard, durable followups, Mattermost bridge and wakeup integration remain pending. An older schema-5 image can read the additive schema-6 data after rollback but resumes legacy writes without the new audit coverage; preserve schema 6 and fix forward for an audited writer.

## Durable PR inventory acceptance (2026-10-06)

The next Ash Delivery stage passed all 15 [remote acceptance targets](https://carverauto.buildbuddy.io/invocation/806505ce-555b-4bf3-9514-a00e607e7ddd).
Packaged Phoenix and the real API-only Go CLI against normal-role TLS
PostgreSQL prove canonical case deduplication under concurrent submissions,
per-task first submitter/model/harness evidence retained after handoff and URL
replacement, atomic task/version/event/timeline/inventory rollback on audit
failure, terminal keyset discovery and idempotent overlapping sweeps. The
[final focused proof](https://carverauto.buildbuddy.io/invocation/2d534d51-125b-4267-bc34-d2b87c66b16f)
adds archived-terminal coverage and verifies update/delete/truncate failures
come from immutable guards. Unknown legacy attribution and submission time
stay unset. Fresh and repeated schema-7 migrations and schema-4 upgrade
preserve existing IDs, timeline and HTML. The
[remote formatter](https://carverauto.buildbuddy.io/invocation/44881ec0-581a-402e-9a56-5f8585f6a52c)
ran in the packaged release on RBE.

[Archify inventory source](architecture/pr-inventory.architecture.json) and
[standalone HTML](architecture/pr-inventory.html) have a
[9-check delivery receipt](architecture/pr-inventory.receipt.json),
[automated browser receipt](architecture/pr-inventory.visual-check.json) and
[separate image review](architecture/pr-inventory.visual-review.json).
Light-theme measurements pass at 1440×900, 1600×1000, 1920×1080 and 2048×1320;
light/dark endpoint screenshots were inspected for containment, route clarity
and balanced height. The diagram uses Archify's existing classic viewer, with
no custom page redesign or active Lavish review.

Only OpenSpec task 4.1 is complete in this stage (9/37 overall). The full
schema/generator baselines, scheduler, provider polls/verdicts, followups,
completion guard, PR dashboard/API/CLI and live monitoring rollout remain
unchecked. This is pre-merge acceptance, not production deployment evidence.

Actual [release image and CLI packaging](https://carverauto.buildbuddy.io/invocation/b3808aa8-76df-4701-bc94-744ff98c97b9) passed remotely.


## Canonical PR inventory rollout (PR32, 2026-10-07 UTC)

Merged PR32 (`f5308a7ff00d6277682fc683a4469ef98cee4f11`) is live on farm01 at
`registry.carverauto.dev/agentboard/dashboard@sha256:eb5c074b40cfea5b59cac49a689390d66d778ef18e99b606896cb809a0255fa4`.
The [publication workflow](https://github.com/carverauto/agentboard/actions/runs/37550717976)
passed [all 15 remote acceptance targets](https://carverauto.buildbuddy.io/invocation/e53783aa-96fb-4607-889d-c1e3a2e42960)
and [image packaging](https://carverauto.buildbuddy.io/invocation/dbe2a557-631a-484c-94f1-6e3729eae17a).
The immutable tag was independently resolved in Harbor before deploying.

Scoped ConfigMap, migration Job and Deployment resources passed server-side
dry-run. Job `agentboard-migrate-f5308a7` completed on the same digest before the
dashboard rolled. One Ready pod runs that exact image with zero restarts.
Verified HTTPS readiness and the installed API-only CLI report schema 7/API 1.
The [normalized receipt](verification/farm01-pr-inventory.json) records the
unchanged pre-roll task-event/document/context prefixes, healthy two-instance
CNPG, pg_textsearch 1.5.1 and nonsuperuser application roles.

The real CLI retained the earliest timeline submitting agent/model/harness when
relinking this work's PR36 after migration. BM25 search returned a positive
score. The installed CLI watch stayed connected through the Gateway for 45
seconds with ten valid NDJSON snapshots, no stderr and clean cancellation.
Existing HTML48/49 and worker-review HTML50/51 downloaded byte-exactly; the
latter also rendered in sandboxed Chrome viewers. Mattermost HTTPS, database
and filestore checks remain healthy. No application build or test ran locally.

This rolls the canonical inventory only. Automatic historical discovery is
explicitly false; the attribution repair and AshOban catch-up worker remain in
merged PR36, awaiting rollout. Existing padded-attribution history
count was zero before rollout. GitHub/BuildBuddy CI observation, follow-ups,
completion enforcement, PR views and Mattermost/wakeup integration remain
unfinished. Preserve schema 7 and immutable inventory/audit tables if rolling
back the image; record any schema-6 writer inventory gap and fix forward.


## Inventory catch-up and historical attribution (2026-10-07 UTC)

A whitespace-bearing invented legacy event reproduced the initial TaskLink
model/harness trimming regression through the packaged release's public
Delivery discovery operation. It failed before the fix in
[BuildBuddy dd524092](https://carverauto.buildbuddy.io/invocation/dd524092-3e72-425d-9a3e-e1e10d9b8e85)
and passed after explicit source-preserving constraints in
[BuildBuddy cf4bde5a](https://carverauto.buildbuddy.io/invocation/cf4bde5a-5253-4b1e-8a10-69a866acd891).
No already-persisted immutable attribution is rewritten.

The [two-target focused run](https://carverauto.buildbuddy.io/invocation/6d512b3d-af38-4767-b0cb-3d758ed78c93)
passed inventory and actual asynchronous catch-up. The latter waits for the
configured Cron consumer to persist work while the queue is paused, restarts
the supervised Oban child, then observes 125 invented terminal/archived task
links across durable cursor pages. An injected database insert error enters
Oban's retry path without a partial PR; normal explicit retry recovers. Repeated
sweeps preserve task/timeline bytes and do not add duplicate links/versions/events.
An already-queued job snoozes when the runtime feature switch is disabled and
recovers after re-enable. No private application/test-only mutation API is used.
An earlier run found a missing optional cursor key in the newly authored worker;
the fix handles an argument-free Cron root correctly, as this passing run proves.

This is remote packaged-release/PostgreSQL proof of inventory catch-up, not
GitHub/BuildBuddy observation, CI classification, follow-up or a live rollout.
The new Archify source and standalone HTML have nine showcase checks with no
errors/warnings, four desktop containment measurements and separate actual
light/dark perceptual review receipts under `docs/architecture/pr-discovery.*`.

Rendered Docker Compose dashboard/migration configuration defaults discovery off
through the real Compose consumer. The rendered farm01 ConfigMap passed a scoped
server dry-run with the same default. A full-overlay dry-run encountered the
pre-existing immutable migration Job template; that is not a catch-up rollout
and no live resource was changed.

After applying touched Elixir formatting from the remote formatter artifact,
all **16 acceptance targets passed** in
[BuildBuddy ba7ad036](https://carverauto.buildbuddy.io/invocation/ba7ad036-08c6-4ca9-b57e-29d89e5adde9).
This includes the existing board/CAS/lease/watch, quota/document/context, archive,
TLS/migration, CLI/image and connected LiveView compatibility targets.


## Observation scheduling rollout (PR45, 2026-10-07 UTC)

Rolled merged PR45 (`9f1e712ffc98311d267bae907738114070e224e4`) after its
[container workflow](https://github.com/carverauto/agentboard/actions/runs/37570672161)
passed [18-target remote acceptance](https://carverauto.buildbuddy.io/invocation/63421f99-6474-4051-bd9b-feeb8f19b239)
and [remote packaging](https://carverauto.buildbuddy.io/invocation/1de87586-41aa-4da5-a11a-e4e40e3314d3).
The published commit tag was independently resolved with the existing
pull-only registry credential, without exposing it. The matching immutable
digest is pinned in the farm01 overlay and used by migration and dashboard.

Server-side dry-run passed for the scoped ConfigMap, unique migration Job
and Deployment. Only those release resources were applied; CNPG, Mattermost,
storage and edge resources were preserved. `agentboard-migrate-9f1e712`
completed before Deployment rollout. Schema 9/API 1 and a Ready zero-restart
pod on the exact image ID are confirmed. Discovery and observation are false
in both configuration and the new pod environment. Four retained canonical
PRs have four unobserved poll rows; provider remaining budgets are GitHub 60
and BuildBuddy 30, with zero runnable observation jobs.

Pre-roll immutable cutoffs were task events 246 (230 retained rows),
documents 60 (28 rows) and Context 4 (three rows). Post-roll counts and hashes
match at each cutoff. Actual HTML bytes for documents 59/60 match the retained
source files; document metadata digests include metadata and are not HTML-only
SHA256 values. All existing dashboard routes, live/ready/meta and both sandbox
viewer routes returned HTTPS 200. This HTTP check alone does not prove browser
interactions. The existing CLI BM25 search reports `pg_textsearch-1.5.1`.
A task watch stayed connected through the Gateway for 25 seconds, produced five
valid NDJSON snapshots, no stderr and clean cancellation.

CNPG has two Ready instances, pg_textsearch 1.5.1, and neither application role
is superuser. Mattermost ping/database/filestore are OK. Its enabled existing
agentboard bot token authenticates and its memberships include board/agents/quota
in `carver-automation-corporation`; all three had zero posts. This release
contains no Mattermost bridge or worker conversation client.

No application code compiled on the Mac. The prior digest is retained for
additive rollback, which was not exercised live. Full normalized results are
in [farm01-pr45-scheduling.json](verification/farm01-pr45-scheduling.json).
Provider collection, confirmed CI truth, repair obligations, worker delivery
and chat traffic are not implied by this rollout.


## Worker and Mattermost bridge image rollout (PR61, 2026-10-07 UTC)

Merged main `21afca5366726cbbe5486b008df320c7e2595b78` rolled the dashboard to
`sha256:a60886cdeb0a296782d29166150a593b64b52a135d5f2c3e7a8c54d98030c815`.
Job `agentboard-migrate-21afca5` completed; schema 9/API 1 with a Ready
zero-restart pod. CI discovery and observation stay disabled and the bridge
stays disabled with four retained intents. Full results are in the [rollout
receipt](verification/farm01-mattermost-bridge.json); the operator runbook
retains the [historical rollout
record](deploy/reference-farm01.md#worker-and-mattermost-bridge-image-rollout-pr61).
This pointer claims no bot-post or worker interoperability proof.


## Collector and cooperation foundation rollout (4b15860, 2026-10-07 UTC)

Published main `4b158601cc60a9877312d654a258d2030ce963ca` passed 24 remote
acceptance targets and image publication in the
[container workflow](https://github.com/carverauto/agentboard/actions/runs/37643460359).
Both dashboard and CLI commit tags independently resolved to the supplied
immutable digests. Farm01 now runs dashboard
`sha256:098b466b15f9e30b6d59ee80d7a0074fcfea9a5a9272ceb4a1ce7d827e2f8c92`.
The migration Job completed before the Ready, zero-restart dashboard rolled.
Schema 9 advanced through 10 to 11, matching the selected release's required
schema 11/API 1; the coordinator acknowledged this correction to the original
schema-10 brief before rollout.

Scoped server-side dry-runs and writes covered only the migration Job,
ConfigMap and Deployment. Discovery, observation, cooperation dispatch and
Mattermost bridge flags are all false in configuration and the running pod.
CNPG's spec/image are unchanged, both instances are Ready and BM25 remains
pg_textsearch 1.5.1. Mattermost ping/database/filestore are OK. Captured prefixes
retain 670 task events through ID 686, 42 documents through ID 74 and 93 Context
entries through ID 95 with identical hashes. HTML downloads 69/73/74 are
byte-identical to source. Task, message and quota Gateway watches each stayed
connected for 25 seconds, produced five valid snapshots, no stderr and exited
cleanly after SIGINT. Health, meta, dashboard and document routes returned 200;
this does not prove browser interactions.

Full results, cutoffs, digests and limits are in the
[normalized receipt](verification/farm01-4b15860-rollout.json) and the
[historical operator record](deploy/reference-farm01.md#collector-and-cooperation-foundation-image-rollout-4b15860).
No local compilation, CLI installation, worker activation, chat delivery,
storage modification, pruning or live rollback occurred in this rollout.


## Per-agent chat identities and merge-to-Done rollout (9432792, 2026-10-08 UTC)

Merged main `9432792a57019ae9d3aa6245cda229044adc7ab4` rolled the dashboard to
`sha256:76af4541a0598501d210b1d37d12b97c2a2d161ed68bddbd24d3e1e096f566a3`
with schema 11 to 12 via Job `agentboard-migrate-9432792`. Full results are in the [rollout
receipt](verification/farm01-9432792-rollout.json); the operator runbook retains the [current
rollout record](deploy/reference-farm01.md#per-agent-chat-identities-and-merge-to-done-image-rollout-9432792).
The same session rolled forward to `3c6e5b3` (PR88) at
`sha256:b892c442a7578c814ba756afc644b0feb96c6004925f4b8869420f232835015c`; its migration Job was a no-op and schema stays 12. That is the
[pin before 901f6a6](deploy/reference-farm01.md#roll-forward-to-3c6e5b3-pr88).


## Shared-bot agent chat rollout (901f6a6, 2026-10-08 UTC)

Merged main `901f6a6` (PR91) rolled the dashboard to
`sha256:5193d83379a629cf2e4af3e756839efed745c93f497cc0642eb20c7db33ef029` via Job `agentboard-migrate-901f6a6`. That Job dropped the
empty per-agent identity tables, and schema stays 12. Full results are in the
[rollout receipt](verification/farm01-901f6a6-rollout.json). The
[current rollout record](deploy/reference-farm01.md#shared-bot-agent-chat-image-rollout-901f6a6)
is in the operator runbook.

