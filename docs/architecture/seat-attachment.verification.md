# Seat attachment verification

Captain board message 1255 approved OpenSpec and implementation together for [issue #141](https://github.com/carverauto/agentboard/issues/141). This receipt covers the authored checkpoint; native publication and current-head GitHub CI are tracked on the board task.

## Executed remote behavior

All build/test invocations use `./scripts/bazel`, which injects `--config=remote`. No local Go, Elixir, asset or container build was performed.

- [Four affected tests passed](https://carverauto.buildbuddy.io/invocation/0b0de86f-9d99-46fe-85e3-5fbcdd83bc06): packaged seat attachment, pinned seat isolation, publication guard and CLI tests.
- [Final two affected CLI tests passed](https://carverauto.buildbuddy.io/invocation/86af1222-eeee-4ee6-929d-91e9d72b17a2) after separating task-page ownership validation from pagination. Isolation and publication code stayed unchanged after their passing run.
- The public CLI fixture uses an invented HTTP board plus real Git and pinned Treehouse v3.1.2, in a product repository without Agentboard scripts. It exercises paginated owned-task evidence, concurrent/retry lease reuse, failed recording, interrupted-allocation refusal, WIP/credential preservation, shell quoting, secret-free output, primary/foreign/legacy refusal, native repeat attachment and installed documentation payload.
- The publication sibling fixture initially lacked a real Treehouse lease. It was corrected to acquire the pinned lease; the existing guard was retained. A later mistyped Bazel label failed before execution and was corrected to the targets in the linked final proof.
- Strict OpenSpec validation passes. The implementation checklist records seven completed tasks.

No live farm01 deployment was made. The remote Linux package is verified; the new CLI commands are not installed on the Mac until a release is built and installed. Python 3, Git and pinned Treehouse are explicit runtime prerequisites. Skill text is a shipped instruction contract; tests do not claim an LLM will follow it.

## Documentation evidence

Archify deterministic delivery passed all nine showcase checks with zero errors and warnings. Its browser receipt covers four desktop viewports and light/dark modes. Its separate perceptual receipt records actual inspection of the captured images. Source and delivered HTML checksums are bound in the receipts; the source was not changed after delivery.

The portable OpenSpec HTML renders all four canonical artifacts, includes the retained diagram and uses Agentboard's existing CSS theme tokens. Its source receipt binds the canonical Markdown hashes and exported HTML checksum. Actual browser measurements show scroll width equal to viewport width at desktop 1440 and narrow 390, with all sections expanded. Light/dark desktop and narrow screenshots were opened for perceptual review. The browser screenshot command had an acknowledgement error despite writing usable PNGs; the receipt distinguishes that tool limitation from the successful DOM measurements and actual image review.

## Deliberate boundaries

Same-host task acquisition is serialized and persisted before board recording. An interrupted allocation without its final receipt, another host's record, conflicting protected metadata or a real isolation/ownership failure remains a blocker; no blind acquisition, reset or automatic takeover follows. Recovery output cannot change a parent shell or running harness: the session consumes exports, changes cwd and rechecks. Existing credential files are preserved. No global Herdr hooks or fleet dispatch are added. Missing environment alone does not authorize resuming a pending captain decision.

Only selected remote results and invocation URLs are retained. Raw Bazel BEP, execution logs, profiles and credential-bearing configs are excluded from publication evidence.
