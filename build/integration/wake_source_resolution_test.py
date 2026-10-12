"""Exact-attempt canonical wake resolution at the packaged HTTP/Postgres boundary.

All agents, claims, messages and capabilities are invented. A frozen transport
notice identifies work; only an authenticated, current, exact-attempt resolver
may disclose canonical material, and neither resolution nor replay consumes it.
"""
import concurrent.futures
import copy
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def sql(statement):
    return subprocess.check_output(
        [os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', statement],
        text=True).strip()


def rpc(expression):
    script = 'value = (' + expression + '); IO.puts("SOURCE_RESULT:" <> Jason.encode!(value))'
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', script],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split(':', 1)[1] for line in result.stdout.splitlines()
                           if line.startswith('SOURCE_RESULT:')))


def api(path, data=None, agent='resolve-sender', token=None, captain=False, status=200):
    headers = {'Content-Type': 'application/json', 'x-agentboard-agent': agent,
               'x-agentboard-model': 'fixture', 'x-agentboard-harness': 'codex',
               'x-agentboard-worker-protocol': '1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
        if not token:
            headers['Authorization'] = 'Bearer ' + CAPTAIN
    request = urllib.request.Request(os.environ['AGENTBOARD_URL'] + '/api/v1/' + path,
        data=json.dumps(data).encode() if data is not None else None, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = json.load(response)
        assert response.status == status, (path, response.status, body)
        return body


CAPTAIN = 'invented-exact-source-captain-token-32'
CAPABILITIES = {name: {'supported': True} for name in
                ['idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery']}
TABLES = ['messages', 'tasks', 'decision_requests', 'decision_wakes',
          'wake_intents', 'wake_intents_versions', 'wake_attempts', 'wake_attempts_versions',
          'cooperation_subscriptions', 'cooperation_bindings', 'cooperation_events',
          'cooperation_deliveries', 'cooperation_batches', 'cooperation_attempts',
          'cooperation_receipts']


def snapshot(tables=TABLES):
    # JSON has deterministic array ordering and includes complete records. Even
    # updated_at, an implicit received receipt, or a retained audit write matters.
    return sql('SELECT jsonb_build_object(' + ','.join(
        "'" + table + "',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM " + table + ' t)'
        for table in tables) + ')')


def worker(name):
    identity = 'resolve-' + name
    host_id = name + '-host'
    api('agents/register', {'name': 'Invented source fixture ' + name}, agent=identity)
    provision = api('workers/provision', {'worker_id': identity, 'host_id': host_id,
        'repos': ['fixture/exact-source'], 'model': 'fixture', 'harness': 'codex',
        'idempotency_key': name + '-enroll'}, captain=True)
    bound = api('workers/' + identity + '/bind', {'idempotency_key': name + '-bind',
        'expected_epoch': 0, 'host_id': host_id, 'session_id': name + '-session',
        'pane_id': name + '-generation', 'adapter': 'pi-native-v1',
        'adapter_version': 'pi-native-v1', 'capabilities': CAPABILITIES},
        token=provision['host_token'])
    result = {'id': identity, 'host_id': host_id, 'host': provision['host_token'],
              'receipt': bound['receipt_token'], 'epoch': 1,
              'path': 'hosts/' + host_id + '/wake-intents/' + identity}
    ready(result)
    return result


def ready(owner):
    api('workers/' + owner['id'] + '/state', {'binding_epoch': owner['epoch'],
        'adapter_state': 'ready', 'connector_state': 'healthy'}, token=owner['host'])


def task(owner, suffix='source'):
    task_id = owner['id'] + '-' + suffix
    api('tasks', {'id': task_id, 'title': 'Invented canonical ' + suffix,
                  'description': 'Canonical task detail ' + task_id,
                  'repo': 'fixture/exact-source'}, agent=owner['id'])
    return task_id


def message(owner, suffix='source'):
    task_id = task(owner, suffix)
    body = 'Canonical private message for ' + owner['id'] + '/' + suffix
    value = api('messages', {'to': owner['id'], 'task': task_id, 'body': body})['message']
    return value


def intent(owner, source_id, kind):
    return next(row for row in api(owner['path'], token=owner['host'])['intents']
                if row['source']['id'] == str(source_id) and row['source']['kind'] == kind)


def reserve(owner, source_id, kind='board_message', key='reserve'):
    ready(owner)
    row = intent(owner, source_id, kind)
    state = api(owner['path'], token=owner['host'])['readiness']
    data = {'intent_id': row['intent_id'], 'intent_revision': row['intent_revision'],
            'reason_hash': row['reason_hash'], 'idempotency_key': key,
            'enrollment_revision': state['enrollment_revision'],
            'binding_epoch': state['binding_epoch'], 'session_id': state['session_id'],
            'adapter_generation': state['adapter_generation']}
    value = api(owner['path'] + '/reserve', data, token=owner['host'])
    assert value['reservation'] is not None, value
    return value


def callback(reserved):
    return {key: reserved['reservation'][key] for key in
            ['attempt_id', 'intent_id', 'reason_hash', 'payload_hash', 'recipient']}


def receipt_data(reserved, kind='received', key='received'):
    batch = reserved['batch']
    data = {key: batch[key] for key in
            ['attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash']}
    return dict(data, kind=kind, delivery_ids=batch['delivery_ids'], idempotency_key=key)


def resolve(owner, reserved, reason=None, token=None):
    before = snapshot()
    value = api(owner['path'] + '/resolve', callback(reserved), token=token or owner['host'])
    assert snapshot() == before, 'Resolution mutated canonical, transport, receipt or audit state'
    assert value['reservation'] == reserved['reservation']
    if reason is None:
        assert value['actionable'] is True and value['reason_codes'] == [], value
        assert value['source'] is not None, value
        for key in ['kind', 'id', 'version']:
            assert value['source'][key] == reserved['reservation']['source'][key], value
    else:
        assert value['actionable'] is False and value['source'] is None, value
        assert reason in value['reason_codes'], value
    return value


def deny_receipt(owner, reserved, kind='received', key='rejected-receipt'):
    before = snapshot()
    api('workers/' + owner['id'] + '/receipts', receipt_data(reserved, kind, key),
        token=owner['receipt'], status=409)
    assert snapshot() == before, 'Rejected receipt changed canonical or delivery state'


def result(owner, reserved, status='submitted', key='fixture-acceptance'):
    value = dict(callback(reserved), status=status, reason_codes=[], evidence_refs=['fixture:' + key])
    return api(owner['path'] + '/result', value, token=owner['host'])




def cli_resolve(owner, reserved, expected):
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        token_file = root / 'token'
        receipt_file = root / 'token.receipt'
        receipt_file.write_text(owner['receipt'] + '\n')
        receipt_file.chmod(0o600)
        recipient = reserved['reservation']['recipient']
        binding = {'agent_id': owner['id'], 'model': 'fixture', 'harness': 'codex',
            'host_id': owner['host_id'], 'server_id': 'invented-server',
            'session_id': recipient['session_id'], 'adapter_generation': recipient['adapter_generation'],
            'adapter': 'pi-native-v1', 'socket_path': str(root / 'absent.sock'),
            'token_file': str(token_file), 'binding_epoch': recipient['binding_epoch'],
            'repos': ['fixture/exact-source']}
        config_path = root / 'worker.json'
        config_path.write_text(json.dumps({'version': 1, 'url': os.environ['AGENTBOARD_URL'],
            'journal_dir': str(root / 'journal'), 'bindings': [binding]}))
        config_path.chmod(0o600)
        input_path = root / 'callback.json'
        input_path.write_text(json.dumps(callback(reserved)))
        before_files = {path.name: path.read_bytes() for path in root.iterdir()}
        before = snapshot()
        environment = dict(os.environ, AGENT_ID=owner['id'], AGENTBOARD_TOKEN='',
                           AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE='')
        command = [os.environ['AB_BINARY'], 'worker', '--config', str(config_path),
            '--worker-id', owner['id'], '--session-id', recipient['session_id'],
            '--adapter-generation', recipient['adapter_generation'], '--json',
            'wake-resolve', '--input-file', str(input_path)]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=15, env=environment)
        assert completed.returncode == 0, (completed.stdout, completed.stderr)
        assert owner['receipt'] not in completed.stdout + completed.stderr
        assert owner['host'] not in completed.stdout + completed.stderr
        actual = json.loads(completed.stdout)
        assert actual['actionable'] == expected['actionable']
        assert actual['source'] == expected['source']
        assert actual['reason_codes'] == expected['reason_codes']
        assert actual['reservation'] == expected['reservation']
        assert snapshot() == before
        assert {path.name: path.read_bytes() for path in root.iterdir()} == before_files
        assert not (root / 'journal').exists() and not (root / 'absent.sock').exists()

def generic_decision(name):
    owner = worker('generic-' + name)
    canonical_task = task(owner)
    api('tasks/' + canonical_task + '/claim', {}, agent=owner['id'])
    request = api('decisions', {'task': canonical_task, 'kind': 'ask_user_gate',
        'gate': 'fixture/generic/' + name, 'question': 'Generic decision source?',
        'findings': 'Invented generic decision', 'options': ['Approve', 'Fix']},
        agent=owner['id'])['decision']
    answer = api('decisions/' + request['id'] + '/answer', {'answer': 'Generic canonical answer'},
                 agent='captain', captain=True)
    generic = api('workers/' + owner['id'] + '/reserve',
                  {'binding_epoch': 1, 'idempotency_key': 'generic-reserve'}, token=owner['host'])
    assert generic['batch'] is not None, generic
    batch = generic['batch']
    assert sql("SELECT count(*) FROM wake_attempts WHERE id='" + batch['attempt_id'] + "'") == '0'
    delivery_id = sql("SELECT id FROM cooperation_deliveries WHERE worker_id='" + owner['id'] +
                      "' AND event_id='" + answer['wake']['worker_event_id'] + "'")
    assert delivery_id in batch['delivery_ids'], generic
    data = receipt_data(generic, key='generic-received')
    data['delivery_ids'] = [delivery_id]
    first = api('workers/' + owner['id'] + '/receipts', data, token=owner['receipt'])
    return owner, generic, delivery_id, data, first, request



def wait_for_claim(task_id):
    deadline = time.monotonic() + 15
    while sql("SELECT claim_expires_at <= clock_timestamp() FROM tasks WHERE id='" + task_id + "'") != 't':
        assert time.monotonic() < deadline, 'Claim did not expire at its canonical deadline'
        time.sleep(0.05)

def wait_for_lease(batch):
    deadline = time.monotonic() + 125
    while sql("SELECT lease_expires_at <= clock_timestamp() FROM cooperation_batches WHERE id='" + batch['batch_id'] + "'") != 't':
        assert time.monotonic() < deadline, 'Frozen 120-second lease did not expire'
        time.sleep(0.1)

rpc('Application.put_env(:agentboard, :captain_token, "' + CAPTAIN + '"); '
    'Application.put_env(:agentboard, :cooperation_enabled, true); '
    'Application.put_env(:agentboard, :wake_delivery_enabled, true); true')
api('agents/register', {'name': 'Invented sender'})
api('agents/register', {'name': 'Invented captain'}, agent='captain')

# Start real immutable 120-second lease clocks before the other cases. Their
# expiry checks run last; no fixture alters a frozen batch or disables a trigger.
expiring = worker('lease')
lease_source = message(expiring)
lease_attempt = reserve(expiring, lease_source['id'])
resolve(expiring, lease_attempt)
generic_expiry = generic_decision('expired')

# The complete owner handshake: canonical occurrence -> exact reservation ->
# immutable notice/ref -> non-consuming resolution -> explicit received/handled.
owner = worker('roundtrip')
source = message(owner)
reserved = reserve(owner, source['id'])
reservation, batch = reserved['reservation'], reserved['batch']
assert source['body'] not in batch['payload']
assert hashlib.sha256(batch['payload'].encode()).hexdigest() == batch['payload_hash']
expected_ref = {key: reservation['source'][key] for key in ['kind', 'id', 'version']}
expected_ref['delivery_id'] = batch['delivery_ids'][0]
assert reservation['source_refs'] == [expected_ref]
assert reservation['source']['task_id'] == source['task_id']
resolved = resolve(owner, reserved)
assert resolved['source']['message']['id'] == source['id']
assert resolved['source']['message']['body'] == source['body']
assert resolve(owner, reserved, token=owner['receipt']) == resolved
cli_resolve(owner, reserved, resolved)
# A lost HTTP response is retried byte-for-byte, with no received receipt hidden
# in a successful source fetch and no canonical read mutation.
assert resolve(owner, reserved) == resolved
assert sql("SELECT count(*) FROM cooperation_receipts WHERE worker_id='" + owner['id'] + "'") == '0'
assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(source['id'])) == 't'
assert sql("SELECT state FROM cooperation_deliveries WHERE id='" + batch['delivery_ids'][0] + "'") == 'pending'

# Attribution headers are not authority; callbacks must bind every exact fence.
api(owner['path'] + '/resolve', callback(reserved), agent=owner['id'], status=401)
api(owner['path'].replace(owner['host_id'], 'foreign-host') + '/resolve', callback(reserved),
    token=owner['host'], status=403)
for field, replacement in [('intent_id', '00000000-0000-0000-0000-000000000000'),
                           ('reason_hash', '0' * 64), ('payload_hash', '0' * 64)]:
    before = snapshot()
    api(owner['path'] + '/resolve', dict(callback(reserved), **{field: replacement}),
        token=owner['host'], status=409)
    assert snapshot() == before
for field in ['agent_id', 'host_id', 'repo', 'session_id', 'adapter_generation']:
    changed = copy.deepcopy(callback(reserved))
    changed['recipient'][field] = 'foreign-' + field
    api(owner['path'] + '/resolve', changed, token=owner['host'], status=409)
for field in ['enrollment_revision', 'binding_epoch']:
    changed = copy.deepcopy(callback(reserved))
    changed['recipient'][field] += 1
    api(owner['path'] + '/resolve', changed, token=owner['host'], status=409)
missing = callback(reserved)
del missing['reason_hash']
api(owner['path'] + '/resolve', missing, token=owner['host'], status=422)
api(owner['path'] + '/resolve', dict(callback(reserved), body='forged canonical text'),
    token=owner['host'], status=422)
result(owner, reserved, 'uncertain', 'uncertain-native-outcome')
assert resolve(owner, reserved)['source']['message']['body'] == source['body']
result(owner, reserved)
assert resolve(owner, reserved)['source']['message']['body'] == source['body']
received_data = receipt_data(reserved)
received = api('workers/' + owner['id'] + '/receipts', received_data, token=owner['receipt'])
assert received['idempotent'] is False
assert sql("SELECT state FROM cooperation_deliveries WHERE id='" + batch['delivery_ids'][0] + "'") == 'received'
assert resolve(owner, reserved)['source']['message']['body'] == source['body']
handled_data = receipt_data(reserved, 'handled', 'handled')
handled = api('workers/' + owner['id'] + '/receipts', handled_data, token=owner['receipt'])
assert handled['idempotent'] is False
assert sql("SELECT state FROM cooperation_deliveries WHERE id='" + batch['delivery_ids'][0] + "'") == 'handled'
assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(source['id'])) == 't'
reconciled = api(owner['path'] + '/reconcile', callback(reserved), token=owner['host'])
assert reconciled['attempt']['state'] == 'handled' and reconciled['cooperation']['resolved']
resolve(owner, reserved, 'attempt_not_current')
before = snapshot()
replayed = api('workers/' + owner['id'] + '/receipts', handled_data, token=owner['receipt'])
assert replayed['idempotent'] and replayed['receipt'] == handled['receipt']
assert snapshot() == before
print('Exact source handshake, immutable notice, current credentials, lost-response replay and explicit receipts PASS', flush=True)

# Retained source versions may become obsolete while their notice is in flight.
# Denial must withhold material and must not suppress/handle the retained delivery.
for mutation in ['version', 'handled', 'scope', 'task']:
    current = worker(mutation)
    original = message(current)
    attempt = reserve(current, original['id'])
    assert resolve(current, attempt)['source']['message']['body'] == original['body']
    if mutation == 'version':
        sql("UPDATE messages SET created_at=created_at + interval '1 second', "
            "body='Newer canonical text must not leak' WHERE id=" + str(original['id']))
        reason = 'source_suppressed'
    elif mutation == 'handled':
        api('messages/' + str(original['id']) + '/read', {}, agent=current['id'])
        reason = 'source_handled'
    elif mutation == 'scope':
        sql("UPDATE tasks SET repo='elsewhere/private' WHERE id='" + original['task_id'] + "'")
        reason = 'source_suppressed'
    else:
        other_task = task(current, 'moved')
        sql("UPDATE messages SET task_id='" + other_task + "' WHERE id=" + str(original['id']))
        reason = 'source_suppressed'
    denied = resolve(current, attempt, reason)
    if mutation == 'version':
        cli_resolve(current, attempt, denied)
    assert original['body'] not in json.dumps(denied)
    assert 'Newer canonical text must not leak' not in json.dumps(denied)
    deny_receipt(current, attempt)
    deny_receipt(current, attempt, 'handled', 'rejected-handled')
print('Stale source version, canonical handling and repository drift withhold material and reject receipt mutation PASS', flush=True)

# The receipt idempotency branch is evidence, not a new action. It still returns
# its original record after the source becomes invalid; a new receipt must fail.
replay_owner = worker('replay')
replay_source = message(replay_owner)
replay_attempt = reserve(replay_owner, replay_source['id'])
replay_data = receipt_data(replay_attempt)
first = api('workers/' + replay_owner['id'] + '/receipts', replay_data, token=replay_owner['receipt'])
api('messages/' + str(replay_source['id']) + '/read', {}, agent=replay_owner['id'])
resolve(replay_owner, replay_attempt, 'source_handled')
before = snapshot()
again = api('workers/' + replay_owner['id'] + '/receipts', replay_data, token=replay_owner['receipt'])
assert again['idempotent'] and again['receipt'] == first['receipt']
assert snapshot() == before
deny_receipt(replay_owner, replay_attempt, 'handled', 'new-handled')
print('Lost receipt response replays original evidence after source invalidation without reapplying it PASS', flush=True)

# A claim warning refers to one exact live expiry and owner. Public renewal and
# handoff invalidate it; wall-clock expiry is tested without changing its version.
for mutation in ['renewed', 'transferred', 'expired']:
    claimant = worker('claim-' + mutation)
    claimed_task = task(claimant)
    api('tasks/' + claimed_task + '/claim', {'ttl_seconds': 10 if mutation == 'expired' else 600},
        agent=claimant['id'])
    claim_attempt = reserve(claimant, claimed_task, 'task_claim')
    value = resolve(claimant, claim_attempt)
    assert value['source']['task']['id'] == claimed_task
    assert value['source']['task']['assignee_id'] == claimant['id']
    if mutation == 'renewed':
        api('tasks/' + claimed_task + '/renew', {'ttl_seconds': 7200}, agent=claimant['id'])
    elif mutation == 'transferred':
        api('tasks/' + claimed_task + '/handoff',
            {'to': 'resolve-sender', 'note': 'Invented claim transfer for exact-source fixture'},
            agent=claimant['id'])
    else:
        wait_for_claim(claimed_task)
    resolve(claimant, claim_attempt, 'source_suppressed')
    deny_receipt(claimant, claim_attempt)
print('Exact claim version, transferred ownership and natural claim expiration gate source and receipts PASS', flush=True)

# A current task assignment can materialize fresh editable task details without
# changing its exact assignment occurrence. Claiming consumes that assignment.
assigned_owner = worker('assigned')
assigned_task = task(assigned_owner)
api('agents/' + assigned_owner['id'] + '/heartbeat', {'status': 'idle'}, agent=assigned_owner['id'])
api('tasks/' + assigned_task + '/assign', {'to': assigned_owner['id']}, captain=True)
assigned_attempt = reserve(assigned_owner, assigned_task, 'task_assignment')
assert resolve(assigned_owner, assigned_attempt)['source']['task']['status'] == 'assigned'
api('tasks/' + assigned_task + '/edit', {'title': 'Current editable assignment title'})
assert resolve(assigned_owner, assigned_attempt)['source']['task']['title'] == 'Current editable assignment title'
api('tasks/' + assigned_task + '/claim', {}, agent=assigned_owner['id'])
resolve(assigned_owner, assigned_attempt, 'source_suppressed')
deny_receipt(assigned_owner, assigned_attempt)
print('Exact assignment occurrence resolves current task details and becomes inert after claim PASS', flush=True)

# Decision material requires the current task claim, even though the immutable
# decision answer version itself still matches. Public transitions intentionally
# refuse transferring a held decision, so SQL supplies the legacy/stale fixture.
for mutation in ['live', 'expired', 'transferred']:
    decider = worker('decision-' + mutation)
    decision_task = task(decider)
    api('tasks/' + decision_task + '/claim',
        {'ttl_seconds': 10 if mutation == 'expired' else 7200}, agent=decider['id'])
    request = api('decisions', {'task': decision_task, 'kind': 'ask_user_gate',
        'gate': 'fixture/source/' + mutation, 'question': 'Canonical question ' + mutation + '?',
        'findings': 'Invented decision findings', 'options': ['Approve', 'Fix']},
        agent=decider['id'])['decision']
    answer = api('decisions/' + request['id'] + '/answer',
                 {'answer': 'Canonical answer ' + mutation}, agent='captain', captain=True)
    decision_attempt = reserve(decider, answer['wake']['id'], 'decision_wake')
    detail = resolve(decider, decision_attempt)['source']
    assert detail['decision']['id'] == request['id']
    assert detail['decision']['answer'] == 'Canonical answer ' + mutation
    if mutation == 'live':
        api('workers/' + decider['id'] + '/receipts', receipt_data(decision_attempt), token=decider['receipt'])
        assert sql("SELECT status FROM decision_requests WHERE id='" + request['id'] + "'") == 'answered'
        api('decisions/' + request['id'] + '/ack', {}, agent=decider['id'])
        resolve(decider, decision_attempt, 'source_handled')
    else:
        if mutation == 'expired':
            wait_for_claim(decision_task)
        else:
            sql("UPDATE tasks SET assignee_id='resolve-sender' WHERE id='" + decision_task + "'")
        denied = resolve(decider, decision_attempt, 'source_suppressed')
        assert 'Canonical answer ' + mutation not in json.dumps(denied)
        deny_receipt(decider, decision_attempt)
print('Canonical decision answer resolution requires the current live task claim and never applies an answer PASS', flush=True)

# Eligibility can change after reservation. Resolution and new exact receipts
# share the fresh gate, while a paused source is still canonically pending.
control = worker('controls')
control_source = message(control)
control_attempt = reserve(control, control_source['id'])
api('workers/' + control['id'] + '/pause', {'binding_epoch': 1}, token=control['host'])
resolve(control, control_attempt, 'paused')
deny_receipt(control, control_attempt)
api('workers/' + control['id'] + '/resume', {'binding_epoch': 1}, token=control['host'])
resolve(control, control_attempt)
api('availability', {'agent_id': control['id'], 'state': 'out_of_service',
                     'reason': 'Invented current admission change'}, captain=True)
resolve(control, control_attempt, 'agent_unavailable')
deny_receipt(control, control_attempt)
api('availability', {'agent_id': control['id'], 'state': 'active'}, captain=True)
rpc('Application.put_env(:agentboard, :cooperation_enabled, false); true')
resolve(control, control_attempt, 'cooperation_disabled')
deny_receipt(control, control_attempt)
rpc('Application.put_env(:agentboard, :cooperation_enabled, true); true')
sql("UPDATE cooperation_bindings SET capabilities=jsonb_set(capabilities, '{receipt,supported}', 'false') WHERE id='" + control['id'] + "'")
resolve(control, control_attempt, 'receipt_unsupported')
deny_receipt(control, control_attempt)
sql("UPDATE cooperation_bindings SET capabilities=jsonb_set(capabilities, '{receipt,supported}', 'true') WHERE id='" + control['id'] + "'")
resolve(control, control_attempt)
api('workers/' + control['id'] + '/revoke', {}, captain=True)
before = snapshot()
api(control['path'] + '/resolve', callback(control_attempt), token=control['host'], status=401)
api(control['path'] + '/resolve', callback(control_attempt), token=control['receipt'], status=401)
assert snapshot() == before
print('Pause, availability, runtime enablement, receipt capability and revocation enforce current eligibility PASS', flush=True)

# A new binding does not inherit the old recipient's authority or source text.
replacement = worker('replacement')
old_source = message(replacement)
old_attempt = reserve(replacement, old_source['id'])
old_receipt_token = replacement['receipt']
new_bind = api('workers/' + replacement['id'] + '/bind', {'idempotency_key': 'replacement-bind-2',
    'expected_epoch': 1, 'host_id': replacement['host_id'], 'session_id': 'replacement-session-2',
    'pane_id': 'replacement-generation-2', 'adapter': 'pi-native-v1',
    'adapter_version': 'pi-native-v1', 'capabilities': CAPABILITIES}, token=replacement['host'])
replacement.update(epoch=2, receipt=new_bind['receipt_token'])
ready(replacement)
resolve(replacement, old_attempt, 'historical_recipient')
resolve(replacement, old_attempt, 'historical_recipient', token=replacement['receipt'])
before = snapshot()
api(replacement['path'] + '/resolve', callback(old_attempt), token=old_receipt_token, status=403)
api('workers/' + replacement['id'] + '/receipts', receipt_data(old_attempt),
    token=replacement['receipt'], status=409)
assert snapshot() == before
print('Replacement epoch preserves old evidence while withholding old source authority from both incarnations PASS', flush=True)

# Re-enrollment changes authority even when the physical binding epoch, session
# and adapter generation stay unchanged. A newly issued host capability cannot
# revive an attempt reserved under the prior enrollment revision.
reenrolled = worker('reenrolled')
reenroll_source = message(reenrolled)
reenroll_attempt = reserve(reenrolled, reenroll_source['id'])
old_host, old_receipt = reenrolled['host'], reenrolled['receipt']
api('workers/' + reenrolled['id'] + '/revoke', {}, captain=True)
new_enrollment = api('workers/provision', {'worker_id': reenrolled['id'],
    'host_id': reenrolled['host_id'], 'repos': ['fixture/exact-source'],
    'model': 'fixture', 'harness': 'codex', 'idempotency_key': 'new-enrollment'}, captain=True)
reenrolled['host'] = new_enrollment['host_token']
assert sql("SELECT epoch FROM cooperation_bindings WHERE id='" + reenrolled['id'] + "'") == '1'
resolve(reenrolled, reenroll_attempt, 'historical_recipient')
before = snapshot()
api('workers/' + reenrolled['id'] + '/receipts', receipt_data(reenroll_attempt),
    token=reenrolled['host'], status=409)
for old_token in [old_host, old_receipt]:
    api(reenrolled['path'] + '/resolve', callback(reenroll_attempt), token=old_token, status=401)
assert snapshot() == before
print('New enrollment revision invalidates prior source authority and receipts within an unchanged binding epoch PASS', flush=True)

# Within one binding, a terminal old attempt may accept historical receipt
# evidence after a newer generation starts, but cannot act on that generation.
history_owner = worker('history')
historical_source = message(history_owner, 'first')
historical_attempt = reserve(history_owner, historical_source['id'], key='first-reserve')
result(history_owner, historical_attempt, 'not_submitted', 'no-native-call')
new_source = message(history_owner, 'second')
new_attempt = reserve(history_owner, new_source['id'], key='second-reserve')
resolve(history_owner, historical_attempt, 'attempt_not_current')
assert resolve(history_owner, new_attempt)['source']['message']['id'] == new_source['id']
# Deliberately invalidate the older source. Historical evidence remains legal,
# but this must not reclassify or apply the old delivery in the new generation.
api('messages/' + str(historical_source['id']) + '/read', {}, agent=history_owner['id'])
historical_data = receipt_data(historical_attempt, 'handled', 'historical-handled')
retained_tables = [table for table in TABLES if table != 'cooperation_receipts']
before = snapshot(retained_tables)
evidence = api('workers/' + history_owner['id'] + '/receipts', historical_data,
               token=history_owner['receipt'])
assert evidence['historical'] is True and evidence['idempotent'] is False
assert snapshot(retained_tables) == before
before = snapshot()
replayed = api('workers/' + history_owner['id'] + '/receipts', historical_data,
               token=history_owner['receipt'])
assert replayed['historical'] and replayed['idempotent'] and replayed['receipt'] == evidence['receipt']
assert snapshot() == before
assert resolve(history_owner, new_attempt)['source']['message']['id'] == new_source['id']
# A valid host for a different worker is not authority over the old attempt.
api(history_owner['path'] + '/resolve', callback(old_attempt), token=history_owner['host'], status=403)
print('Same-epoch historical receipt evidence and idempotent replay preserve the current source and attempt PASS', flush=True)

# Legacy generic batches can contain a canonical answered-decision event without
# a wake reservation. Inactive current attempts must not admit new receipts.
generic_inactive = generic_decision('inactive')
generic_owner, generic, delivery_id, received_data, first, request = generic_inactive
fences = {key: generic['batch'][key] for key in
          ['attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash']}
api('workers/' + generic_owner['id'] + '/result',
    dict(fences, status='not_submitted', reason='Invented no native call'), token=generic_owner['host'])

# Resolution and receipt application must wait for the canonical source lock,
# then see its committed invalidation rather than act on a pre-lock snapshot.
for operation in ['resolve', 'receipts']:
    locked_owner = worker('locked-' + operation)
    locked_source = message(locked_owner)
    locked_attempt = reserve(locked_owner, locked_source['id'])
    connection = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    connection.stdin.write("BEGIN; UPDATE messages SET created_at=created_at + interval '1 second' WHERE id=" + str(locked_source['id']) + "; SELECT 'SOURCE_LOCKED';\n")
    connection.stdin.flush()
    while connection.stdout.readline().strip() != 'SOURCE_LOCKED':
        assert connection.poll() is None, connection.stderr.read()
    retained_tables = [table for table in TABLES if table != 'messages']
    before = snapshot(retained_tables)
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        if operation == 'resolve':
            pending = pool.submit(api, locked_owner['path'] + '/resolve', callback(locked_attempt),
                                  token=locked_owner['host'])
        else:
            pending = pool.submit(api, 'workers/' + locked_owner['id'] + '/receipts',
                                  receipt_data(locked_attempt), token=locked_owner['receipt'], status=409)
        try:
            deadline = time.monotonic() + 10
            while sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'SELECT id FROM messages WHERE id=%FOR UPDATE%'") != '1':
                assert not pending.done(), 'Operation bypassed its canonical source row lock'
                assert time.monotonic() < deadline, 'Operation did not reach canonical source lock'
                time.sleep(0.05)
        finally:
            connection.stdin.write('COMMIT;\n')
            connection.stdin.flush()
            connection.stdin.close()
            assert connection.wait(timeout=10) == 0, connection.stderr.read()
        denied = pending.result(timeout=15)
    if operation == 'resolve':
        assert denied['actionable'] is False and denied['source'] is None
        assert 'source_suppressed' in denied['reason_codes']
    assert snapshot(retained_tables) == before
    assert sql('SELECT read_at IS NULL FROM messages WHERE id=' + str(locked_source['id'])) == 't'
print('Held canonical source transaction serializes both resolution and new receipt application PASS', flush=True)

# Expiration is an authorization denial, never implicit acceptance or an
# uncertain/handled transition caused merely by resolving the frozen notice.
wait_for_lease(lease_attempt['batch'])
resolve(expiring, lease_attempt, 'attempt_expired')
deny_receipt(expiring, lease_attempt)
assert sql("SELECT state FROM wake_attempts WHERE id='" + lease_attempt['reservation']['attempt_id'] + "'") == 'reserved'
print('Real immutable lease expiry denies material and receipts without changing retained uncertainty PASS', flush=True)

wait_for_lease(generic_expiry[1]['batch'])
for expected_reason, fixture in [('attempt_expired', generic_expiry), ('attempt_not_current', generic_inactive)]:
    generic_owner, generic, delivery_id, received_data, first, request = fixture
    before = snapshot()
    retained = api('workers/' + generic_owner['id'] + '/receipts', received_data,
                   token=generic_owner['receipt'])
    assert retained['idempotent'] and retained['receipt'] == first['receipt']
    assert snapshot() == before
    rejected = dict(received_data, kind='handled', idempotency_key='generic-new-handled')
    denied = api('workers/' + generic_owner['id'] + '/receipts', rejected,
        token=generic_owner['receipt'], status=409)
    assert expected_reason in denied['error']['message'], denied
    assert 'Generic canonical answer' not in json.dumps(denied)
    assert snapshot() == before
    assert sql("SELECT state FROM cooperation_deliveries WHERE id='" + delivery_id + "'") == 'received'
    assert sql("SELECT status FROM decision_requests WHERE id='" + request['id'] + "'") == 'answered'
print('Generic decision-event batch expiry and inactive-attempt gates preserve prior receipts without granting action PASS', flush=True)
