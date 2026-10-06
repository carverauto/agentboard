#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]] || { echo 'Requires isolated root RBE action'; exit 1; }
rootfs="$TEST_TMPDIR/cnpg-image"
mkdir -p "$rootfs"
tar -xzf "$TEST_SRCDIR/$1" -C "$rootfs"
mkdir -p "$rootfs/tmp" "$rootfs/dev"
chmod 1777 "$rootfs/tmp"
: > "$rootfs/dev/null"
chmod 666 "$rootfs/dev/null"
image_run() { python3 "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/as_postgres_image_user.py" "$rootfs" "$@"; }
bin=/usr/lib/postgresql/18/bin
port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
image_run "$bin/initdb" -D /tmp/data --encoding=UTF8 --no-locale --auth=trust > "$TEST_TMPDIR/initdb.log" 2>&1 || { cat "$TEST_TMPDIR/initdb.log"; exit 1; }
cleanup() { image_run "$bin/pg_ctl" -D /tmp/data -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
image_run "$bin/pg_ctl" -D /tmp/data -l /tmp/postgres.log -o "-c listen_addresses=127.0.0.1 -p $port -c unix_socket_directories=/tmp -c shared_preload_libraries=pg_textsearch -c pg_textsearch.memory_limit=16MB" -w start >/dev/null || { cat "$rootfs/tmp/postgres.log"; exit 1; }
sql() { image_run "$bin/psql" -h /tmp -p "$port" -d postgres -v ON_ERROR_STOP=1 -Atc "$1"; }
[[ "$(sql 'SHOW server_version')" == 18.6* ]]
sql 'CREATE EXTENSION pg_textsearch' >/dev/null
[[ "$(sql "SELECT extversion FROM pg_extension WHERE extname='pg_textsearch'")" == 1.5.1 ]]
sql "CREATE TABLE findings(id int PRIMARY KEY, content text NOT NULL);
INSERT INTO findings VALUES (1,'TLS certificate rotation failed'),(2,'dashboard layout'),(3,'TLS certificate');
CREATE INDEX findings_search ON findings USING bm25(content) WITH (text_config='simple');" >/dev/null
rank="SELECT string_agg(id::text,',' ORDER BY score,id) FROM (SELECT id,content <@> to_bm25query('TLS certificate','findings_search') score FROM findings WHERE to_tsvector('simple',content) @@ plainto_tsquery('simple','TLS certificate')) ranked"
[[ "$(sql "$rank")" == 3,1 ]]
image_run "$bin/pg_ctl" -D /tmp/data -m fast restart >/dev/null
[[ "$(sql "$rank")" == 3,1 ]]
echo 'Actual CNPG PostgreSQL 18.6 image loads pg_textsearch 1.5.1, ranks and survives restart as its postgres account.'
