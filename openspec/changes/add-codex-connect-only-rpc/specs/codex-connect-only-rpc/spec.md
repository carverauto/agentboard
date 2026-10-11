## ADDED Requirements

### Requirement: One existing connection only
The client SHALL validate the exact protected native socket alias, ownership,
permissions and identity; connect once with bounded WebSocket framing; and NEVER
repair or restart a daemon, retry, redirect, resend or use an embedded fallback.

#### Scenario: Socket changes
- WHEN alias, socket or trusted ancestry identity changes
- THEN the client synchronously retires its identity and closes its connection
- AND no queued request is retried on another connection

### Requirement: Owner proof is separate from native wire fields
The client SHALL require an external trusted owner to authorize initialization,
bind the actual connected stream and attest server lifetime/build/schema and
recipient enrollment. It SHALL NOT promote path, PID, user agent, session-tree ID
or a local connection token to native incarnation evidence.

#### Scenario: Proof is missing or revoked
- WHEN required proof is missing, rejected, asynchronous or synchronously revoked
- THEN no live-ready identity is exposed
- AND pending calls reject only after identity has been retired

### Requirement: Bounded protocol with no server responses
The client SHALL allow only the attested thread's metadata read, bounded queue
list and bounded single-text queue add. It SHALL correlate exact never-reused
IDs, preserve raw responses and bound framing, fragmentation, notifications,
pending work, wire bytes and lifetime. It SHALL NOT answer any server request.

#### Scenario: Shared approval arrives
- WHEN an approval or other server request arrives
- THEN the connection retires without a JSON-RPC result or error response
- AND any uncertain add remains protected by the existing transport journal

### Requirement: Synthetic proof is not native conformance
Fixtures SHALL use invented peers and disposable state. Hosted/Bazel fixtures
SHALL require the invented Unix-socket test and may not convert a denied/unrun
socket check into success. No fixture SHALL open the actual protected daemon.

#### Scenario: Assistant VM denies Unix sockets
- WHEN the synthetic listener receives EPERM
- THEN the Unix fixture is reported blocked/unrun without an access bypass
- AND in-memory framing/path fixtures remain distinct passed evidence
