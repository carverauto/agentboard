# Task documentation

Architecture/design and feature PRs include validated Archify source JSON and standalone HTML. Included OpenSpec proposals automatically open in Lavish and are exported to portable HTML. The canonical [agent workflow](../skills/agentboard/SKILL.md) applies to every harness; reviewers check these delivery artifacts.

As a registered live task owner, upload before marking the task complete:

```sh
agentboard doc push TASK --file docs/architecture/change.html --kind archify --title 'Change architecture' --pr https://github.com/OWNER/REPO/pull/NUMBER --commit COMMIT_SHA --json
agentboard doc push TASK --file docs/architecture/proposal.html --kind openspec --proposal CHANGE --title 'CHANGE proposal' --pr https://github.com/OWNER/REPO/pull/NUMBER --commit COMMIT_SHA --json
agentboard doc list TASK --json
```

Uploads use the Phoenix HTTP API, with the same 429/Retry-After handling and provenance as task writes. Only a live owner can add documentation. Renew before upload when necessary. An identical task, source agent, content and metadata retry returns the original artifact; changed content or metadata creates another immutable version. Completed tasks accept identical retries but no new versions. The task detail shows every version and its source agent/model/harness, optional PR URL, source commit and OpenSpec change name. The response supplies `viewer_url` and `download_url` relative to `AGENTBOARD_URL`; put the resulting absolute viewer URL in the PR and delivery note. Local Lavish URLs are temporary review surfaces, not durable links.

`POST /api/v1/tasks/:id/documents` accepts a JSON object with required `kind` (`archify` or `openspec`), `title` (1–256 bytes), and `html`. Optional fields are `pr_url` (GitHub HTTPS PR), `source_revision` (40 lowercase hexadecimal characters), and `proposal_name` (slug). `GET /api/v1/tasks/:id/documents` returns metadata only. HTML must be a standalone UTF-8 document starting with a doctype/html element, contain no NUL, and be at most 2 MiB; the existing 5 MiB JSON request-body limit also applies to its encoded transport. A task retains at most 100 versions. Upload, attributed event and task revision are atomic; no HTML is carried in board list/watch snapshots. PostgreSQL retains HTML and metadata.

`/documents/:id` is the trusted viewer, `/documents/:id/html` serves sandboxed HTML, and `/documents/:id/download` returns an attachment. The iframe and HTML response CSP allow inline scripts and downloads without same-origin access, API/network fetches, child frames, forms, popups or top navigation. Self-contained diagrams keep their interactions. Exported OpenSpec HTML must inline its images/styles and use static embedded diagrams rather than nested frames. Features relying on external assets/network or browser storage are unsupported inside the isolated viewer. Download the original file when a trusted local workflow needs its full export tools. Never add `allow-same-origin` to make a document work.

Small bounded documentation lives with task history in PostgreSQL (including TOAST storage for larger values). An external object store can be introduced later if measured document volume warrants it.

Storage background: [PostgreSQL TOAST](https://www.postgresql.org/docs/18/storage-toast.html) stores larger values outside the main row.
