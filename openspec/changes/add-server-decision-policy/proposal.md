# Server-owned captain decision policy

## Why

GH154 moves routine decision answers into deterministic board machinery. GH145's
schema/evaluator is not on main, so this change includes that prerequisite and a
thin API-backed CLI. The coordinator never receives captain authority.

## What changes

- A strict bounded `CaptainDecisionPolicy` document, a single authoritative
  deterministic evaluator, and read-only validate/plan/explain surfaces.
- Immutable named policy versions, captain-only approval of an exact digest,
  and a compare-and-set active-version pointer. Editing creates a fresh draft.
- Transactional event-created AshOban jobs. Only an explicitly active, approved
  version and opt-in server apply mode can answer; the default is dry-run.
- An append-only evaluation/answer ledger, database uniqueness, current-source
  and policy generation fences, and serialized PR/day and decision CI budgets.
- Existing decision answer/message/event/wake behavior reused atomically.
- Thin CLI lifecycle, plan/explain/ledger commands and truthful coordinator
  attention metadata without additional runner authority.

## Boundaries and remaining work

No deployment, credential changes, live policy activation, seat dispatch or
coordinator schedule changes are part of implementation. GH153 signed push is
absent; escalations remain durable open decisions with explicit delivery status,
not a claim of human push. Do not retire the existing decision poll until a
separately authorized live deployment and transport/cutover verification.

This is the server-owned replacement for GH145 apply. JSON is the initial
interchange format (the schema is compatible with JSON's YAML subset). Full
standalone YAML parsing, offline apply/file locks and local pending JSONL are
not claimed complete; thin CLI calls the server's one authoritative evaluator.
They remain GH145 packaging work rather than a second rule implementation.

## Validation

Test strict schema and deterministic matching; auth spoofing and approval hash
binding; activation/current-source races; duplicate job and answer delivery
idempotency; shared PR/day and CI budgets; transaction rollback and database
immutability; read-only CLI/plan and existing decision/coordinator regressions.
Every Bazel invocation remains remote; absent remote configuration is disclosed.
