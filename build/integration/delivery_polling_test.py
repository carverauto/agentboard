"""Packaged Ash/PG poll exclusivity, durable backoff and stale-writer contracts.

Inventory tests own identity and attribution. These invented fixtures prove
reservation behavior through the real domain, not provider CI collection.
"""
import concurrent.futures
import json
import os
import subprocess


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc',
                             expression + '; IO.puts("POLL_RESULT=" <> Jason.encode!(result))'],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split('=', 1)[1] for line in result.stdout.splitlines()
                           if line.startswith('POLL_RESULT=')))


def reserve(limit=20):
    return rpc(f'{{:ok, result}} = Agentboard.Delivery.reserve_due({limit})')


def defer(reservation, delay, reason='unavailable'):
    args = ', '.join([json.dumps(reservation['id']), json.dumps(reservation['attempt_id']),
                      str(reservation['generation']), str(delay), json.dumps(reason)])
    return rpc(f'result = case Agentboard.Delivery.defer_poll({args}) do '
               '{:ok, state} -> %{state: state}; {:error, code, _} -> %{error: code} end')


cli_env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
cli_env.update(AGENT_ID='poll-owner', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=cli_env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


ab('agent', 'register')
ab('task', 'create', '--id', 'poll-one', '--title', 'First PR', '--pr',
   'https://github.com/fixture/repo/pull/101')
assert reserve() == [], 'Default-off observation reserved work'
rpc('Application.put_env(:agentboard, :pr_observation_enabled, true); result = true')
assert sql("SELECT ci_state||','||generation||','||(observed_at IS NULL)||','||(head_sha IS NULL) FROM delivery_poll_states") == 'unknown,0,true,true'
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == '1'

# Both real callers race the same due PR. Exactly one owns generation one.
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    batches = list(pool.map(lambda _: reserve(1), range(2)))
assert sorted(map(len, batches)) == [0, 1], batches
first = next(batch[0] for batch in batches if batch)
assert first['generation'] == 1 and first['number'] == '101'
assert reserve() == [], 'Live reservation was selected again'
assert sql("SELECT lease_expires_at-last_attempt_at = interval '120 seconds' FROM delivery_poll_states") == 't'

# An expired response cannot write, even before a replacement reserves it.
sql("UPDATE delivery_poll_states SET lease_expires_at=clock_timestamp()-interval '1 second'")
assert defer(first, 60) == {'error': 'conflict'}
second = reserve(1)[0]
assert second['generation'] == 2 and second['attempt_id'] != first['attempt_id']
before = sql('SELECT row_to_json(t) FROM delivery_poll_states t')
assert defer(first, 60) == {'error': 'conflict'}
assert sql('SELECT row_to_json(t) FROM delivery_poll_states t') == before

# Delay persists, releases the reservation, and does not certify CI. A repeated
# result cannot reuse its consumed reservation.
deferred = defer(second, 3600, 'rate_limited')['state']
assert deferred['attempt_id'] is None and deferred['lease_expires_at'] is None
assert deferred['last_error'] == 'rate_limited' and deferred['ci_state'] == 'unknown'
assert sql("SELECT next_poll_at >= clock_timestamp()+interval '59 minutes' FROM delivery_poll_states") == 't'
assert reserve() == []
assert defer(second, 60) == {'error': 'conflict'}

# A held PR row doesn't serialize other polls or unrelated board writes.
ab('task', 'create', '--id', 'poll-two', '--title', 'Second PR', '--pr',
   'https://github.com/fixture/repo/pull/102')
sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second'")
locker = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1'],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
locker.stdin.write("BEGIN; SELECT id FROM delivery_poll_states WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='101') FOR UPDATE; SELECT 'LOCKED';\n")
locker.stdin.flush()
while True:
    line = locker.stdout.readline()
    assert line, 'Could not hold poll row'
    if line.strip() == 'LOCKED':
        break
try:
    batch = reserve(100)
    assert len(batch) == 1 and batch[0]['number'] == '102', batch
    ab('task', 'create', '--id', 'independent-board', '--title', 'Board remains available')
finally:
    locker.stdin.write('COMMIT;\n\\q\n')
    locker.stdin.flush()
    assert locker.wait(timeout=10) == 0
third = reserve(1)[0]
assert third['number'] == '101' and third['generation'] == 3

# A disabled runtime fences already-due work without consuming it.
rpc('Application.put_env(:agentboard, :pr_observation_enabled, false); result = true')
sql("UPDATE delivery_poll_states SET lease_expires_at=clock_timestamp()-interval '1 second'")
before = sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t')
assert reserve() == []
assert defer(third, 60) == {'error': 'disabled'}
assert sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t') == before
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == '2', 'Operational polling produced version noise'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PollState'") == '2'
assert sql("SELECT count(*) FROM delivery_poll_states WHERE ci_state!='unknown' OR observed_at IS NOT NULL OR head_sha IS NOT NULL") == '0'
# Operator repair must audit even disabled -> disabled retirement, preserve
# unknown CI, reject a partial cohort/live reservation and be retry-safe.
ab('task', 'create', '--id', 'repair-already-resumed', '--title', 'Already resumed PR',
   '--pr', 'https://github.com/fixture/repo/pull/103')
ids = json.loads(sql('SELECT json_agg(id ORDER BY id) FROM delivery_poll_states'))
actor = '%{"agent" => "poll-owner", "model" => "fixture-model", "harness" => "codex"}'


def repair(cohort=ids, apply=False):
    expression = ('result = case Agentboard.Delivery.Polling.reconcile_disabled(' +
                  json.dumps(cohort) + ', ' + actor + ', ' + str(apply).lower() + ') do '
                  '{:ok, rows} -> %{rows: rows}; {:error, code, _} -> %{error: code} end')
    return rpc(expression)


sql("UPDATE delivery_poll_states SET enabled=false,attempt_id=NULL,lease_expires_at=NULL,lifecycle=CASE WHEN id=(SELECT id FROM delivery_pull_requests WHERE number='101') THEN 'merged' ELSE 'open' END")
# Discovery may resume some incident rows between deploy and the operator step.
sql("UPDATE delivery_poll_states SET enabled=true WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='103')")
before = sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t')
assert repair(ids + ['missing-state'], True) == {'error': 'not_found'}
assert sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t') == before
assert sorted(row['disposition'] for row in repair()['rows']) == ['reenabled', 'reenabled', 'retired']
assert sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t') == before
sql("UPDATE delivery_poll_states SET attempt_id=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '1 minute' WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='101')")
assert repair(apply=True) == {'error': 'conflict'}
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == '3'
sql('UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL')
sql("CREATE FUNCTION fixture_reject_repair() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture audit unavailable'; END $$; CREATE TRIGGER fixture_audit_failure BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION fixture_reject_repair()")
assert repair(apply=True) == {'error': 'unavailable'}
assert sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t') == before
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == '3'
sql('DROP TRIGGER fixture_audit_failure ON board_action_events; DROP FUNCTION fixture_reject_repair()')
assert sorted(row['disposition'] for row in repair(apply=True)['rows']) == ['reenabled', 'reenabled', 'retired']
assert sql("SELECT string_agg(number||':'||enabled,',' ORDER BY number) FROM delivery_poll_states JOIN delivery_pull_requests USING(id)") == '101:false,102:true,103:true'
assert sql("SELECT count(*) FROM delivery_poll_states_versions WHERE version_action_name='reconcile_disabled' AND provenance->>'agent'='poll-owner'") == '3'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PollState'") == '6'
repaired = sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t')
assert all(row['disposition'] == 'already_reconciled' for row in repair(apply=True)['rows'])
assert sql('SELECT json_agg(t ORDER BY id) FROM delivery_poll_states t') == repaired
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == '6'
assert sql("SELECT count(*) FROM delivery_poll_states WHERE ci_state!='unknown' OR observed_at IS NOT NULL OR head_sha IS NOT NULL") == '0'
print('Exclusive reservations, durable backoff, disabled observation and audited retry-safe operator repair passed')
