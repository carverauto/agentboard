# Approval receipt

The captain reviewed the portable proposal and architecture and returned the
exact feedback `approved`, ending the review themselves. The retained durable
captain decision was subsequently answered `approved` and applied by the worker.

The approved proposal/design/tasks/spec bundle SHA-256 is
`554ba524ace6dedeee7d632e6e97cb0c7fb5dc901960c1bc41021b556732bee8`.
That digest identifies the original reviewed inputs, retained in the portable
proposal review. Subsequent implementation proof does not change that receipt.

An explicitly authorized coordination amendment adds the optional protocol-1
`state.worker.availability` requirement to the specification. It permits the
narrow server snapshot and packaged API proof, requires older-client
compatibility and Codex fail-closed behavior, and grants disposable installed
native conformance with the existing login and a synthetic scoped API. It does
not authorize production enrollment or delivery. This amendment is separate
from the original bundle digest.

Approval covers the dedicated opt-in native Codex implementation. Production
enrollment, activation, canary rollout and Herdr delivery are separate gates.
No shared-session takeover or schema migration is authorized by this receipt.
