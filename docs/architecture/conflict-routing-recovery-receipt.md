# Native routing checkpoint recovery

Captain message1856 authorizes guarded recovery and one continuation run for
#169. It supersedes message1852's same-run restriction, retaining the task,
leased Treehouse seat, fixes and evidence. It authorizes no merge, deployment,
activation or native publication/custody capability.

The old run `01M4HCGTXV2PYEN9DWV6YEHN1P` stopped at its Document evidence gate.
The installed v1.84.0 refused completed Test reentry with `step mismatch:
responding to "test" but "document" is awaiting approval`. Supported cancellation
then guarded `no-mistakes axi sync --recover` returned custody at
`e6fab488ad72f1f07aa3fe1d5ceedb0553f576a8`, preserving all four native fix
commits: retained-deadline enforcement, deduplication, corrected timestamp
fixture/documentation and deadline documentation. Prior logs and receipts were
retained before cancellation. No reset, replacement ref or native state edit
was used to recover custody.

## Product regression proof

The corrected collector/API/Postgres/AshOban fixture remains the primary owner.
Its retained episode hands the repair from the unavailable author to retain-a,
then at the elapsed earliest deadline to retain-b. Consecutive routes of the
current retained_third order must leave its identity, effect counts and audits
unchanged; source claims remain unchanged and publication grants remain absent.

Only the deduplication guard in `ConflictRouting.route_reason` was temporarily
removed, restoring that file exactly to native commit
`9d9686abdbc8cc8e34589492df6fb9f8e0560a1f`, while retaining the corrected test.
[Product RED](https://carverauto.buildbuddy.io/invocation/d1c4535d-0007-4e02-8f2c-e207bc30b5bf)
failed remotely at the intended assertion: repeated routing changed the current
order ID instead of retaining retained_third. This is distinct from the earlier
timestamp-fixture failure, which is not product regression evidence.

Production bytes were restored immediately after RED, before any further test.
The restored hash equals the pre-mutation hash and Git reported a clean tree.
[Fresh remote GREEN](https://carverauto.buildbuddy.io/invocation/a89bc54b-a276-4c3c-86b2-02a75cc68922)
passed in 41.0s with test caching disabled. The preceding
[cached GREEN](https://carverauto.buildbuddy.io/invocation/f6454b32-ed4c-49d5-9ad3-7c83df883255)
reused the valid prior identical-source result; fresh GREEN supplies the final
post-restoration execution evidence.

| Bytes | SHA256 |
| --- | --- |
| Production before and after restoration | `dd3fcbb26b56a46cbf299bb178131085c599d003fbced8ce38bac1593abe4cf3` |
| Pre-dedup production used for RED | `14bdc2409be5df12cb57f974537bdba0753843b31eb3cb31dc1304124f00c5cb` |
| Corrected test, unchanged throughout | `489b294243936242e459fe42ac625f403faa3e4a1d498f67ba6753eb7ae5dcc2` |

Every check used `./scripts/bazel test //build/integration:conflict_routing_test
--config=remote --test_output=errors`; fresh GREEN additionally used
`--nocache_test_results`. No workstation compilation or test execution occurred.

## Publication status

The portable wrappers are regenerated from tracked source and include this
receipt, the corrected regression and retained production. The accepted
consumer.v3 diagram is unchanged. Documents201/202 remain historical receipts
for submitted ef706a39 and must not be described as the corrected publication
head. Final uploads/download verification and the continuation run's PR and
exact-head CI evidence remain outstanding. Full OpenSpec remains incomplete;
native admission/grants/custody/credit and live rollout retain their previously
declared limits. Deployed keyboard and narrow-screen product behavior remains
UNTESTED-live.
