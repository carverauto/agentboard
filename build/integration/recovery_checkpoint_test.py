"""Disabled recovery persistence/audit contract; no host-restart or activation proof.

Invented actors. The reducer suite owns lifecycle contracts; release_schema_test
owns migration upgrades. This fixture owns serialized dry-run capture, protected
Ash writes, audit immutability and preservation of actual held board rows.
"""
import concurrent.futures
import json
import os
import subprocess
import urllib.request


def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', statement], text=True).strip()


def rpc(expression):
    script = 'value = (' + expression + '); IO.puts("RECOVERY_RESULT:" <> Jason.encode!(value))'
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', script],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split(':', 1)[1] for line in result.stdout.splitlines()
                           if line.startswith('RECOVERY_RESULT:')))


def api(path, data):
    request = urllib.request.Request(os.environ['AGENTBOARD_URL'] + '/api/v1/' + path,
        data=json.dumps(data).encode(), headers={'Content-Type': 'application/json',
        'x-agentboard-agent': 'recovery-seat', 'x-agentboard-model': 'fixture',
        'x-agentboard-harness': 'codex'})
    with urllib.request.urlopen(request, timeout=15) as result:
        return json.load(result)


api('agents/register', {'name': 'Recovery fixture'})
api('tasks', {'id': 'recovery-held', 'title': 'Held recovery fixture', 'repo': 'example/repo'})
api('tasks/recovery-held/claim', {})
decision = api('decisions', {'task': 'recovery-held', 'kind': 'ask_user_gate',
    'gate': 'fixture/run/original-gate', 'question': 'Retained question?',
    'findings': 'Retained exact findings', 'options': ['Fix', 'Approve']})['decision']
retained_query = """SELECT jsonb_build_object('task',(SELECT to_jsonb(t) FROM tasks t WHERE id='recovery-held'),
'decision',(SELECT to_jsonb(d) FROM decision_requests d WHERE task_id='recovery-held'),
'wakes',(SELECT coalesce(jsonb_agg(to_jsonb(w)),'[]') FROM decision_wakes w WHERE task_id='recovery-held'))"""
retained = sql(retained_query)
setup = '''
candidate = %{agent_id: "recovery-seat", host_id: "fixture-host", repo: "example/repo",
  enrollment_revision: 7, binding_epoch: 4, session_id: "old-native", lease_id: "owned-lease",
  last_heartbeat_at: ~U[2025-01-01 00:00:00Z], task_ids: ["recovery-held"],
  decision_ids: ["''' + decision['id'] + '''"], enrolled: true, availability: "active",
  paused: false, revoked: false, restart_proven: true}
policy = %{"mode" => "dry_run", "approved" => true, "id" => "fixture-policy", "version" => 1, "cadence_seconds" => 120}
actor = %{"agent" => "recovery-system", "model" => "system", "harness" => "ash", :recovery_internal => true}
'''
assert rpc('Agentboard.Recovery.readiness()')['restart_available'] is False
assert rpc(setup + '''
{:error, "unavailable", _} = Agentboard.Recovery.capture(candidate, Map.put(policy, "mode", "active"), actor)
{:error, "forbidden", _} = Agentboard.Recovery.capture(candidate, policy, Map.delete(actor, :recovery_internal))
true
''') is True
assert sql('SELECT count(*) FROM recovery_episodes') == '0'
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda _: rpc(setup + '''
{:ok, result} = Agentboard.Recovery.capture(candidate, policy, actor)
result
'''), range(2)))
assert results[0]['episode']['id'] == results[1]['episode']['id']
assert sorted(result['idempotent'] for result in results) == [False, True]
assert all(result['dry_run'] and result['episode']['state'] == 'detected' for result in results)
assert sql('SELECT count(*) FROM recovery_episodes') == '1'
assert sql('SELECT count(*) FROM recovery_episodes_versions') == '1'
assert sql("SELECT count(*) FROM board_action_events WHERE resource = 'Elixir.Agentboard.Recovery.Episode'") == '1'
assert sql('SELECT count(*) FROM recovery_attempts') == '0'
assert sql(retained_query) == retained
# Valid fields must reach the actual Ash authorizer; an earlier validation error
# would not prove ordinary agent attribution lacks recovery authority.
assert rpc(setup + '''
{:ok, attrs} = Agentboard.Recovery.preview(candidate, policy)
result = Agentboard.Recovery.Episode |> Ash.Changeset.for_create(:record, attrs, actor: Map.delete(actor, :recovery_internal)) |> Ash.create()
match?({:error, %Ash.Error.Forbidden{}}, result)
''') is True
assert sql('SELECT count(*) FROM recovery_episodes') == '1'
# Audit evidence cannot be rewritten or truncated, including at the DB boundary.
for statement in ['DELETE FROM recovery_episodes_versions',
                  'UPDATE recovery_episodes_versions SET provenance=\'{}\'',
                  'TRUNCATE recovery_episodes_versions']:
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1',
                             '-c', statement], capture_output=True, text=True)
    assert result.returncode != 0, statement
assert sql('SELECT count(*) FROM recovery_episodes_versions') == '1'
# Binding epoch is part of incarnation identity even when the native session
# marker and last heartbeat are unchanged; reuse must not return the old fence.
new_epoch = rpc(setup + '''
{:ok, result} = Agentboard.Recovery.capture(%{candidate | binding_epoch: 5}, policy, actor)
result
''')
assert new_epoch['idempotent'] is False
assert new_epoch['episode']['id'] != results[0]['episode']['id']
assert new_epoch['episode']['binding_epoch'] == 5

print('Disabled recovery capture, concurrent idempotency, authorization, audit and held-row preservation passed')
