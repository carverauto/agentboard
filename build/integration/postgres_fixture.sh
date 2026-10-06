#!/usr/bin/env bash
# Source only inside an isolated Linux BuildBuddy test action.
set -euo pipefail
if [[ -z "${TEST_TMPDIR:-}" || "$(uname -s)" != Linux ]]; then
  echo "PostgreSQL fixture requires a Linux Bazel test action" >&2
  return 1
fi
fixture_root="$(mktemp -d "$TEST_TMPDIR/agentboard-db.XXXXXX")"
tar -xzf "${POSTGRES_RUNTIME_ARCHIVE:?declare the pinned PostgreSQL runtime input}" -C "$fixture_root"
fixture_bin="$fixture_root/usr/lib/postgresql/18/bin"
export LD_LIBRARY_PATH="$fixture_root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fixture_user=()
if [[ "$(id -u)" == 0 ]]; then
  cat > "$fixture_root/as_user.py" <<'PY'
import os, pwd, sys
account = pwd.getpwnam("nobody")
os.setgroups([])
os.setgid(account.pw_gid)
os.setuid(account.pw_uid)
os.execv(sys.argv[1], sys.argv[1:])
PY
  fixture_user=(python3 "$fixture_root/as_user.py")
  chmod o+x "$TEST_TMPDIR"
fi
cleanup_fixture() {
  if [[ -e "$fixture_root/data/postmaster.pid" ]]; then
    "${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$fixture_root/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$fixture_root"
}
trap cleanup_fixture EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.crt" \
  -subj '/CN=Agentboard isolated test CA' >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -keyout "$fixture_root/server.key" \
  -out "$fixture_root/server.csr" -subj '/CN=localhost' >/dev/null 2>&1
cat > "$fixture_root/server.extensions" <<'EXTENSIONS'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXTENSIONS
openssl x509 -req -in "$fixture_root/server.csr" -CA "$fixture_root/ca.crt" \
  -CAkey "$fixture_root/ca.key" -CAcreateserial -days 1 \
  -extfile "$fixture_root/server.extensions" -out "$fixture_root/server.crt" >/dev/null 2>&1
openssl rand -hex 24 > "$fixture_root/password"
chmod 600 "$fixture_root/ca.key" "$fixture_root/server.key" "$fixture_root/password"
if [[ "${#fixture_user[@]}" != 0 ]]; then chown -R nobody:nogroup "$fixture_root"; fi
"${fixture_user[@]}" "$fixture_bin/initdb" -D "$fixture_root/data" --no-locale --encoding=UTF8 \
  --username=postgres --pwfile="$fixture_root/password" --auth-host=scram-sha-256 --auth-local=trust >"$fixture_root/initdb.log" 2>&1 || {
  cat "$fixture_root/initdb.log" >&2; exit 1;
}
printf 'hostnossl all all all reject\nhostssl all all all scram-sha-256\nlocal all all trust\n' > "$fixture_root/data/pg_hba.conf"
export DATABASE_HOST=127.0.0.1
export DATABASE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export DATABASE_NAME=agentboard_test
export DATABASE_USER=agentboard
export DATABASE_PASSWORD="$(cat "$fixture_root/password")"
export DATABASE_CA_FILE="$fixture_root/ca.crt"
unset DATABASE_URL
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$fixture_root/data" -l "$fixture_root/postgres.log" \
  -o "-c listen_addresses=127.0.0.1 -p $DATABASE_PORT -c unix_socket_directories='$fixture_root' -c ssl=on -c ssl_cert_file='$fixture_root/server.crt' -c ssl_key_file='$fixture_root/server.key' -c jit=off" \
  -w start >/dev/null || { cat "$fixture_root/postgres.log" >&2; exit 1; }
fixture_role_attribute=SUPERUSER
if [[ "${FIXTURE_NORMAL_ROLE:-false}" == true ]]; then fixture_role_attribute=NOSUPERUSER; fi
"$fixture_bin/psql" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -Atc \
  "CREATE ROLE agentboard LOGIN $fixture_role_attribute PASSWORD '$DATABASE_PASSWORD'" >/dev/null
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_test
fixture_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" \
    "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_test user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" \
    -v ON_ERROR_STOP=1 -Atc "$1"
}
