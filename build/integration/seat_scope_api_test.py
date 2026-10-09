"""Captain-managed seat scope at the packaged HTTP, CLI and PostgreSQL boundary.

All actors, repositories, tokens and tasks are disposable local fixture data.
This proves task admission and audit; it does not exercise a fleet scheduler.
"""
import concurrent.futures
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from liveview_client import Page, RenderedView

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-seat-scope-captain-0123456789'
TOKEN = Path(os.environ['TEST_TMPDIR']) / 'scope-captain.token'
TOKEN.write_text(CAPTAIN + '\n')
TOKEN.chmod(0o600)
BASE = dict(os.environ, AGENT_ID='scope-captain', AGENTBOARD_MODEL='fixture-model',
            AGENTBOARD_HARNESS='codex', AGENTBOARD_CAPTAIN_TOKEN_FILE=str(TOKEN))


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=None, *, actor='scope-captain', harness='codex', captain=False,
        token=None, status=200, method=None, headers=None):
    request_headers = {'X-Agentboard-Agent': actor, 'X-Agentboard-Model': 'fixture-model',
                       'X-Agentboard-Harness': harness, 'Content-Type': 'application/json',
                       'X-Agentboard-Worker-Protocol': '1'}
    if captain:
        request_headers['Authorization'] = 'Bearer ' + CAPTAIN
        request_headers['X-Agentboard-Captain-Token'] = CAPTAIN
    if token:
        request_headers['Authorization'] = 'Bearer ' + token
    request_headers.update(headers or {})
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=request_headers,
                                    data=None if data is None else json.dumps(data).encode(),
                                    method=method)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    assert CAPTAIN not in json.dumps(body), 'Captain capability leaked'
    if status is None:
        return response.status, body
    assert response.status == status, (path, response.status, status, body)
    return body


def cli(*args, actor='scope-captain', harness='codex', code=0, env=None):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args],
                            env=dict(BASE, AGENT_ID=actor, AGENTBOARD_HARNESS=harness, **(env or {})),
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert CAPTAIN not in result.stdout + result.stderr, 'Captain capability leaked'
    return json.loads(result.stderr if code else result.stdout)


def replacement(revision=0, repos=None, required=None, allowed=None):
    return {'allowed_repos': ['fixture/scope'] if repos is None else repos,
            'required_labels': [] if required is None else required,
            'allowed_labels': [] if allowed is None else allowed, 'revision': revision}


def scope(agent):
    return api('agents/' + agent + '/scope')['scope']


def set_scope(agent, data=None, **kwargs):
    return api('agents/' + agent + '/scope', replacement() if data is None else data,
               captain=True, method='PUT', **kwargs)


def register(agent, harness='codex', **fields):
    return api('agents/register', dict(name=agent, **fields), actor=agent, harness=harness)['agent']


def task(task_id, repo='fixture/scope', labels=None):
    return api('tasks', {'id': task_id, 'title': 'Seat scope fixture', 'repo': repo,
                        'labels': ['security', 'backend', 'urgent', 'extra'] if labels is None else labels})['task']


def unchanged_rejection(task_id, action, data, *, method=None, **kwargs):
    before = api('tasks/' + task_id)
    path = 'tasks/' + task_id + ('/' + action if action else '')
    result = api(path, data, method=method, status=409, **kwargs)
    assert 'scope' in result['error']['message'].lower(), result
    assert api('tasks/' + task_id) == before, 'Rejected admission changed task or history'


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
for agent in ['scope-captain', 'scope-seat', 'scope-other', 'scope-legacy', 'scope-race',
              'scope-new-race', 'scope-lock', 'scope-cli', 'scope-coordinator', 'scope-runtime', 'scope-ui', 'scope-cast']:
    register(agent)

# Absent policy has an explicit, readable state; metadata and identity flags are not authority.
legacy = scope('scope-legacy')
assert legacy == {'agent_id': 'scope-legacy', 'state': 'unmanaged', 'revision': 0,
                  'allowed_repos': [], 'required_labels': [], 'allowed_labels': [],
                  'changed_by': None, 'updated_at': None}, legacy
api('agents/missing-seat/scope', status=404)
assert cli('agent', 'scope', 'show', 'scope-legacy')['scope'] == legacy
api('agents/scope-seat/scope', replacement(), method='PUT', status=403)
api('agents/scope-seat/scope', replacement(), method='PUT', actor='scope-coordinator',
    headers={'X-Agentboard-Availability-Admin': 'true', 'X-Agentboard-Role': 'captain'}, status=403)
api('agents/scope-seat/scope', replacement(), method='PUT',
    headers={'Authorization': 'Bearer fixture-invalid-captain-token'}, status=403)
api('agents/register', {'allowed_repos': ['foreign/repo']}, actor='scope-seat', status=422)
api('agents/register', {'scope': replacement()}, actor='scope-seat', status=422)
register('scope-seat', capabilities=['availability_admin', 'scope_admin'],
         metadata={'availability_admin': True, 'scope': replacement(repos=['foreign/repo'])})
assert scope('scope-seat')['state'] == 'unmanaged'
api('agents/scope-seat/scope', replacement(), method='PUT', actor='scope-seat', status=403)

# Full replacement rejects partial/null/unknown/wildcard values without creating an audit row.
invalid = [None, [], {'allowed_repos': []}, dict(replacement(), availability_admin=True),
           dict(replacement(), changed_by='spoofed')]
invalid += [{k: v for k, v in replacement().items() if k != field} for field in replacement()]
for field in ['allowed_repos', 'required_labels', 'allowed_labels']:
    invalid += [dict(replacement(), **{field: value}) for value in [None, 'security', [None], [1], ['*'], ['bad\x00label'], ['two\nlines'], ['tab\tlabel'], ['delete\x7flabel']]]
invalid += [replacement(repos=value) for value in [[], ['scope'], ['fixture/*'], ['https://github.com/fixture/scope']]]
invalid += [replacement(revision=value) for value in [-1, '0', 0.5, True]]
for data in invalid:
    # Explicit null bodies are encoded; passing data=None would otherwise mean a read.
    if data is None:
        request = urllib.request.Request(URL + '/api/v1/agents/scope-seat/scope', data=b'null',
            method='PUT', headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + CAPTAIN,
            'X-Agentboard-Agent': 'scope-captain', 'X-Agentboard-Model': 'fixture-model', 'X-Agentboard-Harness': 'codex'})
        try:
            urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            assert error.code in (400, 422), error.code
        else:
            raise AssertionError('Null scope body was accepted')
    else:
        set_scope('scope-seat', data, status=422)
assert scope('scope-seat')['state'] == 'unmanaged'
assert sql('SELECT count(*) FROM seat_scopes_versions') == '0'

configured = set_scope('scope-seat', replacement(repos=['Fixture/Scope', 'fixture/scope'],
    required=['security', 'backend', 'security'], allowed=['urgent', 'routine', 'urgent']))['scope']
assert configured['agent_id'] == 'scope-seat' and configured['state'] == 'managed'
assert configured['revision'] == 1 and configured['allowed_repos'] == ['fixture/scope']
assert configured['required_labels'] == ['security', 'backend']
assert configured['allowed_labels'] == ['urgent', 'routine']
assert configured['changed_by'] == 'scope-captain' and configured['updated_at']
assert api('agents/scope-seat')['agent']['scope'] == configured
register('scope-seat', metadata={'scope': replacement(repos=['foreign/repo'])})
assert scope('scope-seat') == configured, 'Registration overwrote captain scope'
set_scope('scope-seat', replacement(), status=409)
assert scope('scope-seat') == configured
assert sql("SELECT count(*) FROM seat_scopes_versions WHERE version_source_id='scope-seat'") == '1'
assert sql("SELECT provenance->>'agent' FROM seat_scopes_versions WHERE version_source_id='scope-seat'") == 'scope-captain'

# Raw HTTP and packaged CLI enforce the same repo + required ALL + allowed ANY predicate.
for suffix, repo, labels in [('other-repo', 'foreign/scope', ['security', 'backend', 'urgent']),
                             ('bare-repo', 'scope', ['security', 'backend', 'urgent']),
                             ('null-repo', None, ['security', 'backend', 'urgent']),
                             ('missing-required', 'fixture/scope', ['security', 'urgent']),
                             ('missing-allowed', 'fixture/scope', ['security', 'backend']),
                             ('label-case', 'fixture/scope', ['Security', 'backend', 'urgent'])]:
    task_id = 'scope-deny-' + suffix
    task(task_id, repo, labels)
    unchanged_rejection(task_id, 'claim', {}, actor='scope-seat')
    before = api('tasks/' + task_id)
    error = cli('task', 'claim', task_id, actor='scope-seat', code=4)
    assert 'scope' in error['error']['message'].lower(), error
    assert api('tasks/' + task_id) == before
for suffix, labels in [('urgent', ['security', 'backend', 'urgent', 'extra']),
                       ('routine', ['backend', 'routine', 'security'])]:
    task_id = 'scope-allow-' + suffix
    task(task_id, 'Fixture/Scope', labels)
    assert api('tasks/' + task_id + '/claim', {}, actor='scope-seat')['task']['assignee_id'] == 'scope-seat'
task('scope-manual-legacy', None, [])
assert api('tasks/scope-manual-legacy/claim', {}, actor='scope-legacy')['task']['assignee_id'] == 'scope-legacy'

# Destination admission covers all mutation routes, including protected captain assignment.
set_scope('scope-other', replacement(repos=['foreign/scope']))
task('scope-assign-denied')
for captain in [False, True]:
    unchanged_rejection('scope-assign-denied', 'assign', {'to': 'scope-other'}, captain=captain)
task('scope-assign-allowed')
api('tasks/scope-assign-allowed/assign', {'to': 'scope-seat'}, captain=True)
api('tasks/scope-assign-allowed/claim', {}, actor='scope-seat')
unchanged_rejection('scope-assign-allowed', 'handoff', {'to': 'scope-other', 'note': 'Denied destination'},
                    actor='scope-seat', captain=True)
api('tasks/scope-assign-allowed/handoff', {'to': 'scope-legacy', 'note': 'Manual legacy destination'}, actor='scope-seat')
task('scope-reclaim-denied')
api('tasks/scope-reclaim-denied/claim', {'ttl_seconds': 0.05}, actor='scope-legacy')
time.sleep(0.08)
unchanged_rejection('scope-reclaim-denied', 'reclaim', {}, actor='scope-other')
api('tasks/scope-reclaim-denied/reclaim', {}, actor='scope-seat')

# Editing owned task repo/labels cannot evade scope; safe ordinary edits remain possible.
for fields in [{'repo': 'foreign/scope'}, {'labels': ['security', 'urgent']},
               {'repo': None}, {'labels': ['security', 'backend']}]:
    unchanged_rejection('scope-allow-urgent', '', fields, method='PATCH', actor='scope-seat')
api('tasks/scope-allow-urgent', {'title': 'Still permitted', 'labels': ['security', 'backend', 'routine', 'extra']},
    method='PATCH', actor='scope-seat')

# Guard the labels that the Task resource actually persists, including Ash trimming.
# Raw padded input must not exploit an exact-label gate checked before casting.
set_scope('scope-cast', replacement(allowed=['safe', ' padded ']))
task('scope-cast-task', labels=['safe'])
api('tasks/scope-cast-task/claim', {}, actor='scope-cast')
unchanged_rejection('scope-cast-task', '', {'labels': [' padded ']}, method='PATCH', actor='scope-cast')
set_scope('scope-cast', replacement(1, allowed=['padded']))
cast_edit = api('tasks/scope-cast-task', {'labels': [' padded ']}, method='PATCH', actor='scope-cast')['task']
assert cast_edit['labels'] == ['padded']

# Availability remains conjunctive; captain authority cannot override managed scope.
api('availability', {'agent_id': 'scope-seat', 'state': 'reserved', 'reason': 'Named work only'}, captain=True)
task('scope-reserved-good')
api('tasks/scope-reserved-good/claim', {}, actor='scope-seat', status=409)
api('tasks/scope-reserved-good/assign', {'to': 'scope-seat'}, captain=True)
api('tasks/scope-reserved-good/claim', {}, actor='scope-seat')
task('scope-reserved-bad', 'foreign/scope')
unchanged_rejection('scope-reserved-bad', 'assign', {'to': 'scope-seat'}, captain=True)
api('availability', {'agent_id': 'scope-seat', 'state': 'active'}, captain=True)

# Narrowing takes effect for new work while preserving current ownership and recovery.
set_scope('scope-seat', replacement(revision=1, repos=['foreign/scope']))
cli('task', 'renew', 'scope-allow-urgent', actor='scope-seat')
cli('task', 'update', 'scope-allow-urgent', '--status', 'blocked', '--body', 'Existing owner remains responsible', actor='scope-seat')
api('tasks/scope-allow-urgent', {'title': 'Progress survives scope narrowing'}, method='PATCH', actor='scope-seat')
api('tasks/scope-allow-urgent/release', {}, actor='scope-seat')
assert api('tasks/scope-allow-urgent')['task']['status'] == 'open'
unchanged_rejection('scope-allow-urgent', 'claim', {}, actor='scope-seat')

# Typed work orders require a task and use recipient scope; ordinary messages remain recovery-safe.
for agent in ['fanout-match', 'fanout-mismatch', 'fanout-legacy', 'fanout-unavailable']:
    register(agent, harness='scope-fixture')
set_scope('fanout-match', replacement(required=['security']))
set_scope('fanout-mismatch', replacement(required=['unmatched']))
set_scope('fanout-unavailable', replacement())
api('availability', {'agent_id': 'fanout-unavailable', 'state': 'out_of_service', 'reason': 'Fixture maintenance'}, captain=True)
task('scope-fanout')
api('messages', {'to': 'fanout-match', 'body': 'Missing canonical task', 'kind': 'task_order'}, status=422)
api('messages', {'to': 'fanout-mismatch', 'task': 'scope-fanout', 'body': 'Mismatched order', 'kind': 'task_order'}, status=409)
api('messages', {'to': 'fanout-match', 'task': 'scope-fanout', 'body': 'Matching order', 'kind': 'task_order'})
api('messages', {'to': 'fanout-mismatch', 'task': 'scope-fanout', 'body': 'Ordinary recovery note'})
orders = cli('msg', 'broadcast', '--task', 'scope-fanout', '--body', 'Captain manual fanout', '--selector-harness', 'scope-fixture')
assert orders['recipient_ids'] == ['fanout-legacy', 'fanout-match'], orders
assert len(orders['message_ids']) == 2
assert sql("SELECT count(*) FROM messages WHERE recipient_id='fanout-mismatch' AND kind='task_order'") == '0'

# Real CLI does full replacement, not an accidental merge; token files fail closed.
cli_scope = cli('agent', 'scope', 'set', 'scope-cli', '--repo', 'Fixture/Scope',
                '--required-label', 'security', '--allowed-label', 'api,cli', '--revision', '0')['scope']
assert cli_scope['revision'] == 1 and cli_scope['allowed_labels'] == ['api,cli']
assert cli('agent', 'scope', 'show', 'scope-cli')['scope'] == cli_scope
cli('agent', 'scope', 'set', 'scope-cli', '--repo', 'fixture/scope', '--revision', '0', code=4)
cleared = cli('agent', 'scope', 'set', 'scope-cli', '--repo', 'fixture/scope', '--revision', '1')['scope']
assert cleared['required_labels'] == [] and cleared['allowed_labels'] == []
cli('agent', 'scope', 'set', 'scope-cli', '--repo', 'fixture/scope', code=2)
TOKEN.chmod(0o644)
cli('agent', 'scope', 'set', 'scope-cli', '--repo', 'foreign/scope', '--revision', '2', code=2)
TOKEN.chmod(0o600)
assert scope('scope-cli') == cleared

# Two concurrent editors of an existing or absent policy have exactly one winner and audit.
set_scope('scope-race')
for agent, revision in [('scope-race', 1), ('scope-new-race', 0)]:
    before = int(sql("SELECT count(*) FROM seat_scopes_versions WHERE version_source_id='" + agent + "'"))
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        outcomes = list(pool.map(lambda repo: set_scope(agent, replacement(revision, repos=[repo]), status=None),
                                 ['fixture/first', 'fixture/second']))
    assert sorted(status for status, _ in outcomes) == [200, 409], outcomes
    winner = next(body['scope'] for status, body in outcomes if status == 200)
    assert scope(agent) == winner and winner['revision'] == revision + 1
    assert int(sql("SELECT count(*) FROM seat_scopes_versions WHERE version_source_id='" + agent + "'")) == before + 1

# A policy writer blocked on its row already holds exclusive admission custody.
# The claimant must wait, then re-read the committed policy instead of using stale scope.
set_scope('scope-lock')
task('scope-lock-task')
locker = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1'],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
locker.stdin.write("BEGIN; SELECT agent_id FROM seat_scopes WHERE agent_id='scope-lock' FOR UPDATE; SELECT 'ready';\n")
locker.stdin.flush()
while locker.stdout.readline().strip() != 'ready':
    assert locker.poll() is None
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    writer = pool.submit(set_scope, 'scope-lock', replacement(1, repos=['foreign/scope']))
    deadline = time.monotonic() + 5
    while sql("SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE '%seat_scopes%'") == '0':
        assert time.monotonic() < deadline and not writer.done(), 'Scope writer did not wait on its policy row'
        time.sleep(0.02)
    claimant = pool.submit(api, 'tasks/scope-lock-task/claim', {}, actor='scope-lock', status=409)
    time.sleep(0.15)
    assert not claimant.done(), 'Task admission ignored concurrent scope writer'
    locker.stdin.write('COMMIT;\n'); locker.stdin.flush(); locker.stdin.close()
    assert writer.result()['scope']['revision'] == 2
    assert 'scope' in claimant.result()['error']['message'].lower()
assert locker.wait(timeout=10) == 0, locker.stderr.read()
assert api('tasks/scope-lock-task')['task']['status'] == 'open'

# Enrollment cannot broaden captain policy; exact prior receipts survive later narrowing.
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
set_scope('scope-runtime', replacement(repos=['fixture/receipts']))
provision = {'worker_id': 'scope-runtime', 'host_id': 'scope-host', 'repos': ['fixture/receipts'],
             'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'scope-provision'}
api('workers/provision', dict(provision, repos=['fixture/receipts', 'foreign/repo']), captain=True, status=409)
assert sql("SELECT count(*) FROM cooperation_subscriptions WHERE id='scope-runtime'") == '0'
host = api('workers/provision', provision, captain=True)['host_token']
capabilities = {name: {'supported': name in ('receipt', 'recovery'), 'reason': 'Manual fixture'}
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bound = api('workers/scope-runtime/bind', {'idempotency_key': 'scope-bind', 'expected_epoch': 0,
    'host_id': 'scope-host', 'session_id': 'scope-session', 'pane_id': 'scope-pane',
    'adapter': 'manual', 'adapter_version': '1', 'capabilities': capabilities}, token=host)
task('scope-receipt-task', 'fixture/receipts')
api('tasks/scope-receipt-task/claim', {}, actor='scope-runtime')
batch = api('workers/scope-runtime/reserve', {'binding_epoch': 1, 'idempotency_key': 'scope-reserve'}, token=host)['batch']
assert batch and batch['delivery_ids']
set_scope('scope-runtime', replacement(1, repos=['foreign/receipts']))
api('tasks/scope-receipt-task/renew', {}, actor='scope-runtime')
fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
api('workers/scope-runtime/attempts/' + batch['attempt_id'] + '/result', dict(fences, status='submitted'), token=host)
receipt = dict(fences, attempt_id=batch['attempt_id'], idempotency_key='scope-handled',
               kind='handled', delivery_ids=batch['delivery_ids'])
api('workers/scope-runtime/receipts', receipt, token=bound['receipt_token'])
assert api('workers/scope-runtime/attempts/' + batch['attempt_id'] + '/reconcile', fences, token=host)['resolved']
api('workers/provision', provision, captain=True, status=409)

# Real signed captain session and LiveView transport preserve a stale draft without writing.
class ScopeDocument(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.dialogs = {}
        self.buttons = {}
        self.forms = []
        self.fields = {}
        self.textarea = None
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'dialog':
            self.dialogs[attrs.get('id')] = attrs
        if tag == 'button' and attrs.get('id'):
            self.buttons[attrs['id']] = attrs
        if tag == 'form' and attrs.get('phx-submit') == 'set_scope':
            self.forms.append(attrs)
        if tag == 'textarea' and attrs.get('name'):
            self.textarea = attrs['name']
            self.fields[self.textarea] = ''

    def handle_data(self, value):
        if self.textarea is not None:
            self.fields[self.textarea] += value

    def handle_endtag(self, tag):
        if tag == 'textarea':
            self.textarea = None


public = RenderedView(URL, '/agents')
assert 'Unmanaged' in public.document and 'Managed' in public.document
assert 'scope-open-scope-ui' not in ScopeDocument(public.document).buttons
public.request('event', {'type': 'click', 'event': 'open_scope', 'value': {'id': 'scope-ui'}})
public.request('event', {'type': 'form', 'event': 'set_scope',
    'value': urllib.parse.urlencode({'agent_id': 'scope-ui', 'revision': '0', 'allowed_repos': 'foreign/repo'})})
assert 'scope-dialog' not in ScopeDocument(public.document).dialogs
assert scope('scope-ui')['state'] == 'unmanaged'
public.close()
jar = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
with browser.open(URL + '/settings') as response:
    csrf = Page(); csrf.feed(response.read().decode())
with browser.open(urllib.request.Request(URL + '/settings/unlock', data=urllib.parse.urlencode(
        {'token': CAPTAIN, '_csrf_token': csrf.csrf}).encode())) as response:
    assert response.status == 200
cookie = '; '.join(c.name + '=' + c.value for c in jar)
roster = RenderedView(URL, '/agents', cookie)


def ui_event(name, fields=None, form=False):
    return ScopeDocument(roster.request('event', {'type': 'form' if form else 'click', 'event': name,
        'value': urllib.parse.urlencode(fields or {}) if form else fields or {}}))


page = ui_event('open_scope', {'id': 'scope-ui'})
assert page.dialogs['scope-dialog']['data-close-event'] == 'close_scope'
assert page.dialogs['scope-dialog']['data-return-focus'] == 'scope-open-scope-ui'
assert len(page.forms) == 1 and page.forms[0]['phx-change'] == 'scope_draft'
assert page.fields == {'allowed_repos': '', 'required_labels': '', 'allowed_labels': ''}
draft = {'allowed_repos': 'fixture/scope', 'required_labels': 'security', 'allowed_labels': 'urgent\nroutine'}
page = ui_event('scope_draft', draft, form=True)
assert page.fields == draft
ui_event('close_scope')
assert 'scope-dialog' not in ScopeDocument(roster.document).dialogs
assert scope('scope-ui')['revision'] == 0, 'Dismissing scope editor wrote a policy'
ui_event('open_scope', {'id': 'scope-ui'})
page = ui_event('set_scope', dict(draft, allowed_repos='*'), form=True)
assert 'scope-dialog' in page.dialogs and page.fields['allowed_repos'] == '*'
assert scope('scope-ui')['revision'] == 0
ui_event('scope_draft', draft, form=True)
concurrent_scope = set_scope('scope-ui', replacement(repos=['fixture/concurrent']))['scope']
# Actual fallback refresh also proves a draft survives independently of roster updates.
time.sleep(5.2)
page = ui_event('column_page', {'status': 'invalid', 'direction': 'next'})
assert page.fields == draft
page = ui_event('set_scope', draft, form=True)
assert 'scope-dialog' in page.dialogs and page.fields == draft
assert 'Your draft is kept. Close and reopen' in roster.document
assert scope('scope-ui') == concurrent_scope, 'Stale modal replaced a newer policy'
ui_event('close_scope')
page = ui_event('open_scope', {'id': 'scope-ui'})
assert page.fields['allowed_repos'] == 'fixture/concurrent'
other_scope = scope('scope-other')
page = ui_event('set_scope', dict(draft, agent_id='scope-other', revision='999'), form=True)
assert 'scope-dialog' not in page.dialogs and 'Seat scope updated.' in roster.document
assert scope('scope-other') == other_scope, 'Submitted form fields changed socket-owned target'
ui_scope = scope('scope-ui')
assert ui_scope['revision'] == 2 and ui_scope['changed_by'] == 'captain'
assert ui_scope['required_labels'] == ['security'] and ui_scope['allowed_labels'] == ['urgent', 'routine']
roster.close()

# Protected auth mode preserves scope reads while rejecting ordinary/coordinator writes.
rpc('Application.put_env(:agentboard, :coordinator_id, "scope-coordinator")')
agent_token = api('agents/scope-cli/tokens/issue', {}, captain=True)['token']
coordinator_token = api('agents/scope-coordinator/tokens/issue', {}, captain=True)['token']
rpc('Application.put_env(:agentboard, :agent_auth_mode, "enforce")')
api('agents/scope-cli/scope', status=401)
assert api('agents/scope-cli/scope', actor='scope-cli', token=agent_token)['scope'] == cleared
api('agents/scope-cli/scope', replacement(2), actor='scope-cli', token=agent_token, method='PUT', status=403)
api('agents/scope-cli/scope', replacement(2), actor='scope-coordinator', token=coordinator_token, method='PUT', status=403)
assert api('agents/scope-cli/scope', actor='scope-coordinator', token=coordinator_token)['scope'] == cleared
assert api('agents/scope-cli', actor='scope-coordinator', token=coordinator_token)['agent']['scope'] == cleared
assert api('agents/scope-cli/scope', captain=True)['scope'] == cleared
admin_scope = set_scope('scope-cli', replacement(2))['scope']
assert admin_scope['changed_by'] == 'captain' and admin_scope['revision'] == 3
rpc('Application.put_env(:agentboard, :agent_auth_mode, "off")')

# History is append-only for normal fixture DB roles, including TRUNCATE.
for statement in ["UPDATE seat_scopes_versions SET provenance='{}'::jsonb",
                  'DELETE FROM seat_scopes_versions', 'TRUNCATE seat_scopes_versions']:
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', statement],
                            capture_output=True, text=True)
    assert result.returncode != 0, 'Scope audit accepted mutation: ' + statement
assert int(sql('SELECT version FROM board_schema WHERE id=1')) >= 34
print('Seat scope authorization, validation, HTTP/CLI admission, atomic revisions, lock fencing, recovery and immutable audit passed')
