#!/usr/bin/env bash
set -euo pipefail
export AGENTBOARD_API_TEST_SCRIPT=archive_api_test.py
export AGENTBOARD_CAPTAIN_TOKEN=synthetic-captain-capability-0123456789-for-isolated-tests
export FIXTURE_NORMAL_ROLE=true
export ARCHIVE_RELEASE_BIN="$TEST_TMPDIR/release/bin/agentboard"
exec bash "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/board_api_test.sh" "$@"
