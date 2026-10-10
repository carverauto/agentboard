# Tasks

- [x] Write proposal before implementation; verify isolated authorized VM root.
- [x] Verify source-pinned wire contract and record limitations.
- [x] Implement unregistered transport and protected native-evidence journal.
- [x] Cover exact correlation, no replay, filesystem and process races with fixtures.
- [x] Add isolated integration target and run available VM checks.
- [x] Independent review and resolve findings before any commit (scoped core clear; see verification).
- [ ] Remote Bazel acceptance (requires configured remote credentials).

Native conformance, runtime integration and production activation are explicitly
outside this change, not checked off by synthetic fixture success.
