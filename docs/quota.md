# Quota evidence

Agentboard accepts quota-axi's `QuotaAxiResponse` schema 5 or 6. It never contacts providers or refreshes credentials. Push a single report from stdin, or use `--file`:

```sh
quota-axi --json --max-age 90s | ab quota push --json
ab quota push --file=report.json --json
ab quota list --provider=codex --json
ab quota watch --provider=codex --account=work --json
```

The caller needs registered agent/model/harness context. HTTP clients POST the producer report directly to `/api/v1/quota`. Required top-level fields are `schemaVersion`, a valid RFC3339 `generatedAt`, and `providers`. Provider rows require a nonempty provider identity, `state.status`, boolean `state.stale`, and a `windows` array. Empty provider/window arrays are valid observations. Supported producer statuses are fresh/stale/unavailable/auth_required/rate_limited/error. Window IDs and scope identities must be unique within their observation, and known percentage fields must be numeric in 0–100.

Schema 5 assigns `account_key=default` and permits one observation per provider in a report. Schema 6 requires a nonempty `accountKey` per provider row and a unique provider/account pair. `accountKeys` aliases remain producer metadata; they do not create extra accounts. Unknown provider names are accepted with valid structure.

A report, its provider/account observations, windows, and effective scopes commit together. The database retains the complete raw producer JSON, source agent/model/harness, producer generation time, and server ingestion time. History rejects updates, deletes, and truncate. No v1 retention cleanup runs. The canonical digest sorts object keys recursively, preserves array order, and normalizes integral JSON numbers; an exact retry by the same source returns the original report with `idempotent=true`. It does not add children or emit a false quota change. Distinct source identities retain distinct collection provenance.

Latest reads choose the whole observation per provider/account by generation time, then ingestion time, then report ID. Older arrivals remain history and cannot replace a newer reading. A newer observation with no windows clears older windows from the current view; a newer error/stale observation preserves that new state rather than silently borrowing earlier fresh numbers.

List output uses the `quota` array and `next_cursor`, with provider/account ordering and the same bounded keyset contract as other lists. Board projections use snake_case keys, including nested window/scope fields; stored raw JSON keeps the producer's original names and optional/unknown fields. `observation_stale` compares generation time to the default ten-minute threshold (`--stale-after` / `AGENTBOARD_STALE_AFTER`), separately from producer-reported `state.stale` and `state.status`.

Windows preserve reported IDs, kinds, labels, percentages, parent shares, resets, and optional pace. A `share_of` meter without reported remaining capacity remains unknown; agentboard does not compute 100 minus used. Effective scopes preserve status, bounds, conflicts, limiting windows, runway, and selection. `through_reset` remains that producer conclusion; it is not infinity, finite runway seconds, or a common reset clock. Unknown/conflicting/untrusted/stale readings remain uncertainty. `selection.spend_priority` is advisory evidence for a person or explicitly directed assistant, never an automatic assignment, provider preference, or worker launch.

Quota watches use `/api/v1/quota/watch` and the same full-snapshot/reconnect/fallback semantics as task/message watches. `ab quota list --watch` is an alias. The only quota notification is a compact committed report ID; raw reports and account metadata are not broadcast.

Tests use invented reports constructed from the installed quota-axi public type contract. They do not collect or copy live quota, credentials, account email, or token-bearing provider exports.
