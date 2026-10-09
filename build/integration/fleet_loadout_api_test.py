"""Dormant captain FleetLoadout contract at packaged HTTP and PostgreSQL boundaries.

All identities and policies are disposable fixtures. Configuration never provisions
hosts, workers, agents or tasks, and never sends a prompt or activates a fleet.
"""
import concurrent.futures
import copy
import http.cookiejar
from html.parser import HTMLParser
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from liveview_client import Page, RenderedView

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-fleet-captain-capability-0123456789'
MISSING = object()


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=MISSING, *, captain=False, token=None, actor='fleet-captain',
        harness='codex', model='fixture-observed', status=200, method=None, headers=None):
    request_headers = {'X-Agentboard-Agent': actor, 'X-Agentboard-Model': model,
                       'X-Agentboard-Harness': harness, 'Content-Type': 'application/json',
                       'X-Agentboard-Worker-Protocol': '1'}
    if captain:
        request_headers['Authorization'] = 'Bearer ' + CAPTAIN
    if token is not None:
        request_headers['Authorization'] = 'Bearer ' + token
    request_headers.update(headers or {})
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=request_headers,
                                    data=None if data is MISSING else json.dumps(data).encode(),
                                    method=method)
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    assert CAPTAIN not in json.dumps(body), 'Captain capability leaked'
    if status is None:
        return response.status, body
    expected = status if isinstance(status, tuple) else (status,)
    assert response.status in expected, (path, response.status, expected, body)
    return body


def show(fleet='main', **kwargs):
    return api('fleets/' + fleet + '/loadout', captain=True, **kwargs)


def put(data, fleet='main', **kwargs):
    return api('fleets/' + fleet + '/loadout', data, method='PUT', captain=True, **kwargs)


def register(agent, *, harness='codex', model='fixture-observed', kind='seat', **fields):
    return api('agents/register', dict(name=agent, kind=kind, **fields), actor=agent,
               harness=harness, model=model)['agent']


def set_scope(agent, revision=0, repo='fixture/fleet'):
    return api('agents/' + agent + '/scope', {'allowed_repos': [repo],
        'required_labels': ['fleet'], 'allowed_labels': [], 'revision': revision},
        method='PUT', captain=True)['scope']


def seat(agent='fleet-seat', seat_id='seat-a', **fields):
    return dict({'seat_id': seat_id, 'agent_id': agent, 'harness': 'codex',
                 'desired_host_id': 'future-host', 'desired_model': 'unlisted/model-v99',
                 'desired_effort': 'unlisted-effort-v99', 'scope_revision': 1}, **fields)


def replacement(revision=0, key='initial', seats=None):
    return {'revision': revision, 'idempotency_key': key,
            'seats': [seat()] if seats is None else seats}


def rows(tables):
    return {table: sql('SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'
                       "'[]'::jsonb) FROM \"" + table + '\" t') for table in tables}


def fleet_rows():
    return rows(['fleet_loadouts', 'fleet_seat_bindings',
                 'fleet_loadout_receipts', 'fleet_loadouts_versions'])


def dormant(result, revision=None, count=None):
    assert set(result) == {'loadout', 'replayed'}, result
    loadout = result['loadout']
    assert loadout['enabled'] is False, loadout
    assert loadout['activation_state'] == 'not_activatable', loadout
    assert loadout['catalog_status'] == 'unverified', loadout
    assert loadout['host_status'] == 'unverified', loadout
    assert loadout['seat_count'] == len(loadout['seats']), loadout
    assert [s['seat_id'] for s in loadout['seats']] == sorted(s['seat_id'] for s in loadout['seats'])
    if revision is not None:
        assert loadout['revision'] == revision, loadout
    if count is not None:
        assert loadout['seat_count'] == count, loadout
    return loadout


def wait_for_lock(future, table):
    deadline = time.monotonic() + 8
    while sql("SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() "
             "AND wait_event_type='Lock' AND query LIKE '%" + table + "%'") == '0':
        assert time.monotonic() < deadline and not future.done(), ('No lock wait', table)
        time.sleep(0.02)


def locker(query):
    process = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    process.stdin.write('BEGIN; ' + query + "; SELECT 'ready';\n")
    process.stdin.flush()
    while process.stdout.readline().strip() != 'ready':
        assert process.poll() is None, process.stderr.read()
    return process


def unlock(process, update=''):
    process.stdin.write(update + '; COMMIT;\n')
    process.stdin.flush()
    process.stdin.close()
    assert process.wait(timeout=10) == 0, process.stderr.read()


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
# A captain read/write must not bootstrap even the fixed captain identity.
empty_agents = rows(['agents'])
empty = show('empty')
assert dormant(empty, 0, 0) == {'id': 'empty', 'revision': 0, 'enabled': False,
    'seat_count': 0, 'seats': [], 'activation_state': 'not_activatable',
    'catalog_status': 'unverified', 'host_status': 'unverified',
    'changed_by': None, 'updated_at': None}, empty
assert empty['replayed'] is False
assert rows(['agents']) == empty_agents
assert all(value == '[]' for value in fleet_rows().values())
empty_saved = put(replacement(seats=[]), fleet='empty')
assert dormant(empty_saved, 1, 0)['changed_by'] == 'captain'
assert rows(['agents']) == empty_agents, 'Captain loadout write registered an identity'

for agent in ['fleet-captain', 'fleet-seat', 'fleet-other', 'fleet-third', 'fleet-unmanaged',
              'fleet-retired', 'fleet-coordinator', 'fleet-race-a', 'fleet-race-b',
              'fleet-replay', 'fleet-lock-scope', 'fleet-lock-retire', 'fleet-lock-harness',
              'fleet-cross-race', 'fleet-same-key']:
    register(agent)
    if agent != 'fleet-unmanaged':
        set_scope(agent)
for kind in ['human', 'system', 'fixture']:
    register('fleet-kind-' + kind, kind=kind)
    set_scope('fleet-kind-' + kind)
api('agents/fleet-retired/retire', {'reason': 'Fixture retirement'}, captain=True)
# Metadata cannot become a substitute for separately verified captain authority.
register('fleet-seat', metadata={'captain': True, 'fleet_admin': True},
         capabilities=['captain', 'fleet_admin'])

# Existing owned work and message bytes are preserved alongside empty runtime tables.
api('tasks', {'id': 'fleet-preserved-task', 'title': 'Existing owner remains responsible',
              'repo': 'fixture/fleet', 'labels': ['fleet']})
api('tasks/fleet-preserved-task/claim', {}, actor='fleet-seat')
api('messages', {'to': 'fleet-seat', 'task': 'fleet-preserved-task',
                 'body': 'Existing manual message remains exact.'})

operational_tables = sql("SELECT tablename FROM pg_tables WHERE schemaname='public' AND "
    "(tablename IN ('agents','tasks','task_events','messages','task_documents','seat_scopes',"
    "'seat_scopes_versions','availability_policies') OR tablename LIKE 'cooperation_%' "
    "OR tablename LIKE 'wake_%' OR tablename LIKE 'delivery_%') ORDER BY tablename").splitlines()
operational_before = rows(operational_tables)

# Both reads and writes require the real captain capability in permissive auth mode.
for method, data in [('GET', MISSING), ('PUT', replacement())]:
    for kwargs in [{}, {'actor': 'fleet-coordinator'},
                   {'actor': 'fleet-seat', 'headers': {'X-Agentboard-Role': 'captain',
                                                     'X-Agentboard-Availability-Admin': 'true'}},
                   {'token': 'fixture-invalid-capability'}]:
        api('fleets/main/loadout', data, method=method, status=403, **kwargs)
assert dormant(show(), 0, 0)['updated_at'] is None

# Full replacement and exact nested shape. Rejections must not reserve a key or seat.
before_invalid = fleet_rows()
base = replacement()
invalid = [None, [], 'loadout', {}, {'revision': 0}, dict(base, enabled=False),
           dict(base, enabled=True), dict(base, seat_count=1), dict(base, host_id='live-host'),
           dict(base, activation_state='active'), dict(base, changed_by='spoofed')]
invalid += [{key: value for key, value in base.items() if key != omitted} for omitted in base]
invalid += [dict(base, revision=value) for value in [-1, True, 0.1, '0', 2147483647, 10**30]]
invalid += [dict(base, idempotency_key=value) for value in [None, 1, '', '  ', 'x'*129,
                                                          'two\nlines', 'nul\x00key', 'del\x7fkey', 'c1\x85key',
                                                          'format\u200bkey', 'é'*65]]
invalid += [dict(base, seats=value) for value in [None, {}, '', [None], [1], [seat()]*33]]
for field in seat():
    missing = seat(); del missing[field]
    invalid.append(replacement(seats=[missing]))
for field in ['seat_id', 'agent_id', 'harness', 'desired_host_id']:
    invalid += [replacement(seats=[seat(**{field: value})]) for value in
                [None, 1, '', '  ', 'UpperCase', 'with/slash', 'bad\nvalue', 'x'*129]]
for field, limit in [('desired_model', 256), ('desired_effort', 64)]:
    invalid += [replacement(seats=[seat(**{field: value})]) for value in
                [None, 1, '', ' \t ', 'x'*(limit+1), 'é'*(limit//2+1),
                 'nul\x00value', 'two\nlines', 'tab\tvalue', 'del\x7fvalue',
                 'c1\x85value', 'format\u200bvalue']]
invalid += [replacement(seats=[seat(scope_revision=value)]) for value in
            [None, 0, -1, True, 1.5, '1', 2147483648]]
for field, value in [('scope', {'allowed_repos': ['foreign/repo']}), ('allowed_repos', ['foreign/repo']),
                     ('enabled', True), ('current_scope_revision', 1), ('observed_model', 'spoof')]:
    invalid.append(replacement(seats=[seat(**{field: value})]))
invalid += [replacement(seats=[seat(), seat('fleet-other')]),
            replacement(seats=[seat(), seat(seat_id='seat-b')])]
for data in invalid:
    put(data, status=(400, 422) if data is None else 422)
assert fleet_rows() == before_invalid, 'Invalid body persisted loadout, binding, receipt or audit'
for fleet in ['UpperCase', 'invalid.name', 'x'*129]:
    show(fleet, status=422)

# References validate current registered identities and canonical managed scopes.
for agent in ['missing-agent', 'fleet-retired', 'fleet-kind-human', 'fleet-kind-system', 'fleet-kind-fixture']:
    put(replacement(seats=[seat(agent)]), status=422)
put(replacement(seats=[seat(harness='claude')]), status=422)
put(replacement(seats=[seat(), seat('missing-agent', 'seat-b')]), status=422)
put(replacement(seats=[seat('fleet-unmanaged')]), status=409)
put(replacement(seats=[seat(scope_revision=2)]), status=409)
assert fleet_rows() == before_invalid
put(replacement(2147483646, 'valid-high-revision'), status=409)
put(replacement(seats=[seat(scope_revision=2147483647)]), status=409)

# Unsupported catalog strings and future host IDs are retained as dormant intent.
initial_request = replacement(seats=[seat('fleet-other', 'seat-b', desired_model='  arbitrary/model  ',
    desired_effort='  anything  '), seat()])
initial = put(initial_request)
loadout = dormant(initial, 1, 2)
assert not initial['replayed'] and loadout['changed_by'] == 'captain' and loadout['updated_at']
assert loadout['id'] == 'main'
assert loadout['seats'][1]['desired_model'] == 'arbitrary/model'
assert loadout['seats'][1]['desired_effort'] == 'anything'
for saved in loadout['seats']:
    canonical = api('agents/' + saved['agent_id'] + '/scope')['scope']
    assert saved['scope'] == canonical and saved['current_scope_revision'] == 1
    assert saved['observed_model'] == 'fixture-observed' and saved['observed_retired_at'] is None
assert show()['loadout'] == initial['loadout']
assert rows(operational_tables) == operational_before, 'Dormant config changed operational state'
audit_count = int(sql('SELECT count(*) FROM fleet_loadouts_versions'))
reordered = copy.deepcopy(initial_request); reordered['seats'].reverse()
reordered['idempotency_key'] = '  initial  '
replay = put(reordered)
assert replay == dict(initial, replayed=True), replay
assert int(sql('SELECT count(*) FROM fleet_loadouts_versions')) == audit_count
assert sql("SELECT provenance->>'agent' FROM fleet_loadouts_versions WHERE version_source_id='main'") == 'captain'
assert sql("SELECT count(*) FROM fleet_loadout_receipts WHERE fleet_id='main'") == '1'
put(replacement(0, 'stale-key'), status=409)
put(dict(initial_request, seats=[seat()]), status=409)
assert show()['loadout'] == initial['loadout']

# Removing a seat never deletes its immutable per-fleet identity binding.
removed = put(replacement(1, 'remove-seat', [seat()]))
assert dormant(removed, 2, 1)['seats'][0]['seat_id'] == 'seat-a'
put(replacement(2, 'rebind-seat', [seat('fleet-third')]), status=409)
# The same seat ID is valid in another fleet with a distinct current agent.
other_fleet = put(replacement(0, 'other-fleet', [seat('fleet-third')]), fleet='other')
assert dormant(other_fleet, 1, 1)['seats'][0]['seat_id'] == 'seat-a'
put(replacement(1, 'cross-duplicate', [seat(seat_id='unbound-seat')]), fleet='other', status=409)
# A removed agent may take a new seat; old seat-b cannot be rebound afterward.
replacement_slot = put(replacement(2, 'replacement-slot', [seat(), seat('fleet-other', 'seat-c')]))
assert dormant(replacement_slot, 3, 2)['seats'][1]['seat_id'] == 'seat-c'
put(replacement(3, 'old-binding-rebind', [seat(), seat('fleet-third', 'seat-b')]), status=409)
put(replacement(3, 'duplicate-current-agent', [seat(), seat(seat_id='seat-d')]), status=422)
cleared = put(replacement(3, 'clear-fleet', []))
assert dormant(cleared, 4, 0)['seats'] == []
assert put(initial_request) == dict(initial, replayed=True), 'Replay returned latest loadout'
assert show()['loadout'] == cleared['loadout']

# Live projection follows scope/model/retirement; the accepted receipt is immutable.
receipt_request = replacement(0, 'frozen-receipt', [seat('fleet-replay')])
receipt = put(receipt_request, fleet='receipt')
updated_scope = set_scope('fleet-replay', 1, 'fixture/narrowed')
register('fleet-replay', model='new-observed-model')
projection = dormant(show('receipt'), 1, 1)['seats'][0]
assert projection['scope_revision'] == 1 and projection['current_scope_revision'] == 2
assert projection['scope'] == updated_scope and projection['observed_model'] == 'new-observed-model'
put(replacement(1, 'scope-stale', [seat('fleet-replay')]), fleet='receipt', status=409)
api('agents/fleet-replay/retire', {'reason': 'Fixture changed after receipt'}, captain=True)
assert show('receipt')['loadout']['seats'][0]['observed_retired_at']
before_replay = fleet_rows()
assert put(receipt_request, fleet='receipt') == dict(receipt, replayed=True)
put(dict(receipt_request, revision=1), fleet='receipt', status=409)
assert fleet_rows() == before_replay, 'Replay or conflict rewrote immutable evidence'

# Existing and absent CAS each have exactly one winner, one receipt and one audit.
for fleet, revision in [('race-new', 0), ('race-existing', 1)]:
    if revision:
        put(replacement(0, 'seed', []), fleet=fleet)
    before = int(sql('SELECT count(*) FROM fleet_loadouts_versions'))
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda n: put(replacement(revision, 'race-' + str(n), []),
                                             fleet=fleet, status=None), range(2)))
    assert sorted(status for status, _ in results) == [200, 409], results
    winner = next(body for status, body in results if status == 200)
    assert dormant(winner, revision + 1, 0) == show(fleet)['loadout']
    assert int(sql('SELECT count(*) FROM fleet_loadouts_versions')) == before + 1

identical = replacement(0, 'identical-concurrent', [seat('fleet-same-key')])
before = int(sql('SELECT count(*) FROM fleet_loadouts_versions'))
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda _: put(identical, fleet='same-key'), range(2)))
assert sorted(result['replayed'] for result in results) == [False, True], results
assert results[0]['loadout'] == results[1]['loadout']
assert int(sql('SELECT count(*) FROM fleet_loadouts_versions')) == before + 1
# Global current-agent exclusion also serializes writers to distinct fleets.
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda fleet: put(replacement(0, 'cross', [seat('fleet-cross-race')]),
                                             fleet=fleet, status=None), ['cross-a', 'cross-b']))
assert sorted(status for status, _ in results) == [200, 409], results

# Scope writer holds admission custody before its blocked policy row is updated.
process = locker("SELECT agent_id FROM seat_scopes WHERE agent_id='fleet-lock-scope' FOR UPDATE")
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    scope_writer = pool.submit(set_scope, 'fleet-lock-scope', 1, 'fixture/changed')
    wait_for_lock(scope_writer, 'seat_scopes')
    loadout_writer = pool.submit(put, replacement(0, 'scope-lock', [seat('fleet-lock-scope')]),
                                 fleet='scope-lock', status=409)
    time.sleep(0.15)
    assert not loadout_writer.done(), 'Loadout ignored concurrent canonical scope writer'
    unlock(process)
    assert scope_writer.result()['revision'] == 2
    loadout_writer.result()
assert dormant(show('scope-lock'), 0, 0)['changed_by'] is None

# Shared target row custody prevents validation from racing identity changes.
for agent, change in [('fleet-lock-retire', "retired_at=clock_timestamp(),retired_by='captain',retire_reason='Fixture'"),
                      ('fleet-lock-harness', "harness='claude'")]:
    process = locker("SELECT id FROM agents WHERE id='" + agent + "' FOR UPDATE")
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        writer = pool.submit(put, replacement(0, 'identity-lock', [seat(agent)]),
                             fleet=agent, status=422)
        wait_for_lock(writer, 'agents')
        assert not writer.done()
        unlock(process, "UPDATE agents SET " + change + " WHERE id='" + agent + "'")
        writer.result()
    assert dormant(show(agent), 0, 0)['changed_by'] is None

# Exact accepted upper bounds and count derive solely from the full seat list.
limit_seats = []
for n in range(32):
    agent = 'fleet-limit-' + str(n)
    register(agent)
    set_scope(agent)
    limit_seats.append(seat(agent, 'limit-' + str(n), desired_model='é'*128,
                           desired_effort='é'*32))
limit_request = replacement(0, 'k'*128, limit_seats)
limits = dormant(put(limit_request, fleet='limits'), 1, 32)
assert all(len(s['desired_model'].encode()) == 256 for s in limits['seats'])
assert all(len(s['desired_effort'].encode()) == 64 for s in limits['seats'])
limit_before = fleet_rows()
put(replacement(1, 'overflow', limit_seats + [seat('fleet-race-a', 'overflow')]),
    fleet='limits', status=422)
assert fleet_rows() == limit_before

# Real signed captain session and rendered WebSocket transport reach the service.
class FleetDocument(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.elements = {}
        self.fields = {}
        self.definitions = {}
        self.current_field = None
        self.definition_tag = None
        self.definition_text = ''
        self.definition_label = None
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if attrs.get('id'):
            self.elements[attrs['id']] = attrs
        if tag == 'textarea' and attrs.get('name'):
            self.current_field = attrs['name']
            self.fields[self.current_field] = ''
        if tag in ['dt', 'dd']:
            self.definition_tag = tag
            self.definition_text = ''

    def handle_data(self, value):
        if self.current_field is not None:
            self.fields[self.current_field] += value
        if self.definition_tag is not None:
            self.definition_text += value

    def handle_endtag(self, tag):
        if tag == 'textarea':
            self.current_field = None
        if tag == self.definition_tag:
            if tag == 'dt':
                self.definition_label = self.definition_text.strip()
            elif self.definition_label is not None:
                self.definitions[self.definition_label] = self.definition_text.strip()
            self.definition_tag = None


before_public = fleet_rows()
public = RenderedView(URL, '/settings')
assert 'fleet-select' not in FleetDocument(public.document).elements
for event, fields in [('open_fleet', {'fleet_id': 'fleet-ui'}),
                      ('save_fleet', {'seats_json': '[]'})]:
    public.request('event', {'type': 'form', 'event': event,
                            'value': urllib.parse.urlencode(fields)})
assert 'fleet-loadout-editor' not in FleetDocument(public.document).elements
assert 'Captain access required' in public.document
public.close()
assert fleet_rows() == before_public

register('fleet-ui-seat', model='ui-observed-model')
set_scope('fleet-ui-seat')
jar = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
with browser.open(URL + '/settings') as response:
    csrf = Page(); csrf.feed(response.read().decode())
with browser.open(urllib.request.Request(URL + '/settings/unlock', data=urllib.parse.urlencode(
        {'token': CAPTAIN, '_csrf_token': csrf.csrf}).encode())) as response:
    assert response.status == 200
cookie = '; '.join(c.name + '=' + c.value for c in jar)
settings = RenderedView(URL, '/settings', cookie)
assert 'fleet-select' in FleetDocument(settings.document).elements


def ui_event(name, fields=None, form=False):
    return FleetDocument(settings.request('event', {'type': 'form' if form else 'click',
        'event': name, 'value': urllib.parse.urlencode(fields or {}) if form else fields or {}}))


page = ui_event('open_fleet', {'fleet_id': 'fleet-ui'}, form=True)
assert 'fleet-loadout-editor' in page.elements
assert page.elements['fleet-loadout-form']['phx-change'] == 'fleet_draft'
assert page.elements['fleet-loadout-form']['phx-submit'] == 'save_fleet'
assert json.loads(page.fields['seats_json']) == []
assert 'readonly' not in page.elements['fleet-seats-json']
assert dormant(show('fleet-ui'), 0, 0)['updated_at'] is None
ui_seat = seat('fleet-ui-seat', desired_model='ui-desired-model',
               desired_effort='ui-desired-effort', desired_host_id='ui-desired-host')
draft = {'seats_json': json.dumps([ui_seat])}
page = ui_event('fleet_draft', draft, form=True)
assert json.loads(page.fields['seats_json']) == [ui_seat]
ui_operational_before = rows(operational_tables)
page = ui_event('save_fleet', draft, form=True)
ui_saved = show('fleet-ui')
assert dormant(ui_saved, 1, 1)['seats'][0]['desired_model'] == 'ui-desired-model'
assert 'Configuration saved at revision 1.' in settings.document
assert 'readonly' in page.elements['fleet-seats-json']
assert page.definitions['Desired host'] == 'ui-desired-host (unverified)'
assert page.definitions['Desired model'] == 'ui-desired-model (catalog unverified)'
assert page.definitions['Desired effort'] == 'ui-desired-effort (unverified)'
assert page.definitions['Observed model'] == 'ui-observed-model'
assert page.definitions['Desired scope revision'] == page.definitions['Current scope revision'] == '1'
assert 'Disabled' in settings.document and 'Not activatable' in settings.document
assert 'Host readiness: unverified' in settings.document
assert 'Canonical current scope (read-only)' in settings.document
assert json.loads(page.fields['seats_json']) == [ui_seat], 'Observed fields entered editable JSON'
assert rows(operational_tables) == ui_operational_before
ui_rows = fleet_rows()
ui_event('save_fleet', {'seats_json': '[]'}, form=True)
assert fleet_rows() == ui_rows, 'Queued duplicate UI submit created another revision'
assert show('fleet-ui')['loadout'] == ui_saved['loadout']
page = ui_event('close_fleet')
assert 'fleet-loadout-editor' not in page.elements and 'fleet-select' in page.elements
assert fleet_rows() == ui_rows

# Reopening refreshes observations without changing persisted desired fields.
register('fleet-ui-seat', model='ui-new-observed-model')
set_scope('fleet-ui-seat', 1, 'fixture/ui-narrowed')
page = ui_event('open_fleet', {'fleet_id': 'fleet-ui'}, form=True)
assert 'readonly' not in page.elements['fleet-seats-json']
assert json.loads(page.fields['seats_json']) == [ui_seat]
assert page.definitions['Observed model'] == 'ui-new-observed-model'
assert page.definitions['Desired scope revision'] == '1'
assert page.definitions['Current scope revision'] == '2'
assert 'Scope has changed since this seat configuration was saved.' in settings.document
assert dormant(show('fleet-ui'), 1, 1)['seats'][0]['desired_model'] == 'ui-desired-model'
ui_event('fleet_draft', {'seats_json': '[]'}, form=True)
ui_event('close_fleet')
page = ui_event('open_fleet', {'fleet_id': 'fleet-ui'}, form=True)
assert json.loads(page.fields['seats_json']) == [ui_seat], 'Dismissal persisted an unsaved draft'
assert dormant(show('fleet-ui'), 1, 1)['seats'][0]['current_scope_revision'] == 2
settings.close()

# Enforced agent auth never expands ordinary/coordinator access to loadouts.
rpc('Application.put_env(:agentboard, :coordinator_id, "fleet-coordinator")')
agent_token = api('agents/fleet-seat/tokens/issue', {}, captain=True)['token']
coordinator_token = api('agents/fleet-coordinator/tokens/issue', {}, captain=True)['token']
rpc('Application.put_env(:agentboard, :agent_auth_mode, "enforce")')
for token, actor in [(None, 'fleet-seat'), (agent_token, 'fleet-seat'),
                     (coordinator_token, 'fleet-coordinator')]:
    api('fleets/protected/loadout', token=token, actor=actor, status=403)
    api('fleets/protected/loadout', replacement(seats=[]), token=token,
        actor=actor, method='PUT', status=403)
protected_before = rows(operational_tables)
assert dormant(show('protected'), 0, 0)['id'] == 'protected'
protected = put(replacement(seats=[]), fleet='protected')
assert dormant(protected, 1, 0)['changed_by'] == 'captain'
assert rows(operational_tables) == protected_before, 'Protected write changed or created operational identities'
rpc('Application.put_env(:agentboard, :agent_auth_mode, "off")')

# Immutable binding, saved response and audit evidence reject all destructive SQL.
for table in ['fleet_seat_bindings', 'fleet_loadout_receipts', 'fleet_loadouts_versions']:
    before = rows([table])
    for operation in ['UPDATE "' + table + '" SET ' +
                      ('seat_id=seat_id' if table == 'fleet_seat_bindings' else
                       'idempotency_key=idempotency_key' if table == 'fleet_loadout_receipts' else 'provenance=provenance'),
                      'DELETE FROM "' + table + '"', 'TRUNCATE "' + table + '"']:
        result = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', operation],
                                capture_output=True, text=True)
        assert result.returncode != 0, 'Immutable fleet evidence accepted: ' + operation
    assert rows([table]) == before
assert int(sql('SELECT version FROM board_schema WHERE id=1')) >= 35
assert sql("SELECT count(*) FROM agents WHERE id='captain'") == '0', 'Fleet API bootstrapped captain'
print('Dormant FleetLoadout auth, exact validation, identity/scope fences, CAS, immutable replay, real Settings transport and operational isolation passed')
