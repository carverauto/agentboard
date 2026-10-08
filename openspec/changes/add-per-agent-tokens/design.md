# Design

## Context

APIController.actor/1 reads x-agentboard attribution directly. Agentboard.Captain already verifies a configured capability in constant time; WorkerController and Cooperation.Runtime demonstrate captain-gated provisioning and hash-only worker credentials. Browser Settings uses the existing captain session. CLI Client owns HTTPS, redirect refusal and bounded retry behavior. This change extends those seams without adding an identity provider.

## Goals / Non-Goals

Create a verifiable principal and useful adoption evidence without disrupting current writes. Deliver the observe phase only under coordinator msg974. Do not enable enforcement, issue real credentials, change host wake producers or reuse Mattermost bot tokens.

## Decisions

1. **Credential boundary.** A dedicated Ash domain stores random credential IDs, agent ID, SHA256 digest, safe fingerprint, fixed scope, issuer, created/last-used/revoked timestamps. Tokens contain 256 random bits. Only captain-capability API or unlocked Settings may administer them. Rotate locks the agent credential set and revokes old active credentials atomically. List and normal resource projection omit both plaintext and digest. No plaintext persistence, logging or audit metadata.
2. **Observe semantics.** Off keeps legacy attribution. Observe verifies the bearer and attaches its agent as a separate authenticated principal; effective board attribution remains the existing header, including mismatches, as required by GH128's accept-every-write contract. Matched principals therefore identify the same actor. Record anonymous, invalid/revoked and actor_mismatch outcomes for mutating board endpoints, with method, normalized route, attributed/verified IDs and timestamp only. Emit bounded telemetry outcomes and show durable counts/recent samples on Agents. Audit failure fails visibly rather than claiming unrecorded evidence. Worker protocol endpoints retain their separate verifier; captain administration retains its capability.
3. **Enforcement gate.** Proposed phase two makes the verified agent the effective actor and rejects missing/invalid tokens (401) or mismatches (403 actor_mismatch); internal server actors remain in-process. Reserved system names cannot receive ordinary agent/coordinator credentials. Fixed scopes are agent, coordinator, system and captain-admin; scope must never grant captain privileges merely from a caller header. Implementing scoped external system/captain-admin access and the enforce switch waits for captain approval.
4. **CLI custody.** AGENTBOARD_TOKEN is used only in the Authorization header over the existing guarded transport. Administration reads the existing captain capability. Issue/rotate require a protected output path and atomically create a new 0600 file; stdout/JSON prints metadata and path only. No automatic adoption, token echo, metadata inclusion or error-body reflection of secret values. Environment transport is phase one; protected file loading checks ownership, regular-file status and permissions.
5. **Seat boundary.** Launcher refuses coordinator identity, checks the actual persisted Treehouse lease holder on acquisition and --check, writes only its own non-secret identity/URL environment into exclusive 0600 agent.env and git-excludes the seat directory. Tests may exercise token propagation using fixture values; runtime real-token provisioning is captain/admin custody and is not performed by this agent. Shared fleet guidance contains URL/coordinator only.
6. **Migration / rollback.** Add schema25 resources and set GREATEST(existing,25); schema compatibility uses 25. Upgrade regression preserves newer stamps and existing records. Off is the default and rollback setting. Retain credential/audit data on rollback; no destructive down migration during rollout.

## Risks / Trade-offs

Observe deliberately preserves spoofable legacy writes until approved enforcement, so counts are adoption evidence, not access control. Concurrent rotation and last-use updates must not resurrect revoked credentials. Administrative token responses must never be routed into ordinary logs or CLI output. The captain reviews the report and approves the separate enforcement implementation before configuring observe/enforce on a deployment.

## Verification

Remote packaged Phoenix/Postgres tests cover captain denial, hash-only storage, issue/rotate/revoke and old-token invalidation; off/observe effective attribution and durable mismatch evidence; reserved identities, stable metadata and audit absence of fixture secrets. Remote Go tests inspect actual outbound headers and stdout/error suppression. Launcher executable tests use fixture Treehouse pools for coordinator rejection, lease mismatch and 0600/exclusion behavior. Enforce tests belong to the approved second phase; they are not claimed in this delivery.
