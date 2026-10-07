#!/usr/bin/env bash
set -euo pipefail
PATH="$(dirname "$TEST_SRCDIR/$2"):$PATH"
export PATH
"$TEST_SRCDIR/$2" "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/claude_native_test.mjs" "$(dirname "$TEST_SRCDIR/$1")"
