"""Packaged canonical wake capture and Postgres history contract.

The existing cooperation fixture owns transport/batch receipts. This fixture
owns first-capture concurrency, rollback at the source write, and pending-state
discovery of a lower-ID late commit. All actors and source data are invented.
"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import tempfile
import fcntl
import plistlib
import configparser
import shlex
import datetime
import time
import subprocess
import urllib.request
import urllib.error


def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-qAt', '-v',
        'ON_ERROR_STOP=1', '-c', statement], text=True).strip()


def rpc(expression):
    script = 'value = (' + expression + '); IO.puts("WAKE_RESULT:" <> Jason.encode!(value))'
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', script],
        capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split(':', 1)[1] for line in result.stdout.splitlines()
        if line.startswith('WAKE_RESULT:')))


def api(path, data=None, agent='wake-seat', token=None, captain=None, status=200):
    headers = {'Content-Type': 'application/json', 'x-agentboard-agent': agent,
        'x-agentboard-model': 'fixture', 'x-agentboard-harness': 'codex',
        'x-agentboard-worker-protocol': '1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = captain
        if not token:
            headers['Authorization'] = 'Bearer ' + captain
    request = urllib.request.Request(os.environ['AGENTBOARD_URL'] + '/api/v1/' + path,
        data=json.dumps(data).encode() if data is not None else None, headers=headers)
    try:
        result = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        result = error
    with result:
        body = json.load(result)
        expected = status if isinstance(status, tuple) else (status,)
        assert result.status in expected, (path, result.status, body)
        return body


def discover():
    return rpc('''
    {:ok, value} = Agentboard.WakeIntents.reconcile("wake-seat", ["fixture/repo"])
    value
    ''')


api('agents/register', {'name': 'Wake fixture'})
api('agents/register', {'name': 'Sender fixture'}, agent='wake-sender')
api('tasks', {'id': 'wake-source', 'title': 'Canonical fixture', 'repo': 'fixture/repo'})
# Taskless legacy messages have no canonical repository, even for one subscription.
legacy = api('messages', {'to': 'wake-seat', 'body': 'Unscoped invented DM'}, agent='wake-sender')['message']
discover()
assert sql('SELECT count(*) FROM wake_intents') == '0'
# Bypass the live producer to exercise concurrent recovery of a canonical source.
message = {'id': int(sql("INSERT INTO messages(sender_id,recipient_id,task_id,model,harness,body,created_at) VALUES ('wake-sender','wake-seat','wake-source','fixture','codex','Scoped legacy DM',clock_timestamp()) RETURNING id"))}
assert sql('SELECT count(*) FROM wake_intents') == '0'
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    list(pool.map(lambda _: discover(), range(2)))
assert sql('SELECT count(*) FROM wake_intents') == '1'
assert sql('SELECT count(*) FROM wake_intents_versions') == '1'
record = json.loads(sql('SELECT to_jsonb(w) FROM wake_intents w'))
expected_hash = hashlib.sha256(json.dumps([
    'agentboard-wake-v1', 'wake-seat', 'fixture/repo', 'unread_dm',
    'board_message', str(message['id']), record['source_version']
], ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
assert record['reason_hash'] == expected_hash
assert record['state'] == 'pending' and record['delivery_id'] is None
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Wake.Intent'") == '1'
assert sql("SELECT read_at IS NULL FROM messages WHERE id=" + str(message['id'])) == 't'
# A valid persisted payload reaches the Ash authorizer, not an earlier validator.
assert rpc('''
row = Ash.get!(Agentboard.Wake.Intent, "''' + record['id'] + '''")
attrs = Map.take(row, Ash.Resource.Info.attributes(Agentboard.Wake.Intent) |> Enum.map(& &1.name))
attrs = Map.put(attrs, :id, Ash.UUID.generate())
result = Agentboard.Wake.Intent |> Ash.Changeset.for_create(:record, attrs,
  actor: %{"agent" => "wake-seat", "model" => "fixture", "harness" => "codex"}) |> Ash.create()
match?({:error, %Ash.Error.Forbidden{}}, result)
''') is True
# Failed capture must roll back canonical message and both audit streams.
before = sql('SELECT count(*) FROM messages')
sql("CREATE FUNCTION reject_wake_capture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture capture rejection'; END $$")
sql('CREATE TRIGGER reject_wake_capture BEFORE INSERT ON wake_intents FOR EACH ROW EXECUTE FUNCTION reject_wake_capture()')
assert rpc('''
result = Agentboard.Board.message(nil, %{"agent" => "wake-sender", "model" => "fixture", "harness" => "codex"},
  %{"to" => "wake-seat", "task" => "wake-source", "body" => "Rollback fixture"})
match?({:error, _, _}, result)
''') is True
assert sql('SELECT count(*) FROM messages') == before
assert sql('SELECT count(*) FROM wake_intents_versions') == '1'
sql('DROP TRIGGER reject_wake_capture ON wake_intents')
# Reserve a lower sequence ID in an uncommitted real DB transaction. A later
# visible DM is scanned first; committing the lower ID must still discover it.
connection = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
connection.stdin.write("BEGIN; INSERT INTO messages(sender_id,recipient_id,task_id,model,harness,body,created_at) VALUES ('wake-sender','wake-seat','wake-source','fixture','codex','Lower late DM',clock_timestamp()) RETURNING id;\n")
connection.stdin.flush()
low_id = int(connection.stdout.readline().strip())
later = api('messages', {'to': 'wake-seat', 'task': 'wake-source', 'body': 'Higher visible DM'}, agent='wake-sender')['message']
assert later['id'] > low_id
discover()
assert sql("SELECT count(*) FROM wake_intents WHERE source_id='" + str(low_id) + "'") == '0'
connection.stdin.write("COMMIT;\n")
connection.stdin.flush()
connection.stdin.close()
assert connection.wait(timeout=10) == 0, connection.stderr.read()
discover()
assert sql("SELECT count(*) FROM wake_intents WHERE source_id='" + str(low_id) + "'") == '1'
discover()
assert sql('SELECT count(*) FROM wake_intents') == '3'
# History remains retained against update/delete/truncate, at the actual DB owner.
for statement in ["DELETE FROM wake_intents_versions",
                  "UPDATE wake_intents_versions SET provenance='{}'",
                  "TRUNCATE wake_intents_versions"]:
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1',
        '-c', statement], capture_output=True, text=True)
    assert result.returncode != 0, statement
assert sql('SELECT count(*) FROM wake_intents_versions') == '3'
assert sql('SELECT count(*) FROM wake_attempts') == '0'
print('Canonical wake concurrency, independent hash, rollback, late commit and retained audit PASS')

# Real worker credentials own inspection scope; attribution headers cannot grant it.
captain = 'invented-wake-captain-capability-32'
rpc('Application.put_env(:agentboard, :captain_token, "' + captain + '"); true')
provision = api('workers/provision', {'worker_id': 'wake-seat', 'host_id': 'fixture-host',
    'repos': ['fixture/repo'], 'model': 'fixture', 'harness': 'codex',
    'idempotency_key': 'wake-provision'}, captain=captain)
host = provision['host_token']
api('workers/wake-seat/wake_intents', status=401)
api('workers/foreign-seat/wake_intents', token=host, status=401)
api('workers/wake-seat/wake_intents?limit=33', token=host, status=422)
retained_query = "SELECT jsonb_build_object('messages',(SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM messages m),'intents',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM wake_intents i),'history',(SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM wake_intents_versions v),'bindings',(SELECT jsonb_agg(to_jsonb(b) ORDER BY id) FROM cooperation_bindings b))"
retained = sql(retained_query)
preview = api('workers/wake-seat/wake_intents', token=host)
assert preview['mode'] == 'dry_run' and preview['native_delivery_enabled'] is False
assert preview['readiness']['supported_actions']['idle_wake'] is False
assert preview['restart']['restart_available'] is False
assert {i['reason_hash'] for i in preview['intents']} == set(sql('SELECT reason_hash FROM wake_intents').splitlines())
assert all(i['disposition'] == 'pending' and i['dispatch_allowed'] is False for i in preview['intents'])
assert api('workers/wake-seat/wake_intents', token=host) == preview
assert sql(retained_query) == retained
# Pagination is scoped and restartable, not a permanent maximum-ID watermark.
page = api('workers/wake-seat/wake_intents?limit=1', token=host)
visited = []
while True:
    visited.extend(i['intent_id'] for i in page['intents'])
    if page['next_cursor'] is None:
        break
    page = api('workers/wake-seat/wake_intents?limit=1&cursor=' + page['next_cursor'], token=host)
assert set(visited) == {i['intent_id'] for i in preview['intents']} and len(visited) == 3
api('messages/' + str(message['id']) + '/read', {})
updated = api('workers/wake-seat/wake_intents', token=host)
handled = next(i for i in updated['intents'] if i['source']['id'] == str(message['id']))
assert handled['disposition'] == 'handled' and handled['source_state'] == 'handled'
# Inspecting another repository's source must not leak its identity.
api('tasks', {'id': 'wake-foreign', 'title': 'Foreign fixture', 'repo': 'elsewhere/private'})
foreign = api('messages', {'to': 'wake-seat', 'task': 'wake-foreign', 'body': 'Foreign-scope fixture'}, agent='wake-sender')['message']
assert all(i['source']['id'] != str(foreign['id']) for i in api('workers/wake-seat/wake_intents', token=host)['intents'])
assert sql('SELECT count(*) FROM wake_attempts') == '0'
print('Authenticated scoped read, pagination, canonical handling and no-consumption PASS')

# Self-send/own echo stays readable but cannot become a second wake.
before_self = sql('SELECT count(*) FROM wake_intents')
api('messages', {'to': 'wake-seat', 'task': 'wake-source', 'body': 'Own echo fixture'})
discover()
assert sql('SELECT count(*) FROM wake_intents') == before_self
# A warning identifies the exact expiry, not a scan tick; renewal invalidates it.
api('tasks/wake-source/claim', {'ttl_seconds': 600})
warning = next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['reason'] == 'claim_expiring')
discover()
assert sql("SELECT count(*) FROM wake_intents WHERE reason='claim_expiring'") == '1'
api('tasks/wake-source/renew', {'ttl_seconds': 7200})
old_warning = next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['intent_id'] == warning['intent_id'])
assert old_warning['disposition'] == 'suppressed'
api('tasks/wake-source/renew', {'ttl_seconds': 600})
assert sql("SELECT count(*) FROM wake_intents WHERE reason='claim_expiring'") == '2'
# Only a captain-authorized assignment can wake an idle seat. Ordinary title
# edits must not manufacture another assignment occurrence.
api('agents/wake-seat/heartbeat', {'status': 'idle'})
api('tasks', {'id': 'wake-assigned', 'title': 'Assigned fixture', 'repo': 'fixture/repo'})
api('tasks/wake-assigned/assign', {'to': 'wake-seat'}, agent='wake-sender', captain=captain)
assigned = next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['reason'] == 'idle_assigned')
api('tasks/wake-assigned/edit', {'title': 'Edited assignment title'})
discover()
assert sql("SELECT count(*) FROM wake_intents WHERE reason='idle_assigned'") == '1'
assert next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['intent_id'] == assigned['intent_id'])['disposition'] == 'pending'
api('tasks/wake-assigned/claim', {})
assert next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['intent_id'] == assigned['intent_id'])['disposition'] == 'suppressed'
print('Own echo, exact-expiry renewal and authorized assignment identity PASS')

# Availability affects eligibility without consuming or renewing canonical work.
api('availability', {'agent_id': 'wake-seat', 'state': 'out_of_service',
    'reason': 'Invented maintenance'}, captain=captain)
unavailable = api('workers/wake-seat/wake_intents', token=host)
assert 'agent_unavailable' in unavailable['readiness']['reason_codes']
assert all(i['eligible'] is False and i['dispatch_allowed'] is False for i in unavailable['intents'])
api('availability', {'agent_id': 'wake-seat', 'state': 'active'}, captain=captain)
api('tasks/wake-source/update', {'status': 'done'})
assert all(i['disposition'] == 'suppressed' for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['reason'] == 'claim_expiring')
api('tasks', {'id': 'wake-untrusted', 'title': 'Untrusted assignment', 'repo': 'fixture/repo'})
api('tasks/wake-untrusted/assign', {'to': 'wake-seat'}, agent='wake-sender')
discover()
assert all(i['source']['id'] != 'wake-untrusted' for i in api('workers/wake-seat/wake_intents', token=host)['intents'])

# Existing answered-decision delivery must be adopted, never shadowed by its DM.
# These capability declarations exercise server audience selection only; they
# do not prove a native input boundary, and this fixture sends no native input.
api('agents/register', {'name': 'Invented captain'}, agent='captain')
rpc('Application.put_env(:agentboard, :cooperation_enabled, true); true')
capabilities = {name: {'supported': True} for name in
    ['idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery']}
api('workers/wake-seat/bind', {'idempotency_key': 'wake-bind', 'expected_epoch': 0,
    'host_id': 'fixture-host', 'session_id': 'invented-session', 'pane_id': 'invented-pane',
    'adapter': 'manual', 'adapter_version': 'fixture-1', 'capabilities': capabilities}, token=host)
api('workers/wake-seat/state', {'binding_epoch': 1, 'adapter_state': 'ready',
    'connector_state': 'healthy'}, token=host)
api('tasks', {'id': 'wake-decision', 'title': 'Decision fixture', 'repo': 'fixture/repo'})
api('tasks/wake-decision/claim', {})
request = api('decisions', {'task': 'wake-decision', 'kind': 'ask_user_gate',
    'gate': 'fixture/run/wake-answer', 'question': 'Retained question?',
    'findings': 'Invented findings', 'options': ['Approve', 'Fix']})['decision']
answer = api('decisions/' + request['id'] + '/answer', {'answer': 'Approved fixture'},
    agent='captain', captain=captain)
wake = answer['wake']
assert wake['route'] == 'worker' and wake['worker_event_id'] is not None
answer_intent = next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['reason'] == 'decision_answered')
assert answer_intent['source']['id'] == wake['id']
assert sql("SELECT cooperation_event_id FROM wake_intents WHERE id='" + answer_intent['intent_id'] + "'") == wake['worker_event_id']
discover()
assert sql("SELECT count(*) FROM wake_intents WHERE source_kind='decision_wake' AND source_id='" + wake['id'] + "'") == '1'
assert sql("SELECT count(*) FROM wake_intents WHERE source_kind='board_message' AND source_id='" + str(answer['decision']['message_id']) + "'") == '0'
api('messages/' + str(answer['decision']['message_id']) + '/read', {})
assert next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['intent_id'] == answer_intent['intent_id'])['source_state'] == 'pending'
api('decisions/' + request['id'] + '/ack', {})
assert next(i for i in api('workers/wake-seat/wake_intents', token=host)['intents']
    if i['intent_id'] == answer_intent['intent_id'])['disposition'] == 'handled'
assert sql('SELECT count(*) FROM wake_attempts') == '0'
print('Availability, terminal claims, unauthorized assignments and existing answer adoption PASS')

# Server CAS and receipts use the real scoped HTTP owner. Declared Pi readiness
# here proves server fences only: there is no native socket or actual input.
wake_path = 'hosts/fixture-host/wake-intents/wake-seat'
api('hosts/other-host/wake-intents/wake-seat', token=host, status=403)
api(wake_path, token=host)['intents']


def reserve_data(intent, key, path=wake_path, token=host):
    ready = api(path, token=token)['readiness']
    return {'intent_id': intent['intent_id'], 'intent_revision': intent['intent_revision'],
        'reason_hash': intent['reason_hash'], 'idempotency_key': key,
        'enrollment_revision': ready['enrollment_revision'],
        'binding_epoch': ready['binding_epoch'], 'session_id': ready['session_id'],
        'adapter_generation': sql("SELECT pane_id FROM cooperation_bindings WHERE id='" + ready['worker_id'] + "'")}


pending = next(i for i in api(wake_path, token=host)['intents']
    if i['source']['id'] == str(low_id) and i['source']['kind'] == 'board_message')
disabled = api(wake_path + '/reserve', reserve_data(pending, 'disabled'), token=host)
assert disabled['reservation'] is None and 'wake_delivery_disabled' in disabled['reason_codes']
rpc('Application.put_env(:agentboard, :wake_delivery_enabled, true); true')
unsupported = api(wake_path + '/reserve', reserve_data(pending, 'unsupported'), token=host)
assert unsupported['reservation'] is None and 'safe_input_unproven' in unsupported['reason_codes']
assert sql('SELECT count(*) FROM wake_attempts') == '0'
bind_pi = {'idempotency_key': 'wake-pi-bind', 'expected_epoch': 1, 'host_id': 'fixture-host',
    'session_id': 'invented-pi-session', 'pane_id': 'invented-pi-pane',
    'adapter': 'pi-native-v1', 'adapter_version': 'pi-native-v1', 'capabilities': capabilities}
pi_bound = api('workers/wake-seat/bind', bind_pi, token=host)
receipt_token = pi_bound['receipt_token']
api('workers/wake-seat/state', {'binding_epoch': 2, 'adapter_state': 'ready', 'connector_state': 'healthy'}, token=host)
api('availability', {'agent_id': 'wake-seat', 'state': 'out_of_service', 'reason': 'Admission fixture'}, captain=captain)
unavailable = api(wake_path + '/reserve', reserve_data(pending, 'unavailable'), token=host)
assert unavailable['reservation'] is None and 'agent_unavailable' in unavailable['reason_codes']
api('availability', {'agent_id': 'wake-seat', 'state': 'active'}, captain=captain)
api('workers/wake-seat/pause', {'binding_epoch': 2}, token=host)
paused = api(wake_path + '/reserve', reserve_data(pending, 'paused'), token=host)
assert paused['reservation'] is None and 'paused' in paused['reason_codes']
api('workers/wake-seat/resume', {'binding_epoch': 2}, token=host)
requests = [reserve_data(pending, 'daemon-' + str(i)) for i in range(2)]
reservation_snapshot = "SELECT jsonb_build_object('intents',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM wake_intents i),'versions',(SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM wake_intents_versions v),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM cooperation_events e),'deliveries',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM cooperation_deliveries d),'batches',(SELECT jsonb_agg(to_jsonb(b) ORDER BY id) FROM cooperation_batches b),'bindings',(SELECT jsonb_agg(to_jsonb(b) ORDER BY id) FROM cooperation_bindings b),'attempts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM cooperation_attempts a))"
before_reservation = sql(reservation_snapshot)
sql('CREATE TRIGGER reject_wake_attempt BEFORE INSERT ON wake_attempts FOR EACH ROW EXECUTE FUNCTION reject_wake_capture()')
api(wake_path + '/reserve', reserve_data(pending, 'rollback-attempt'), token=host, status=503)
assert sql(reservation_snapshot) == before_reservation
assert sql('SELECT count(*) FROM wake_attempts_versions') == '0'
sql('DROP TRIGGER reject_wake_attempt ON wake_attempts')
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    replies = list(pool.map(lambda data: api(wake_path + '/reserve', data, token=host, status=(200, 409)), requests))
winners = [r for r in replies if r.get('reservation')]
assert len(winners) == 1 and sql('SELECT count(*) FROM wake_attempts') == '1'
assert sql('SELECT count(*) FROM wake_attempts_versions') == '1'
assert rpc('''
row = Agentboard.Wake.Attempt |> Ash.read_one!()
result = row |> Ash.Changeset.for_update(:change, %{state: "uncertain"},
  actor: %{"agent" => "wake-seat", "model" => "fixture", "harness" => "codex"}) |> Ash.update()
match?({:error, %Ash.Error.Forbidden{}}, result)
''') is True
for statement in ['DELETE FROM wake_attempts_versions',
                  "UPDATE wake_attempts_versions SET provenance='{}'", 'TRUNCATE wake_attempts_versions']:
    denied = subprocess.run([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', statement], capture_output=True, text=True)
    assert denied.returncode != 0
assert sql('SELECT count(*) FROM wake_attempts_versions') == '1'
winner = winners[0]
reservation, batch = winner['reservation'], winner['batch']
assert hashlib.sha256(batch['payload'].encode()).hexdigest() == batch['payload_hash']
expected_reservation_hash = hashlib.sha256(json.dumps([
    'agentboard-wake-reservation-v1', pending['intent_id'], pending['intent_revision'], pending['reason_hash'],
    'wake-seat', 'fixture-host', 'fixture/repo', requests[0]['enrollment_revision'], 2,
    bind_pi['session_id'], bind_pi['pane_id'], batch['attempt_id'], batch['payload_hash'],
    'board_message', str(low_id), pending['source']['version'], batch['delivery_ids'][0]
], separators=(',', ':')).encode()).hexdigest()
assert reservation['payload_hash'] == expected_reservation_hash
winner_key = sql('SELECT idempotency_key FROM wake_attempts')
retry = api(wake_path + '/reserve', next(d for d in requests if d['idempotency_key'] == winner_key), token=host)
assert retry['reservation'] == reservation and retry['batch'] == batch
assert reservation['source_refs'][0]['delivery_id'] == batch['delivery_ids'][0]
assert sql('SELECT count(*) FROM cooperation_deliveries WHERE id=\'' + batch['delivery_ids'][0] + "'") == '1'
assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(low_id)) == 't'
callback = {k: reservation[k] for k in ['attempt_id', 'intent_id', 'reason_hash', 'payload_hash', 'recipient']}
api(wake_path + '/result', dict(callback, payload_hash='0' * 64, status='submitted', reason_codes=[], evidence_refs=['fixture:accepted']), token=host, status=409)
submitted = api(wake_path + '/result', dict(callback, status='submitted', reason_codes=[], evidence_refs=['fixture:accepted']), token=host)
assert submitted['attempt']['state'] == 'submitted'
assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(low_id)) == 't'
api(wake_path + '/result', dict(callback, status='submitted', reason_codes=[], evidence_refs=['fixture:conflicting']), token=host, status=409)
fences = {k: batch[k] for k in ['attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash']}
ack = dict(fences, kind='received', delivery_ids=batch['delivery_ids'], idempotency_key='wake-received')
api('workers/wake-seat/receipts', ack, token=receipt_token)
reconciled = api(wake_path + '/reconcile', callback, token=host)
assert reconciled['attempt']['state'] == 'submitted' and not reconciled['cooperation']['resolved']
ack.update(kind='handled', idempotency_key='wake-handled')
api('workers/wake-seat/receipts', ack, token=receipt_token)
reconciled = api(wake_path + '/reconcile', callback, token=host)
assert reconciled['attempt']['state'] == 'handled' and reconciled['cooperation']['resolved']
assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(low_id)) == 't'
print('Scoped host CAS, default-off admission, exact immutable retry, transport versus handling and receipt reuse PASS')

# A terminal old retry never regresses the new attempt or its audited intent.
retry_message = api('messages', {'to': 'wake-seat', 'task': 'wake-source',
    'body': 'Retry ownership fixture'}, agent='wake-sender')['message']
retry_intent = next(i for i in api(wake_path, token=host)['intents']
    if i['source']['kind'] == 'board_message' and i['source']['id'] == str(retry_message['id']))
a = api(wake_path + '/reserve', reserve_data(retry_intent, 'retry-a'), token=host)
a_callback = {k: a['reservation'][k] for k in callback}
a_result = dict(a_callback, status='not_submitted', reason_codes=['native_call_never_began'],
    evidence_refs=['fixture:' + str(i) + ':' + 'x' * 190 for i in range(3)])
a_recorded = api(wake_path + '/result', a_result, token=host)
assert a_recorded['attempt']['evidence_refs'] == a_result['evidence_refs']
retry_intent = next(i for i in api(wake_path, token=host)['intents'] if i['intent_id'] == retry_intent['intent_id'])
b = api(wake_path + '/reserve', reserve_data(retry_intent, 'retry-b'), token=host)
assert b['reservation'] is not None
api(wake_path + '/reserve', dict(reserve_data(retry_intent, 'retry-a'),
    intent_revision=a['reservation']['intent_revision']), token=host, status=409)
frozen = sql(reservation_snapshot)
frozen_wake = sql("SELECT jsonb_build_object('attempts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM wake_attempts a),'versions',(SELECT count(*) FROM wake_attempts_versions))")
api(wake_path + '/result', a_result, token=host)
assert api(wake_path + '/reconcile', a_callback, token=host)['cooperation']['historical']
assert sql(reservation_snapshot) == frozen
assert sql("SELECT jsonb_build_object('attempts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM wake_attempts a),'versions',(SELECT count(*) FROM wake_attempts_versions))") == frozen_wake
b_callback = {k: b['reservation'][k] for k in callback}
api(wake_path + '/result', dict(b_callback, status='not_submitted', reason_codes=['native_call_never_began'], evidence_refs=['fixture:no-call-b']), token=host)
api('messages/' + str(retry_message['id']) + '/read', {})
retry_intent = next(i for i in api(wake_path, token=host)['intents'] if i['intent_id'] == retry_intent['intent_id'])
refused = api(wake_path + '/reserve', reserve_data(retry_intent, 'read-source'), token=host)
assert refused['reservation'] is None and 'source_handled' in refused['reason_codes']
ordinary = api('workers/wake-seat/reserve', {'binding_epoch': 2, 'idempotency_key': 'no-wake-bypass'}, token=host)
if ordinary['batch'] is not None:
    assert not set(b['batch']['delivery_ids']) & set(ordinary['batch']['delivery_ids'])
    generic_fences = {k: ordinary['batch'][k] for k in ['attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash']}
    api('workers/wake-seat/result', dict(generic_fences, status='not_submitted', reason='fixture no native call'), token=host)
print('Superseded result/reconcile preserve current intent and canonical source cannot bypass wake admission PASS')

# Uncertain effects survive replacement. A callback carrying the old incarnation
# cannot modify a new reservation; historical reconciliation never grants replay.
pending = next(i for i in api(wake_path, token=host)['intents']
    if i['source']['id'] == str(later['id']) and i['source']['kind'] == 'board_message')
collision_snapshot = sql(reservation_snapshot)
collision_wakes = sql("SELECT count(*) FROM wake_attempts_versions")
api(wake_path + '/reserve', reserve_data(pending, 'no-wake-bypass'), token=host, status=409)
assert sql(reservation_snapshot) == collision_snapshot
assert sql("SELECT count(*) FROM wake_attempts_versions") == collision_wakes
uncertain = api(wake_path + '/reserve', reserve_data(pending, 'uncertain-effect'), token=host)
old = {k: uncertain['reservation'][k] for k in callback}
# Exercise the actual immutable lease clock, rather than manufacturing a frame
# or mutating its expiry in the DB. A timeout cannot prove non-submission.
expiry = datetime.datetime.fromisoformat(uncertain['batch']['lease_expires_at'])
remaining = (expiry - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
time.sleep(max(0, remaining) + 0.2)
expired = api(wake_path + '/reconcile', old, token=host)
assert expired['attempt']['state'] == 'uncertain' and not expired['cooperation']['replay_allowed']
assert sql("SELECT active_attempt_id IS NOT NULL FROM cooperation_bindings WHERE id='wake-seat'") == 't'
print('Actual 120-second frozen lease expiry retains uncertainty and forbids replay PASS', flush=True)
rebound = dict(bind_pi, idempotency_key='wake-pi-replacement', expected_epoch=2, session_id='replacement-pi-session')
api('workers/wake-seat/bind', rebound, token=host)
api(wake_path + '/result', dict(old, status='submitted', reason_codes=[], evidence_refs=['fixture:old-callback']), token=host, status=409)
history = api(wake_path + '/reconcile', old, token=host)
assert history['attempt']['state'] == 'uncertain' and history['cooperation']['historical']
assert history['cooperation']['replay_allowed'] is False
api('workers/wake-seat/revoke', {}, captain=captain)
api(wake_path + '/reconcile', old, token=host, status=401)
print('Lost acceptance, incarnation fencing, retained historical uncertainty and revoked credentials PASS')

# A real fallback wake answered before enrollment is elected once under its
# original source lock. No second answer DM, event, delivery or hash is created.
api('agents/register', {'name': 'Late fixture'}, agent='wake-late')
api('tasks', {'id': 'late-answer', 'title': 'Late answer fixture', 'repo': 'fixture/repo'}, agent='wake-late')
api('tasks/late-answer/claim', {}, agent='wake-late')
late_request = api('decisions', {'task': 'late-answer', 'kind': 'ask_user_gate',
    'gate': 'fixture/run/late-answer', 'question': 'Late enrollment?', 'findings': 'Invented',
    'options': ['Approve', 'Fix']}, agent='wake-late')['decision']
late_answer = api('decisions/' + late_request['id'] + '/answer', {'answer': 'Approved fixture'}, agent='captain', captain=captain)
assert late_answer['wake']['route'] == 'seat_watcher'
late_host = api('workers/provision', {'worker_id': 'wake-late', 'host_id': 'late-host',
    'repos': ['fixture/repo'], 'model': 'fixture', 'harness': 'codex', 'idempotency_key': 'late-enroll'}, captain=captain)['host_token']
late_bind = dict(bind_pi, expected_epoch=0, idempotency_key='late-bind', host_id='late-host')
api('workers/wake-late/bind', late_bind, token=late_host)
api('workers/wake-late/state', {'binding_epoch': 1, 'adapter_state': 'ready', 'connector_state': 'healthy'}, token=late_host)
late_path = 'hosts/late-host/wake-intents/wake-late'
late_intent = next(i for i in api(late_path, token=late_host)['intents'] if i['reason'] == 'decision_answered')
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    futures = [pool.submit(api, late_path + '/reserve', reserve_data(late_intent, 'late-daemon', late_path, late_host), token=late_host, status=(200, 409)),
        pool.submit(api, 'decisions/wakes/' + late_answer['wake']['id'] + '/reserve', {'key': 'fallback-watcher'}, agent='captain', captain=captain, status=(200, 409))]
    race = [f.result() for f in futures]
host_won = race[0].get('reservation') is not None
watcher_won = race[1].get('dispatch_allowed') is True
assert host_won != watcher_won, race
if host_won:
    assert sql("SELECT route FROM decision_wakes WHERE id='" + late_answer['wake']['id'] + "'") == 'worker'
    assert sql("SELECT count(*) FROM cooperation_events WHERE source_key='" + late_answer['wake']['source_key'] + "'") == '1'
    assert sql("SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.source_key='" + late_answer['wake']['source_key'] + "'") == '1'
assert sql("SELECT count(*) FROM wake_intents WHERE source_id='" + late_answer['wake']['id'] + "'") == '1'
assert sql("SELECT count(*) FROM messages WHERE id=" + str(late_answer['decision']['message_id'])) == '1'
print('Concurrent fallback watcher and late enrolled host elect exactly one answer owner PASS')

# Guarantee the host-first interleaving is covered even when the watcher wins
# the race above. Paused enrollment retains fallback until exact adoption.
if host_won:
    late_callback = {k: race[0]['reservation'][k] for k in callback}
    api(late_path + '/result', dict(late_callback, status='not_submitted', reason_codes=['native_call_never_began'], evidence_refs=['fixture:no-native-call']), token=late_host)
api('workers/wake-late/pause', {'binding_epoch': 1}, token=late_host)
api('tasks', {'id': 'late-host-first', 'title': 'Paused answer fixture', 'repo': 'fixture/repo'}, agent='wake-late')
api('tasks/late-host-first/claim', {}, agent='wake-late')
host_first_request = api('decisions', {'task': 'late-host-first', 'kind': 'ask_user_gate',
    'gate': 'fixture/run/host-first', 'question': 'Adopt original fallback?', 'findings': 'Invented',
    'options': ['Approve', 'Fix']}, agent='wake-late')['decision']
host_first = api('decisions/' + host_first_request['id'] + '/answer', {'answer': 'Approved fixture'}, agent='captain', captain=captain)
assert host_first['wake']['route'] == 'seat_watcher'
api('workers/wake-late/resume', {'binding_epoch': 1}, token=late_host)
host_intent = next(i for i in api(late_path, token=late_host)['intents'] if i['source']['id'] == host_first['wake']['id'])
adopted = api(late_path + '/reserve', reserve_data(host_intent, 'host-first', late_path, late_host), token=late_host)
assert adopted['reservation'] is not None
api('decisions/wakes/' + host_first['wake']['id'] + '/reserve', {'key': 'too-late-watcher'}, agent='captain', captain=captain, status=409)
assert sql("SELECT count(*) FROM cooperation_events WHERE source_key='" + host_first['wake']['source_key'] + "'") == '1'
assert sql("SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.source_key='" + host_first['wake']['source_key'] + "'") == '1'
print('Host-first adoption retains original answer source and fences the fallback watcher PASS')

# Public remote-built host CLI talks to the packaged real API. This owns the
# cross-language fence/scope and local custody boundary, not native admission.
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    token_path, config_path, journal_dir = root / 'host-token', root / 'host.json', root / 'journal'
    token_path.write_text(late_host + '\n')
    token_path.chmod(0o600)
    journal_dir.mkdir(mode=0o700)
    binding = {'agent_id': 'wake-late', 'model': 'fixture', 'harness': 'codex',
        'host_id': 'late-host', 'server_id': 'invented-server', 'session_id': late_bind['session_id'],
        'adapter_generation': late_bind['pane_id'], 'adapter': 'pi-native-v1',
        'socket_path': str(root / 'never-open.sock'), 'token_file': str(token_path),
        'binding_epoch': 1, 'repos': ['fixture/repo']}
    config = {'version': 1, 'url': os.environ['AGENTBOARD_URL'],
        'journal_dir': str(journal_dir), 'bindings': [binding]}
    config_path.write_text(json.dumps(config))
    config_path.chmod(0o600)
    journal = {'version': 1, 'reservation_key': 'host-first', 'phase': 'awaiting_receipt',
        'batch': adopted['batch'], 'outcome': 'uncertain', 'binding': binding}
    journal_path = journal_dir / 'wake-late.json'
    journal_path.write_text(json.dumps(journal))
    journal_path.chmod(0o600)
    journal_before, token_before = journal_path.read_bytes(), token_path.read_bytes()
    retained = sql(retained_query)
    attempts_before = sql('SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM wake_attempts a')

    def host_cli(*args, success=True):
        result = subprocess.run([os.environ['AB_BINARY'], 'host', *args, '--config', str(config_path), '--json'],
            capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        assert late_host not in result.stdout + result.stderr
        return result

    inspected = json.loads(host_cli('inspect').stdout)
    assert inspected['connector_state'] == 'dry_run' and inspected['wake']['journal_phase'] == 'awaiting_receipt'
    assert inspected['wake']['native_delivery_enabled'] is False
    assert journal_path.read_bytes() == journal_before and token_path.read_bytes() == token_before
    assert not pathlib.Path(binding['socket_path']).exists()
    assert sql(retained_query) == retained and sql('SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM wake_attempts a') == attempts_before
    # The same lock used by foreground Step refuses a simultaneous host read;
    # no parallel native owner or replacement journal can be created.
    with (journal_dir / 'wake-late.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        host_cli('inspect', success=False)
        process = subprocess.Popen([os.environ['AB_BINARY'], 'host', 'run', '--config', str(config_path), '--json'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        report = json.loads(process.stdout.readline())
        assert report['connector_state'] == 'degraded'
        process.terminate()
        process.communicate(timeout=10)
    assert journal_path.read_bytes() == journal_before
    assert json.loads(host_cli('inspect').stdout)['wake']['journal_phase'] == 'awaiting_receipt'
    host_cli('run', '--dry-run=false', success=False)
    for scopes in [[], ['elsewhere/private']]:
        binding['repos'] = scopes
        config_path.write_text(json.dumps(config))
        host_cli('inspect', success=False)
    binding['repos'] = ['fixture/repo']
    binding['session_id'] = 'replaced-local-session'
    config_path.write_text(json.dumps(config))
    host_cli('inspect', success=False)
    assert journal_path.read_bytes() == journal_before and token_path.read_bytes() == token_before
    # Actual unit bytes are independently parsed; preview cannot create or
    # overwrite foreign supervision, hooks, credentials or pending journals.
    home = root / 'preview home & owner'
    for platform in ['linux', 'darwin']:
        plan = json.loads(host_cli('install', '--platform', platform, '--home', str(home)).stdout)
        assert plan['applied'] is False and len(plan['contents']) == 1
        target, contents = next(iter(plan['contents'].items()))
        assert not pathlib.Path(target).exists()
        if platform == 'darwin':
            parsed = plistlib.loads(contents.encode())
            argv = parsed['ProgramArguments']
        else:
            parsed = configparser.ConfigParser(interpolation=None)
            parsed.read_string(contents)
            argv = shlex.split(parsed['Service']['ExecStart'])
        assert argv[1:4] == ['host', 'run', '--dry-run'] and argv[-1] == str(config_path)
        assert hashlib.sha256(contents.encode()).hexdigest() == plan['files'][0]['sha256']
        pathlib.Path(target).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(target).write_text('foreign integration retained')
        host_cli('install', '--platform', platform, '--home', str(home), success=False)
        assert pathlib.Path(target).read_text() == 'foreign integration retained'
    assert sql(retained_query) == retained
print('Public host shadow CLI, protected token refs, scopes, shared custody, restart and parsed supervision preview PASS')

# Repository scope belongs to the canonical task, never subscription order or
# the only enrolled repository. Excluded legacy/foreign rows cannot starve a page.
api('agents/register', {'name': 'Scope fixture'}, agent='wake-scope')
api('tasks', {'id': 'scope-canonical', 'title': 'Scope fixture', 'repo': 'scope/right'})
api('tasks', {'id': 'scope-foreign', 'title': 'Foreign scope fixture', 'repo': 'scope/foreign'})
sql("INSERT INTO messages(sender_id,recipient_id,model,harness,body,created_at) SELECT 'wake-sender','wake-scope','fixture','codex','Legacy taskless '||n,clock_timestamp() FROM generate_series(1,40) n")
sql("INSERT INTO messages(sender_id,recipient_id,task_id,model,harness,body,created_at) SELECT 'wake-sender','wake-scope','scope-foreign','fixture','codex','Foreign '||n,clock_timestamp() FROM generate_series(1,40) n")
scope_message = sql("INSERT INTO messages(sender_id,recipient_id,task_id,model,harness,body,created_at) VALUES ('wake-sender','wake-scope','scope-canonical','fixture','codex','Scoped after legacy backlog',clock_timestamp()) RETURNING id")
for scopes in [['scope/empty'], [], ['scope/empty', 'scope/right'], ['scope/right', 'scope/empty']]:
    result = rpc('{:ok, value} = Agentboard.WakeIntents.reconcile("wake-scope", ' + json.dumps(scopes) + ', 1); value')
    assert result['messages'] == (1 if scopes == ['scope/empty', 'scope/right'] else 0), result
assert sql("SELECT count(*) FROM wake_intents WHERE recipient_id='wake-scope'") == '1'
assert sql("SELECT repo FROM wake_intents WHERE recipient_id='wake-scope'") == 'scope/right'
scope_provision = {'worker_id': 'wake-scope', 'host_id': 'scope-host', 'repos': ['scope/empty', 'scope/right'],
    'model': 'fixture', 'harness': 'codex', 'idempotency_key': 'scope-provision'}
scope_token = api('workers/provision', scope_provision, captain=captain)['host_token']
scope_snapshot = sql("SELECT jsonb_agg(to_jsonb(i)) FROM wake_intents i WHERE recipient_id='wake-scope'")
# Runtime scope mutations are fixture-only; public rotation intentionally retains
# scopes. Exercise the reader/reconciler against changing current subscriptions.
for scopes in [['scope/right', 'scope/empty'], ['scope/empty'], ['scope/right']]:
    sql("UPDATE cooperation_subscriptions SET repos=ARRAY[" + ','.join("'" + x + "'" for x in scopes) + "] WHERE id='wake-scope'")
    rpc('{:ok, value} = Agentboard.WakeIntents.reconcile("wake-scope", ' + json.dumps(scopes) + ', 1); value')
    rows = api('workers/wake-scope/wake_intents', token=scope_token)['intents']
    assert len(rows) == (1 if 'scope/right' in scopes else 0), rows
    assert sql("SELECT jsonb_agg(to_jsonb(i)) FROM wake_intents i WHERE recipient_id='wake-scope'") == scope_snapshot
assert sql("SELECT count(*) FROM messages WHERE recipient_id='wake-scope' AND read_at IS NULL") == '81'
# Changed canonical scope invalidates the retained occurrence rather than moving it.
sql("UPDATE tasks SET repo='scope/changed' WHERE id='scope-canonical'")
row = api('workers/wake-scope/wake_intents', token=scope_token)['intents'][0]
assert row['source']['id'] == scope_message and row['source_state'] == 'suppressed'
print('Task-only scope, legacy backlog starvation, subscription reorder/change and canonical scope drift PASS')

# Canonical decision answering works for legacy/unscoped tasks; lack of a wake
# repository must not roll back the answer or replace its existing fallback.
api('agents/register', {'name': 'Unscoped decision fixture'}, agent='wake-unscoped')
for suffix, repo in [('nil', None), ('invalid', 'not a repository')]:
    task_id = 'unscoped-decision-' + suffix
    task_data = {'id': task_id, 'title': 'Unscoped decision'}
    if repo is not None:
        task_data['repo'] = repo
    api('tasks', task_data, agent='wake-unscoped')
    api('tasks/' + task_id + '/claim', {}, agent='wake-unscoped')
    question = api('decisions', {'task': task_id, 'kind': 'ask_user_gate',
        'gate': 'fixture/unscoped/' + suffix, 'question': 'Keep legacy answer?',
        'findings': 'Invented', 'options': ['Approve', 'Fix']}, agent='wake-unscoped')['decision']
    answered = api('decisions/' + question['id'] + '/answer', {'answer': 'Approved fixture'},
        agent='captain', captain=captain)
    assert answered['decision']['status'] == 'answered'
    assert answered['wake']['route'] == 'seat_watcher'
    assert sql("SELECT status FROM decision_requests WHERE id='" + question['id'] + "'") == 'answered'
    assert sql("SELECT count(*) FROM wake_intents WHERE source_id='" + answered['wake']['id'] + "'") == '0'
print('Unscoped/invalid-repository decision answers retain canonical fallback without scoped intent PASS')

# Deterministically exercise real routing's event->worker lock wait against the
# FK check needed by worker-owned wake/bootstrap delivery adoption (worker->event).
api('agents/register', {'name': 'FK lock fixture'}, agent='wake-lock')
api('workers/provision', {'worker_id': 'wake-lock', 'host_id': 'lock-host',
    'repos': ['lock/repo'], 'model': 'fixture', 'harness': 'codex',
    'idempotency_key': 'lock-provision'}, captain=captain)
rpc('Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end); true')
worker_key = int.from_bytes(hashlib.sha256(b'agentboard-worker:wake-lock').digest()[:8], 'big', signed=True)
owner = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
owner.stdin.write("BEGIN; SELECT pg_advisory_xact_lock(" + str(worker_key) + "); SELECT id FROM cooperation_subscriptions WHERE id='wake-lock' FOR UPDATE; SELECT 'LOCKED';\n")
owner.stdin.flush()
while owner.stdout.readline().strip() != 'LOCKED':
    assert owner.poll() is None, owner.stderr.read()
event_id = rpc('''{:ok, event} = Agentboard.Board.Operations.transaction(fn ->
  Agentboard.Cooperation.Runtime.capture(%{source_key: "wake-lock-race", kind: "unread_dm",
    repo: "lock/repo", task_id: nil, summary: "Invented lock fixture", source_url: "/fixture",
    priority: 1}, recipient: "wake-lock")
end); event.id''')
with concurrent.futures.ThreadPoolExecutor(1) as pool:
    routing = pool.submit(rpc, '''{:ok, value} = Agentboard.Board.Operations.transaction(fn ->
      Agentboard.Repo.statement!("SET LOCAL application_name = 'wake-route-fk-regression'", [])
      Agentboard.Cooperation.Runtime.route()
    end); value''')
    deadline = time.monotonic() + 15
    while sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='wake-route-fk-regression' AND wait_event='advisory'") != '1':
        assert time.monotonic() < deadline, 'Actual router did not reach the worker-lock wait'
        time.sleep(0.05)
    owner.stdin.write("SET LOCAL lock_timeout='2s'; INSERT INTO cooperation_deliveries(id,event_id,worker_id,state,created_at) VALUES (gen_random_uuid(),'" + event_id + "','wake-lock','pending',clock_timestamp()); COMMIT;\n")
    owner.stdin.flush()
    owner.stdin.close()
    assert owner.wait(timeout=10) == 0, owner.stderr.read()
    assert routing.result(timeout=15)['routed_pages'] >= 1
assert sql("SELECT count(*) FROM cooperation_deliveries WHERE event_id='" + event_id + "'") == '1'
assert sql("SELECT routed FROM cooperation_events WHERE id='" + event_id + "'") == 't'
print('Actual router/worker-owned FK adoption lock inversion regression and unique delivery PASS')
