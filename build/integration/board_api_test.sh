#!/usr/bin/env bash
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
release_archive="$TEST_SRCDIR/$2"
export AB_BINARY="$TEST_SRCDIR/$3"
if [[ $# -ge 5 ]]; then
  export FIXTURE_RENDERED_BUNDLE="$TEST_SRCDIR/$4"
  export FIXTURE_RENDERED_NODE="$TEST_SRCDIR/$5"
fi
source "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
release_root="$TEST_TMPDIR/release"
mkdir -p "$release_root"
tar -xzf "$release_archive" -C "$release_root"
export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export RELEASE_TMP="$TEST_TMPDIR/runtime"
export ELIXIR_ERL_OPTIONS='+fnu +S 4:4'
export PHX_SERVER=false
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()' >"$TEST_TMPDIR/migration.log" 2>&1 || { cat "$TEST_TMPDIR/migration.log"; exit 1; }
export PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export PHX_HOST=127.0.0.1
export PHX_SERVER=true API_RATE_LIMIT_IP=1000 API_RATE_LIMIT_AGENT=1000
export AGENTBOARD_URL="http://127.0.0.1:$PORT"
export AGENTBOARD_BIN="$release_root/bin/agentboard"
"$release_root/bin/agentboard" start >"$TEST_TMPDIR/web.log" 2>&1 &
web_pid=$!
cleanup_board() { kill "$web_pid" 2>/dev/null || true; wait "$web_pid" 2>/dev/null || true; cleanup_fixture; }
trap cleanup_board EXIT
for attempt in $(seq 1 100); do
  if curl -sf "$AGENTBOARD_URL/health/ready" >/dev/null; then break; fi
  if ! kill -0 "$web_pid" 2>/dev/null; then cat "$TEST_TMPDIR/web.log"; exit 1; fi
  sleep 0.1
done
export QUOTA_FIXTURES="$TEST_SRCDIR/$TEST_WORKSPACE/testdata/quota"
export FIXTURE_CONTROL="$fixture_bin/pg_ctl" FIXTURE_DATA="$fixture_root/data"
export FIXTURE_PSQL="$fixture_bin/psql"
export PGHOST=127.0.0.1 PGPORT="$DATABASE_PORT" PGDATABASE=agentboard_test PGUSER=agentboard PGPASSWORD="$DATABASE_PASSWORD" PGSSLMODE=verify-full PGSSLROOTCERT="$DATABASE_CA_FILE"
python3 "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/${AGENTBOARD_API_TEST_SCRIPT:-board_api_test.py}" || { tail -60 "$TEST_TMPDIR/web.log"; exit 1; }
