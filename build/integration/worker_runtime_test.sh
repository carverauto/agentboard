#!/usr/bin/env bash
set -euo pipefail
export AB_BINARY="$TEST_SRCDIR/$1"
export AB_WORKER_CONTRACT="$TEST_SRCDIR/$TEST_WORKSPACE/testdata/worker_contract"
python3 "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/worker_runtime_test.py"
