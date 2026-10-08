# Agent availability modal verification

The `/agents` header and roster rows open the same captain-only dialog. Row actions prefill the agent ID. Changes use the existing `set_availability` event and Ash availability domain. Invalid saves retain the draft and display errors inside the dialog; cancellation writes no policy. Saving closes the dialog and confirms the update. Reason appears for Reserved / Out of service, and Until appears for Out of service.

The dialog reuses `QuotaDialog`, with a per-dialog close event and return-focus target. Pinned LiveView 1.1.33 `JS.ignore_attributes("open")` preserves only the browser-owned open attribute; draft/error contents still update. No new process, API, schema or task-ownership behavior is introduced.

## Remote runtime proof

`./scripts/bazel test //build/integration:availability_api_test //build/integration:board_paging_test //build/integration:dialog_hook_test //build/integration:board_api_test //build/integration:seat_attachment_test //build/integration:details_hook_test //web:decision_panel_test --test_output=summary`

**7/7 passed** after rebasing onto main with merged PR #174: [BuildBuddy invocation](https://carverauto.buildbuddy.io/invocation/ee654a6b-d396-43aa-9b6a-9ff655979772). The append conflict in the test manifest retained both findings and dialog targets.

Availability is exercised through a real CSRF-protected captain unlock, signed session, LiveView websocket, the pinned SDK's rendered-wire consumer, and persisted Ash policies. Coverage includes public denial, row/header opening, row prefill, cancellation, conditional fields, invalid reasons/timestamps, successful save, and draft retention through the actual fallback reload. The browser hook test executes the production application registration and callbacks; SDK stand-ins capture registration only.

Tests-first baseline failed because the inline form remained permanently visible: [baseline](https://carverauto.buildbuddy.io/invocation/9c743292-9239-4029-8452-6a854bd223b4). The dialog-hook baseline independently failed because availability dismissal routed to `close_quota`: [baseline](https://carverauto.buildbuddy.io/invocation/00cfc587-c317-48bc-8f20-8d1e3bae338a).

Pulling forward from main exposed an omitted `seat_attach.go` Bazel source entry: [failed compile](https://carverauto.buildbuddy.io/invocation/7ea20e53-0681-4c11-9067-7e7ae15a887d). Restoring that entry makes the existing seat attachment and UI fixtures build and pass. No Go behavior change is included.

This proof does **not** drive a disposable browser through the running product. Native focus trapping, real keyboard/backdrop dismissal, focus return, visual responsive layout, and preserving an open dialog through actual browser DOM patches remain **UNTESTED-live**. Archify browser checks below validate the documentation viewer, not the product UI.

## Archify receipt

- Diagram: workflow; [source](agents-availability-modal.json), [standalone HTML](agents-availability-modal.html).
- Specification SHA-256: `25637131d03fe7e429f34c9e2990618a333e9555aaf61ed50adfee2ff4a67c77` (3376 bytes).
- Artifact SHA-256: `3b1c163f78275a48cf742bcd6a455bedceb4afc0b2bdc097bce6e879c3b43ac8` (710532 bytes).
- Deterministic validation: **9/9 showcase**, zero errors or warnings.
- Automated browser evidence: **passed**. READ / Still light-theme containment at 1440×900, 1600×1000, 1920×1080 and 2048×1320; light/dark captures at both endpoint sizes.
- Perceptual review: **passed** after image review of the actual final artifact in light/dark, including the 2048×1320 composition. Browser interaction exercised node search, opening the Audited policy passport, and Escape closure with focus restored. No horizontal overflow was observed.
- Correction rounds: **2** (compact redundant lanes/cards for containment, then label the PostgreSQL legend accurately).

The artifact is self-contained and contains no deployment coordinates or credential material. Browser sidecars are review evidence; the retained source and standalone HTML are the durable documentation.
