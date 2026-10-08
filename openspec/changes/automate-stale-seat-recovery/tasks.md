# Tasks

Planning checkpoint: all implementation items remain unchecked. Captain must approve the proposal before project code changes; proposed defaults and dependency contracts are presented in the review artifact.

## 1. Approved contracts and policy admission

- [ ] 1.1 Obtain captain proposal approval and agree #156 host reservation/receipt and #141 ensure/check/env contracts; verify the recorded board decision and contract fixtures before code.
- [ ] 1.2 Integrate #154 approved policy version, disable/dry-run defaults, declared cadence and active-seat capability gates; verify reserved/paused/revoked/missing-cadence cases produce no restart in remote packaged API tests.
- [ ] 1.3 Document policy values, per-host readiness and retained-claim exhaustion behavior; verify docs and dry-run output distinguish proposed/configured/active status.

## 2. Durable server episode and detector

- [ ] 2.1 Reserve the additive schema number, add audited episode/attempt resources and uniqueness constraints; verify migration from current/higher schema with existing claims, decisions and worker uncertainty preserved remotely.
- [ ] 2.2 Implement bounded AshOban detector and transactional admission using database time and established lock order; verify concurrent replicas yield one episode/intent and fresh heartbeat/availability changes cancel admission before reserve.
- [ ] 2.3 Add read-only recovery state to API/CLI/dashboard and retain manual Supersede; verify public responses contain bounded reason/progress fields and no credentials, and dashboard still shows separate held/expired/stale states.
- [ ] 2.4 Document episode lifecycle, retry schedule and audit reasons; verify each server transition has a structured policy/episode/attempt trace in packaged tests.

## 3. Authenticated host restart

- [ ] 3.1 Implement #156 restart intent reservation/result/reconciliation behind host/seat/incarnation authorization; verify cross-host, old-generation, duplicate key and revoked credentials cannot mutate recovery remotely.
- [ ] 3.2 Implement local per-seat journal and exact process/session reconciliation; verify lost spawn receipts and host restarts never create a duplicate native child and uncertain effects are retained.
- [ ] 3.3 Preserve existing Treehouse lease/WIP/No-mistakes custody and apply #141 validated environment before native startup; verify primary/foreign/missing slots refuse editing and responsive live sessions are never killed.
- [ ] 3.4 Prove owned-session replacement capability per adapter/host using a disposable session; verify unsupported/UI-attached sessions are refused and readiness is not inferred from backend metadata.
- [ ] 3.5 Document host enrollment, protected credential file references, journal recovery and kill switch; inspect generated launchd/systemd examples without activating production services.

## 4. Startup proof and canonical decision catch-up

- [ ] 4.1 Correlate host generation/isolation proof, fresh heartbeat and startup responsibility snapshot; verify heartbeat alone and delayed old-incarnation results cannot mark recovered.
- [ ] 4.2 Return original held cards and answered-but-unapplied decision references at startup; verify frozen worker/watcher route, uncertain wake, answer bytes and request IDs stay unchanged, with no automatic ack or lease renewal.
- [ ] 4.3 Exercise exact native gate application then requester renew/ack for a killed disposable seat; verify one retained answer is applied without human/coordinator input, while terminal/mismatched gates remain unapplied with a diagnostic.
- [ ] 4.4 Document the distinction between recovered liveness, consumed transport, applied decision and completed task; verify CLI/dashboard examples show these states separately.

## 5. Exhaustion, override and delivery

- [ ] 5.1 Implement bounded attempt/reconciliation budgets and one #155 escalation per exhausted episode; verify repeated failures/notification retries preserve ownership and produce one alert while coordinator is offline.
- [ ] 5.2 Fence policy-disable, enrollment replacement and manual Supersede races; verify no new native effect or revived decision after an override, and already-started effects remain reconcilable.
- [ ] 5.3 Publish override/exhaustion/rollback documentation; verify documented disable path stops reservations and preserves unsettled episodes/journals rather than deleting evidence.

## 6. Integrated delivery and gated rollout

- [ ] 6.1 Run relevant packaged Phoenix/Postgres, public CLI and disposable native-host recovery scenarios only through remote Bazel; retain invocation URLs, scenario outcomes and unsupported-worker limitations.
- [ ] 6.2 Deliver implementation Archify and portable OpenSpec documents, then native No-mistakes without --yes through exact-head green PR CI; link PR/docs on the owned board task and never merge.
- [ ] 6.3 Obtain separate captain policy activation and one-seat rollout permission; verify dry-run parity and per-host proof first, stop on production hook/secret/service activation without that permission, and retain the local nudger until replacement proof.
- [ ] 6.4 Preserve all work and explicitly return only this seat's Treehouse lease after delivery; verify pool holder/id are cleared and durable task state remains accurate.
