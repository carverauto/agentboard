"""Packaged API owns scoped delivery, atomic capture and uncertainty contracts.

Invented source data; no assertions inspect implementation text. Existing board
and Context tests own legacy behavior. These exercise their runtime transaction
integration plus protected public worker routes against the real release/PG.
"""
import concurrent.futures
import hashlib
import json
import os
import subprocess
import urllib.error
import urllib.request
import uuid

URL = os.environ['AGENTBOARD_URL']
ACTOR = {'x-agentboard-agent': 'fixture-agent', 'x-agentboard-model': 'fixture-model',
         'x-agentboard-harness': 'codex'}
CAPTAIN = 'fixture-captain-capability-32-characters'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def open_transaction(query):
    connection = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
    connection.stdin.write("BEGIN;\n" + query.rstrip(';') + ";\nSELECT 'fixture-ready';\n")
    connection.stdin.flush()
    while connection.stdout.readline().strip() != 'fixture-ready':
        assert connection.poll() is None, connection.stderr.read()
    return connection


def commit(connection):
    connection.stdin.write("COMMIT;\n")
    connection.stdin.flush()
    connection.stdin.close()
    assert connection.wait(timeout=10) == 0, connection.stderr.read()


def api(path, data=None, token=None, status=200, captain=False, method=None, actor=ACTOR):
    headers = dict(actor, **{'x-agentboard-worker-protocol': '1'})
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(URL + '/api/v1' + path,
                                 data=json.dumps(data).encode() if data is not None else None,
                                 headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    assert response.status == status, (path, response.status, body)
    return body


rpc(f'Application.put_env(:agentboard, :captain_token, {json.dumps(CAPTAIN)})')
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
api('/agents/register', {'name': 'Fixture worker'})
foreign_actor = dict(ACTOR, **{'x-agentboard-agent': 'foreign-agent'})
api('/agents/register', {'name': 'Foreign worker'}, actor=foreign_actor)
provision = {'worker_id': 'fixture-agent', 'host_id': 'fixture-host', 'repos': ['fixture/repo'],
             'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'provision-1'}
api('/workers/provision', provision, status=403)
host = api('/workers/provision', provision, captain=True)['host_token']
assert 'host_token' not in api('/workers/provision', provision, captain=True)
api('/workers/fixture-agent/state', status=401)
api('/workers/foreign-agent/state', token=host, status=401)
capabilities = {name: {'supported': name in ('receipt', 'recovery'), 'reason': 'Manual fixture'}
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bind = {'idempotency_key': 'bind-1', 'expected_epoch': 0, 'host_id': 'fixture-host',
        'session_id': 'fixture-session', 'pane_id': 'fixture-pane', 'adapter': 'manual',
        'adapter_version': '1', 'capabilities': capabilities}
bound = api('/workers/fixture-agent/bind', bind, token=host)
receipt_token = bound['receipt_token']
assert bound['binding']['epoch'] == 1
assert 'receipt_token' not in api('/workers/fixture-agent/bind', bind, token=host)
api('/workers/fixture-agent/reserve', {'binding_epoch': 1, 'idempotency_key': 'foreign-reserve'},
    token=receipt_token, status=403)

# Canonical board change and durable source intent have one transaction boundary.
api('/tasks', {'id': 'runtime-task', 'title': 'Runtime fixture', 'repo': 'fixture/repo'})
first = api('/workers/fixture-agent/pending', token=host)
assert len(first['deliveries']) == 1
assert api('/workers/fixture-agent/pending', token=host) == first
sql("CREATE FUNCTION reject_runtime_source() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture source failure'; END $$")
sql('CREATE TRIGGER reject_runtime_source BEFORE INSERT ON cooperation_events FOR EACH ROW EXECUTE FUNCTION reject_runtime_source()')
api('/tasks', {'id': 'rollback-task', 'title': 'Must roll back', 'repo': 'fixture/repo'}, status=503)
assert sql("SELECT count(*) FROM tasks WHERE id='rollback-task'") == '0'
sql('DROP TRIGGER reject_runtime_source ON cooperation_events')

# Freeze, one-winner concurrent reservation and arrivals mid-batch.
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    outcomes = list(pool.map(lambda n: api('/workers/fixture-agent/reserve',
                                          {'binding_epoch': 1, 'idempotency_key': 'reserve-' + str(n)}, token=host), range(2)))
batches = [r['batch'] for r in outcomes if r['batch']]
assert len(batches) == 1, outcomes
batch = batches[0]
handled_batch = batch
assert hashlib.sha256(batch['payload'].encode()).hexdigest() == batch['payload_hash']
assert len(batch['payload'].encode()) <= 16384
assert api('/workers/fixture-agent/state', token=host)['active_batch'] == batch
rpc('Application.put_env(:agentboard, :cooperation_enabled, false)')
assert not api('/workers/fixture-agent/state', token=host)['worker']['enabled']
assert api('/workers/fixture-agent/reserve', {'binding_epoch': 1, 'idempotency_key': 'disabled-reserve'}, token=host)['batch'] is None
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
assert api('/workers/fixture-agent/state', token=host)['active_batch'] == batch
api('/tasks', {'id': 'mid-batch', 'title': 'Later arrival', 'repo': 'fixture/repo'})
assert len(api('/workers/fixture-agent/pending', token=host)['deliveries']) == 2
fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
result_path = '/workers/fixture-agent/attempts/' + batch['attempt_id'] + '/result'
api(result_path, dict(fences, dispatch_generation=999, status='submitted'), token=host, status=409)
api(result_path, dict(fences, status='submitted'), token=host)
assert all(d['state'] == 'pending' for d in api('/workers/fixture-agent/pending', token=host)['deliveries'])
receipt = dict(fences, attempt_id=batch['attempt_id'], idempotency_key='received-1',
               kind='received', delivery_ids=batch['delivery_ids'])
r = api('/workers/fixture-agent/receipts', receipt, token=receipt_token)['receipt']
assert r == api('/workers/fixture-agent/receipts', receipt, token=receipt_token)['receipt']
api('/workers/fixture-agent/receipts', dict(receipt, kind='handled'), token=receipt_token, status=409)
api('/workers/fixture-agent/receipts', dict(receipt, kind='handled', idempotency_key='handled-1'), token=receipt_token)
assert len(api('/workers/fixture-agent/pending', token=host)['deliveries']) == 1

# Ambiguous transport parks uncertainty; positive crash-before-call evidence permits retry.
batch = api('/workers/fixture-agent/reserve', {'binding_epoch': 1, 'idempotency_key': 'crash-before'}, token=host)['batch']
fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
path = '/workers/fixture-agent/attempts/' + batch['attempt_id']
api(path + '/result', dict(fences, status='uncertain', reason='crash_journal_submitting'), token=host)
assert api('/workers/fixture-agent/reserve', {'binding_epoch': 1, 'idempotency_key': 'no-blind-replay'}, token=host)['batch'] is None
reconciled = api(path + '/reconcile', fences, token=host)
assert not reconciled['replay_allowed'] and reconciled['batch']['status'] == 'uncertain'
api(path + '/result', dict(fences, status='not_submitted', reason='journal_proves_adapter_not_called'), token=host)
assert api(path + '/reconcile', fences, token=host)['replay_allowed']

# Context handling compatibility in both directions, including atomic failure.
context = {'entry_key': 'runtime-context', 'repo': 'fixture/repo', 'kind': 'FACT', 'summary': 'A fact'}
own_entry = api('/context', dict(context, entry_key='own-context'))['entry']
assert not any(d['context_id'] == own_entry['id'] for d in api('/workers/fixture-agent/pending', token=host)['deliveries'])
entry = api('/context', context, actor=foreign_actor)['entry']
pending = api('/workers/fixture-agent/pending', token=host)['deliveries']
assert any(d['context_id'] == entry['id'] for d in pending)
batch = api('/workers/fixture-agent/reserve', {'binding_epoch': 1, 'idempotency_key': 'context-reserve'}, token=host)['batch']
fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
context_delivery = next(d['id'] for d in pending if d['context_id'] == entry['id'])
ack = dict(fences, attempt_id=batch['attempt_id'], idempotency_key='context-handle', kind='handled', delivery_ids=[context_delivery])
sql('CREATE TRIGGER reject_runtime_receipt BEFORE INSERT ON cooperation_receipts FOR EACH ROW EXECUTE FUNCTION reject_runtime_source()')
api('/workers/fixture-agent/receipts', ack, token=receipt_token, status=503)
assert sql("SELECT count(*) FROM context_receipts WHERE entry_id=" + str(entry['id'])) == '0'
sql('DROP TRIGGER reject_runtime_receipt ON cooperation_receipts')
api('/workers/fixture-agent/receipts', ack, token=receipt_token)
assert sql("SELECT count(*) FROM context_receipts WHERE entry_id=" + str(entry['id'])) == '1'
entry2 = api('/context', dict(context, entry_key='already-handled'), actor=foreign_actor)['entry']
api('/context/' + str(entry2['id']) + '/ack', {})
assert not any(d['context_id'] == entry2['id'] for d in api('/workers/fixture-agent/pending', token=host)['deliveries'])

# Explicit replacement retires session callbacks and retains uncertainty.
api('/workers/fixture-agent/bind', dict(bind, expected_epoch=1, idempotency_key='bind-2'), token=host)
historical_fences = {key: handled_batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
historical_path = '/workers/fixture-agent/attempts/' + handled_batch['attempt_id']
proof = api(historical_path + '/reconcile', historical_fences, token=host)
assert proof['historical'] and proof['resolved'] and proof['batch']['status'] == 'handled'
api(historical_path + '/result', dict(historical_fences, status='submitted'), token=host, status=409)
api(historical_path + '/reconcile', dict(historical_fences, payload_hash='bad'), token=host, status=409)
api('/workers/foreign-agent/attempts/' + handled_batch['attempt_id'] + '/reconcile',
    historical_fences, token=host, status=401)
api('/workers/fixture-agent/receipts', dict(ack, idempotency_key='stale-epoch'), token=receipt_token, status=403)
api('/workers/fixture-agent/pause', {'binding_epoch': 2}, token=host)
assert api('/workers/fixture-agent/doctor', token=host)['worker']['paused']
api('/workers/fixture-agent/resume', {'binding_epoch': 2}, token=host)
assert not api('/workers/fixture-agent/state', token=host)['worker']['paused']
# A replacement's orphan submission requires a protected, explicit captain decision.
active = api('/workers/fixture-agent/state', token=host)['active_attempt']
uncertain_path = '/workers/fixture-agent/attempts/' + active['id']
uncertain_fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
proof = api(uncertain_path + '/reconcile', uncertain_fences, token=host)
assert proof['historical'] and not proof['resolved'] and not proof['replay_allowed']
assert api('/workers/fixture-agent/state', token=host)['active_attempt'] == active
api('/workers/fixture-agent/resolve_attempt', {'attempt_id': active['id'], 'decision': 'retry', 'reason': 'Fixture operator accepts replay risk'}, token=host, status=403)
api('/workers/fixture-agent/resolve_attempt', {'attempt_id': active['id'], 'decision': 'retry', 'reason': 'Fixture operator accepts replay risk'}, captain=True)

# Bounded frames and independent paginated responsibilities; no discarded arrivals.
for n in range(25):
    api('/tasks', {'id': 'backlog-' + str(n).zfill(2), 'title': 'Long untrusted ' + ('雪' * 60), 'repo': 'fixture/repo'})
batch = api('/workers/fixture-agent/reserve', {'binding_epoch': 2, 'idempotency_key': 'bounded-backlog'}, token=host)['batch']
assert len(batch['delivery_ids']) <= 20 and len(batch['payload'].encode()) <= 10240 and batch['more']
assert any('雪' in item['summary'] for item in json.loads(batch['payload'])['items'])
assert len(api('/workers/fixture-agent/pending?limit=100', token=host)['deliveries']) >= 25
api('/workers/fixture-agent/pause', {'binding_epoch': 2}, token=host)
assert api('/workers/fixture-agent/reserve', {'binding_epoch': 2, 'idempotency_key': 'paused-backlog'}, token=host)['batch'] is None
api('/workers/fixture-agent/resume', {'binding_epoch': 2}, token=host)

# Read all authorized responsibility pages even when the original task is terminal.
api('/tasks/runtime-task/claim', {})
api('/tasks/runtime-task/update', {'status': 'done', 'note': 'Terminal source remains a responsibility'})
page = api('/workers/fixture-agent/responsibilities?limit=1', token=host)
assert page['tasks'][0]['id'] == 'runtime-task' and page['tasks'][0]['status'] == 'done'

# A committed larger source ID cannot hide an earlier uncommitted source.
# Invented durable rows exercise recovery, independently of notification delivery.
late_id = '00000000-0000-4000-8000-000000000001'
connection = open_transaction("INSERT INTO cooperation_events(id,source_key,kind,repo,summary,source_url,priority,audience,route_cursor,routed,created_at) VALUES ('" + late_id + "','late-commit','context','fixture/repo','Late committed source','/context/late',2,ARRAY['fixture-agent'],0,false,clock_timestamp())")
api('/tasks', {'id': 'committed-first', 'title': 'Arrives first', 'repo': 'fixture/repo'})
assert not any(d['summary'] == 'Late committed source' for d in api('/workers/fixture-agent/pending?limit=100', token=host)['deliveries'])
commit(connection)
rpc('Agentboard.Repo.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)')
assert any(d['summary'] == 'Late committed source' for d in api('/workers/fixture-agent/pending?limit=100', token=host)['deliveries'])

# A blocked host row does not block independent board and Context commits.
connection = open_transaction("SELECT id FROM cooperation_bindings WHERE id='fixture-agent' FOR UPDATE;")
api('/tasks', {'id': 'independent-write', 'title': 'Independent board mutation', 'repo': 'fixture/repo'})
api('/context', dict(context, entry_key='independent-context'))
commit(connection)

# One source's recipient pages survive an interrupted transaction and a new RPC.
rpc('{:ok, _} = Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)')
sql("INSERT INTO agents(id,name,model,harness) SELECT 'page-'||n,'Paged worker','fixture-model','codex' FROM generate_series(1,205) n")
sql("INSERT INTO cooperation_subscriptions(id,host_id,repos,model,harness,paused,revoked,enrolled_at) SELECT 'page-'||n,'host-'||n,ARRAY['fixture/repo'],'fixture-model','codex',false,false,clock_timestamp() FROM generate_series(1,205) n")
page_event = str(uuid.uuid4())
sql("INSERT INTO cooperation_events(id,source_key,kind,repo,summary,source_url,priority,audience,route_cursor,routed,created_at) VALUES ('" + page_event + "','recipient-pages','context','fixture/repo','Paged source','/context/paged',2,ARRAY(SELECT 'page-'||n FROM generate_series(1,205) n),0,false,clock_timestamp())")
rpc('{:ok, _} = Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)')
assert sql("SELECT route_cursor FROM cooperation_events WHERE id='" + page_event + "'") == '100'
sql("CREATE TRIGGER interrupt_page BEFORE INSERT ON cooperation_deliveries FOR EACH ROW WHEN (NEW.event_id='" + page_event + "') EXECUTE FUNCTION reject_runtime_source()")
assert '{:error,' in rpc('IO.puts(inspect(Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)))')
assert sql("SELECT route_cursor FROM cooperation_events WHERE id='" + page_event + "'") == '100'
sql('DROP TRIGGER interrupt_page ON cooperation_deliveries')
for _ in range(2):
    rpc('{:ok, _} = Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)')
assert sql("SELECT route_cursor||','||routed FROM cooperation_events WHERE id='" + page_event + "'") == '205,true'
assert sql("SELECT count(*) FROM cooperation_deliveries WHERE event_id='" + page_event + "'") == '205'

# Seed a valid historical reservation, as a process restart would find it.
# PostgreSQL clock expiry changes only the attempt, never its immutable batch.
old_batch, old_attempt = str(uuid.uuid4()), str(uuid.uuid4())
delivery_id = api('/workers/fixture-agent/pending?limit=100', token=host)['deliveries'][-1]['id']
payload = json.dumps({'batch_id': old_batch, 'attempt_id': old_attempt, 'binding_epoch': 2,
                      'dispatch_generation': 1000, 'items': [{'delivery_id': delivery_id}]})
payload_hash = hashlib.sha256(payload.encode()).hexdigest()
sql("INSERT INTO cooperation_batches(id,worker_id,epoch,generation,delivery_ids,payload,payload_hash,more,lease_expires_at,created_at) VALUES ('" + old_batch + "','fixture-agent',2,1000,ARRAY['" + delivery_id + "'],'" + payload + "','" + payload_hash + "',true,clock_timestamp()-interval '1 second',clock_timestamp()-interval '121 seconds')")
sql("INSERT INTO cooperation_attempts(id,batch_id,worker_id,epoch,generation,idempotency_key,status,created_at,updated_at) VALUES ('" + old_attempt + "','" + old_batch + "','fixture-agent',2,1000,'historical-reservation','reserved',clock_timestamp()-interval '121 seconds',clock_timestamp()-interval '121 seconds')")
sql("UPDATE cooperation_bindings SET generation=1000,active_attempt_id='" + old_attempt + "' WHERE id='fixture-agent'")
expired = api('/workers/fixture-agent/state', token=host)
assert expired['active_attempt']['status'] == 'uncertain'
assert expired['active_batch']['payload'] == payload
assert api('/workers/fixture-agent/reserve', {'binding_epoch': 2, 'idempotency_key': 'expired-no-replay'}, token=host)['batch'] is None

api('/workers/fixture-agent/revoke', {}, captain=True)
api('/workers/fixture-agent/state', token=host, status=401)
api('/workers/provision', dict(provision, idempotency_key='rotate-foreign-scope',
    repos=['foreign/repo']), captain=True, status=409)
rotated = api('/workers/provision', dict(provision, idempotency_key='rotate-same-scope'), captain=True)
assert api('/workers/fixture-agent/state', token=rotated['host_token'])['worker']['repos'] == ['fixture/repo']
api('/workers/fixture-agent/state', token=receipt_token, status=401)
print('Packaged runtime scoped delivery/capture/receipt/uncertainty contracts passed')
