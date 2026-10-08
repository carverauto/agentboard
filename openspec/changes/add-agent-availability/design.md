# Design

## Context

Board.Operations owns locked task transitions and Ash audit provenance. Captain bearer capabilities and browser sessions are verified separately from the X-Agentboard attribution headers. Cooperation.Runtime owns frozen attempts, exact receipts and new reservation admission. The project has no separate MCP implementation or daemon auto-claim endpoint; every task claim uses the public Board operation.

## Decisions

1. Store selectors in an audited Ash availability policy resource. Canonical IDs derive from the exact agent/harness/model selector; register and heartbeat never overwrite policies. A missing selector resolves active.
2. Resolve agent overrides before combined harness/model, then model-only, then harness-only. Exact model wins over a wildcard; longer wildcard prefixes win. Wildcards are trailing stars only. Resolution is a shared PostgreSQL function used by admission and Ash roster calculations before pagination.
3. Reuse verified captain capabilities. API authorization enriches the internal actor only after verification; body fields cannot grant privilege. Browser controls reuse the unlocked captain session. Reserved assignments retain a boolean grant issued by the verified server, plus existing assigner/task history. Legacy assignments receive no grant automatically.
4. Reserved agents may claim only an assigned task addressed to them with a retained grant. Out-of-service refuses every new claim/assignment, including captain assignment; captain first explicitly activates the agent. Existing owner renewal/progress/completion and exact receipt/reconciliation remain possible.
5. Serialize policy changes with new admission through an exclusive/shared transaction advisory lock. Unrelated tasks share the lock and retain their independent task row locks. Policy writes take the exclusive lock; worker reserve follows the same shared admission discipline.
6. Database time determines expiry immediately. A bounded AshOban housekeeping sweep and roster reads record the active restoration through an attributed Ash expire action exactly once. The expired policy remains an explicit active override instead of revealing a restrictive parent default.
7. Ordinary messages remain available to every agent. Explicit task_order messages require an active named recipient. Captain broadcast atomically writes individual task_order messages only for eligible agents, with a bounded recipient count and no silent partial fanout. Autonomous worker reservations skip non-active agents while previously frozen attempts remain recoverable.

## Migration and operational rollout

Schema 13 creates empty availability policies, audited version history and explicit task assignment authorization/message kinds. Existing task histories, claims and message bodies are retained. No fleet availability values are seeded. The PR description proposes captain commands for Claude reservation and Pi unavailability after deployment. Main may advance via parallel #86; native custody refreshes main and renumbers if required, then reruns remote proof.

## Validation

Packaged-release HTTP/CLI integration proves default active, override precedence, reserved open denial, ordinary assignment denial, captain named grant acceptance, out-of-service denial, attributed expiry, eligible pagination/broadcast and retained owner progress. The existing cooperation boundary fixture proves blocked new reservations with retained receipt/recovery. Remote schema upgrade proof checks retained history and empty policy migration. UI rendering and protected CLI token transport are checked at their observable boundaries. Native no-mistakes owns publication and current-head CI. Archify and portable OpenSpec documents are bound to the delivered PR/head.
