#!/usr/bin/env bash
# Real schema42->43 upgrade on a disposable PostgreSQL fixture: the chat spool
# and private route tables are additive, retained data is untouched, the
# marker is monotonic and rollback refuses to drop unresolved-send evidence.
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
fixture_script="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
release_root="$TEST_TMPDIR/release"
mkdir -p "$release_root"
tar -xzf "$TEST_SRCDIR/$2" -C "$release_root"
export SECRET_KEY_BASE="$(openssl rand -base64 64)" PHX_SERVER=false FIXTURE_NORMAL_ROLE=true
export ELIXIR_ERL_OPTIONS='+fnu +S 4:4'
check() { if [[ "$1" != "$2" ]]; then echo "Chat spool upgrade: $3 (expected $2, got $1)" >&2; exit 1; fi; }
migrate_to() {
  "$release_root/bin/agentboard" eval "Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: $1) end)"
}
for marker in 42 99; do (
  root="$TEST_TMPDIR/chat-spool-upgrade-$marker"
  mkdir -p "$root"
  export RELEASE_TMP="$root/runtime"
  source "$fixture_script"
  migrate_to 20261008004200 >"$root/pre42.log" 2>&1 || { cat "$root/pre42.log"; exit 1; }
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" 42 'actual old schema'
  check "$(fixture_psql "SELECT to_regclass('conversation_spool') IS NULL AND to_regclass('mattermost_agent_routes') IS NULL")" t 'new tables absent'
  check "$(fixture_psql 'SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user')" t 'normal role'
  # Production shape at 42: agents, a parked private notice intent, a sent
  # thread intent and chat coverage receipts must all survive unchanged.
  fixture_psql "
    INSERT INTO agents(id,name,model,harness) VALUES ('spool-a','Spool A','fixture','codex'),('spool-b','Spool B','fixture','codex');
    INSERT INTO tasks(id,title,repo) VALUES ('spool-task','Retained task','fixture/upgrade');
    INSERT INTO mattermost_outbox(id,source,source_key,source_version,task_id,destination,routing_revision,state,generation,next_eligible_at,event_marker,payload,last_error,attempts,created_at,updated_at)
      VALUES ('30000000-0000-4000-8000-000000000043','board_message','message:4301',1,NULL,'mattermost:agent_inbox:spool-b',1,'pending',0,'2026-10-01 00:00:00+00','agentboard:message:4301:notice','{\"action\":\"message\",\"message_id\":4301}','recipient_route_unavailable',0,'2026-10-01 00:00:00+00','2026-10-01 00:00:00+00'),
             ('30000000-0000-4000-8000-000000000044','board_task_event','task_event:4302',1,'spool-task','mattermost:board_thread:spool-task',1,'sent',1,'2026-10-01 00:00:00+00','agentboard:spool-task:4302:create','{\"action\":\"create\"}',NULL,1,'2026-10-01 00:00:00+00','2026-10-01 00:00:00+00');
    INSERT INTO conversation_coverage(id,agent_id,channel_id,last_post_id,last_version,caught_up,incomplete_reason,checked_at,created_at,updated_at)
      VALUES ('40000000-0000-4000-8000-000000000043','spool-a','chan-1','post-7',0,false,'send_only','2026-10-01 00:00:00+00','2026-10-01 00:00:00+00','2026-10-01 00:00:00+00');
    UPDATE board_schema SET version=$marker WHERE id=1;
  " >/dev/null
  history="$(fixture_psql "SELECT 'SELECT jsonb_object_agg(name,rows ORDER BY name) FROM (' || string_agg(format('SELECT %L AS name, COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),''[]''::jsonb) AS rows FROM %I.%I t',tablename,schemaname,tablename),' UNION ALL ' ORDER BY tablename) || ') preserved' FROM pg_tables WHERE schemaname='public' AND tablename NOT IN ('board_schema','schema_migrations')")"
  fixture_psql "$history" >"$root/before.json"
  for run in first repeated; do
    migrate_to 20261008004300 >"$root/$run.log" 2>&1 || { cat "$root/$run.log"; exit 1; }
    fixture_psql "$history" >"$root/after-$run.json"
    cmp "$root/before.json" "$root/after-$run.json"
  done
  expected=43; if [[ "$marker" == 99 ]]; then expected=99; fi
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected" 'monotonic aggregate marker'
  check "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004300')" 1 'one migration'
  check "$(fixture_psql 'SELECT (SELECT count(*) FROM conversation_spool) + (SELECT count(*) FROM mattermost_agent_routes)')" 0 'nothing invented for history'
  check "$(fixture_psql "SELECT has_table_privilege('public','conversation_spool','SELECT') OR has_table_privilege('public','mattermost_agent_routes','SELECT')")" f 'no PUBLIC access'
  check "$(fixture_psql "SELECT routing_revision||','||state||','||last_error FROM mattermost_outbox WHERE source_key='message:4301'")" '1,pending,recipient_route_unavailable' 'parked private intent stays parked'
  # The spool shape refuses a retained body on a verified send.
  if fixture_psql "INSERT INTO conversation_spool(msg_id,agent_id,channel_id,task_id,kind,body,body_sha256,state,post_id,created_at,expires_at,updated_at) VALUES ('m1','spool-a','chan-1','general','note','kept',repeat('a',64),'sent','post-1',now(),now(),now())" >/dev/null 2>&1; then
    echo 'Chat spool accepted a body on a sent row' >&2; exit 1
  fi
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Application.ensure_all_started(:ash_postgres); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Adapters.SQL.query!(repo, "SELECT 1", [], queue: true); {:ok, version} = Agentboard.SchemaVersion.current(); true = version >= 43; nil = Agentboard.Mattermost.AgentRoutes.lookup("spool-b"); {:ok, %{deleted: 0, expired: 0}} = Agentboard.Mattermost.ChatSpool.purge_expired(); false = Agentboard.Mattermost.AgentRoutes.enabled?(); IO.puts("Upgraded spool/route reads and default-off routes passed") end)' >"$root/app.log" 2>&1 || { cat "$root/app.log"; exit 1; }
  if "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :down, step: 1) end)' >"$root/down.log" 2>&1; then
    echo 'Chat spool migration unexpectedly allowed destructive down' >&2; exit 1
  fi
  grep -q 'Retain chat spool and private route evidence' "$root/down.log"
  fixture_psql "$history" >"$root/after-down.json"
  cmp "$root/after-repeated.json" "$root/after-down.json"
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected" 'failed down marker preserved'
); done
printf 'Chat spool schema42->43 upgrade, retained data, repeated migration, protection, default-off and higher marker preservation passed\n'
