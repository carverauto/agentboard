# Per-harness worker readiness (OpenSpec 6.3–6.5)

This is a live run on farm01 on 2026-10-12, authorized by the maintainer. The
server ran main 358c8a3 (schema 44) with dual message mode and cooperation
enabled. Everything ran on one macOS host, `arrakis`.

Each harness was proved separately; a result for one harness or model says
nothing about another. The host worker binary has darwin arm64 sha256
`f87c91995719878ea00efdbb847149fcc7c88ece14cb02f431e1d8db9231cdc8`. The
installed `claude-native` plugin matches the tree: `bridge.mjs` `979e91bffb38704022ea5be83b78ddcbd408d57a06a7bf0d5900efc1d4355fc5`,
`hooks/register.js` `9274bb699d449215649eca33478db0f211b62334ea3881a0c2470bc126c40814`.

The new bindings lived in separate protected configs with their own journals.
The running Pi pilot workers, their config and their LaunchAgent were not
touched. Every worker was registered and provisioned through the captain API
(`POST /api/v1/workers/provision`) for repo `carverauto/agentboard`. Each
source was a controlled task created by the coordinator and assigned to that
worker; no worker was asked to act on source content.

## Readiness matrix

| Worker (harness / model) | Delivery path | Idle wake | Turn start | Tool return | Explicit check-in + exact receipt | Lifecycle |
| --- | --- | --- | --- | --- | --- | --- |
| Pi 0.99.2 exclusive RPC (`pi-native-v1`) | Native extension | **Proved** ([first-release pilot](runtime-first-release-pilot.md)) | Proved | Dedicated check-in return proved | Proved | New, rebind, pause/resume proved |
| Claude Code 2.1.296 headless stream-json (`claude-hook-v1`), claude-sonnet-5-5 | Native plugin | **Unsupported** (no proven atomic composer/wake-owner guard) | **Proved**: frame added as context, prompt byte-identical | Explicit check-in only; result unmodified | **Proved** through the plugin ack tool | Resume, fork, pause/resume, stale refusal, no replay **proved** |
| Grok (`manual`), grok-4.7 | Operator-frozen batch | Unsupported | Unsupported | Unsupported | **Proved**: two rounds | — |
| Muse Code 1.4.6 (`manual`), muse-wonder-full-1.0 | Operator-frozen batch | Unsupported | Unsupported | Unsupported | **Proved**: two rounds | — |
| Codex CLI 0.162.1 on macOS (`manual`), gpt-6.1-sol | Operator-frozen batch | Unsupported | Unsupported | Unsupported | **Proved**: two rounds; network writes needed sandbox approval | Native owner unsupported on Darwin |
| AGY 1.3.3 (`manual`), Gemini 3.8 Flash (High) | Operator-frozen batch | Unsupported | Unsupported | Unsupported | **Proved for round 1 only**; round 2 not run | — |

Interactive, Desktop and App surfaces for Claude, and Herdr-driven prompting for
any harness, were not tested and are not claimed. Herdr 0.9.0 automatic prompting
stays disabled (see [Herdr capability evidence](worker-herdr-capabilities.json)).
Gemini CLI is installed but is not one of the fleet's six workers, so it was not attempted.

## Claude: `worker-agentboard-claude-1`

The session was isolated: `claude -p --input-format stream-json --output-format stream-json`
ran with `--plugin-dir …/claude-native`, `--setting-sources ""`, `--tools ""`,
`--permission-mode dontAsk` and only the plugin's MCP tools allowed. A
`--settings` file installed a separate command hook that logs SessionStart,
UserPromptSubmit, Stop and SessionEnd. That hook stands in for the user's own
hooks. A host `worker serve` ran on the separate config. Native prompts were
appended as stream-json lines to the session's stdin FIFO.

| Step (UTC) | Evidence |
| --- | --- |
| c1 start | Session `3c35d723-4ac8-4ae7-b290-b4e8dbdc91df`, generation `299d52e3-da33-4f38-b18c-6906645623b4`, socket `cc/c1`. Plugin MCP server `connected`. |
| 19:17:12 bind | Epoch 0→1. Doctor: state `boundary`; turn_start, receipt and recovery supported; idle_wake and tool_return unsupported. Server: adapter `ready`, connector `healthy`. |
| 19:17:16 → 19:18:00 | Serve staged attempt `f4bb8c66-4ff1-42af-9942-736c09c306af` (10 deliveries); evidence phase `accepted`. Prompt P1 (19:17:46): the model answered the question in the prompt, then listed the exact attempt and IDs. `agentboard_ack` received `1eae7a07-cbf5-40f2-be95-7f6875b1b111` (2026-10-12T19:17:56.808649Z) and handled `5b45b84c-b312-4bdf-8445-44821c91d2d2` (2026-10-12T19:18:00.309888Z). Evidence phase moved to `boundary_received`. |
| Prompt preservation | The logging hook saw every prompt byte-identical to the input sent (72 and 467 bytes). The frame entered as separate context, not prompt text. |
| 19:18:52 tool result | Attempt `98458c79-2b1c-4ce7-a2f6-da7f1ecd3094` (9 IDs) was staged, then taken at P2's prompt boundary. Within that turn `agentboard_check_in` returned the plain check-in JSON (25,565 bytes): same keys as the CLI, no frame text. P3 acked exactly: received `104885ab-6f47-4630-bdaa-86c04692b2f6` (2026-10-12T19:19:46.975039Z), handled `925cabdc-04c6-4b44-ba72-2e6e98b3384b` (2026-10-12T19:19:50.802423Z). |
| 19:20:37 pause | Attempt `fcba5716-ceda-4bf4-8ad8-c4684471adf2` was staged (`accepted`), then the worker was paused. P4 answered `NO-FRAME`, evidence stayed `accepted` and serve reported `paused`. |
| 19:21:18 resume | P5 received the held frame. Received `e5d3110d-44a2-4115-bb3f-36195bf0a94f` (2026-10-12T19:21:21.204687Z) and handled `6485f745-a160-4727-9042-9ac4a6f594a5` (2026-10-12T19:21:23.431427Z). |
| Stranded attempt | Controlled source `harness-proof-claude-20261012` was staged in c1 as attempt `37ac2c40-5889-440d-adf8-b604dbe601a9` (delivery `38c26c21-2825-4095-ae3b-917c08ba3da3`) and deliberately left untaken. It has no receipts. |
| 19:48:33 c1 end | SIGINT. The logging hook saw `SessionEnd` (reason `other`); sockets and identity descriptor were removed. |
| c2 resume | `--resume 3c35d723-4ac8-4ae7-b290-b4e8dbdc91df`: same session ID, new generation `473f59f0-d294-44e5-ae84-256480608f86`; SessionStart source `resume`. |
| 19:49:01 rebind | Epoch 1→2. Attempt `37ac2c40-5889-440d-adf8-b604dbe601a9` went `submitted` → `uncertain` / `binding_replaced`. |
| Stale refusal | The preserved epoch-1 receipt capability got HTTP 403 for check-in, ack and state. The CLI refused the old generation with "native session generation does not match binding". The live c2 socket, asked about the old generation, answered `not_submitted`. |
| No replay | P1 on c2 (19:49:17) answered `NO-FRAME`. Serve held dispatch: "old binding crash journal retained; historical reconcile did not resolve the frozen attempt". |
| Captain decision | The coordinator resolved `37ac2c40-5889-440d-adf8-b604dbe601a9` as `not_submitted` (`captain_authorized_possible_duplicate`). Serve reconciled the journal about 19:50:13 and dispatch resumed. |
| 19:50:42 → 19:51:00 | New attempt `475e4f60-9398-4b58-8b39-3f7b912eee79` held the retried delivery `38c26c21-2825-4095-ae3b-917c08ba3da3` and the new controlled source `66c6e956-ab4e-4722-9805-90d9f00eaa48`. Frame at P2; received `f2b4dedf-456a-4b8e-942a-e09111cc89ce` (2026-10-12T19:50:58.763148Z), handled `02ce9483-ad9e-4b35-a556-2b0a28cfec3c` (2026-10-12T19:51:00.889293Z). |
| 20:02:15 c2 end | SIGINT; `SessionEnd` logged; transport removed. |
| c3 fork | `--resume 3c35d723-4ac8-4ae7-b290-b4e8dbdc91df --fork-session`: new session `be5d0ed4-b8f0-46e5-bb61-d3a721981a4c`, generation `9c1144fe-7cda-49bb-b3be-f2a60e46a569`; SessionStart source `fork`. |
| 20:02:37 rebind | Epoch 2→3. The epoch-2 capability got 403 for check-in, state and ack. The old session/generation was refused by the CLI and by the c3 socket (`not_submitted`). |
| 20:03:14 → 20:03:27 | Attempt `d3d6d1a1-a8e6-4b4b-b6e7-6f955c4d64f9` (controlled source `f28a1bc5-5c53-4a6d-ab8d-29eca7863e5b`) was staged and taken at the prompt. Received `6d07096c-f92d-41ef-88b5-ed3821ca1454` (2026-10-12T20:03:25.892687Z), handled `e4d25865-4bb3-4e7f-bc89-96ec6efe2398` (2026-10-12T20:03:27.814317Z). |

One wake owner: the plugin advertises no idle wake. Nothing else in the
isolated session wakes it; each frame entered only at a native prompt.

## Manual harnesses: Grok, Muse, AGY, Codex

Each worker was bound with adapter `manual` and all five capabilities reported
unsupported with a reason. Its session handle (`herdr-workspace:harness-NAME`)
is operator-asserted, not native proof. The operator froze each batch with the
worker's host credential just before launching the harness.

Each harness then ran interactively in its own Herdr workspace in an empty
private directory, with a brief allowing only `agentboard worker
check-in|state|ack` on that worker. The proof is that session's own exact-ID
received and handled receipts, in the table below. Each worker's batches came mostly from its bootstrap
Context backlog. Grok's round-1 batch included its controlled `task_assign`
delivery; the other workers' controlled deliveries showed as pending in
check-in.

| Worker | Round 1 attempt (IDs) | Round 2 attempt (IDs) | Observed |
| --- | --- | --- | --- |
| grok | `e8e61a6e-a8f7-419b-9c34-b18bff279b1e` (11) | `a079e920-e705-45fd-a362-c460d18af6f9` (9) | Both rounds received and handled; "no command failed". Ran one read-only search outside the brief. `grok --version` reported 1.0.53 at write-up; the running session's version was not captured. |
| muse | `623a3a86-a8e1-4216-9084-8e9fcdec77c7` (11) | `63694391-3b73-4830-8c42-e6361ee6369e` (9) | Both rounds; "no commands failed". Loaded its `agentboard-muse` skill on its own (read-only). |
| codex | `117f65c9-761e-4af7-8294-1bb7abf715da` (11) | `701796a3-2651-46e9-9c79-a868c73eda71` (9) | Both rounds. The first sandboxed check-in failed `connection_failed`; every network command needed the maintainer's approval. Round-1 receipts (`2026-10-12T19:23:43.615795Z`, `2026-10-12T19:24:01.608829Z`) were accepted after the 120 s lease had expired and the attempt was `uncertain`. |
| agy | `5abfbe35-afb3-40aa-9082-d5fb7db014e9` (11) | not frozen | Round 1 received and handled. Its command tool truncated the ~25 KB check-in output, so it read its own transcript files to recover the IDs. Round 2 timed out because the operator froze no batch in time; this is a run omission, not a harness result. |

Receipts were read back with each attempt's frozen epoch, generation and hash
(`POST /api/v1/workers/:id/attempts/:attempt/reconcile`). Every row below is
`handled` and `resolved` true. The server stamps receipt harness and model
from the worker enrollment. AGY round 2 was not frozen and has no receipts.

| Worker | Round | Attempt | Kind | Receipt ID | created_at (UTC) | Idempotency key |
| --- | --- | --- | --- | --- | --- | --- |
| grok | 1 | `e8e61a6e-a8f7-419b-9c34-b18bff279b1e` | received | `10ca6e9c-0022-4aae-82c1-b5c7781dc9a2` | `2026-10-12T19:19:01.136131Z` | `harness-proof-grok-r1-received` |
| grok | 1 | `e8e61a6e-a8f7-419b-9c34-b18bff279b1e` | handled | `8d55a31c-cdfd-4cef-a107-7283f7d7fc3f` | `2026-10-12T19:19:06.040862Z` | `harness-proof-grok-r1-handled` |
| grok | 2 | `a079e920-e705-45fd-a362-c460d18af6f9` | received | `61df7bec-000c-4d9e-973b-441643ae6640` | `2026-10-12T19:23:00.121110Z` | `harness-proof-grok-r2-received` |
| grok | 2 | `a079e920-e705-45fd-a362-c460d18af6f9` | handled | `e436e4f2-76af-40e9-b171-80c7ec460100` | `2026-10-12T19:23:04.644028Z` | `harness-proof-grok-r2-handled` |
| muse | 1 | `623a3a86-a8e1-4216-9084-8e9fcdec77c7` | received | `e50ee178-5680-4bd4-ad94-1a4ac80ccfff` | `2026-10-12T19:20:26.922782Z` | `harness-proof-muse-r1-received` |
| muse | 1 | `623a3a86-a8e1-4216-9084-8e9fcdec77c7` | handled | `4f4f9d24-335e-403d-bd9c-b08b8672ff3e` | `2026-10-12T19:20:33.850802Z` | `harness-proof-muse-r1-handled` |
| muse | 2 | `63694391-3b73-4830-8c42-e6361ee6369e` | received | `c6e2a45b-e357-401a-880a-285421eeebbe` | `2026-10-12T19:22:56.938976Z` | `harness-proof-muse-r2-received` |
| muse | 2 | `63694391-3b73-4830-8c42-e6361ee6369e` | handled | `b38ce4db-c59a-470f-96ef-da3f4a619fbb` | `2026-10-12T19:23:02.550398Z` | `harness-proof-muse-r2-handled` |
| codex | 1 | `117f65c9-761e-4af7-8294-1bb7abf715da` | received | `c41ae191-8d1a-4166-abe8-feefdbcf9a84` | `2026-10-12T19:23:43.615795Z` | `harness-proof-codex-r1-received` |
| codex | 1 | `117f65c9-761e-4af7-8294-1bb7abf715da` | handled | `f1b263c5-3616-438e-871f-a4a8a11d6e45` | `2026-10-12T19:24:01.608829Z` | `harness-proof-codex-r1-handled` |
| codex | 2 | `701796a3-2651-46e9-9c79-a868c73eda71` | received | `08aa3fa6-a540-426f-9d2c-07ea543977a8` | `2026-10-12T19:37:02.484885Z` | `harness-proof-codex-r2-received` |
| codex | 2 | `701796a3-2651-46e9-9c79-a868c73eda71` | handled | `06624b36-f296-40e1-9d6c-1af4412b5ce9` | `2026-10-12T19:37:33.002494Z` | `harness-proof-codex-r2-handled` |
| agy | 1 | `5abfbe35-afb3-40aa-9082-d5fb7db014e9` | received | `f90ed3be-b00c-4a64-9565-9155636461d7` | `2026-10-12T19:24:20.145205Z` | `harness-proof-agy-r1-received` |
| agy | 1 | `5abfbe35-afb3-40aa-9082-d5fb7db014e9` | handled | `6dba9ce1-1348-4c23-883e-230578a18db4` | `2026-10-12T19:24:25.721270Z` | `harness-proof-agy-r1-handled` |

## Gaps found

- **No CLI path for manual workers.** `worker bind` requires a native adapter
  probe and refuses `manual` ("automatic adapter unsupported; use explicit
  check-in"). `worker serve` never reserves for them. Explicit check-in needs a
  receipt capability that only bind issues, and `worker ack` needs a frozen
  attempt. This run therefore did bind and reserve through the published worker
  API with the worker's own host credential. A supported manual
  bind/reserve command is needed before manual workers are self-service.
- **Check-in output size.** One check-in was about 25 KB (pending pages plus
  Mattermost coverage). AGY's command tool truncates that.
- **Codex sandbox.** The default macOS sandbox blocks the worker API. Each
  `agentboard worker` command needed escalation approval.
- **Stopping headless Claude.** Closing the stream-json stdin FIFO did not end an
  idle Claude 2.1.296 `-p` session. SIGINT did, with `SessionEnd` and clean
  transport removal.
- **Isolation leak.** With `--setting-sources ""`, the claude.ai connector MCP
  servers (Gmail, Drive, Docs and others) still loaded in the session. The
  permission mode denied them; only the plugin tools were allowed.
- **Codex native on Darwin.** The verified-FD owner is Linux-only
  ([Codex owner](../worker-codex-owner.md)). Darwin is unsupported before dial,
  and cross-compilation is not runtime proof.
- **Grok, Muse, AGY have no native adapter.** The worker config admits only
  `pi-native-v1`, `claude-hook-v1` and `codex-app-server-v1` as automatic
  adapters. Their native boundaries are therefore unsupported, not unproven.
- **Install is coupled to one service config.** `worker install --config PATH
  --apply` rewrites the single LaunchAgent plist to serve PATH. This run installed
  with the existing config path (all eight owned files already current) and ran
  the proof `worker serve` separately.
- **Bootstrap backlog.** A new worker is seeded with up to 20 Context deliveries,
  so its first batch is backlog rather than the newest controlled source.
- **Operator brief adherence.** Grok, Muse and AGY each did one read-only action
  outside their brief. None wrote, claimed or acted on source content.
