#!/usr/bin/env bash
# Real schema39 -> 40 upgrade with a normal database role. The optional fixture
# and release overrides run the same assertions on a disposable Linux VM.
set -euo pipefail

if [[ -n "${COORDINATOR_UPGRADE_RELEASE_ROOT:-}" ]]; then
  release_root="$COORDINATOR_UPGRADE_RELEASE_ROOT"
  fixture_script="${COORDINATOR_UPGRADE_FIXTURE:?provide a disposable PostgreSQL fixture}"
  export TEST_TMPDIR="${TEST_TMPDIR:-$(mktemp -d)}"
else
  export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
  release_archive="$TEST_SRCDIR/$2"
  fixture_script="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
  release_root="$TEST_TMPDIR/release"
  mkdir -p "$release_root"
  tar -xzf "$release_archive" -C "$release_root"
fi

export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export ELIXIR_ERL_OPTIONS='+fnu +S 4:4'
export PHX_SERVER=false FIXTURE_NORMAL_ROLE=true

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "Coordinator upgrade assertion failed: $3 (expected '$2', got '$1')" >&2
    exit 1
  fi
}

for initial_marker in 9000 39; do (
  case_root="$TEST_TMPDIR/coordinator-upgrade-$initial_marker"
  mkdir -p "$case_root"
  export RELEASE_TMP="$case_root/runtime"
  source "$fixture_script"

  # Do not remove/rename packaged migration files to fake an old release.
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008003900) end)' >"$case_root/migrate39.log" 2>&1 || {
    cat "$case_root/migrate39.log" >&2; exit 1;
  }
  assert_eq "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" 39 'actual pre40 schema marker'
  assert_eq "$(fixture_psql 'SELECT max(version) FROM schema_migrations')" 20261008003900 'actual pre40 migration boundary'
  assert_eq "$(fixture_psql "SELECT to_regclass('coordinator_handling_batches') IS NULL AND to_regclass('coordinator_handling_items') IS NULL")" t 'new tables absent before upgrade'
  assert_eq "$(fixture_psql 'SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user')" t 'migration uses unprivileged application role'
  assert_eq "$(fixture_psql 'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()')" t 'database connection uses TLS'

  # All values are synthetic, including digest-shaped tokens. Include every old
  # scope, revocation/use metadata, a channel grant, and durable decision history.
  fixture_psql "
    INSERT INTO agents(id,name,model,harness) VALUES
      ('upgrade-agent','Retained worker','fixture','codex'),
      ('upgrade-coordinator','Retained observer','fixture','codex'),
      ('upgrade-participant','Retained participant','fixture','codex'),
      ('upgrade-system','Retained system','fixture','codex'),
      ('upgrade-admin','Retained administrator','fixture','codex');
    INSERT INTO agent_api_credentials(id,agent_id,token_hash,fingerprint,scope,channel_ids,issuer,created_at,last_used_at,revoked_at) VALUES
      ('00000000-0000-4000-8000-000000000001','upgrade-agent',repeat('1',64),repeat('1',12),'agent',ARRAY[]::text[],'captain','2026-10-01 00:00:00+00','2026-10-02 00:00:00+00',NULL),
      ('00000000-0000-4000-8000-000000000002','upgrade-coordinator',repeat('2',64),repeat('2',12),'coordinator',ARRAY[]::text[],'captain','2026-10-01 00:00:00+00',NULL,NULL),
      ('00000000-0000-4000-8000-000000000003','upgrade-participant',repeat('3',64),repeat('3',12),'coordinator_participant',ARRAY['approved-channel','second-channel'],'captain','2026-10-01 00:00:00+00','2026-10-03 00:00:00+00',NULL),
      ('00000000-0000-4000-8000-000000000004','upgrade-system',repeat('4',64),repeat('4',12),'system',ARRAY[]::text[],'captain','2026-10-01 00:00:00+00',NULL,'2026-10-04 00:00:00+00'),
      ('00000000-0000-4000-8000-000000000005','upgrade-admin',repeat('5',64),repeat('5',12),'captain-admin',ARRAY[]::text[],'captain','2026-10-01 00:00:00+00',NULL,NULL);
    INSERT INTO tasks(id,title,repo) VALUES ('upgrade-task','Retained task','fixture/upgrade');
    INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision,body)
      VALUES ('upgrade-task','upgrade-agent','fixture','codex','created',1,'Retained exact event body');
    INSERT INTO messages(sender_id,recipient_id,model,harness,task_id,body)
      VALUES ('upgrade-agent','upgrade-coordinator','fixture','codex','upgrade-task','Retained exact message: café 東京');
    INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest)
      VALUES ('upgrade-task','upgrade-agent','fixture','codex','archify','Retained document','<!doctype html><p>Retained café 東京</p>',repeat('a',64));
    INSERT INTO decision_requests(id,task_id,requester_id,kind,gate_ref,question,findings,options,status,message_id,event_id,created_at,updated_at)
      SELECT '10000000-0000-4000-8000-000000000001','upgrade-task','upgrade-agent','approval','upgrade-gate','Keep the evidence?','Retained findings',ARRAY['yes','no'],'open',m.id,e.id,'2026-10-05 00:00:00+00','2026-10-05 00:00:00+00'
      FROM messages m CROSS JOIN task_events e;
    INSERT INTO decision_requests_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at)
      VALUES ('10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','create','open','{\"status\":\"open\"}','{\"agent\":\"upgrade-agent\"}','2026-10-05 00:00:00+00','2026-10-05 00:00:00+00');
    INSERT INTO decision_conversation_intents(id,decision_id,operation,actor_id,credential_id,channel_ids,request_key,request_hash,source,repo,channel_id,root_id,recipient_id,task_id,board_message_id,msg_id,payload_hash,state,bot_user_id,post_id,post_version,post_metadata,created_at,updated_at,submitted_at,verified_at)
      SELECT '20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','notify','upgrade-participant','00000000-0000-4000-8000-000000000003',ARRAY['approved-channel','second-channel'],'retained-notice',repeat('b',64),repeat('c',64),'fixture/upgrade','approved-channel','','upgrade-agent','upgrade-task',id,'synthetic-message',repeat('d',64),'sent','synthetic-bot','synthetic-post',repeat('e',64),'{\"fixture\":true}','2026-10-05 00:00:00+00','2026-10-05 00:00:00+00','2026-10-05 00:00:00+00','2026-10-05 00:00:00+00' FROM messages;
    UPDATE board_schema SET version=$initial_marker WHERE id=1;
  " >/dev/null

  # Capture every pre-existing public table, including empty tables. Only the
  # two schema bookkeeping tables may change. Ordering is deterministic even
  # for tables without a primary key; complete JSON rows preserve all columns.
  history_query="$(fixture_psql "SELECT 'SELECT jsonb_object_agg(name,rows ORDER BY name) FROM (' || string_agg(format('SELECT %L AS name, COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),''[]''::jsonb) AS rows FROM %I.%I t',tablename,schemaname,tablename),' UNION ALL ' ORDER BY tablename) || ') preserved' FROM pg_tables WHERE schemaname='public' AND tablename NOT IN ('board_schema','schema_migrations')")"
  fixture_psql "$history_query" >"$case_root/before.json"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()' >"$case_root/migrate40.log" 2>&1 || {
    cat "$case_root/migrate40.log" >&2; exit 1;
  }
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()' >"$case_root/repeat40.log" 2>&1 || {
    cat "$case_root/repeat40.log" >&2; exit 1;
  }
  expected_marker=40
  if [[ "$initial_marker" == 9000 ]]; then expected_marker=9000; fi
  assert_eq "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected_marker" 'aggregate marker is monotonic'
  assert_eq "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004000')" 1 'coordinator migration applied exactly once'
  assert_eq "$(fixture_psql 'SELECT max(version) FROM schema_migrations')" 20261008004000 'migration endpoint is40'
  fixture_psql "$history_query" >"$case_root/after.json"
  cmp "$case_root/before.json" "$case_root/after.json"
  assert_eq "$(fixture_psql 'SELECT (SELECT count(*) FROM coordinator_handling_batches)+(SELECT count(*) FROM coordinator_handling_items)')" 0 'no invented handling evidence'
  assert_eq "$(fixture_psql "SELECT count(*) FROM agent_api_credentials WHERE scope='coordinator_runner'")" 0 'no legacy credential is promoted to runner'
  assert_eq "$(fixture_psql "SELECT scope || ':' || array_to_string(channel_ids,',') FROM agent_api_credentials WHERE agent_id='upgrade-participant'")" 'coordinator_participant:approved-channel,second-channel' 'participant grant stays exact'

  expect_rejection() {
    if fixture_psql "$1" >"$case_root/expected-rejection.log" 2>&1; then
      echo "Invalid coordinator upgrade operation accepted: $3" >&2; exit 1
    fi
    if ! grep -Eq "$2" "$case_root/expected-rejection.log"; then
      echo "Unexpected failure instead of $3" >&2
      cat "$case_root/expected-rejection.log" >&2; exit 1
    fi
  }
  credential_insert="INSERT INTO agent_api_credentials(id,agent_id,token_hash,fingerprint,scope,channel_ids,issuer,created_at) VALUES ('00000000-0000-4000-8000-000000000006','upgrade-coordinator',repeat('6',64),repeat('6',12),'coordinator_runner'"
  for channels in "ARRAY['unexpected-channel']" "ARRAY['same','same']" "ARRAY[NULL]::text[]"; do
    expect_rejection "$credential_insert,$channels,'captain',clock_timestamp())" agent_credential_channels 'runner channel grant constraint'
  done
  expect_rejection "$credential_insert,NULL,'captain',clock_timestamp())" 'null value in column "channel_ids"' 'null runner grant constraint'
  expect_rejection "UPDATE agent_api_credentials SET scope='coordinator_runner' WHERE scope='coordinator'" 'immutable credential' 'legacy observer promotion guard'
  expect_rejection "UPDATE agent_api_credentials SET channel_ids=ARRAY['expanded-channel'] WHERE scope='coordinator_participant'" 'immutable credential' 'participant grant immutability'
  fixture_psql "$history_query" >"$case_root/after-rejections.json"
  cmp "$case_root/before.json" "$case_root/after-rejections.json"

  # A newly issued runner is allowed with no channels. A complete atomic batch
  # is append-only; an incomplete batch must roll back at transaction commit.
  fixture_psql "$credential_insert,ARRAY[]::text[],'captain',clock_timestamp())" >/dev/null
  batch_insert="INSERT INTO coordinator_handling_batches(id,actor_id,credential_id,operation,retry_key,request_hash,model,harness,item_count,created_at) VALUES ('30000000-0000-4000-8000-000000000001','upgrade-coordinator','00000000-0000-4000-8000-000000000006','ack','upgrade-retry',repeat('f',64),'fixture','codex',1,clock_timestamp())"
  expect_rejection "$batch_insert" 'Handling batch requires all exact members' 'incomplete batch commit guard'
  assert_eq "$(fixture_psql 'SELECT count(*) FROM coordinator_handling_batches')" 0 'rejected incomplete batch leaves no row'
  fixture_psql "BEGIN; $batch_insert;
    INSERT INTO coordinator_handling_items(id,batch_id,decision_id,source_version,task_id,task_revision,requester_id,disposition,created_at)
      VALUES ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',repeat('a',64),'upgrade-task',1,'upgrade-agent','reviewed',clock_timestamp()); COMMIT" >/dev/null
  for table in coordinator_handling_batches coordinator_handling_items; do
    for operation in "UPDATE $table SET id=id" "DELETE FROM $table" "TRUNCATE $table CASCADE"; do
      expect_rejection "$operation" 'append.only|immutable|history' 'immutable coordinator handling evidence'
    done
  done
  evidence_query="SELECT jsonb_build_object('batches',(SELECT jsonb_agg(t ORDER BY id) FROM coordinator_handling_batches t),'items',(SELECT jsonb_agg(t ORDER BY id) FROM coordinator_handling_items t))"
  fixture_psql "$evidence_query" >"$case_root/evidence-before.json"
  fixture_psql "$history_query" >"$case_root/populated-before.json"
  if "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :down, step: 1) end)' >"$case_root/down.log" 2>&1; then
    echo 'Coordinator migration unexpectedly allowed destructive down' >&2; exit 1
  fi
  grep -q 'Retain immutable coordinator handling evidence; use compatible code' "$case_root/down.log"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()' >"$case_root/populated-repeat.log" 2>&1 || {
    cat "$case_root/populated-repeat.log" >&2; exit 1;
  }
  assert_eq "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected_marker" 'marker survives down refusal and repeat'
  assert_eq "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004000')" 1 'down refusal retains migration record'
  fixture_psql "$history_query" >"$case_root/populated-after.json"
  fixture_psql "$evidence_query" >"$case_root/evidence-after.json"
  cmp "$case_root/populated-before.json" "$case_root/populated-after.json"
  cmp "$case_root/evidence-before.json" "$case_root/evidence-after.json"
  echo "Schema39 -> 40 passed (marker $initial_marker -> $expected_marker): all legacy rows/grants preserved, no promotion/backfill, runner grants rejected, atomic immutable handling, down refused, repeat idempotent."
); done
