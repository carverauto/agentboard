"""Off/shadow coordinator triage at the packaged HTTP/PostgreSQL boundary.

All actors, credentials, sources and messages are disposable fixture data.
This proves retained classification and read-only visibility, not native delivery,
source-producer trust, assignment admission or a coordinator cutover.
"""
import concurrent.futures
from collections import Counter
from html.parser import HTMLParser
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from liveview_client import RenderedView


URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-triage-captain-capability-0123456789'
COORDINATOR = 'triage-coordinator'
SENDER = 'triage-sender'
MISSING = object()
CONFIG = 'settings/coordinator-triage'
TABLES = ['messages', 'messages_versions', 'coordinator_inbox_triage',
          'coordinator_triage_dispositions', 'coordinator_triage_configuration_versions',
          'board_action_events']


def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-qAt', '-v',
        'ON_ERROR_STOP=1', '-c', statement], text=True).strip()


def rpc(expression):
    script = 'value = (' + expression + '); IO.puts("TRIAGE_RESULT:" <> Jason.encode!(value))'
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', script],
        capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split(':', 1)[1] for line in result.stdout.splitlines()
        if line.startswith('TRIAGE_RESULT:')))


def elixir(value):
    return 'Jason.decode!(' + json.dumps(json.dumps(value)) + ')'


def api(path, data=MISSING, *, actor=SENDER, captain=False, token=None,
        status=200, method=None, headers=None):
    request_headers = {'Content-Type': 'application/json', 'X-Agentboard-Agent': actor,
        'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex',
        'X-Agentboard-Worker-Protocol': '1'}
    if captain:
        request_headers['X-Agentboard-Captain-Token'] = CAPTAIN
        request_headers['Authorization'] = 'Bearer ' + CAPTAIN
    if token:
        request_headers['Authorization'] = 'Bearer ' + token
    request_headers.update(headers or {})
    request = urllib.request.Request(URL + '/api/v1/' + path,
        data=None if data is MISSING else json.dumps(data).encode(),
        headers=request_headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        try:
            body = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            body = raw.decode()
        assert CAPTAIN not in json.dumps(body), 'Captain capability leaked'
        if status is None:
            return response.status, body
        expected = status if isinstance(status, tuple) else (status,)
        assert response.status in expected, (path, response.status, expected, body)
        return body


def metadata(category='status', attention='routine', source=None):
    return {'version': 1, 'category': category, 'attention': attention, 'source': source}


def config():
    return api(CONFIG, captain=True)['configuration']


def replace(mode, coordinator=COORDINATOR, revision=None, **kwargs):
    data = {'mode': mode, 'coordinator_id': coordinator,
            'revision': config()['revision'] if revision is None else revision}
    return api(CONFIG, data, captain=True, method='PUT', **kwargs)


def send(triage=MISSING, *, to=COORDINATOR, body='Invented informational note',
         actor=SENDER, **fields):
    data = dict(body=body, **fields)
    if to is not None:
        data['to'] = to
    if triage is not MISSING:
        data['triage'] = triage
    return api('messages', data, actor=actor)['message']


def exact(message_id, **kwargs):
    return api('messages/' + str(message_id), **kwargs)['message']


def triage(message_id, **kwargs):
    return api('messages/' + str(message_id) + '/triage', **kwargs)['triage']


def counts(tables=TABLES):
    return {table: int(sql('SELECT count(*) FROM ' + table)) for table in tables}


def effects():
    return counts(['tasks', 'task_events', 'wake_intents', 'wake_attempts',
                   'cooperation_events', 'cooperation_deliveries', 'cooperation_receipts'])


def retained(record, message, expected_metadata, classification, state, reason=None):
    assert record['message_id'] == message['id'], record
    assert record['metadata'] == expected_metadata, record
    assert record['classification'] == classification, record
    assert record['capture_mode'] == 'shadow', record
    assert record['configuration_revision'] == shadow_revision, record
    assert record['state'] == state, record
    if reason is not None:
        assert record['reason_code'] == reason, record
    assert record['delivery'] == {'state': 'not_attempted'}, record
    assert record['handling'] == {'state': 'not_inferred'}, record
    assert len(record['history']) == 1, record
    assert record['history'][0]['state'] == state, record
    assert record['history'][0]['sequence'] == 1, record
    assert record['history'][0]['reason_code'] == record['reason_code'], record
    assert record['provenance']['agent'] == SENDER, record
    assert record['provenance']['model'] == 'fixture', record
    assert record['provenance']['harness'] == 'codex', record
    assert message['body'] not in json.dumps(record), 'Triage copied the private body'
    assert exact(message['id'])['read_at'] is None
    return record


def capture(message_id, value, expected='ok'):
    result = rpc('''
    result = Agentboard.Board.Operations.transaction(fn ->
      Agentboard.Repo.statement!("SELECT id FROM messages WHERE id=$1 FOR UPDATE", [''' + str(message_id) + '''])
      message = Ash.get!(Agentboard.Board.Resources.Message, ''' + str(message_id) + ''')
      Agentboard.CoordinatorTriage.capture_message(message,
        %{"agent" => "triage-sender", "model" => "fixture", "harness" => "codex"},
        ''' + elixir(value) + ''')
      true
    end)
    case result do
      {:ok, _} -> "ok"
      {:error, code, _} -> code
    end
    ''')
    assert result == expected, (result, expected)


def all_messages(state=None, limit=2, **filters):
    params = dict(to=COORDINATOR, limit=str(limit), **filters)
    if state is not None:
        params['triage_state'] = state
    result = []
    seen_cursors = set()
    while True:
        page = api('messages?' + urllib.parse.urlencode(params))
        result.extend(page['messages'])
        cursor = page['next_cursor']
        if cursor is None:
            return result
        assert cursor not in seen_cursors, 'Pagination cursor did not advance'
        seen_cursors.add(cursor)
        params['cursor'] = cursor


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + '); true')
for agent in [SENDER, COORDINATOR, 'triage-other', 'triage-new-coordinator', 'triage-retired']:
    api('agents/register', {'name': agent}, actor=agent)
api('agents/triage-retired/retire', {'reason': 'Invented retired fixture'}, captain=True)

# Off is the explicit default, independently protected even when agent auth is off.
initial = config()
assert {key: initial[key] for key in ['mode', 'coordinator_id', 'revision']} == {
    'mode': 'off', 'coordinator_id': None, 'revision': 0}, initial
for verb in ['GET', 'PUT']:
    data = MISSING if verb == 'GET' else dict(mode='shadow', coordinator_id=COORDINATOR, revision=0)
    api(CONFIG, data, method=verb, status=403)
    api(CONFIG, data, actor=COORDINATOR, method=verb, status=403,
        headers={'X-Agentboard-Role': 'captain', 'X-Agentboard-Availability-Admin': 'true'})
    api(CONFIG, data, method=verb, status=403,
        headers={'Authorization': 'Bearer invented-invalid-capability'})

valid_configuration = {'mode': 'shadow', 'coordinator_id': COORDINATOR, 'revision': 0}
invalid_configuration = [None, [], 'shadow', {},
    *[{key: value for key, value in valid_configuration.items() if key != omitted}
      for omitted in valid_configuration],
    dict(valid_configuration, active=True), dict(valid_configuration, changed_by='forged'),
    *[dict(valid_configuration, mode=value) for value in ['active', 'SHADOW', '', None, 1, True]],
    *[dict(valid_configuration, coordinator_id=value) for value in
      [None, '', 'unknown-coordinator', 1, True, [], 'two seats']],
    *[dict(valid_configuration, revision=value) for value in [-1, '0', 0.5, True, None]]]
before = counts()
for value in invalid_configuration:
    api(CONFIG, value, captain=True, method='PUT', status=(400, 422))
api(CONFIG, dict(valid_configuration, coordinator_id='triage-retired'),
    captain=True, method='PUT', status=409)
assert config() == initial
assert counts() == before, 'Rejected configuration wrote data or audit'

# Metadata validates before all Message writes, including when triage is disabled.
invalid_metadata = [None, [], True, 'status', {},
    *[{key: value for key, value in metadata().items() if key != omitted}
      for omitted in metadata()],
    dict(metadata(), unknown=True), dict(metadata(), classification='captain_addressed'),
    dict(metadata(), provenance={'agent': 'captain'}),
    *[dict(metadata(), version=value) for value in [0, 2, '1', True, 1.5, None]],
    *[dict(metadata(), category=value) for value in ['captain_addressed', 'STATUS', '', 1, None]],
    *[dict(metadata(), attention=value) for value in ['urgent', 'CAPTAIN', '', 1, None]],
    metadata(source={}), metadata(source=[]), metadata(source='task'),
    metadata('ci'), metadata('conflict')]
sources = {
    'status': {'kind': 'task_status', 'task_id': 'triage-task', 'task_event_id': 1, 'task_revision': 1},
    'ci': {'kind': 'cooperation_event', 'event_id': '11111111-1111-4111-8111-111111111111', 'source_key': 'fixture/source'},
    'next_work': {'kind': 'task_assignment', 'task_id': 'triage-task', 'assignment_revision': 1},
    'needs_judgment': {'kind': 'decision_request', 'request_id': '22222222-2222-4222-8222-222222222222'}}
for category, source in sources.items():
    invalid_metadata.append(metadata(category, source=dict(source, forged=True)))
    for missing in source:
        invalid_metadata.append(metadata(category, source={k: v for k, v in source.items() if k != missing}))
    invalid_metadata.append(metadata(category, source=dict(source, kind='unsupported')))
    for key in ['task_event_id', 'task_revision', 'assignment_revision']:
        if key in source:
            for value in [0, -1, True, '1', 1.5, 9007199254740992, None]:
                invalid_metadata.append(metadata(category, source=dict(source, **{key: value})))
    if 'task_id' in source:
        for value in ['', 'UpperCase', 'two tasks', 'x' * 129, None, 1]:
            invalid_metadata.append(metadata(category, source=dict(source, task_id=value)))
    for key in ['event_id', 'request_id']:
        if key in source:
            for value in ['', 'not-a-uuid', 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', None, 1]:
                invalid_metadata.append(metadata(category, source=dict(source, **{key: value})))
for value in ['', 'x' * 241, 'e\u0301' * 121, 'bad\nsource', 'bad\x00source', 'bad\x7fsource', None, 1]:
    invalid_metadata.append(metadata('ci', source=dict(sources['ci'], source_key=value)))
for category, foreign_source in [('status', sources['ci']), ('ci', sources['status']),
                                 ('next_work', sources['status']), ('needs_judgment', sources['ci'])]:
    invalid_metadata.append(metadata(category, source=foreign_source))


def reject_invalid_metadata():
    before = counts()
    for value in invalid_metadata:
        api('messages', {'to': COORDINATOR, 'body': 'Rejected fixture', 'triage': value}, status=422)
    for extra in ['classification', 'provenance', 'source_verification', 'triage_state',
                  'capture_mode', 'configuration_revision']:
        api('messages', {'to': COORDINATOR, 'body': 'Forged envelope', extra: 'forged'}, status=422)
    assert counts() == before, 'Invalid metadata committed a Message or dependent audit'


reject_invalid_metadata()
# JSON Schema length counts Unicode codepoints, not grapheme clusters: these
# visually similar source keys contain exactly 240 and 242 codepoints.
boundary_key = 'e\u0301' * 120
assert len(boundary_key) == 240
unicode_off = send(metadata('ci', source=dict(sources['ci'], source_key=boundary_key)),
                   body='Valid maximum-codepoint source key')
assert triage(unicode_off['id']) is None
legacy_off = send(body='Legacy note remains ordinary while off')
typed_off = send(metadata(), body='Typed note remains ordinary while off')
assert triage(legacy_off['id']) is None and triage(typed_off['id']) is None
assert exact(legacy_off['id'])['triage'] is None
assert counts()['coordinator_inbox_triage'] == 0

# Configuration is a compare-and-swap replacement with exactly one audited winner.
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    outcomes = list(pool.map(lambda _: api(CONFIG, valid_configuration, captain=True,
        method='PUT', status=None), range(2)))
assert sorted(status for status, _ in outcomes) == [200, 409], outcomes
shadow = config()
shadow_revision = shadow['revision']
assert shadow['mode'] == 'shadow' and shadow_revision == 1
assert shadow['coordinator_id'] == COORDINATOR and shadow['changed_by'] == 'captain'
assert shadow['updated_at']
assert sql('SELECT count(*) FROM coordinator_triage_configuration_versions') == '1'
assert sql("SELECT provenance->>'agent' FROM coordinator_triage_configuration_versions") == 'captain'
api(CONFIG, valid_configuration, captain=True, method='PUT', status=409)
assert config() == shadow
assert triage(legacy_off['id']) is None and triage(typed_off['id']) is None, 'Shadow backfilled off history'
capture(legacy_off['id'], None)
capture(typed_off['id'], metadata())
assert triage(legacy_off['id']) is None and triage(typed_off['id']) is None, 'Internal retry captured off history'
reject_invalid_metadata()

# Classification is explicit. Reads and shadow capture never infer handling.
before_effects = effects()
legacy = send(body='@captain CI failed: please use judgment and pick next work')
legacy_record = retained(triage(legacy['id']), legacy, None, 'unclassified', 'blocked')
assert legacy_record['reason_code'] == 'metadata_missing'
routine = send(metadata(), body='@captain CI failure conflict urgent judgment next-work')
routine_record = retained(triage(routine['id']), routine, metadata(), 'status', 'recorded')
assert routine_record['reason_code'] == 'informational_only'
assert routine_record['provenance']['authentication'] == 'unverified_attribution'
assert routine_record['provenance']['source_authority'] == 'unverified'
assert routine_record['source_verification'] == 'not_applicable'
judgment = send(metadata('needs_judgment'), body='A taskless explicit decision request')
retained(triage(judgment['id']), judgment, metadata('needs_judgment'),
         'needs_judgment', 'escalation_pending', 'transport_unavailable')
captain_note = send(metadata(attention='captain'), body='Explicit captain attention')
retained(triage(captain_note['id']), captain_note, metadata(attention='captain'),
         'captain_addressed', 'escalation_pending', 'transport_unavailable')
next_work = send(metadata('next_work'), body='Taskless refill is unsupported')
retained(triage(next_work['id']), next_work, metadata('next_work'), 'next_work', 'blocked')
assert effects() == before_effects, 'Shadow capture invented a task, wake or delivery effect'
for message in [routine, judgment, captain_note, next_work, legacy]:
    assert message['task_id'] is None
    record = triage(message['id'])
    assert record.get('task_id') is None and record.get('repo') is None, record
    assert exact(message['id'])['triage']['classification'] == record['classification']
    assert exact(message['id'])['read_at'] is None

# Identical POST bodies are distinct Message occurrences, not a body-dedupe API.
duplicate = send(metadata(), body=routine['body'])
assert duplicate['id'] != routine['id']
assert triage(duplicate['id'])['message_id'] == duplicate['id']
assert triage(routine['id']) == routine_record

# Selection is exact recipient + direct note; all other legacy delivery stays intact.
task = api('tasks', {'id': 'triage-task', 'title': 'Canonical triage source',
                    'repo': 'fixture/triage'})
api('tasks', {'id': 'triage-other-task', 'title': 'Different canonical task', 'repo': 'foreign/triage'})
other_message = send(to='triage-other', triage=metadata())
task_only = send(to=None, task='triage-task', triage=metadata())
task_order = send(task='triage-task', kind='task_order')
api('messages', {'to': COORDINATOR, 'task': 'triage-task', 'kind': 'task_order',
    'body': 'Kinds remain separate', 'triage': metadata()}, status=422)
for message in [other_message, task_only, task_order]:
    assert triage(message['id']) is None and exact(message['id'])['triage'] is None

# Task-status references must agree on exact task, event and revision. References
# describe information only; neither the body nor a real ID authorizes routing.
task_source = {'kind': 'task_status', 'task_id': 'triage-task',
               'task_event_id': task['event_id'], 'task_revision': task['task']['revision']}
canonical = send(metadata(source=task_source), task='triage-task', body='Canonical informational status')
retained(triage(canonical['id']), canonical, metadata(source=task_source), 'status', 'recorded')
assert triage(canonical['id'])['source_verification'] == 'informational_reference'
unreferenced = send(metadata(), task='triage-task', body='Task-scoped status needs an explicit source')
retained(triage(unreferenced['id']), unreferenced, metadata(), 'status', 'blocked', 'source_required')
task_before = api('tasks/triage-task')
for source in [dict(task_source, task_id='triage-other-task'),
               dict(task_source, task_event_id=9007199254740991),
               dict(task_source, task_revision=task_source['task_revision'] + 1)]:
    message = send(metadata(source=source), task='triage-task', body='Mismatched informational source')
    retained(triage(message['id']), message, metadata(source=source), 'status', 'blocked')
assert api('tasks/triage-task') == task_before

# Even an exact, existing assignment is merely context in shadow mode. Triage
# cannot assign/claim/renew or add a second wake beyond the existing unread DM.
api('tasks', {'id': 'triage-assignment', 'title': 'Existing assignment', 'repo': 'fixture/triage'})
assigned = api('tasks/triage-assignment/assign', {'to': SENDER}, captain=True)['task']
assignment_source = {'kind': 'task_assignment', 'task_id': assigned['id'],
                     'assignment_revision': assigned['revision']}
assigned_before = api('tasks/triage-assignment')
assignment_effects = effects()
assigned_note = send(metadata('next_work', source=assignment_source),
                     task=assigned['id'], body='Existing assignment only')
retained(triage(assigned_note['id']), assigned_note,
         metadata('next_work', source=assignment_source), 'next_work', 'blocked', 'route_unavailable')
assert api('tasks/triage-assignment') == assigned_before
expected_effects = dict(assignment_effects, wake_intents=assignment_effects['wake_intents'] + 1)
assert effects() == expected_effects
assert sql("SELECT count(*) FROM wake_intents WHERE source_kind='board_message' AND source_id='" +
           str(assigned_note['id']) + "' AND reason='unread_dm' AND recipient_id='triage-coordinator'") == '1'

# Real cooperation identity and exact marker still are caller claims. Producer
# association is deliberately unavailable in this slice, so both categories block.
for category in ['ci', 'conflict']:
    event_id = str(uuid.uuid4())
    source_key = 'fixture/triage/existing-' + category
    kind = 'ci_failure' if category == 'ci' else 'pr_conflict'
    sql("INSERT INTO cooperation_events(id,source_key,kind,repo,task_id,summary,source_url,priority,audience,route_cursor,routed,created_at) VALUES ('" +
        event_id + "','" + source_key + "','" + kind + "','fixture/triage','triage-task','Invented known event','',1,ARRAY[]::text[],0,false,clock_timestamp())")
    event_source = {'kind': 'cooperation_event', 'event_id': event_id, 'source_key': source_key}
    value = metadata(category, source=event_source)
    message = send(value, task='triage-task', body='[agentboard-cooperation:' + event_id + '] exact marker ' + source_key)
    retained(triage(message['id']), message, value, category, 'blocked', 'untrusted_source')
    priority = metadata(category, attention='captain', source=event_source)
    addressed = send(priority, task='triage-task', body='Explicit captain attention with untrusted source')
    retained(triage(addressed['id']), addressed, priority, 'captain_addressed',
             'escalation_pending', 'transport_unavailable')

# Ordinary exact reads, filtered pages and repeated inspection cannot acknowledge.
before_reads = counts()
before_effects = effects()
for state in ['recorded', 'blocked', 'escalation_pending', 'unresolved']:
    messages = all_messages(state)
    ids = [message['id'] for message in messages]
    assert len(ids) == len(set(ids)) and ids, (state, ids)
    predicate = "d.state IN ('blocked','escalation_pending')" if state == 'unresolved' else "d.state='" + state + "'"
    expected_ids = {int(value) for value in sql("SELECT m.id FROM messages m JOIN coordinator_triage_dispositions d ON d.message_id=m.id WHERE m.recipient_id='triage-coordinator' AND " + predicate).splitlines()}
    assert set(ids) == expected_ids, (state, sorted(ids), sorted(expected_ids))
    for message in messages:
        projection = triage(message['id'])
        assert projection['state'] in (['blocked', 'escalation_pending'] if state == 'unresolved' else [state])
        assert exact(message['id'])['read_at'] is None
raw_ids = {message['id'] for message in all_messages(unread='true')}
assert {legacy_off['id'], typed_off['id'], legacy['id'], routine['id'], judgment['id']} <= raw_ids, {
    'paged_ids': sorted(raw_ids),
    'single_page_ids': [message['id'] for message in all_messages(unread='true', limit=100)],
    'database_dates': sql('SELECT id,created_at FROM messages ORDER BY id LIMIT 5')}
assert counts() == before_reads and effects() == before_effects
for value in ['routed', 'handled', 'off', '', 'BLOCKED']:
    api('messages?to=' + COORDINATOR + '&triage_state=' + value, status=422)
page = api('messages?to=' + COORDINATOR + '&triage_state=unresolved&limit=1')
assert page['next_cursor']
cursor = urllib.parse.quote(page['next_cursor'], safe='')
api('messages?to=' + COORDINATOR + '&triage_state=recorded&limit=1&cursor=' + cursor, status=422)
api('messages?to=triage-other&triage_state=unresolved&limit=1&cursor=' + cursor, status=422)
api('messages?to=' + COORDINATOR + '&limit=1&cursor=' + cursor, status=422)
for path in ['messages/0', 'messages/-1', 'messages/not-an-id', 'messages/0/triage']:
    api(path, status=422)
api('messages/9007199254740991', status=404)
api('messages/9007199254740991/triage', status=404)

# Exact capture retries return immutable retained evidence under concurrency.
before_replay = counts()
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    list(pool.map(lambda _: capture(routine['id'], metadata()), range(2)))
assert triage(routine['id']) == routine_record and counts() == before_replay
capture(routine['id'], metadata('needs_judgment'), expected='conflict')
assert triage(routine['id']) == routine_record and counts() == before_replay

print('Off/shadow selection, exact schema, explicit classification, fail-closed sources and read-only pagination PASS', flush=True)

# Two first-capture transactions serialize on one canonical Message identity.
fresh_id = int(sql("INSERT INTO messages(sender_id,recipient_id,model,harness,body,created_at) VALUES ('triage-sender','triage-coordinator','fixture','codex','Concurrent first-capture fixture',clock_timestamp()) RETURNING id"))
before_race = counts()
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    list(pool.map(lambda _: capture(fresh_id, metadata()), range(2)))
after_race = counts()
assert after_race['coordinator_inbox_triage'] == before_race['coordinator_inbox_triage'] + 1
assert after_race['coordinator_triage_dispositions'] == before_race['coordinator_triage_dispositions'] + 1
assert after_race['board_action_events'] == before_race['board_action_events'] + 2
assert sql('SELECT count(*) FROM coordinator_triage_dispositions WHERE message_id=' + str(fresh_id)) == '1'

# Inject failure at each dependent stage. Message, initial disposition and both
# audit streams must either all commit or all roll back.
sql("CREATE FUNCTION reject_triage_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'invented triage rollback failure'; END $$")
for table in ['coordinator_inbox_triage', 'coordinator_triage_dispositions']:
    before_failure = counts()
    before_failure_effects = effects()
    sql('CREATE TRIGGER reject_triage_fixture BEFORE INSERT ON ' + table + ' FOR EACH ROW EXECUTE FUNCTION reject_triage_fixture()')
    try:
        api('messages', {'to': COORDINATOR, 'body': 'Rollback all dependent capture',
                        'triage': metadata()}, status=503)
    finally:
        sql('DROP TRIGGER reject_triage_fixture ON ' + table)
    assert counts() == before_failure, (table, before_failure, counts())
    assert effects() == before_failure_effects
for resource in ['Elixir.Agentboard.CoordinatorTriage.Record', 'Elixir.Agentboard.CoordinatorTriage.Disposition']:
    before_failure = counts()
    sql("CREATE TRIGGER reject_triage_fixture BEFORE INSERT ON board_action_events FOR EACH ROW WHEN (NEW.resource='" + resource + "') EXECUTE FUNCTION reject_triage_fixture()")
    try:
        api('messages', {'to': COORDINATOR, 'body': 'Rollback required capture audit',
                        'triage': metadata()}, status=503)
    finally:
        sql('DROP TRIGGER reject_triage_fixture ON board_action_events')
    assert counts() == before_failure, (resource, before_failure, counts())
before_failure = counts()
before_configuration = config()
sql('CREATE TRIGGER reject_triage_fixture BEFORE INSERT ON coordinator_triage_configuration_versions FOR EACH ROW EXECUTE FUNCTION reject_triage_fixture()')
try:
    replace('off', coordinator=None, status=503)
finally:
    sql('DROP TRIGGER reject_triage_fixture ON coordinator_triage_configuration_versions')
assert config() == before_configuration and counts() == before_failure

# A real transaction reserves a lower Message ID and holds its blocked record
# uncommitted. A later visible message is paged first; a restarted unresolved
# scan must still find the lower-ID late commit rather than trust a watermark.
connection = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
connection.stdin.write("BEGIN; INSERT INTO messages(sender_id,recipient_id,model,harness,body,created_at) VALUES ('triage-sender','triage-coordinator','fixture','codex','Lower-ID late commit',clock_timestamp()) RETURNING id;\n")
connection.stdin.flush()
low_id = int(connection.stdout.readline().strip())
connection.stdin.write("INSERT INTO coordinator_inbox_triage(message_id,message_created_at,recipient_id,metadata,classification,capture_mode,configuration_revision,policy_version,provenance,source_verification,created_at) SELECT " + str(low_id) + ",m.created_at,r.recipient_id,r.metadata,r.classification,r.capture_mode,r.configuration_revision,r.policy_version,r.provenance,r.source_verification,clock_timestamp() FROM coordinator_inbox_triage r JOIN messages m ON m.id=" + str(low_id) + " WHERE r.message_id=" + str(legacy['id']) + "; INSERT INTO coordinator_triage_dispositions(id,message_id,sequence,state,reason_code,created_at) SELECT '" + str(uuid.uuid4()) + "'," + str(low_id) + ",1,state,reason_code,clock_timestamp() FROM coordinator_triage_dispositions WHERE message_id=" + str(legacy['id']) + "; SELECT 'triage-ready';\n")
connection.stdin.flush()
assert connection.stdout.readline().strip() == 'triage-ready'
try:
    higher = send(body='Higher-ID visible blocked note')
    assert higher['id'] > low_id
    visible = {message['id'] for message in all_messages('unresolved', limit=1)}
    assert higher['id'] in visible and low_id not in visible
    connection.stdin.write('COMMIT;\n')
    connection.stdin.flush()
    connection.stdin.close()
    assert connection.wait(timeout=10) == 0, connection.stderr.read()
finally:
    if connection.poll() is None:
        connection.terminate()
        connection.wait(timeout=10)
visible = [message['id'] for message in all_messages('unresolved', limit=1)]
assert low_id in visible and higher['id'] in visible and len(visible) == len(set(visible))

# Stored identities/history reject mutable Ash actions and direct SQL tampering.
for resource in ['Record', 'Disposition']:
    assert rpc('Ash.Resource.Info.actions(Agentboard.CoordinatorTriage.' + resource +
               ') |> Enum.all?(fn action -> action.type in [:read, :create] end)') is True
assert rpc('''
row = Ash.get!(Agentboard.CoordinatorTriage.Record, ''' + str(routine['id']) + ''')
attrs = Map.take(row, Ash.Resource.Info.attributes(Agentboard.CoordinatorTriage.Record) |> Enum.map(& &1.name))
result = Agentboard.CoordinatorTriage.Record |> Ash.Changeset.for_create(:record, attrs,
  actor: %{"agent" => "triage-sender", "model" => "fixture", "harness" => "codex"}) |> Ash.create()
match?({:error, %Ash.Error.Forbidden{}}, result)
''') is True
for table, update in [
    ('coordinator_inbox_triage', "classification='captain_addressed'"),
    ('coordinator_triage_dispositions', "state='recorded'"),
    ('coordinator_triage_configuration_versions', "provenance='{}'::jsonb")]:
    before_immutable = sql('SELECT count(*) FROM ' + table)
    for statement in ['UPDATE ' + table + ' SET ' + update, 'DELETE FROM ' + table, 'TRUNCATE ' + table]:
        result = subprocess.run([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1',
            '-c', statement], capture_output=True, text=True)
        assert result.returncode != 0, 'Immutable evidence accepted: ' + statement
    assert sql('SELECT count(*) FROM ' + table) == before_immutable
assert triage(routine['id']) == routine_record

# Mode and coordinator changes affect only new sends. Exact retries retain their
# original capture revision, and off never retroactively captures a new Message.
rotated = replace('shadow', coordinator='triage-new-coordinator')['configuration']
assert rotated['revision'] == shadow_revision + 1
old_target = send(metadata())
new_target = send(metadata(), to='triage-new-coordinator')
assert triage(old_target['id']) is None
assert triage(new_target['id'])['configuration_revision'] == rotated['revision']
replace('off', coordinator=None)
off_again = send(metadata(), to='triage-new-coordinator')
off_same_recipient = send(metadata())
assert triage(off_again['id']) is None
before_rotated_replay = counts()
capture(routine['id'], metadata())
capture(routine['id'], metadata('needs_judgment'), expected='conflict')
assert triage(routine['id']) == routine_record and counts() == before_rotated_replay
shadow_revision = replace('shadow')['configuration']['revision']
assert triage(old_target['id']) is None and triage(off_again['id']) is None
capture(off_again['id'], metadata())
capture(off_same_recipient['id'], metadata())
assert triage(off_again['id']) is None, 'Reconfiguration captured earlier off-mode history'
assert triage(off_same_recipient['id']) is None, 'Matching recipient captured earlier off-mode history'

# Freeze a new Message at its actual INSERT, after admission should have taken a
# shared configuration lock. A shadow-to-shadow CAS cannot overtake that source
# transaction and make its freshly stamped Message disappear from capture.
gate_key = 91863001
gate = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
gate.stdin.write('BEGIN; SELECT pg_advisory_xact_lock(' + str(gate_key) + "); SELECT 'triage-gate-ready';\n")
gate.stdin.flush()
while gate.stdout.readline().strip() != 'triage-gate-ready':
    assert gate.poll() is None, gate.stderr.read()
sql("CREATE FUNCTION hold_triage_source_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(" + str(gate_key) + "); RETURN NEW; END $$")
sql("CREATE TRIGGER hold_triage_source_fixture BEFORE INSERT ON messages FOR EACH ROW WHEN (NEW.body='Config race paused new source') EXECUTE FUNCTION hold_triage_source_fixture()")
race_revision = shadow_revision
before_gate = counts()


def advisory_waiters():
    return int(sql("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted AND database=(SELECT oid FROM pg_database WHERE datname=current_database())"))


def await_waiters(number, future):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert not future.done(), ('Source/config transaction escaped the held gate', future.result())
        if advisory_waiters() >= number:
            return
        time.sleep(0.02)
    raise AssertionError('Source/config transaction did not reach its expected lock wait')


try:
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        message_future = pool.submit(send, metadata(), body='Config race paused new source')
        try:
            await_waiters(1, message_future)
            assert counts() == before_gate, 'Held source transaction became partially visible'
            configuration_future = pool.submit(replace, 'shadow', revision=race_revision)
            await_waiters(2, configuration_future)
            assert config()['revision'] == race_revision
            assert not message_future.done() and not configuration_future.done()
        finally:
            gate.stdin.write('COMMIT;\n')
            gate.stdin.flush()
            gate.stdin.close()
            assert gate.wait(timeout=10) == 0, gate.stderr.read()
        raced_message = message_future.result(timeout=20)
        raced_configuration = configuration_future.result(timeout=20)['configuration']
finally:
    if gate.poll() is None:
        gate.terminate()
        gate.wait(timeout=10)
    sql('DROP TRIGGER hold_triage_source_fixture ON messages')
    sql('DROP FUNCTION hold_triage_source_fixture()')
assert raced_configuration['revision'] == race_revision + 1
assert triage(raced_message['id'])['configuration_revision'] == race_revision
assert triage(raced_message['id'])['state'] == 'recorded'
shadow_revision = raced_configuration['revision']
after_rotation = send(metadata(), body='New source after serialized configuration replacement')
assert triage(after_rotation['id'])['configuration_revision'] == shadow_revision
assert len(triage(raced_message['id'])['history']) == 1
print('New-source admission fences concurrent shadow configuration replacement PASS', flush=True)

# Authenticated coordinator credentials can exact-read only their own direct
# Messages. Attribution headers cannot broaden that scope or grant captain power.
rpc('Application.put_env(:agentboard, :coordinator_id, "triage-coordinator"); true')
sender_token = api('agents/' + SENDER + '/tokens/issue', {}, captain=True)['token']
coordinator_token = api('agents/' + COORDINATOR + '/tokens/issue', {}, captain=True)['token']
rpc('Application.put_env(:agentboard, :agent_auth_mode, "enforce"); true')
try:
    for suffix in ['', '/triage']:
        path = 'messages/' + str(routine['id']) + suffix
        api(path, status=401)
        api(path, actor=COORDINATOR, token=coordinator_token)
        api(path, actor=SENDER, token=sender_token)
        api(path, actor=SENDER, token=coordinator_token, status=403)
        for foreign in [other_message, task_only, new_target]:
            api('messages/' + str(foreign['id']) + suffix,
                actor=COORDINATOR, token=coordinator_token, status=404)
    api('messages?to=' + COORDINATOR + '&triage_state=unresolved',
        actor=COORDINATOR, token=coordinator_token)
    api('messages?to=triage-other&triage_state=unresolved',
        actor=COORDINATOR, token=coordinator_token, status=403)
    for token, actor in [(sender_token, SENDER), (coordinator_token, COORDINATOR)]:
        api(CONFIG, actor=actor, token=token, status=403)
        api(CONFIG, dict(mode='off', coordinator_id=None, revision=shadow_revision),
            actor=actor, token=token, method='PUT', status=403)
    assert config()['revision'] == shadow_revision
    authenticated = api('messages', {'to': COORDINATOR, 'body': 'Authenticated attribution',
        'triage': metadata()}, actor=SENDER, token=sender_token)['message']
    authenticated_record = triage(authenticated['id'], actor=COORDINATOR, token=coordinator_token)
    assert authenticated_record['provenance']['authentication'] == 'authenticated_agent'
    assert authenticated_record['provenance']['source_authority'] == 'unverified'
    assert authenticated_record['source_verification'] == 'not_applicable'
    assert CAPTAIN not in json.dumps(authenticated_record) and sender_token not in json.dumps(authenticated_record)
    api('messages', {'to': COORDINATOR, 'body': 'Forged provenance',
        'triage': dict(metadata(), provenance={'authentication': 'authenticated_agent'})},
        actor=SENDER, token=sender_token, status=422)
finally:
    rpc('Application.put_env(:agentboard, :agent_auth_mode, "off"); true')

# A deliberate recipient acknowledgement remains the existing Message operation;
# it is never inferred into the immutable triage handling projection.
before_ack = triage(legacy['id'])
api('messages/' + str(legacy['id']) + '/read', {}, actor=COORDINATOR)
assert exact(legacy['id'])['read_at'] is not None
assert triage(legacy['id']) == before_ack
assert legacy['id'] in {message['id'] for message in all_messages('unresolved')}
print('Capture race/replay, atomic audit rollback, late-commit discovery, immutable evidence and authenticated exact reads PASS', flush=True)


class MessagesDocument(HTMLParser):
    """Inspect real rendered controls and cards, including duplicate bodies."""
    def __init__(self, document):
        super().__init__()
        self.triage_ids = []
        self.inputs = {}
        self.options = {}
        self.forms = []
        self.bodies = []
        self.selected = ''
        self.select = None
        self.description = None
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'form' and attrs.get('action') == '/messages':
            self.forms.append(attrs)
        if tag == 'input' and attrs.get('name'):
            self.inputs[attrs['name']] = attrs
        if tag == 'select':
            self.select = attrs.get('name')
        if tag == 'option' and self.select == 'triage_state':
            self.options[attrs['value']] = attrs
            if 'selected' in attrs:
                self.selected = attrs['value']
        if 'data-triage-message' in attrs:
            self.triage_ids.append(int(attrs['data-triage-message']))
        if tag == 'p' and attrs.get('class') == 'description':
            self.description = ''

    def handle_data(self, data):
        if self.description is not None:
            self.description += data

    def handle_endtag(self, tag):
        if tag == 'select':
            self.select = None
        if tag == 'p' and self.description is not None:
            self.bodies.append(self.description)
            self.description = None


# Real LiveView joins and URL patches exercise the Messages filter rather than
# merely searching template source. Navigation and filter reset are read-only.
before_ui = counts()
before_ui_effects = effects()
read_provenance = sql('SELECT coalesce(jsonb_agg(jsonb_build_array(id,read_at,read_model,read_harness) ORDER BY id),\'[]\') FROM messages')
unresolved_path = '/messages?' + urllib.parse.urlencode({
    'to': COORDINATOR, 'unread': 'true', 'triage_state': 'unresolved'})
view = RenderedView(URL, unresolved_path)
try:
    unresolved_document = MessagesDocument(view.document)
    unresolved_messages = all_messages('unresolved', unread='true')
    assert set(unresolved_document.triage_ids) == {message['id'] for message in unresolved_messages}
    assert Counter(unresolved_document.bodies) == Counter(message['body'] for message in unresolved_messages)
    assert unresolved_document.selected == 'unresolved'
    assert set(unresolved_document.options) == {'', 'recorded', 'blocked', 'escalation_pending', 'unresolved'}
    assert unresolved_document.inputs['to']['value'] == COORDINATOR
    assert 'checked' in unresolved_document.inputs['unread']
    assert unresolved_document.forms[0]['method'] == 'get'
    assert 'Shadow triage:' in view.document and 'No delivery or handling implied.' in view.document
    for state in ['', 'recorded', 'unresolved', '']:
        path = '/messages?' + urllib.parse.urlencode({
            'to': COORDINATOR, 'unread': 'true', 'triage_state': state})
        rendered = view.request('live_patch', {'url': URL + path})
        document = MessagesDocument(rendered)
        expected = all_messages(state or None, unread='true')
        assert Counter(document.bodies) == Counter(message['body'] for message in expected)
        assert set(document.triage_ids) == {message['id'] for message in expected if message['triage']}
        assert document.selected == state
        assert document.inputs['to']['value'] == COORDINATOR
        assert 'checked' in document.inputs['unread']
        if not state:
            assert legacy_off['body'] in document.bodies and typed_off['body'] in document.bodies
            assert legacy['body'] not in document.bodies, 'Reset discarded the unread filter'
finally:
    view.close()
assert counts() == before_ui and effects() == before_ui_effects
assert sql('SELECT coalesce(jsonb_agg(jsonb_build_array(id,read_at,read_model,read_harness) ORDER BY id),\'[]\') FROM messages') == read_provenance
print('Rendered Messages triage selector, unresolved visibility, raw/unread reset and no read-receipt mutation PASS', flush=True)
