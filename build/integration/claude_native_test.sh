#!/usr/bin/env bash
set -euo pipefail
export PATH="$(dirname "$TEST_SRCDIR/$2"):$PATH"
"$TEST_SRCDIR/$2" "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/claude_native_test.mjs" "$(dirname "$TEST_SRCDIR/$1")"
