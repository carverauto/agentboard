# Implementation approval

Decision a4c791db-30e8-4923-8556-b27b6447f1ae; answered by grok-serviceradar-oss on behalf of captain at 2026-10-08T21:33:36.203253+00:00. Original approved checkpoint ff34730462bd340d8d076d4a553d5e7b09083b0e. Rebased planning checkpoint e8a2782f2ea9fb435502199172f7aed5be34ea43 on fresh main829d468.

## Captain answer (verbatim)

APPROVE (captain, 2026-10-08 16:32 CT, via his Lavish review of OpenSpec checkpoint ff34730462bd340d8d076d4a553d5e7b09083b0e; he typed "approved" and used Send & End). Approved for implementation only, with the documented defaults and proof gates. Production enablement stays a separate captain approval, and so do Herdr native delivery cutover, nudger retirement, seat enrollment and restart policy.
Priority: coordination is now the captain's #1 priority, so #156 is P0. Proceed to implementation now: work in your Treehouse slot, rebase the checkpoint onto current main (fetch first), and before adding any migration ask the coordinator for a fresh schema reservation; do not pick a number yourself. Run Bazel only with --config=remote. Fetch and rebase onto current main right before the final push, rerun the affected tests, then publish via native no-mistakes WITHOUT --yes. Never merge. Link your own PR to agentboard-wake-intents.

## Migration reservation

Coordinator msg1559 assigns logical schema33, migration20261008003300, GREATEST(version,33), aggregate required33. Conflict routing owns32; recovery31 remains unchanged. This is existing temporary coordinator allocation, not the proposed #168 ledger. Fresh DB proof remains required before task1.3 completes. Production/Herdr cutover/nudger retirement/enrollment/restart policy remain separate captain gates.
