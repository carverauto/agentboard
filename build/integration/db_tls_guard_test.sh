#!/usr/bin/env bash
set -euo pipefail
release_archive="$TEST_SRCDIR/$1"
release_root="$TEST_TMPDIR/release"
mkdir -p "$release_root"
tar -xzf "$release_archive" -C "$release_root"
export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export RELEASE_TMP="$TEST_TMPDIR/runtime"
export ELIXIR_ERL_OPTIONS='+fnu +S 2:2'
export PHX_SERVER=false
unset DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USER DATABASE_PASSWORD
check_reject() {
  local out="$TEST_TMPDIR/guard.log"
  export DATABASE_URL="$1"
  if "$release_root/bin/agentboard" eval 'IO.puts("BOOTED")' >"$out" 2>&1; then
    echo "Packaged startup accepted a TLS-downgrading DATABASE_URL" >&2
    return 1
  fi
  grep -q 'refusing to start' "$out" || { echo "Rejection did not come from the TLS guard" >&2; cat "$out" >&2; return 1; }
  if grep -q 'BOOTED' "$out"; then
    echo "Application booted despite a TLS-downgrading DATABASE_URL" >&2
    return 1
  fi
  if grep -q 's3cr3t-guard-pw' "$out"; then
    echo "Startup failure disclosed database credentials" >&2
    return 1
  fi
}
check_reject "postgresql://agentboard:s3cr3t-guard-pw@127.0.0.1:1/agentboard_test?ssl=false"
check_reject "postgresql://agentboard:s3cr3t-guard-pw@127.0.0.1:1/agentboard_test?sslmode=disable"
check_reject "postgresql://agentboard:s3cr3t-guard-pw@127.0.0.1:1/agentboard_test?sslmode=allow"
check_reject "postgresql://agentboard:s3cr3t-guard-pw@127.0.0.1:1/agentboard_test?SSLMODE=prefer"
echo "Packaged startup rejects TLS-downgrading DATABASE_URL values without disclosing credentials"
