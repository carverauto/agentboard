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
[[ "$(fixture_psql 'SELECT version FROM board_schema WHERE id = 1')" == 12 ]]

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
[[ -s "$release_root/lib/agentboard-0.1.0/priv/static/assets/app.js" ]]
[[ -s "$release_root/lib/agentboard-0.1.0/priv/static/assets/app.css" ]]
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
[[ "$(upgrade_psql 'SELECT version FROM board_schema WHERE id=1')" == 12 ]]
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
history_query="SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t),'events',(SELECT jsonb_agg(t ORDER BY id) FROM task_events t),'documents',(SELECT jsonb_agg(t ORDER BY id) FROM task_documents t),'prs',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_pull_requests t),'links',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_task_links t),'versions',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_pull_requests_versions t),'audit',(SELECT jsonb_agg(t ORDER BY id) FROM board_action_events t))"
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
[[ "$(inventory_psql 'SELECT version FROM board_schema WHERE id=1')" == 12 ]]
[[ "$(inventory_psql "$history_query")" == "$before_inventory" ]]
[[ "$(inventory_psql 'SELECT to_jsonb(s) FROM delivery_poll_states s')" == "$before_projection" ]]
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
echo 'Schema-10 to 11 preserves immutable snapshot/projection bytes and rejects missing or unverified passing evidence.'
