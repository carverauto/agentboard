#!/usr/bin/env bash
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
source "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
test "$(id -u)" = 0 || { echo 'This isolated image test requires the root RBE container for chroot'; exit 1; }
rootfs="$TEST_TMPDIR/image"
mkdir -p "$rootfs"
tar -xzf "$TEST_SRCDIR/$2" -C "$rootfs"
chmod o+x "$TEST_TMPDIR"
mkdir -p "$rootfs/etc/agentboard/db-ca" "$rootfs/dev" "$rootfs/tmp"
cp "$DATABASE_CA_FILE" "$rootfs/etc/agentboard/db-ca/ca.crt"
chmod 1777 "$rootfs/tmp"
chmod 755 "$rootfs/var/tmp"
# The remote sandbox disallows device creation. The shell only redirects into
# this fixture file; this is not evidence of a container's device mounts.
: > "$rootfs/dev/null"
chmod 666 "$rootfs/dev/null"
export DATABASE_CA_FILE=/etc/agentboard/db-ca/ca.crt
export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export RELEASE_TMP=/tmp/agentboard ELIXIR_ERL_OPTIONS='+fnu +S 2:2' LANG=C.UTF-8 PHX_SERVER=false RELEASE_DISTRIBUTION=none
image_run() { python3 "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/as_image_user.py" "$rootfs" "$@"; }
image_run /bin/sh -c 'test ! -w /app && test ! -w /etc && test ! -w /var/tmp && test -w /tmp'
image_run /app/bin/agentboard eval 'Agentboard.Release.migrate()' >"$TEST_TMPDIR/image-migrate.log" 2>&1 || { cat "$TEST_TMPDIR/image-migrate.log"; exit 1; }
export PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
# Startup must honor DATABASE_URL over deliberately invalid split fields.
export DATABASE_URL="postgresql://agentboard:$DATABASE_PASSWORD@127.0.0.1:$DATABASE_PORT/agentboard_test"
export DATABASE_HOST=invalid.example DATABASE_PORT=1 DATABASE_NAME=invalid DATABASE_USER=invalid DATABASE_PASSWORD=invalid
export PHX_HOST=127.0.0.1 PHX_SERVER=true
image_run /app/bin/agentboard start >"$TEST_TMPDIR/image-web.log" 2>&1 &
image_pid=$!
cleanup_image() { kill "$image_pid" 2>/dev/null || true; wait "$image_pid" 2>/dev/null || true; cleanup_fixture; }
trap cleanup_image EXIT
base="http://127.0.0.1:$PORT"
for attempt in $(seq 1 100); do
  if curl -sf "$base/health/ready" >/dev/null; then break; fi
  if ! kill -0 "$image_pid" 2>/dev/null; then cat "$TEST_TMPDIR/image-web.log"; exit 1; fi
  sleep 0.1
done
curl -fsS "$base/health/live" > "$TEST_TMPDIR/live.json"
curl -fsS "$base/health/ready" > "$TEST_TMPDIR/ready.json"
curl -fsS "$base/assets/app.js" > "$TEST_TMPDIR/app.js"
curl -fsS "$base/assets/app.css" > "$TEST_TMPDIR/app.css"
test -s "$TEST_TMPDIR/app.js" && test -s "$TEST_TMPDIR/app.css"
python3 - <<'PY'
import json,os
from pathlib import Path
root=Path(os.environ['TEST_TMPDIR'])
assert json.loads((root/'live.json').read_text())['status']=='live'
assert json.loads((root/'ready.json').read_text())['status']=='ready'
PY
echo 'Actual OCI rootfs started and migrated as UID/GID 10001 with app/etc unwritable and temporary state under /tmp.'
echo 'A Kubernetes readOnlyRootFilesystem mount and production CNPG image remain rollout checks.'
