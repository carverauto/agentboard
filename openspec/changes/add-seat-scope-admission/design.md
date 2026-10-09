# Design

## Authority and storage

`seat_scopes` is keyed by registered agent ID, separate from registration metadata/capabilities. An Ash resource uses captain policy authorization, paper-trail versions and board action events. The schema-34 migration creates no policies, preserves higher schema markers and forbids destructive downgrade. Versions are append-only. No delete/reset endpoint exists.

GET/PUT `/api/v1/agents/:id/scope` reads or replaces all three arrays. Every write supplies an integer expected revision: zero creates, positive values replace that exact revision. Two writes at the same revision cannot both succeed. Unrecognized keys, missing/null arrays, empty repository allowlists, malformed repositories and wildcards reject. Repository lists are bounded to 100 entries, label lists to 100 each, individual strings to 256 bytes. Arrays deduplicate; repositories lowercase, labels preserve exact case and whitespace. Label strings must contain non-whitespace text and no ASCII control characters (including newline); ordinary spaces are preserved.

No row is explicitly Unmanaged at revision zero. Legacy manual operations remain compatible; this is not automatic claim permission. `managed_matches?/2` returns false for unmanaged seats and is only a scope precondition, never full automatic eligibility. Role, readiness, enrollment and host gates remain deferred. Empty required-label arrays are permitted for this manual scope API, not evidence of automatic fleet readiness. No scheduler consumes either predicate in this change. Existing `routing_eligible` remains an availability/retirement indicator, not task-specific or automatic scope admission.

## Matching

A managed task must have a complete canonical `owner/repo` matching an allowlisted repository. Bare names, nil, wildcards, URLs and malformed paths do not match. Every required label must appear. When allowed labels are nonempty, at least one must appear. Both label gates and repository match must hold. Extra task labels are allowed. Empty label arrays disable that gate. Required `security` is the correct security-only example; an ANY list alone cannot represent all mandatory labels.

## Serialization and new work

Scope replacement takes the same transaction-held exclusive advisory lock used by availability policy writes. Task admission, typed orders, broadcast and provisioning take its shared counterpart before reading scope, even when no row exists. This prevents an absent-row creation race and gives a committed ordering between policy edits and new work.

`Availability.admit/4` invokes the shared scope predicate, preserving retirement and availability behavior. Internal CI and rebase assignment already use that boundary and therefore leave ineligible repair work Open with no responsible seat. Broadcast is an explicit captain manual operation: unmanaged recipients remain compatible and managed mismatches are excluded. Typed task orders require an existing explicit task and active named recipient, and lock the task before checking its routing fields.

Changing an owned task's repository or labels checks the resulting task against its managed owner, preventing claim-then-edit scope escape. An unchanged routing field, description edit, renewal, progress, release, receipt or recovery is not rejected merely because the captain narrowed scope afterward. Scope is admission policy, not retroactive cancellation or filesystem fencing.

Captain provisioning may not request repositories outside a managed seat's approved repositories. Existing subscriptions/credentials are not modified when policy narrows; repair and receipt channels remain intact. Generic batch reservation also rejects retired identities before idempotent replay, matching existing wake admission while preserving state/receipt/reconciliation endpoints.

## UI and clients

Agents shows Managed/Unmanaged and actual scope. The captain modal snapshots revision server-side, retains input on conflict and requires close/reopen to review newer state. Ordinary/forged LiveView events cannot elevate authority. CLI uses the existing protected captain transport and standard conflict/exit conventions. There is no separate MCP server: integrations calling the central task API inherit these checks; no standalone MCP verification is claimed.

## Relationship to retained FleetLoadout proposal

The retained issue #60 design is a proposal, not formal acceptance. Its automatic fleet contract also requires nonempty required labels, explicit allowed task roles, enrollment/readiness and host gates. This preliminary manual admission API does not implement or relax those gates. Optional allowed-label ANY is a new additive restriction; it never replaces required-label ALL. Future FleetLoadout must reference or transactionally update this same scope authority, not establish a competing independently edited allowlist, and must prevent fleet-enrolled identities from bypassing its gates through legacy routes.

This bounded PUT uses optimistic revision, without the proposed loadout idempotency-key protocol. After an uncertain response, read current scope before retrying. An identical replacement with an old revision still conflicts. Full loadout revision/idempotency and fleet enrollment bypass fencing remain future integration work.
