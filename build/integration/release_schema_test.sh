#!/usr/bin/env bash
set -euo pipefail
export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
release_archive="$TEST_SRCDIR/$2"
source "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
release_root="$TEST_TMPDIR/release"
mkdir -p "$release_root"
tar -xzf "$release_archive" -C "$release_root"
export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export RELEASE_TMP="$TEST_TMPDIR/runtime"
export ELIXIR_ERL_OPTIONS='+fnu +S 4:4'
export PHX_SERVER=false

"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(fixture_psql 'SELECT version FROM board_schema WHERE id = 1')" == 39 ]]
[[ "$(fixture_psql 'SELECT count(*) FROM mattermost_agent_bots')" == 0 ]]

fixture_psql "INSERT INTO agents (id, name, model, harness) VALUES ('worker','Worker','model-1','codex')" >/dev/null
fixture_psql "INSERT INTO tasks (id, title) VALUES ('sample','Sample')" >/dev/null
if fixture_psql "UPDATE tasks SET status = 'in_progress' WHERE id = 'sample'" >/dev/null 2>&1; then
  echo "Invalid ownership state accepted" >&2; exit 1
fi
[[ "$(fixture_psql "SELECT status FROM tasks WHERE id = 'sample'")" == open ]]
fixture_psql "INSERT INTO task_events (task_id, actor_id, model, harness, kind, new_revision) VALUES ('sample','worker','model-1','codex','created',1)" >/dev/null
for operation in "UPDATE task_events SET model = 'changed'" 'DELETE FROM task_events' 'TRUNCATE task_events'; do
  if fixture_psql "$operation" >/dev/null 2>&1; then
    echo "Append-only history changed" >&2; exit 1
  fi
done
[[ "$(fixture_psql 'SELECT count(*) FROM task_events')" == 1 ]]
fixture_psql "INSERT INTO messages (sender_id, model, harness, task_id, body) VALUES ('worker','model-1','codex','sample','Investigated TLS');
INSERT INTO task_documents (task_id, source_agent_id, model, harness, kind, title, html, digest) VALUES ('sample','worker','model-1','codex','archify','TLS flow','<!doctype html><p>café &amp; TLS</p>',repeat('a',64));
INSERT INTO quota_reports (source_agent_id, model, harness, schema_version, digest, generated_at, raw) VALUES ('worker','model-1','codex',6,repeat('b',64),clock_timestamp(),'{\"schema_version\":6,\"providers\":{}}');
INSERT INTO quota_observations (report_id, provider, account_key, provider_data) SELECT id, 'fixture-provider','fixture-account','{\"status\":\"ok\"}' FROM quota_reports;
INSERT INTO quota_windows (observation_id, window_id, data) SELECT id,'five-hour','{\"remaining\":42}' FROM quota_observations;
INSERT INTO quota_scopes (observation_id, scope, data) SELECT id,'fixture-model','{\"available\":true}' FROM quota_observations;" >/dev/null
export ASH_COMPAT_SCRIPT="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/ash_schema_compat.exs"
"$release_root/bin/agentboard" eval 'Code.eval_file(System.fetch_env!("ASH_COMPAT_SCRIPT"))'
[[ -s "$release_root/lib/agentboard-0.2.0/priv/static/assets/app.js" ]]
[[ -s "$release_root/lib/agentboard-0.2.0/priv/static/assets/app.css" ]]
echo "Packaged release migrations, schema guards, and assets passed"

# Upgrade the actual current schema-4 migration set, retaining existing history.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_upgrade
export DATABASE_NAME=agentboard_upgrade
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261006000700) end)'
upgrade_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
[[ "$(upgrade_psql 'SELECT version FROM board_schema WHERE id=1')" == 4 ]]
upgrade_psql "INSERT INTO agents(id,name,model,harness) VALUES ('retained','Retained worker','model','codex');
INSERT INTO tasks(id,title) VALUES ('retained-task','Retained task');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('retained-task','retained','model','codex','created',1);
INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('retained-task','retained','model','codex','archify','Retained diagram','<!doctype html><p>Retained</p>',repeat('c',64));
CREATE EXTENSION pg_textsearch VERSION '1.5.1';" >/dev/null
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(upgrade_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(upgrade_psql "SELECT count(*) FROM task_events WHERE task_id='retained-task'")" == 1 ]]
[[ "$(upgrade_psql "SELECT html FROM task_documents WHERE task_id='retained-task'")" == '<!doctype html><p>Retained</p>' ]]
[[ "$(upgrade_psql "SELECT count(*) FROM pg_indexes WHERE indexname='context_entries_bm25'")" == 1 ]]
echo 'Schema-4 upgrade and repeated migration preserve task history and document bytes.'

# Upgrade actual schema 7 with immutable PR inventory and existing history.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_inventory_upgrade
export DATABASE_NAME=agentboard_inventory_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261006001000) end)'
inventory_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_inventory_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 7 ]]
inventory_psql "INSERT INTO agents(id,name,model,harness) VALUES ('retained','Retained worker','model','codex');
INSERT INTO tasks(id,title,status,pr_url) VALUES ('retained-task','Retained task','done','https://github.com/fixture/repo/pull/101');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('retained-task','retained','model','codex','created',1);
INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('retained-task','retained','model','codex','archify','Retained diagram','<!doctype html><p>Retained</p>',repeat('c',64));
INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES (repeat('d',64),'fixture','repo','101','https://github.com/fixture/repo/pull/101',clock_timestamp());
INSERT INTO delivery_task_links(task_id,pull_request_id,submitted_by_id,model,harness,source_event_id,attribution,linked_at,recorded_at) SELECT 'retained-task',repeat('d',64),'retained','model','codex',id,'submission',created_at,clock_timestamp() FROM task_events;
INSERT INTO delivery_pull_requests_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at) VALUES (gen_random_uuid(),repeat('d',64),'create','record','{}','{}',clock_timestamp(),clock_timestamp());" >/dev/null
history_query="SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t)-'assignment_authorized' ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM task_events t),'documents',(SELECT jsonb_agg(t ORDER BY id) FROM task_documents t),'prs',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_pull_requests t),'links',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_task_links t),'versions',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_pull_requests_versions t),'audit',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t))"
before_inventory="$(inventory_psql "$history_query")"
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261007000100) end)'
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 8 ]]
[[ "$(inventory_psql "SELECT ci_state||','||generation||','||(head_sha IS NULL)||','||(observed_at IS NULL)||','||(attempt_id IS NULL)||','||(next_poll_at <= clock_timestamp()) FROM delivery_poll_states")" == 'unknown,0,true,true,true,true' ]]
[[ "$(inventory_psql 'SELECT count(*) FROM delivery_poll_states_versions')" == 0 ]]
inventory_psql "UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour',last_error='rate_limited'" >/dev/null
before_poll="$(inventory_psql "SELECT to_jsonb(s)-'base_sha'-'snapshot_id'-'lifecycle' FROM delivery_poll_states s")"
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261007000200) end)'
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 9 ]]
inventory_psql "UPDATE delivery_provider_budgets SET remaining=17,reset_at=clock_timestamp()+interval '1 hour' WHERE id='github'" >/dev/null
before_budget="$(inventory_psql "SELECT jsonb_agg(to_jsonb(s)-'blocked_until' ORDER BY id) FROM delivery_provider_budgets s")"
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261007000400) end)'
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 10 ]]
[[ "$(inventory_psql "SELECT to_jsonb(s)-'base_sha'-'snapshot_id'-'lifecycle' FROM delivery_poll_states s")" == "$before_poll" ]]
inventory_psql "INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES ('11111111-1111-4111-8111-111111111111',repeat('d',64),1,clock_timestamp(),repeat('a',40),repeat('b',40),'open','failing','{\"coverage\":\"complete_head\",\"policy\":\"unknown\",\"tested_ref\":\"head\",\"attempts\":[]}');
UPDATE delivery_poll_states SET generation=1,head_sha=repeat('a',40),base_sha=repeat('b',40),lifecycle='open',ci_state='failing',snapshot_id=s.id,observed_at=s.observed_at FROM delivery_ci_snapshots s WHERE delivery_poll_states.id=s.pull_request_id;" >/dev/null
before_snapshot="$(inventory_psql 'SELECT to_jsonb(s) FROM delivery_ci_snapshots s')"
before_projection="$(inventory_psql 'SELECT to_jsonb(s) FROM delivery_poll_states s')"
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(inventory_psql "$history_query")" == "$before_inventory" ]]
[[ "$(inventory_psql "SELECT to_jsonb(s)-'default_ref'-'expected_default_sha'-'base_ref'-'expected_base_sha'-'budget_deferred_at'-'unchanged_polls'-'check_fingerprint'-'github_cache' FROM delivery_poll_states s")" == "$before_projection" ]]
[[ "$(inventory_psql 'SELECT base_ref IS NULL AND expected_base_sha IS NULL FROM delivery_poll_states')" == t ]]
[[ "$(inventory_psql 'SELECT to_jsonb(s) FROM delivery_ci_snapshots s')" == "$before_snapshot" ]]
[[ "$(inventory_psql 'SELECT count(*) FROM delivery_poll_states_versions')" == 0 ]]
[[ "$(inventory_psql "SELECT jsonb_agg(to_jsonb(s)-'blocked_until' ORDER BY id) FROM delivery_provider_budgets s")" == "$before_budget" ]]
[[ "$(inventory_psql 'SELECT count(*) FROM delivery_ci_snapshots')" == 1 ]]
echo 'Schema-7 to 8 seeds unknown state; schema-8 to 9 to 10 and repeat retain inventory, history, poll backoff and provider budget bytes.'

# Schema 11 admits only explicitly verified complete-head passing snapshots.
for payload in '{}' '{"policy":"unknown","coverage":"complete_head","tested_ref":"head"}' '{"policy":"verified","coverage":"complete_head","tested_ref":"merge"}'; do
  if inventory_psql "INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES (gen_random_uuid(),repeat('d',64),2,clock_timestamp(),repeat('a',40),repeat('b',40),'open','passing','$payload')" >/dev/null 2>&1; then
    echo 'Unverified passing snapshot accepted' >&2; exit 1
  fi
done
inventory_psql "INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES (gen_random_uuid(),repeat('d',64),2,clock_timestamp(),repeat('a',40),repeat('b',40),'open','passing','{\"policy\":\"verified\",\"coverage\":\"complete_head\",\"tested_ref\":\"head\"}')" >/dev/null
[[ "$(inventory_psql 'SELECT count(*) FROM delivery_ci_snapshots')" == 2 ]]
[[ "$(inventory_psql 'SELECT count(*) FROM availability_policies')" == 0 ]]
[[ "$(inventory_psql "SELECT count(*) FROM tasks WHERE assignment_authorized")" == 0 ]]
echo 'Schema-15 defaults preserve existing tasks and seed no availability policies.'
echo 'Schema-10 to 11 preserves immutable snapshot/projection bytes and rejects missing or unverified passing evidence.'

# Schema 14 already carries merge-conflict evidence without availability.
# Pending migration 20261008000300 must raise it to 15, retaining watches,
# tasks and history while seeding neither policies nor assignment grants.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_availability_upgrade
export DATABASE_NAME=agentboard_availability_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
avail_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_availability_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008000200) end)'
[[ "$(avail_psql 'SELECT version FROM board_schema WHERE id=1')" == 14 ]]
avail_psql "INSERT INTO agents(id,name,model,harness) VALUES ('retained-avail','Retained worker','model','codex');
INSERT INTO tasks(id,title,status,assignee_id,assigner_id) VALUES ('retained-repair','Retained repair','assigned','retained-avail','retained-avail');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('retained-repair','retained-avail','model','codex','created',1);
INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES (repeat('e',64),'fixture','repo','401','https://github.com/fixture/repo/pull/401',clock_timestamp());
INSERT INTO delivery_task_links(task_id,pull_request_id,submitted_by_id,model,harness,source_event_id,attribution,linked_at,recorded_at) SELECT 'retained-repair',repeat('e',64),'retained-avail','model','codex',id,'submission',created_at,clock_timestamp() FROM task_events;
INSERT INTO delivery_poll_states(id,registered_at,next_poll_at,enabled,lifecycle,head_sha,base_sha,base_ref,expected_base_sha) VALUES (repeat('e',64),clock_timestamp(),clock_timestamp()+interval '1 hour',true,'open',repeat('a',40),repeat('b',40),'main',repeat('b',40));
INSERT INTO delivery_base_watches(id,owner,repo,ref,head_sha,next_poll_at) VALUES ('fixture/repo/main','fixture','repo','main',repeat('b',40),clock_timestamp()+interval '1 hour');
INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES ('22222222-2222-4222-8222-222222222222',repeat('e',64),1,clock_timestamp(),repeat('a',40),repeat('b',40),'open','failing','{\"coverage\":\"complete_head\",\"policy\":\"unknown\",\"tested_ref\":\"head\",\"attempts\":[]}');
INSERT INTO delivery_rebase_follow_ups(id,pull_request_id,head_sha,base_sha,snapshot_id,repair_task_id,responsible_id,created_at) VALUES ('33333333-3333-4333-8333-333333333333',repeat('e',64),repeat('a',40),repeat('b',40),'22222222-2222-4222-8222-222222222222','retained-repair','retained-avail',clock_timestamp());" >/dev/null
avail_psql "INSERT INTO delivery_obligations(id,pull_request_id,episode,repair_task_id,responsible_id,state,head_sha,snapshot_id,evidence_urls,last_progress_at,next_reminder_at,reminder_generation,window_at,reminders,resolved_at,created_at) VALUES ('44444444-4444-4444-8444-444444444444',repeat('e',64),1,'retained-repair','retained-avail','resolved',repeat('a',40),'22222222-2222-4222-8222-222222222222','{}',clock_timestamp(),clock_timestamp(),0,clock_timestamp(),0,clock_timestamp(),clock_timestamp()), ('55555555-5555-4555-8555-555555555555',repeat('e',64),2,'retained-repair','retained-avail','unresolved',repeat('a',40),'22222222-2222-4222-8222-222222222222','{}',clock_timestamp(),clock_timestamp(),0,clock_timestamp(),0,NULL,clock_timestamp());" >/dev/null
before_obligations="$(avail_psql 'SELECT jsonb_agg(to_jsonb(o) ORDER BY episode) FROM delivery_obligations o')"
before_avail="$(avail_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT count(*) FROM task_events),'watches',(SELECT jsonb_agg(to_jsonb(w) ORDER BY id) FROM delivery_base_watches w),'followups',(SELECT jsonb_agg(to_jsonb(f)-'current_order_id'-'current_base' ORDER BY id) FROM delivery_rebase_follow_ups f),'snapshots',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_ci_snapshots s),'poll',(SELECT jsonb_agg(to_jsonb(p)-'default_ref'-'expected_default_sha'-'budget_deferred_at'-'unchanged_polls'-'check_fingerprint'-'github_cache' ORDER BY id) FROM delivery_poll_states p))")"
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(avail_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(avail_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t)-'assignment_authorized' ORDER BY id) FROM tasks t),'events',(SELECT count(*) FROM task_events),'watches',(SELECT jsonb_agg(to_jsonb(w) ORDER BY id) FROM delivery_base_watches w),'followups',(SELECT jsonb_agg(to_jsonb(f)-'current_order_id'-'current_base' ORDER BY id) FROM delivery_rebase_follow_ups f),'snapshots',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_ci_snapshots s),'poll',(SELECT jsonb_agg(to_jsonb(p)-'default_ref'-'expected_default_sha'-'budget_deferred_at'-'unchanged_polls'-'check_fingerprint'-'github_cache' ORDER BY id) FROM delivery_poll_states p))")" == "$before_avail" ]]
[[ "$(avail_psql 'SELECT count(*) FROM availability_policies')" == 0 ]]
[[ "$(avail_psql 'SELECT count(*) FROM tasks WHERE assignment_authorized')" == 0 ]]
[[ "$(avail_psql "SELECT status||','||coalesce(assignee_id,'') FROM tasks WHERE id='retained-repair'")" == 'assigned,retained-avail' ]]
echo 'Schema-14 to 15 retains watches/tasks/history and seeds no availability policies or grants.'

[[ "$(avail_psql "SELECT jsonb_agg(to_jsonb(o)-'resolution_reason'-'resolution_snapshot_id' ORDER BY episode) FROM delivery_obligations o")" == "$before_obligations" ]]
[[ "$(avail_psql "SELECT coalesce(resolution_reason,'unset') FROM delivery_obligations ORDER BY episode")" == $'legacy\nunset' ]]
echo 'Schema21 preserves resolved/unresolved obligation prefixes and records legacy without certifying CI.'

# Reserve a higher version before the pending decision migration: it must not lower it.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_decision_upgrade
export DATABASE_NAME=agentboard_decision_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008000300) end)'
decision_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
decision_psql 'UPDATE board_schema SET version=22 WHERE id=1' >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008000800) end)'
[[ "$(decision_psql 'SELECT version FROM board_schema WHERE id=1')" == 22 ]]
[[ "$(decision_psql 'SELECT count(*) FROM decision_requests')" == 0 ]]
[[ "$(decision_psql 'SELECT count(*) FROM decision_wakes')" == 0 ]]
echo 'Pending schema-20 migration preserves higher schema21 and seeds no requests/wakes.'

decision_psql "INSERT INTO agents(id,name,model,harness) VALUES ('legacy-decision-owner','Legacy decision owner','fixture','codex');
INSERT INTO tasks(id,title) VALUES ('legacy-decision-card','Retained legacy decision');
INSERT INTO decision_requests(id,task_id,requester_id,kind,gate_ref,question,findings,options,status,created_at,updated_at)
VALUES ('11111111-1111-4111-8111-111111111129','legacy-decision-card','legacy-decision-owner','ask_user_gate','legacy-gate','  Retained question?  ','Retained findings','{}','open',clock_timestamp(),clock_timestamp());" >/dev/null
legacy_decision="$(decision_psql "SELECT to_jsonb(d) FROM decision_requests d")"
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(decision_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(decision_psql "SELECT to_jsonb(d)-'question_key'-'normalization_version'-'retry_key'-'expires_at'-'expires_in'-'bound_pr'-'source_type'-'source_id'-'promoted_by' FROM decision_requests d")" == "$legacy_decision" ]]

# Stop at schema38: schema39 intentionally adds an FK to the existing inbox.
# Older-timestamp 20261008001800 pending over a higher-marker database must not lower the marker.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_backfill_upgrade
export DATABASE_NAME=agentboard_backfill_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
backfill_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_backfill_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003800) end)'
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003800) end)'
installed_marker="$(backfill_psql 'SELECT version FROM board_schema WHERE id=1')"
[[ "$installed_marker" -ge 21 ]]
backfill_psql "INSERT INTO agents(id,name,model,harness) VALUES ('retained-backfill','Retained worker','model','codex');
INSERT INTO tasks(id,title) VALUES ('retained-backfill-task','Retained task');" >/dev/null
backfill_psql "DELETE FROM schema_migrations WHERE version=20261008001800;
DROP TABLE mattermost_inbox, mattermost_post_versions, mattermost_channel_recovery, mattermost_inbound_runs;" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003800) end)'
[[ "$(backfill_psql 'SELECT version FROM board_schema WHERE id=1')" == "$installed_marker" ]]
[[ "$(backfill_psql "SELECT to_regclass('mattermost_inbox')::text||','||to_regclass('mattermost_post_versions')::text||','||to_regclass('mattermost_channel_recovery')::text||','||to_regclass('mattermost_inbound_runs')::text")" == 'mattermost_inbox,mattermost_post_versions,mattermost_channel_recovery,mattermost_inbound_runs' ]]
[[ "$(backfill_psql "SELECT title FROM tasks WHERE id='retained-backfill-task'")" == 'Retained task' ]]
[[ "$(backfill_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008001800')" == 1 ]]
echo "Backfilled 01800 over marker $installed_marker keeps the higher marker, creates metadata tables and preserves rows."
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(backfill_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
# Actual schema22 -> 24 upgrade, including retained task/event/document prefixes.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_duplicate_upgrade
export DATABASE_NAME=agentboard_duplicate_upgrade
duplicate_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
duplicate_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008002200) end)'
[[ "$(duplicate_psql 'SELECT version FROM board_schema WHERE id=1')" == 22 ]]
duplicate_psql "INSERT INTO agents(id,name,model,harness) VALUES ('upgrade-owner','Upgrade owner','model','codex');
INSERT INTO tasks(id,title) VALUES ('upgrade-card','Upgrade card');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('upgrade-card','upgrade-owner','model','codex','created',1);
INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('upgrade-card','upgrade-owner','model','codex','archify','Upgrade diagram','<!doctype html><p>Retained</p>',repeat('d',64));" >/dev/null
before_duplicate="$(duplicate_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM task_events e),'documents',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM task_documents d))")"
# A pre-existing higher stamp must survive this additive migration as well.
duplicate_psql 'UPDATE board_schema SET version=99 WHERE id=1' >/dev/null
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(duplicate_psql 'SELECT version FROM board_schema WHERE id=1')" == 99 ]]
[[ "$(duplicate_psql 'SELECT count(*) FROM delivery_duplicate_findings')" == 0 ]]
[[ "$(duplicate_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM task_events e),'documents',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM task_documents d))")" == "$before_duplicate" ]]
echo 'Schema22 upgrade retains task/event/document prefixes, seeds no duplicate findings and raises the aggregate marker while preserving retained evidence.'

# Upgrade from actual schema24 with retained board/duplicate state: pending
# credential migration must raise 24 to 25 with empty auth resources.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_auth24_upgrade
export DATABASE_NAME=agentboard_auth24_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
auth24_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_auth24_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008002400) end)'
[[ "$(auth24_psql 'SELECT version FROM board_schema WHERE id=1')" == 24 ]]
[[ -z "$(auth24_psql "SELECT to_regclass('agent_api_credentials')")" ]]
[[ -z "$(auth24_psql "SELECT to_regclass('agent_auth_observations')")" ]]
auth24_psql "INSERT INTO agents(id,name,model,harness) VALUES ('auth24-retained','Retained','fixture','codex');
INSERT INTO tasks(id,title) VALUES ('auth24-card','Auth24 card');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('auth24-card','auth24-retained','fixture','codex','created',1);
INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('auth24-card','auth24-retained','fixture','codex','archify','Auth24 diagram','<!doctype html><p>Retained</p>',repeat('e',64));
INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES (repeat('f',64),'fixture','repo','601','https://github.com/fixture/repo/pull/601',clock_timestamp());
INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES ('66666666-6666-4666-8666-666666666666',repeat('f',64),1,clock_timestamp(),repeat('a',40),repeat('b',40),'open','failing','{\"coverage\":\"complete_head\",\"policy\":\"unknown\",\"tested_ref\":\"head\",\"attempts\":[]}');" >/dev/null
before_auth24="$(auth24_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM task_events e),'documents',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM task_documents d),'prs',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM delivery_pull_requests p),'snapshots',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_ci_snapshots s))")"
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(auth24_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(auth24_psql "SELECT to_regclass('delivery_workflow_runs')::text||','||to_regclass('delivery_workflow_health')::text")" == 'delivery_workflow_runs,delivery_workflow_health' ]]
[[ "$(auth24_psql "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM task_events e),'documents',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM task_documents d),'prs',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM delivery_pull_requests p),'snapshots',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_ci_snapshots s))")" == "$before_auth24" ]]
[[ "$(auth24_psql 'SELECT count(*) FROM agent_api_credentials')" == 0 ]]
[[ "$(auth24_psql 'SELECT count(*) FROM agent_auth_observations')" == 0 ]]
[[ "$(auth24_psql 'SELECT count(*) FROM delivery_duplicate_findings')" == 0 ]]
echo 'Schema24 upgrade retains board/duplicate prefixes and seeds empty auth resources.'

# Upgrade from current schema22 with retained board state and a newer aggregate
# stamp: pending credential migration must never lower another feature's marker.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_auth_upgrade
export DATABASE_NAME=agentboard_auth_upgrade
PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008002200) end)'
auth_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_auth_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
[[ "$(auth_psql 'SELECT version FROM board_schema WHERE id=1')" == 22 ]]
auth_psql "INSERT INTO agents(id,name,model,harness) VALUES ('auth-retained','Retained','fixture','codex'); UPDATE board_schema SET version=99 WHERE id=1" >/dev/null
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(auth_psql 'SELECT version FROM board_schema WHERE id=1')" == 99 ]]
[[ "$(auth_psql "SELECT count(*) FROM agents WHERE id='auth-retained'")" == 1 ]]
[[ "$(auth_psql 'SELECT count(*) FROM agent_api_credentials')" == 0 ]]
[[ "$(auth_psql 'SELECT count(*) FROM agent_auth_observations')" == 0 ]]

# Actual schema33 -> 34 is additive: existing canonical state stays unchanged,
# no seat becomes managed implicitly, and a higher aggregate marker survives.
for initial_marker in 33 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_scope${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_scope${initial_marker}_upgrade"
  scope_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  scope_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003300) end)'
  [[ "$(scope_psql 'SELECT version FROM board_schema WHERE id=1')" == 33 ]]
  [[ -z "$(scope_psql "SELECT to_regclass('seat_scopes')")" ]]
  scope_psql "INSERT INTO agents(id,name,model,harness) VALUES ('scope-retained','Retained scope worker','fixture','codex');
  INSERT INTO tasks(id,title,repo,labels) VALUES ('scope-retained-task','Retained task','fixture/repo',ARRAY['security']);
  INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('scope-retained-task','scope-retained','fixture','codex','created',1);
  INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('scope-retained-task','scope-retained','fixture','codex','archify','Retained scope diagram','<!doctype html><p>café &amp; retained</p>',repeat('f',64));
  INSERT INTO messages(sender_id,model,harness,task_id,body) VALUES ('scope-retained','fixture','codex','scope-retained-task','Retained exact body');
  UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  scope_history_query="SELECT jsonb_build_object('agents',(SELECT jsonb_agg(t ORDER BY id) FROM agents t),'tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM task_events t),'documents',(SELECT jsonb_agg(t ORDER BY id) FROM task_documents t),'messages',(SELECT jsonb_agg(t ORDER BY id) FROM messages t),'audit',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t))"
  before_scope="$(scope_psql "$scope_history_query")"
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003400) end)'
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003400) end)'
  expected_marker=34
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(scope_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(scope_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003400')" == 1 ]]
  [[ "$(scope_psql 'SELECT (SELECT count(*) FROM seat_scopes)+(SELECT count(*) FROM seat_scopes_versions)')" == 0 ]]
  [[ "$(scope_psql "$scope_history_query")" == "$before_scope" ]]

  scope_psql "INSERT INTO seat_scopes(agent_id,allowed_repos,required_labels,allowed_labels,revision,changed_by,updated_at) VALUES ('scope-retained',ARRAY['fixture/repo'],ARRAY['security'],'{}',1,'captain',clock_timestamp());
  INSERT INTO seat_scopes_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at) VALUES (gen_random_uuid(),'scope-retained','create','create_scope','{}','{\"agent\":\"captain\"}',clock_timestamp(),clock_timestamp())" >/dev/null
  for operation in "UPDATE seat_scopes SET allowed_repos='{}'" \
                   'UPDATE seat_scopes SET allowed_repos=ARRAY[NULL]::text[]' \
                   'UPDATE seat_scopes SET required_labels=ARRAY[NULL]::text[]' \
                   'UPDATE seat_scopes SET allowed_labels=ARRAY[NULL]::text[]' \
                   'UPDATE seat_scopes SET revision=0' \
                   "UPDATE seat_scopes SET allowed_labels=array_fill('label'::text,ARRAY[101])" \
                   "UPDATE seat_scopes_versions SET provenance='{}'::jsonb" \
                   'DELETE FROM seat_scopes_versions' 'TRUNCATE seat_scopes_versions' \
                   'DELETE FROM seat_scopes'; do
    if scope_psql "$operation" >/dev/null 2>&1; then
      echo "Invalid scope or audit mutation accepted: $operation" >&2; exit 1
    fi
  done
  scope_rows_query="SELECT jsonb_build_object('scopes',(SELECT jsonb_agg(t ORDER BY agent_id) FROM seat_scopes t),'versions',(SELECT jsonb_agg(t ORDER BY id) FROM seat_scopes_versions t))"
  before_scope_rows="$(scope_psql "$scope_rows_query")"
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003400) end)'
  [[ "$(scope_psql "$scope_rows_query")" == "$before_scope_rows" ]]
  [[ "$(scope_psql "$scope_history_query")" == "$before_scope" ]]
  echo "Schema33 to scope migration preserves marker $expected_marker, canonical history and populated immutable scope audit."
done

# Schema34 -> 35 adds dormant configuration without creating operational state.
# Repeat with a higher deployed marker and retain populated immutable receipts.
for initial_marker in 34 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_fleet${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_fleet${initial_marker}_upgrade"
  fleet_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  fleet_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003400) end)'
  [[ "$(fleet_psql 'SELECT version FROM board_schema WHERE id=1')" == 34 ]]
  [[ -z "$(fleet_psql "SELECT to_regclass('fleet_loadouts')")" ]]
  fleet_psql "INSERT INTO agents(id,name,model,harness) VALUES ('fleet-retained','Retained fleet worker','observed-model','codex');
  INSERT INTO tasks(id,title,repo,labels) VALUES ('fleet-retained-task','Retained task','fixture/fleet',ARRAY['fleet']);
  INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('fleet-retained-task','fleet-retained','observed-model','codex','created',1);
  INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('fleet-retained-task','fleet-retained','observed-model','codex','archify','Retained fleet diagram','<!doctype html><p>café &amp; fleet</p>',repeat('f',64));
  INSERT INTO messages(sender_id,model,harness,task_id,body) VALUES ('fleet-retained','observed-model','codex','fleet-retained-task','Retained exact body');
  INSERT INTO seat_scopes(agent_id,allowed_repos,required_labels,allowed_labels,revision,changed_by,updated_at) VALUES ('fleet-retained',ARRAY['fixture/fleet'],ARRAY['fleet'],'{}',1,'captain',clock_timestamp());
  INSERT INTO seat_scopes_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at) VALUES (gen_random_uuid(),'fleet-retained','create','create_scope','{}','{\"agent\":\"captain\"}',clock_timestamp(),clock_timestamp());
  UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  fleet_history_query="SELECT jsonb_build_object('agents',(SELECT jsonb_agg(t ORDER BY id) FROM agents t),'tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM task_events t),'documents',(SELECT jsonb_agg(t ORDER BY id) FROM task_documents t),'messages',(SELECT jsonb_agg(t ORDER BY id) FROM messages t),'audit',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t),'scopes',(SELECT jsonb_agg(t ORDER BY agent_id) FROM seat_scopes t),'scope_versions',(SELECT jsonb_agg(t ORDER BY id) FROM seat_scopes_versions t))"
  before_fleet="$(fleet_psql "$fleet_history_query")"
  # Include every cooperation, delivery and wake table, even as those evolve.
  operational_tables="$(fleet_psql "SELECT tablename FROM pg_tables WHERE schemaname='public' AND (tablename LIKE 'cooperation_%' OR tablename LIKE 'delivery_%' OR tablename LIKE 'wake_%') ORDER BY tablename")"
  fleet_operational_rows() {
    while IFS= read -r table; do
      printf '%s=' "$table"
      fleet_psql "SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) FROM \"$table\" t"
    done <<< "$operational_tables"
  }
  before_fleet_operational="$(fleet_operational_rows)"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  expected_marker=39
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(fleet_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(fleet_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003500')" == 1 ]]
  [[ "$(fleet_psql 'SELECT (SELECT count(*) FROM fleet_loadouts)+(SELECT count(*) FROM fleet_seat_bindings)+(SELECT count(*) FROM fleet_loadout_receipts)+(SELECT count(*) FROM fleet_loadouts_versions)')" == 0 ]]
  [[ "$(fleet_psql "$fleet_history_query")" == "$before_fleet" ]]
  [[ "$(fleet_operational_rows)" == "$before_fleet_operational" ]]

  fleet_psql "INSERT INTO fleet_loadouts(id,configuration,revision,changed_by,updated_at) VALUES ('retained-fleet','{\"seats\":[{\"seat_id\":\"retained-seat\",\"agent_id\":\"fleet-retained\",\"harness\":\"codex\",\"desired_host_id\":\"future-host\",\"desired_model\":\"unverified-model\",\"desired_effort\":\"unverified-effort\",\"scope_revision\":1}]}',1,'captain',clock_timestamp());
  INSERT INTO fleet_seat_bindings(id,fleet_id,seat_id,agent_id,harness,created_at) VALUES (repeat('a',64),'retained-fleet','retained-seat','fleet-retained','codex',clock_timestamp());
  INSERT INTO fleet_loadout_receipts(id,fleet_id,idempotency_key,request,response,created_at) SELECT repeat('b',64),id,'retained-key',jsonb_build_object('revision',0,'idempotency_key','retained-key','seats',configuration->'seats'),jsonb_build_object('loadout',jsonb_build_object('id',id,'revision',revision,'enabled',false,'seat_count',1,'seats',configuration->'seats','activation_state','not_activatable','catalog_status','unverified','host_status','unverified'),'replayed',false),clock_timestamp() FROM fleet_loadouts WHERE id='retained-fleet';
  INSERT INTO fleet_loadouts_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at) VALUES (gen_random_uuid(),'retained-fleet','create','record','{}','{\"agent\":\"captain\"}',clock_timestamp(),clock_timestamp())" >/dev/null
  for operation in 'UPDATE fleet_loadouts SET revision=0' \
                   "UPDATE fleet_loadouts SET configuration='{}'" \
                   "UPDATE fleet_loadouts SET configuration='{\"seats\":null}'" \
                   "UPDATE fleet_loadouts SET configuration='{\"seats\":[],\"enabled\":true}'" \
                   "UPDATE fleet_loadouts SET configuration=jsonb_build_object('seats',(SELECT jsonb_agg(n) FROM generate_series(1,33) n))" \
                   'UPDATE fleet_seat_bindings SET seat_id=seat_id' \
                   'DELETE FROM fleet_seat_bindings' 'TRUNCATE fleet_seat_bindings' \
                   'UPDATE fleet_loadout_receipts SET response=response' \
                   'DELETE FROM fleet_loadout_receipts' 'TRUNCATE fleet_loadout_receipts' \
                   'UPDATE fleet_loadouts_versions SET provenance=provenance' \
                   'DELETE FROM fleet_loadouts_versions' 'TRUNCATE fleet_loadouts_versions' \
                   'DELETE FROM fleet_loadouts'; do
    if fleet_psql "$operation" >/dev/null 2>&1; then
      echo "Invalid fleet shape or immutable evidence mutation accepted: $operation" >&2; exit 1
    fi
  done
  fleet_rows_query="SELECT jsonb_build_object('loadouts',(SELECT jsonb_agg(t ORDER BY id) FROM fleet_loadouts t),'bindings',(SELECT jsonb_agg(t ORDER BY id) FROM fleet_seat_bindings t),'receipts',(SELECT jsonb_agg(t ORDER BY id) FROM fleet_loadout_receipts t),'versions',(SELECT jsonb_agg(t ORDER BY id) FROM fleet_loadouts_versions t))"
  before_fleet_rows="$(fleet_psql "$fleet_rows_query")"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  [[ "$(fleet_psql "$fleet_rows_query")" == "$before_fleet_rows" ]]
  [[ "$(fleet_psql "$fleet_history_query")" == "$before_fleet" ]]
  [[ "$(fleet_operational_rows)" == "$before_fleet_operational" ]]
  echo "Schema34 to dormant FleetLoadout migration preserves marker $expected_marker, operational state and immutable configuration evidence."
done

# Schema35 -> 36 adds only empty shadow-triage storage. Preserve canonical
# messages/history, never invent a classification or reduce a higher marker.
for initial_marker in 35 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_triage${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_triage${initial_marker}_upgrade"
  triage_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  triage_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003500) end)'
  [[ "$(triage_psql 'SELECT version FROM board_schema WHERE id=1')" == 35 ]]
  triage_psql "INSERT INTO agents(id,name,model,harness) VALUES ('triage-retained','Retained','fixture','codex');
  INSERT INTO tasks(id,title,repo) VALUES ('triage-retained-task','Retained task','fixture/triage');
  INSERT INTO messages(sender_id,model,harness,recipient_id,task_id,body) VALUES ('triage-retained','fixture','codex','triage-retained','triage-retained-task','Retained exact inbox body');
  UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  triage_history_query="SELECT jsonb_build_object('messages',(SELECT jsonb_agg(t ORDER BY id) FROM messages t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t),'tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t),'agents',(SELECT jsonb_agg(t ORDER BY id) FROM agents t))"
  before_triage="$(triage_psql "$triage_history_query")"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  expected_marker=39
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(triage_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(triage_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003600')" == 1 ]]
  [[ "$(triage_psql 'SELECT (SELECT count(*) FROM coordinator_triage_configuration)+(SELECT count(*) FROM coordinator_triage_configuration_versions)+(SELECT count(*) FROM coordinator_inbox_triage)+(SELECT count(*) FROM coordinator_triage_dispositions)')" == 0 ]]
  [[ "$(triage_psql "$triage_history_query")" == "$before_triage" ]]
  echo "Schema35 to triage migration preserves marker $expected_marker and canonical inbox/history without backfill."
done
# Schema36 -> 37 stores display-only pins. No row is backfilled, historical
# evidence and operational state are byte-preserved, and marker99 stays ahead.
for initial_marker in 36 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_pins${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_pins${initial_marker}_upgrade"
  pins_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  pins_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003600) end)'
  [[ "$(pins_psql 'SELECT version FROM board_schema WHERE id=1')" == 36 ]]
  pins_psql "INSERT INTO agents(id,name,model,harness) VALUES ('pins-retained','Retained','fixture','codex');
  INSERT INTO tasks(id,title,repo) VALUES ('pins-retained-task','Retained task','fixture/pins');
  INSERT INTO messages(sender_id,model,harness,recipient_id,task_id,body) VALUES ('pins-retained','fixture','codex','pins-retained','pins-retained-task','Retained exact inbox body');
  INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES (repeat('e',64),'fixture','pins','101','https://github.com/fixture/pins/pull/101',clock_timestamp());
  INSERT INTO delivery_poll_states(id,enabled,lifecycle,ci_state,generation,next_poll_at,registered_at) VALUES (repeat('e',64),true,'open','unknown',0,clock_timestamp()+interval '1 hour',clock_timestamp());
  UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  pins_history_query="SELECT jsonb_build_object('messages',(SELECT jsonb_agg(t ORDER BY id) FROM messages t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t),'tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t),'agents',(SELECT jsonb_agg(t ORDER BY id) FROM agents t),'prs',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_pull_requests t),'polls',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_poll_states t),'workflows',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_workflow_runs t),'loadouts',(SELECT jsonb_agg(t ORDER BY id) FROM fleet_loadouts t),'triage',(SELECT jsonb_agg(t ORDER BY message_id) FROM coordinator_inbox_triage t))"
  before_pins="$(pins_psql "$pins_history_query")"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  expected_marker=39
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(pins_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(pins_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003700')" == 1 ]]
  [[ "$(pins_psql 'SELECT (SELECT count(*) FROM branch_flow_configuration)+(SELECT count(*) FROM branch_flow_configuration_versions)+(SELECT count(*) FROM branch_flow_receipts)')" == 0 ]]
  [[ "$(pins_psql "$pins_history_query")" == "$before_pins" ]]

  pins_psql "INSERT INTO branch_flow_configuration(id,pinned_repositories,revision,changed_by,updated_at) VALUES ('branch-flow',ARRAY['fixture/pins'],1,'captain',clock_timestamp());
  INSERT INTO branch_flow_receipts(id,configuration_id,idempotency_key,request,response,created_at) VALUES (repeat('f',64),'branch-flow','retained-pin-key','{\"revision\":0,\"idempotency_key\":\"retained-pin-key\",\"pinned_repositories\":[\"fixture/pins\"]}','{\"settings\":{\"revision\":1,\"pinned_repositories\":[\"fixture/pins\"]},\"replayed\":false}',clock_timestamp());
  INSERT INTO branch_flow_configuration_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at) VALUES (gen_random_uuid(),'branch-flow','create','record','{}','{\"agent\":\"captain\"}',clock_timestamp(),clock_timestamp())" >/dev/null
  for operation in 'UPDATE branch_flow_configuration SET revision=0' \
                   "UPDATE branch_flow_configuration SET id='other'" \
                   "UPDATE branch_flow_configuration SET changed_by='browser-actor'" \
                   "UPDATE branch_flow_configuration SET pinned_repositories=ARRAY['Fixture/pins']" \
                   "UPDATE branch_flow_configuration SET pinned_repositories=ARRAY['fixture/pins','fixture/pins']" \
                   "UPDATE branch_flow_configuration SET pinned_repositories=ARRAY['fixture/.']" \
                   "UPDATE branch_flow_configuration SET pinned_repositories=ARRAY[NULL]::text[]" \
                   "UPDATE branch_flow_configuration SET pinned_repositories=ARRAY['fixture/a','fixture/b','fixture/c','fixture/d','fixture/e','fixture/f']" \
                   'UPDATE branch_flow_receipts SET response=response' \
                   'DELETE FROM branch_flow_receipts' 'TRUNCATE branch_flow_receipts' \
                   'UPDATE branch_flow_configuration_versions SET provenance=provenance' \
                   'DELETE FROM branch_flow_configuration_versions' 'TRUNCATE branch_flow_configuration_versions' \
                   'DELETE FROM branch_flow_configuration'; do
    if pins_psql "$operation" >/dev/null 2>&1; then
      echo "Invalid pin settings or immutable evidence mutation accepted: $operation" >&2; exit 1
    fi
  done
  pins_rows_query="SELECT jsonb_build_object('configuration',(SELECT jsonb_agg(t ORDER BY id) FROM branch_flow_configuration t),'versions',(SELECT jsonb_agg(t ORDER BY id) FROM branch_flow_configuration_versions t),'receipts',(SELECT jsonb_agg(t ORDER BY id) FROM branch_flow_receipts t))"
  before_pins_rows="$(pins_psql "$pins_rows_query")"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  [[ "$(pins_psql "$pins_rows_query")" == "$before_pins_rows" ]]
  [[ "$(pins_psql "$pins_history_query")" == "$before_pins" ]]
  echo "Schema36 to pin settings migration preserves marker $expected_marker and operational history, with no backfill and immutable receipts."
done
# Upgrade the actual schema31 boundary, preserving legacy conflict records and
# every pre-existing attributed board/document prefix. No synthetic deadline.
"$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard agentboard_conflict_upgrade
export DATABASE_NAME=agentboard_conflict_upgrade
conflict_psql() {
  PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=agentboard_conflict_upgrade user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
}
conflict_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
"$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003100) end)'
[[ "$(conflict_psql 'SELECT version FROM board_schema WHERE id=1')" == 31 ]]
conflict_psql "INSERT INTO agents(id,name,model,harness) VALUES ('conflict-retained','Invented retained','fixture','codex');
INSERT INTO tasks(id,title) VALUES ('conflict-source','Retained source'),('conflict-repair','Retained repair');
INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision) VALUES ('conflict-source','conflict-retained','fixture','codex','created',1);
INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) VALUES ('conflict-source','conflict-retained','fixture','codex','archify','Retained diagram','<!doctype html><p>Retained conflict prefix</p>',repeat('a',64));
INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES (repeat('a',64),'fixture','project','701','https://github.com/fixture/project/pull/701',clock_timestamp());
INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES ('77777777-7777-4777-8777-777777777777',repeat('a',64),1,clock_timestamp(),repeat('a',40),repeat('b',40),'open','failing','{\"coverage\":\"complete_head\",\"policy\":\"unknown\",\"tested_ref\":\"head\",\"attempts\":[]}');
INSERT INTO delivery_rebase_follow_ups(id,pull_request_id,head_sha,base_sha,snapshot_id,repair_task_id,responsible_id,created_at) VALUES ('88888888-8888-4888-8888-888888888888',repeat('a',64),repeat('a',40),repeat('b',40),'77777777-7777-4777-8777-777777777777','conflict-repair','conflict-retained',clock_timestamp());" >/dev/null
conflict_history="SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM task_events e),'documents',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM task_documents d),'followups',(SELECT jsonb_agg(to_jsonb(f)-'current_order_id'-'current_base' ORDER BY id) FROM delivery_rebase_follow_ups f),'snapshots',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_ci_snapshots s))"
before_conflict="$(conflict_psql "$conflict_history")"
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
"$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
[[ "$(conflict_psql 'SELECT version FROM board_schema WHERE id=1')" == 39 ]]
[[ "$(conflict_psql "$conflict_history")" == "$before_conflict" ]]
[[ "$(conflict_psql 'SELECT count(*) FROM delivery_publication_bindings')" == 0 ]]
[[ "$(conflict_psql 'SELECT count(*) FROM delivery_publication_bindings_versions')" == 0 ]]
[[ "$(conflict_psql 'SELECT count(*) FROM delivery_poll_states WHERE default_ref IS NOT NULL OR expected_default_sha IS NOT NULL')" == 0 ]]
[[ "$(conflict_psql 'SELECT bool_and(current_order_id IS NULL AND NOT current_base) FROM delivery_rebase_follow_ups')" == t ]]
for source in delivery_conflict_orders delivery_publication_grants; do
  [[ "$(conflict_psql "SELECT count(*) FROM $source")" == 0 ]]
  [[ "$(conflict_psql "SELECT count(*) FROM ${source}_versions")" == 0 ]]
done
for history in delivery_publication_bindings_versions delivery_conflict_orders_versions delivery_publication_grants_versions; do
  if conflict_psql "TRUNCATE $history" >/dev/null 2>&1; then
    echo "Conflict/publication history is not append-only: $history" >&2; exit 1
  fi
done
echo 'Schema31 upgrade is idempotent and preserves legacy conflict/board/document evidence without invented bindings.'


# Schema37 -> 38 retains verified provider metadata only after a future normal
# collection. Migration does not infer defaults from retained branch/run rows.
for initial_marker in 37 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_metadata${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_metadata${initial_marker}_upgrade"
  metadata_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  metadata_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003700) end)'
  [[ "$(metadata_psql 'SELECT version FROM board_schema WHERE id=1')" == 37 ]]
  [[ -z "$(metadata_psql "SELECT to_regclass('delivery_repository_metadata')")" ]]
  metadata_psql "INSERT INTO delivery_workflow_runs(id,repository,run_id,requested_at,next_poll_at,generation,branch,workflow_id,failed_at) VALUES ('fixture/retained/17','fixture/retained','17',clock_timestamp(),clock_timestamp(),1,'old-default','9',clock_timestamp());
  INSERT INTO branch_flow_configuration(id,pinned_repositories,revision,changed_by,updated_at) VALUES ('branch-flow',ARRAY['fixture/retained'],1,'captain',clock_timestamp());
  UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  metadata_history_query="SELECT jsonb_build_object('runs',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_workflow_runs t),'health',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_workflow_health t),'pins',(SELECT jsonb_agg(t ORDER BY id) FROM branch_flow_configuration t),'audits',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t),'jobs',(SELECT jsonb_agg(t ORDER BY id) FROM oban_jobs t))"
  before_metadata="$(metadata_psql "$metadata_history_query")"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  expected_marker=39
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(metadata_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(metadata_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003800')" == 1 ]]
  [[ "$(metadata_psql 'SELECT count(*) FROM delivery_repository_metadata')" == 0 ]]
  [[ "$(metadata_psql "$metadata_history_query")" == "$before_metadata" ]]
  metadata_psql "INSERT INTO delivery_repository_metadata(id,generation,source_generation,default_ref,observed_at,source_run_id,source_run_generation) VALUES ('fixture/retained',1,1,'release/東京',clock_timestamp(),'fixture/retained/17',1)" >/dev/null
  for operation in 'UPDATE delivery_repository_metadata SET generation=-1' \
                   'UPDATE delivery_repository_metadata SET source_generation=2' \
                   'UPDATE delivery_repository_metadata SET source_generation=NULL' \
                   'UPDATE delivery_repository_metadata SET source_run_generation=0' \
                   'UPDATE delivery_repository_metadata SET observed_at=NULL' \
                   "UPDATE delivery_repository_metadata SET default_ref=repeat('x',256)" \
                   "UPDATE delivery_repository_metadata SET id='Fixture/retained'" \
                   "UPDATE delivery_repository_metadata SET source_run_id='other/repo/17'"; do
    if metadata_psql "$operation" >/dev/null 2>&1; then
      echo "Invalid repository metadata shape accepted: $operation" >&2; exit 1
    fi
  done
  before_metadata_rows="$(metadata_psql 'SELECT jsonb_agg(t ORDER BY id) FROM delivery_repository_metadata t')"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  [[ "$(metadata_psql 'SELECT jsonb_agg(t ORDER BY id) FROM delivery_repository_metadata t')" == "$before_metadata_rows" ]]
  [[ "$(metadata_psql "$metadata_history_query")" == "$before_metadata" ]]
  echo "Schema37 to repository metadata preserves marker $expected_marker, retained-red/pins/audit and populated source metadata."
done

# Coordinator participation is additive: old observer credentials do not acquire
# a grant or scope, and an already newer aggregate marker must not decrease.
for initial_marker in 38 99; do
  "$fixture_bin/createdb" -h "$fixture_root" -p "$DATABASE_PORT" -U postgres -O agentboard "agentboard_participant${initial_marker}_upgrade"
  export DATABASE_NAME="agentboard_participant${initial_marker}_upgrade"
  participant_psql() {
    PGPASSWORD="$DATABASE_PASSWORD" "$fixture_bin/psql" "host=127.0.0.1 port=$DATABASE_PORT dbname=$DATABASE_NAME user=agentboard sslmode=verify-full sslrootcert=$DATABASE_CA_FILE" -v ON_ERROR_STOP=1 -Atc "$1"
  }
  participant_psql "CREATE EXTENSION pg_textsearch VERSION '1.5.1'" >/dev/null
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, Application.app_dir(:agentboard, "priv/repo/migrations"), :up, to: 20261008003800) end)'
  participant_psql "INSERT INTO agents(id,name,model,harness) VALUES ('retained-observer','Observer','fixture','codex');
    INSERT INTO agent_api_credentials(id,agent_id,token_hash,fingerprint,scope,issuer,created_at)
      VALUES ('00000000-0000-4000-8000-000000000039','retained-observer',repeat('a',64),repeat('a',12),'coordinator','captain',clock_timestamp());
    UPDATE board_schema SET version=$initial_marker WHERE id=1" >/dev/null
  before_participant="$(participant_psql 'SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM agent_api_credentials c')"
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  "$release_root/bin/agentboard" eval 'Agentboard.Release.migrate()'
  expected_marker=39
  if [[ "$initial_marker" == 99 ]]; then expected_marker=99; fi
  [[ "$(participant_psql 'SELECT version FROM board_schema WHERE id=1')" == "$expected_marker" ]]
  [[ "$(participant_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008003900')" == 1 ]]
  [[ "$(participant_psql "SELECT jsonb_agg(to_jsonb(c)-'channel_ids' ORDER BY id) FROM agent_api_credentials c")" == "$before_participant" ]]
  [[ "$(participant_psql "SELECT scope || ':' || cardinality(channel_ids) FROM agent_api_credentials WHERE agent_id='retained-observer'")" == 'coordinator:0' ]]
  [[ "$(participant_psql 'SELECT count(*) FROM decision_conversation_intents')" == 0 ]]
  for grant in "ARRAY[]::text[]" "ARRAY['same','same']" "ARRAY['bad/segment']" "ARRAY[NULL]::text[]" "ARRAY[repeat('x',129)]"; do
    if participant_psql "INSERT INTO agent_api_credentials(id,agent_id,token_hash,fingerprint,scope,channel_ids,issuer,created_at)
      VALUES(gen_random_uuid(),'retained-observer',repeat('b',64),repeat('b',12),'coordinator_participant',$grant,'captain',clock_timestamp())" >/dev/null 2>&1; then
      echo 'Invalid participant grant accepted by database constraint' >&2; exit 1
    fi
  done
  participant_psql "INSERT INTO agent_api_credentials(id,agent_id,token_hash,fingerprint,scope,channel_ids,issuer,created_at)
    VALUES(gen_random_uuid(),'retained-observer',repeat('b',64),repeat('b',12),'coordinator_participant',ARRAY['approved-channel'],'captain',clock_timestamp())" >/dev/null
  if participant_psql "UPDATE agent_api_credentials SET channel_ids=ARRAY['expanded-channel'] WHERE scope='coordinator_participant'" >/dev/null 2>&1; then
    echo 'Immutable channel grant changed' >&2; exit 1
  fi
  echo "Schema38 coordinator upgrade preserves old grants/evidence and aggregate marker $expected_marker."
done
