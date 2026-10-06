#!/usr/bin/env bash
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
source "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
fixture_psql "CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE TABLE findings (id bigint PRIMARY KEY, content text NOT NULL);
INSERT INTO findings VALUES (1,'TLS certificate rotation failed with unknown authority'),(2,'Dashboard lane spacing'),(3,'TLS certificate rotation succeeded after CA refresh');
CREATE INDEX findings_bm25 ON findings USING bm25 (content) WITH (text_config='simple');" >/dev/null
rank_sql="SELECT string_agg(id::text,',' ORDER BY score,id) FROM (SELECT id,content <@> to_bm25query('TLS certificate','findings_bm25') AS score FROM findings WHERE to_tsvector('simple',content) @@ plainto_tsquery('simple','TLS certificate') ORDER BY score,id LIMIT 10) ranked"
actual="$(fixture_psql "$rank_sql")"; [[ "$actual" == '1,3' ]] || { echo "Unexpected BM25 order: $actual" >&2; exit 1; }
if fixture_psql "BEGIN; INSERT INTO findings VALUES (4,'TLS certificate rollback probe'); ROLLBACK;" >/dev/null; then
  [[ "$(fixture_psql "SELECT count(*) FROM findings WHERE id=4")" == 0 ]]
fi
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$fixture_root/data" -m fast restart >/dev/null
actual="$(fixture_psql "$rank_sql")"; [[ "$actual" == '1,3' ]] || { echo "Unexpected BM25 order: $actual" >&2; exit 1; }

# Real physical replica, replay and promotion; no mocked search index.
fixture_psql "CREATE ROLE replica WITH REPLICATION LOGIN PASSWORD '$DATABASE_PASSWORD'" >/dev/null
printf 'hostssl replication replica 127.0.0.1/32 scram-sha-256\n' >> "$fixture_root/data/pg_hba.conf"
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$fixture_root/data" reload >/dev/null
replica_root="$fixture_root/standby"
export PGSSLCERT="$fixture_root/not-used.crt" PGSSLKEY="$fixture_root/not-used.key"
export PGPASSWORD="$DATABASE_PASSWORD" PGSSLMODE=verify-full PGSSLROOTCERT="$DATABASE_CA_FILE"
"${fixture_user[@]}" "$fixture_bin/pg_basebackup" -h 127.0.0.1 -p "$DATABASE_PORT" -U replica -D "$replica_root" -X stream -R >/dev/null
replica_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$replica_root" -l "$fixture_root/standby.log" \
  -o "-c listen_addresses=127.0.0.1 -p $replica_port -c unix_socket_directories='$fixture_root' -c ssl=on -c ssl_cert_file='$fixture_root/server.crt' -c ssl_key_file='$fixture_root/server.key' -c shared_preload_libraries=pg_textsearch -c pg_textsearch.memory_limit=16MB -c hot_standby_feedback=on" -w start >/dev/null
cleanup_bm25() {
  "${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$replica_root" -m immediate stop >/dev/null 2>&1 || true
  cleanup_fixture
}
trap cleanup_bm25 EXIT
standby_sql() { "$fixture_bin/psql" "host=127.0.0.1 port=$replica_port dbname=agentboard_test user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"; }
fixture_psql "INSERT INTO findings VALUES (5,'TLS certificate'); SELECT pg_switch_wal();" >/dev/null
for attempt in $(seq 1 100); do
  [[ "$(standby_sql 'SELECT count(*) FROM findings WHERE id=5')" == 1 ]] && break
  sleep .1
done
[[ "$(standby_sql "$rank_sql")" == '5,1,3' ]]
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$fixture_root/data" -m fast stop >/dev/null
"${fixture_user[@]}" "$fixture_bin/pg_ctl" -D "$replica_root" -w promote >/dev/null
[[ "$(standby_sql 'SELECT pg_is_in_recovery()')" == f ]]
[[ "$(standby_sql "$rank_sql")" == '5,1,3' ]]
standby_sql "INSERT INTO findings VALUES (6,'TLS certificate');" >/dev/null
[[ "$(standby_sql 'SELECT count(*) FROM findings')" == 5 ]]
echo 'BM25 ranking, rollback, restart, physical replay and promotion passed'
