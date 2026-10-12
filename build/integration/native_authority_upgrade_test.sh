#!/usr/bin/env bash
# Real schema41->42 upgrade on a disposable PostgreSQL fixture, no native process.
set -euo pipefail
if [[ -n "${NATIVE_AUTHORITY_UPGRADE_RELEASE_ROOT:-}" ]]; then
  release_root="$NATIVE_AUTHORITY_UPGRADE_RELEASE_ROOT"
  fixture_script="${NATIVE_AUTHORITY_UPGRADE_FIXTURE:?provide disposable PostgreSQL fixture}"
  export TEST_TMPDIR="${TEST_TMPDIR:-$(mktemp -d)}"
else
  export POSTGRES_RUNTIME_ARCHIVE="$TEST_SRCDIR/$1"
  fixture_script="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/postgres_fixture.sh"
  release_root="$TEST_TMPDIR/release"
  mkdir -p "$release_root"
  tar -xzf "$TEST_SRCDIR/$2" -C "$release_root"
fi
export SECRET_KEY_BASE="$(openssl rand -base64 64)" PHX_SERVER=false FIXTURE_NORMAL_ROLE=true
export ELIXIR_ERL_OPTIONS='+fnu +S 4:4'
unset AGENTBOARD_NATIVE_AUTHORITY_ENABLED
check() { if [[ "$1" != "$2" ]]; then echo "Native authority upgrade: $3 (expected $2, got $1)" >&2; exit 1; fi; }
for marker in 41 99; do (
  root="$TEST_TMPDIR/native-upgrade-$marker"
  mkdir -p "$root"
  export RELEASE_TMP="$root/runtime"
  source "$fixture_script"
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008004100) end)' >"$root/pre41.log" 2>&1 || { cat "$root/pre41.log"; exit 1; }
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" 41 'actual old schema'
  check "$(fixture_psql "SELECT to_regclass('cooperation_native_approvals') IS NULL")" t 'approval table absent'
  check "$(fixture_psql 'SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user')" t 'normal role'
  check "$(fixture_psql 'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()')" t 'TLS connection'
  fixture_psql "
    INSERT INTO agents(id,name,model,harness) VALUES ('native-upgrade-owner','Retained owner','fixture','codex');
    INSERT INTO tasks(id,title,repo) VALUES ('native-upgrade-task','Retained task','fixture/upgrade');
    INSERT INTO cooperation_subscriptions(id,host_id,repos,model,harness,paused,revoked,enrolled_at)
      VALUES ('native-upgrade-owner','fixture-host',ARRAY['fixture/upgrade'],'fixture','codex',false,false,'2026-10-01 00:00:00+00');
    INSERT INTO cooperation_bindings(id,epoch,generation,session_id,pane_id,adapter,adapter_version,capabilities,connector_state,adapter_state,updated_at)
      VALUES ('native-upgrade-owner',3,4,'fixture-session','fixture-pane','codex-app-server-v1','1','{}','healthy','ready','2026-10-01 00:00:00+00');
    INSERT INTO cooperation_credentials(id,worker_id,token_hash,scope,epoch,idempotency_key,created_at)
      VALUES ('10000000-0000-4000-8000-000000000042','native-upgrade-owner',repeat('a',64),'host',NULL,'old-host-key','2026-10-01 00:00:00+00');
    INSERT INTO cooperation_bindings_versions(id,version_source_id,version_action_type,version_action_name,changes,provenance,version_inserted_at,version_updated_at)
      VALUES ('20000000-0000-4000-8000-000000000042','native-upgrade-owner','create','record','{}','{}','2026-10-01 00:00:00+00','2026-10-01 00:00:00+00');
    UPDATE board_schema SET version=$marker WHERE id=1;
  " >/dev/null
  # Preserve every old table and every old field, including credentials and
  # enrollment time. Only five explicitly added nullable/default fields differ.
  history="$(fixture_psql "SELECT 'SELECT jsonb_object_agg(name,rows ORDER BY name) FROM (' || string_agg(format('SELECT %L AS name, COALESCE(jsonb_agg(to_jsonb(t)-''native_authority_revision''-''native_approval_id''-''native_retire_key''-''native_retire_expected_revision''-''native_retire_revision'' ORDER BY to_jsonb(t)::text),''[]''::jsonb) AS rows FROM %I.%I t',tablename,schemaname,tablename),' UNION ALL ' ORDER BY tablename) || ') preserved' FROM pg_tables WHERE schemaname='public' AND tablename NOT IN ('board_schema','schema_migrations')")"
  fixture_psql "$history" >"$root/before.json"
  for run in first repeated; do
    "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008004200) end)' >"$root/$run.log" 2>&1 || { cat "$root/$run.log"; exit 1; }
    fixture_psql "$history" >"$root/after-$run.json"
    cmp "$root/before.json" "$root/after-$run.json"
  done
  expected=42; if [[ "$marker" == 99 ]]; then expected=99; fi
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected" 'monotonic aggregate marker'
  check "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004200')" 1 'one migration'
  check "$(fixture_psql "SELECT native_authority_revision=0 AND native_approval_id IS NULL AND native_retire_key IS NULL AND native_retire_expected_revision IS NULL AND native_retire_revision IS NULL FROM cooperation_bindings WHERE id='native-upgrade-owner'")" t 'migration grants nothing'
  check "$(fixture_psql 'SELECT count(*) FROM cooperation_native_approvals')" 0 'no invented native approval'
  check "$(fixture_psql 'SELECT count(*) FROM cooperation_credentials')" 1 'no minted capability'
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); Application.ensure_all_started(:ash_postgres); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Adapters.SQL.query!(repo, "SELECT 1", [], queue: true); false = Agentboard.NativeAuthority.enabled?(); %{native_authority_revision: 0, native_approval_id: nil, epoch: 3, generation: 4, session_id: "fixture-session"} = Ash.get!(Agentboard.Cooperation.Binding, "native-upgrade-owner"); [] = Ash.read!(Agentboard.Cooperation.NativeApproval); IO.puts("Ash upgrade/default-off contract passed") end)' >"$root/ash.log" 2>&1 || { cat "$root/ash.log"; exit 1; }
  if "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :down, step: 1) end)' >"$root/down.log" 2>&1; then
    echo 'Native authority migration unexpectedly allowed destructive down' >&2; exit 1
  fi
  grep -q 'Retain native approval and authority fences' "$root/down.log"
  fixture_psql "$history" >"$root/after-down.json"
  cmp "$root/before.json" "$root/after-down.json"
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected" 'failed down marker preserved'
  check "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004200')" 1 'failed down migration retained'
); done
printf 'Native authority schema41->42 upgrade, Ash reads, repeated migration, default-off and higher marker preservation passed\n'
