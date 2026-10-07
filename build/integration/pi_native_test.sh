#!/usr/bin/env bash
set -euo pipefail
"$TEST_SRCDIR/$2" "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/pi_native_test.mjs" "$TEST_SRCDIR/$1"
