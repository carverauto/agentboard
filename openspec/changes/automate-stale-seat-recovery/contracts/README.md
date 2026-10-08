# Recovery dependency boundary checkpoint

Captain implementation approval is applied in `../approval.md`; this records the first implementation interface work, not runtime completion. `restart-boundary.json` contains invented placeholders and a proposed transport-neutral wire shape, with no credential value or server-supplied native argv.

## Verified #141 interface

Inspected PR167 head `a3160e23a1da7bc29a3bed64542a2d454bf1d6b8`: `internal/cli/seat_attach.go` defines resolution as `binding` plus `environment`. Its real CLI consumer checks every task-history page and requires a live owned in_progress/blocked/review claim. `scripts/launch-seat` verifies lease id/holder, pinned pool/source, physical Git registration and cwd. Its final JSON contains the seven binding fields and eight selected non-secret environment fields recorded here. It does not change a parent shell. The remote packaged fixture proves reuse/attachment, WIP/credential preservation and conflict refusals; retained proof is in PR167. This seat has inspected, not rerun, that sibling fixture. Owner confirmation requested in board msg1400.

## Actual missing integration surfaces

Fresh main `5595a136` has worker host/receipt capabilities, bindings and canonical check-in; it does not have #154 captain-approved decision-policy versions, #156 host wake-intent reservations, or #155 escalation delivery. Existing `Cooperation.Runtime.request` takes its worker lock before dispatching operations. Recovery must keep the approved task/decision/worker lock order rather than simply nesting task locks inside that dispatcher.

#164 integrates these boundaries; this checkpoint neither silently replaces them with stubs nor claims they are deployed. Coordinator schema allocation requested in msg1397 (waiting-lane29 is already reserved); dependency interface/scope clarification requested separately. Schema migration remains unwritten until allocation is explicit. Task1.1 is not complete until agreed interfaces/fixtures are verified.

## Contract verification to implement at owning boundaries

- Packaged recovery HTTP/Postgres: concurrent detector replicas reserve one episode/attempt; newly fresh/reserved/revoked enrollment cannot reserve a restart; attributable ordinary heartbeat cannot prove a new session.
- Real disposable native-host process plus journal: stop/lose the owning session, reconcile a lost spawn result, preserve the exact lease/WIP, and never launch a second process while an effect is uncertain.
- Canonical native gate: retrieve the original answer and apply/ack once only while the original gate and rightful live ownership match. A mismatched/terminal gate retains a diagnostic, not an invented acknowledgement.
- Exhaustion: retain claims/decisions after the approved budget; create one durable human escalation even while the coordinator process is absent.

No product code, tests, service activation, credential provisioning, or production rollout has occurred at this interface checkpoint. Full implementation and remote No-mistakes proof remain required.
