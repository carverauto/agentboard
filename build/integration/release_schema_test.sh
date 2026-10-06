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
[[ "$(fixture_psql 'SELECT version FROM board_schema WHERE id = 1')" == 4 ]]

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
[[ -s "$release_root/lib/agentboard-0.1.0/priv/static/assets/app.js" ]]
[[ -s "$release_root/lib/agentboard-0.1.0/priv/static/assets/app.css" ]]
echo "Packaged release migrations, schema guards, and assets passed"
