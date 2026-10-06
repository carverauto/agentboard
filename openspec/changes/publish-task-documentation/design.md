# Design

## Context

See proposal.md for motivation. The existing API uses rate limiting before bounded JSON parsing, Ecto queries in caller processes, atomic task row locks and immutable task events. The dashboard reads task metadata and serves read-only detail pages. The CLI never accesses SQL.

## Goals / Non-Goals

**Goals:** Durable, task-linked visual documentation with attribution, safe interactive viewing and reproducible PR delivery.

**Non-Goals:** A general file store, executable document access to API/session state, server-side Lavish process hosting or server enforcement of external GitHub PR completeness.

## Decisions

1. Store standalone UTF-8 HTML and metadata in PostgreSQL. A document is at most 2 MiB and a task at most 100 immutable versions. PostgreSQL TOAST handles these small documents; a single transaction saves attribution, task revision/event and notification. NATS JetStream Object Store is a chunked NATS client facility, not an HTTP object server. It would require both JetStream operations and an HTTP bridge plus reconciliation of database links. Revisit an external object store when measured volume justifies it.
2. Upload through `agentboard doc push TASK --file FILE --kind archify|openspec --title TITLE`, with optional PR URL, source commit and proposal name. Metadata reads omit HTML; list responses are bounded. Upload is restricted to the live task owner and terminal tasks remain immutable. A content-and-metadata digest makes identical retries idempotent, even after task completion, without authorizing a new write.
3. Serve a trusted wrapper containing a sandboxed iframe. Both iframe sandbox and HTML response CSP allow inline scripts and downloads while excluding same-origin, popups, forms, top navigation, frames and network fetches. This permits Archify interactions while isolating untrusted HTML from the board/API. A raw download is attachment-only with sandbox CSP and nosniff.
4. The canonical skill requires Archify source JSON, delivered standalone HTML, validation receipts, upload and task/PR links before feature/design PR delivery. Harness skills already inherit it. Captain checks completeness. OpenSpec proposals are rendered with Lavish automatically; local review URLs are not durable document URLs. Export a portable HTML, upload it as openspec documentation and record the proposal name.

## Risks / Trade-offs

- Active HTML → persistent iframe sandbox plus response CSP; test hostile document behavior in a browser.
- Storage growth → per-file and per-task bounds, no HTML in task list/watch snapshots.
- Renderer export features may depend on storage/network → isolated viewer permits only self-contained operations; original attachment remains available.
- Existing trusted-network unauthenticated API → preserve its current network boundary and ownership model.

## Migration Plan

Apply additive document table/function migration before the new app digest. Verify API/CLI, viewer headers, task links, browser isolation and live upload. Roll back only to a compatible image; preserve documentation and events.
