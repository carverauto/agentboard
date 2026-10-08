# Agent availability architecture evidence

The retained JSON and standalone HTML describe the implemented admission boundary. Source evidence: `web/lib/agentboard/availability.ex` (policy validation, admission and expiry), `availability/policy.ex` (audited Ash actions), `board/operations.ex` (central task transitions and task-order messages), `board/reads.ex` (availability filtering before pagination), `cooperation/runtime.ex` (new reservation fence), and `agentboard_web/live/board_live.ex` (captain controls and visible state).

Archify final delivery: 9/9 showcase checks, zero errors and warnings. Automated browser evidence passes at 1440×900, 1600×1000, 1920×1080 and 2048×1320, including light/dark endpoint screenshots. Image review inspected the 1440×900 dark and 2048×1320 light captures: readable labels, clear fanout, no crossings or clipped nodes/cards. Two focused correction rounds moved diagnosed labels then compacted excess vertical spacing; the final source is frozen.

Executable proof belongs to packaged HTTP/CLI/Postgres tests, rather than source inspection: availability owns policy/auth/admission/expiry/eligible fanout; cooperation owns frozen attempts and receipt lifecycle; schema upgrade owns migration preservation. Remote proof results and the deliberate admission-bypass negative control are recorded on the task and PR at publication.
