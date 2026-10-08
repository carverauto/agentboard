#!/usr/bin/env bash
set -euo pipefail
"$TEST_SRCDIR/$2" --experimental-vm-modules "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/details_hook_test.mjs" "$TEST_SRCDIR/$1"
