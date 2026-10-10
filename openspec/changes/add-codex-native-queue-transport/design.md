# Design

## Boundary

The caller supplies an immutable attempt ID, source pointer/hash, recipient,
binding epoch and dispatch generation. This library neither reserves nor elects,
recomputes occurrences, provisions or claims. The injected client owns negotiated
RPC correlation and endpoint identity. The pinned source is `rust-v0.162.0`;
installed CLI advertising `queue --thread` does not prove server compatibility.

Only `thread/read`, `thread/queue/add`, and `thread/queue/list` are reachable.
Queue add is immediately effectful and may wake an idle thread. No idle precheck
is used as an atomic fence, and busy acceptance is not receipt or handling.
Native queue insertion has no deduplication. Starting before deleting an item
creates a native crash window; exactly-once is expressly not claimed.

## Evidence

A private owned directory and protected regular 0600 files retain the frozen
frame, endpoint/recipient incarnation, clientUserMessageId and submitting phase
before the sole add. Per-attempt filesystem custody serializes competing
processes. Existing or abandoned locks are never removed automatically. A crash
can reduce availability but cannot authorize another add. Positive acceptance
must match the exact RPC request context, queued ID, client ID and input.
Every retained read establishes its own checked file and directory fsync barrier,
then verifies the observed inode, so an incompletely published rename is never
treated as durable merely because it is visible. Retained acceptance stays
historical even after queue consumption or deletion.

All errors after calling add are uncertain, including malformed acceptance and
response timeout. A failed initial durable save performs zero RPC calls. Changed
attempt/body/recipient/epoch/generation fences fail closed. No error or missing
queue item authorizes retry. Reconcile uses only retained acceptance or positive
exact queue evidence; offset pagination cannot prove absence. Duplicate matches,
edited input, shifting/unfinished pagination and wrong-generation responses are
uncertain. A prompt asking for source recheck is advisory, not an enforced fence.

## Future integration gates

Native version/schema/export and disposable conformance; authorized live
endpoint binding; shared runtime-owner agreement; caller dispatch eligibility;
consumer canonical-source recheck; existing explicit received/handled receipt
path; remote acceptance and separately approved enrollment. None is claimed here.
