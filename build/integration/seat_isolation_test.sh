#!/usr/bin/env bash
set -euo pipefail
python3 "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/seat_isolation_test.py" "$TEST_SRCDIR/$1" "$TEST_SRCDIR/$2"
