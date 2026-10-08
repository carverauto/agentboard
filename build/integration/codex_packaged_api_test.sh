#!/usr/bin/env bash
set -euo pipefail
export CODEX_TEST_NODE="$TEST_SRCDIR/$4"
export CODEX_TEST_BRIDGE="$TEST_SRCDIR/$TEST_WORKSPACE/internal/worker/codex-native.mjs"
export CODEX_TEST_FIXTURE="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/codex_native_fixture.mjs"
export AGENTBOARD_API_TEST_SCRIPT=codex_packaged_api_test.py
PATH="$(dirname "$CODEX_TEST_NODE"):$PATH"
export PATH
bash "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/board_api_test.sh" "$1" "$2" "$3"
