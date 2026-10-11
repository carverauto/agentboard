# Design

Reuse the existing protected client and the shared ack parser/normalizer.
Default probes use only metadata GET then one bounded authenticated tick GET;
o canonical source, ack or heartbeat request is allowed. Stop at a failed
prerequisite, enforce identity and revision, and reject malformed, duplicate-key,
invalid-Unicode or over-budget envelopes. Emit fixed diagnostic text rather
than remote strings. Offline execution bypasses credentials and HTTP entirely.

The report has version 1, a read_only/offline mode, an aggregate status, and
named checks with status/detail. Any FAIL makes the aggregate FAIL and returns
nonzero. Required unverified live-capability warnings prevent aggregate PASS;
WARN exits zero. A page sample does not certify policy correctness, traversal,
server receipt semantics or adapter conformance. Protected-read telemetry is
allowed; coordination rows must remain unchanged.
