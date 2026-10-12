#!/usr/bin/env bash
# Real 40->41 upgrade, with TLS and the normal application role.
set -euo pipefail
if [[ -n "${DECISION_POLICY_UPGRADE_RELEASE_ROOT:-}" ]]; then
  release_root="$DECISION_POLICY_UPGRADE_RELEASE_ROOT"
  fixture_script="${DECISION_POLICY_UPGRADE_FIXTURE:?provide disposable PostgreSQL fixture}"
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
check() { if [[ "$1" != "$2" ]]; then echo "Policy upgrade: $3 (expected $2, got $1)" >&2; exit 1; fi; }
for marker in 40 9000; do (
  root="$TEST_TMPDIR/policy-upgrade-$marker"
  mkdir -p "$root"
  export RELEASE_TMP="$root/runtime"
  source "$fixture_script"
  "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008004000) end)' >"$root/pre40.log" 2>&1 || { cat "$root/pre40.log"; exit 1; }
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" 40 'actual old schema'
  check "$(fixture_psql "SELECT to_regclass('decision_policy_ledger') IS NULL")" t 'new schema absent'
  check "$(fixture_psql 'SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user')" t 'normal role'
  check "$(fixture_psql 'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()')" t 'TLS connection'
  fixture_psql "
    INSERT INTO agents(id,name,model,harness) VALUES ('policy-upgrade-owner','Preserved owner','fixture','codex');
    INSERT INTO tasks(id,title,repo) VALUES ('policy-upgrade-task','Retained decision task','fixture/upgrade');
    INSERT INTO decision_requests(id,task_id,requester_id,kind,gate_ref,question,findings,options,status,created_at,updated_at)
    VALUES ('10000000-0000-4000-8000-000000000041','policy-upgrade-task','policy-upgrade-owner','approval','retained/gate','Retain source?','Exact retained findings',ARRAY['Keep'],'open','2026-10-01 00:00:00+00','2026-10-01 00:00:00+00');
    UPDATE board_schema SET version=$marker WHERE id=1;
  " >/dev/null
  # Legacy off-mode registration may have occupied this reserved name. Never
  # silently adopt or rewrite that identity, and roll the whole migration back.
  if [[ "$marker" == 40 ]]; then
    for mismatch in harness model kind retired matching; do
      fixture_psql "INSERT INTO agents(id,name,model,harness,kind) VALUES ('system-decision-policy','Retain conflicting identity','system','ash','system')" >/dev/null
      case "$mismatch" in
        harness) change="harness='codex'" ;;
        model) change="model='unrelated'" ;;
        kind) change="kind='seat'" ;;
        retired) change="retired_at=clock_timestamp()" ;;
        matching) change="" ;;
      esac
      if [[ -n "$change" ]]; then fixture_psql "UPDATE agents SET $change WHERE id='system-decision-policy'" >/dev/null; fi
      collision="$(fixture_psql "SELECT to_jsonb(a) FROM agents a WHERE id='system-decision-policy'")"
      if "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008004100) end)' >"$root/collision-$mismatch.log" 2>&1; then
        echo "Policy migration adopted pre-existing $mismatch identity" >&2; exit 1
      fi
      grep -q 'Reserved system-decision-policy identity conflicts' "$root/collision-$mismatch.log"
      check "$(fixture_psql "SELECT to_jsonb(a) FROM agents a WHERE id='system-decision-policy'")" "$collision" 'conflicting identity is unchanged'
      check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$marker" 'failed upgrade marker unchanged'
      check "$(fixture_psql "SELECT to_regclass('decision_policy_ledger') IS NULL")" t 'failed upgrade tables rolled back'
      check "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004100')" 0 'failed upgrade not recorded'
      fixture_psql "DELETE FROM agents WHERE id='system-decision-policy'" >/dev/null
    done
  fi
  check "$(fixture_psql "SELECT count(*) FROM agents WHERE id='system-decision-policy'")" 0 'reserved identity absent before first migration'
  # Compare every old table. Only the explicitly added nullable intent field
  # and the migration's one reserved system identity differ after upgrade.
  history="$(fixture_psql "SELECT 'SELECT jsonb_object_agg(name,rows ORDER BY name) FROM (' || string_agg(format('SELECT %L AS name, COALESCE(jsonb_agg(to_jsonb(t)-''requested_ci_runs'' ORDER BY to_jsonb(t)::text),''[]''::jsonb) AS rows FROM %I.%I t%s',tablename,schemaname,tablename,CASE WHEN tablename='agents' THEN ' WHERE id<>''system-decision-policy''' ELSE '' END),' UNION ALL ' ORDER BY tablename) || ') preserved' FROM pg_tables WHERE schemaname='public' AND tablename NOT IN ('board_schema','schema_migrations')")"
  fixture_psql "$history" >"$root/before.json"
  for run in first repeated; do
    "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261008004100) end)' >"$root/$run.log" 2>&1 || { cat "$root/$run.log"; exit 1; }
    if [[ "$run" == first ]]; then
      seeded="$(fixture_psql "SELECT to_jsonb(a) FROM agents a WHERE id='system-decision-policy'")"
    else
      check "$(fixture_psql "SELECT to_jsonb(a) FROM agents a WHERE id='system-decision-policy'")" "$seeded" 'migration-owned identity unchanged on repeat'
    fi
  done
  expected=41; if [[ "$marker" == 9000 ]]; then expected=9000; fi
  check "$(fixture_psql 'SELECT version FROM board_schema WHERE id=1')" "$expected" 'monotonic aggregate marker'
  check "$(fixture_psql 'SELECT count(*) FROM schema_migrations WHERE version=20261008004100')" 1 'one migration'
  fixture_psql "$history" >"$root/after.json"
  cmp "$root/before.json" "$root/after.json"
  check "$(fixture_psql "SELECT requested_ci_runs IS NULL FROM decision_requests WHERE id='10000000-0000-4000-8000-000000000041'")" t 'legacy intent remains unspecified'
  check "$(fixture_psql "SELECT generation=0 AND active_id IS NULL FROM decision_policy_state WHERE id='board'")" t 'no activation'
  check "$(fixture_psql 'SELECT (SELECT count(*) FROM decision_policy_versions)+(SELECT count(*) FROM decision_policy_approvals)+(SELECT count(*) FROM decision_policy_ledger)')" 0 'no invented policy approval or answer'
  check "$(fixture_psql "SELECT count(*) FROM agents WHERE id='system-decision-policy' AND model='system' AND harness='ash' AND kind='system' AND retired_at IS NULL")" 1 'reserved server attribution'
  if "$release_root/bin/agentboard" eval 'Application.load(:agentboard); {:ok, _, _} = Ecto.Migrator.with_repo(Agentboard.Repo, fn repo -> Ecto.Migrator.run(repo, :down, step: 1) end)' >"$root/down.log" 2>&1; then
    echo 'Policy migration unexpectedly allowed destructive down' >&2; exit 1
  fi
  grep -q 'Retain approved policies and immutable answer evidence' "$root/down.log"
  fixture_psql "$history" >"$root/after-down.json"
  cmp "$root/before.json" "$root/after-down.json"
); done
printf 'decision policy 40->41 upgrade and higher marker preservation passed\n'
