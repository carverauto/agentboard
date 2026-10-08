#!/usr/bin/env bash
set -euo pipefail
PATH="$(dirname "$TEST_SRCDIR/$2"):$PATH"
export PATH
"$TEST_SRCDIR/$2" "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/codex_native_test.mjs" "$TEST_SRCDIR/$1" "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/codex_native_fixture.mjs"
