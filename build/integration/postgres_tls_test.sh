#!/usr/bin/env bash
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
source "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
result="$(fixture_psql "SELECT current_database() = 'agentboard_test' AND ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")"
[[ "$result" == t ]] || { echo "Expected isolated TLS database connection" >&2; exit 1; }
if PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" \
  "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_test user=agentboard sslmode=disable" -Atc 'SELECT 1' >/dev/null 2>&1; then
  echo "Non-TLS connection unexpectedly accepted" >&2
  exit 1
fi
if PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" \
  "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_test user=agentboard sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" -Atc 'SELECT 1' >/dev/null 2>&1; then
  echo "Untrusted TLS connection unexpectedly accepted" >&2
  exit 1
fi
fixture_pid="$(head -1 "$fixture_root/data/postmaster.pid")"
cleanup_fixture
if kill -0 "$fixture_pid" 2>/dev/null || [[ -e "$fixture_root" ]]; then
  echo "Fixture cleanup failed" >&2
  exit 1
fi
echo "Isolated PostgreSQL TLS, rejection, and cleanup checks passed"
