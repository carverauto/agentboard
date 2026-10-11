# Safe portable coordinator selftest

Implement the safe diagnostic subset of #159. Operators need a portable way
to check protocol compatibility, scoped read access, attribution and local ack
parsing without enrolling a coordinator or mutating coordination state.

Add `coordinator selftest [--offline] [--json]`, a versioned PASS/WARN/FAIL report,
bounded read-only sampling and shared ack fixtures. Persisted badges, native
schedule/admission, captain delivery, actual received/handled proof and live
activation remain explicitly unverified and out of scope.
