"""Captain policy contract at the packaged HTTP, AshOban and PostgreSQL boundaries.

All actors, capabilities and policies are invented fixtures. The normal database
role uses certificate-verified TLS. Queue draining executes the real registered
worker; row-lock barriers exercise the production transactions. This fixture
does not enable a live board, contact a provider, or dispatch a native worker.
"""
import concurrent.futures
from contextlib import contextmanager
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from liveview_client import LiveView, Page


URL = os.environ['AGENTBOARD_URL'].rstrip('/')
ROOT = 'decisions/policy'
CAPTAIN = 'fixture-policy-captain-capability-0123456789'
OWNER = 'policy-owner'
OTHER = 'policy-other'
COORDINATOR = 'policy-coordinator'
MODEL = 'policy-fixture'
MISSING = object()
TOKENS = {}
SECRETS = [CAPTAIN]
POLICY_TABLES = ['decision_policy_versions', 'decision_policy_approvals',
                 'decision_policy_state', 'decision_policy_ledger']
SOURCE_TABLES = ['tasks', 'tasks_versions', 'task_events', 'decision_requests',
                 'decision_requests_versions', 'messages', 'messages_versions',
                 'decision_wakes', 'decision_wakes_versions', 'cooperation_events',
                 'cooperation_deliveries', 'wake_intents', 'wake_attempts']


def sql(statement, *, reject=False):
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-XqAt', '-v',
        'ON_ERROR_STOP=1', '-c', statement], capture_output=True, text=True, timeout=30)
    if reject:
        assert result.returncode != 0, ('Immutable SQL unexpectedly succeeded', statement)
    else:
        assert result.returncode == 0, ('Fixture SQL failed', result.stderr)
    return result.stdout.strip()


def rpc(expression):
    wrapped = 'value = (' + expression + '); IO.puts("POLICY_RESULT:" <> Jason.encode!(value))'
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', wrapped],
        capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, ('Fixture RPC failed', result.stdout, result.stderr)
    for line in result.stdout.splitlines():
        if line.startswith('POLICY_RESULT:'):
            return json.loads(line.split(':', 1)[1])
    raise AssertionError(('Missing fixture RPC result', result.stdout, result.stderr))


def setting(name, value):
    return rpc('Application.put_env(:agentboard, :' + name + ', Jason.decode!(' +
               json.dumps(json.dumps(value)) + ')); true')


def api(path, data=MISSING, *, actor=OWNER, token=MISSING, captain=False,
        status=200, method=None, headers=None, raw=False):
    request_headers = {'Content-Type': 'application/json',
        'X-Agentboard-Worker-Protocol': '1', 'X-Agentboard-Coordinator-Protocol': '1'}
    if actor is not None:
        request_headers.update({'X-Agentboard-Agent': actor,
            'X-Agentboard-Model': MODEL, 'X-Agentboard-Harness': 'codex'})
    if token is MISSING:
        token = TOKENS.get(actor)
    if token:
        request_headers['Authorization'] = 'Bearer ' + token
    if captain:
        request_headers['Authorization'] = 'Bearer ' + CAPTAIN
        request_headers['X-Agentboard-Captain-Token'] = CAPTAIN
    request_headers.update(headers or {})
    request = urllib.request.Request(URL + '/api/v1/' + path,
        data=None if data is MISSING else json.dumps(data).encode(),
        headers=request_headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        encoded = response.read()
        body = json.loads(encoded) if encoded else None
        assert all(secret not in encoded.decode() for secret in SECRETS), 'Credential leaked in HTTP response'
        expected = status if isinstance(status, tuple) else (status,)
        if status is not None:
            assert response.status in expected, (path, response.status, expected, body)
        return (response.status, body, encoded) if raw else body


def snapshot(tables=None, *, include_jobs=True):
    tables = POLICY_TABLES + SOURCE_TABLES if tables is None else tables
    result = {table: sql("SELECT md5(COALESCE(string_agg(row::text, chr(10) ORDER BY row::text),'')) "
                       'FROM (SELECT to_jsonb(t) AS row FROM ' + table + ' t) rows')
              for table in tables}
    if include_jobs:
        result['policy_jobs'] = sql("SELECT md5(COALESCE(string_agg(to_jsonb(j)::text, chr(10) "
            "ORDER BY id),'')) FROM oban_jobs j WHERE queue='decision_policy'")
    return result


def policy(name='fixture-main', version=1, *, server_mode='apply', limit=2, ci_limit=1):
    return {
        'apiVersion': 'agentboard/v1alpha1', 'kind': 'CaptainDecisionPolicy',
        'metadata': {'name': name, 'version': version, 'status': 'draft'},
        'engine': {'default_mode': 'dry_run', 'server_mode': server_mode, 'timezone': 'UTC',
            'captain_marker': {'explicit_markers': ['CAPTAIN-ONLY']},
            'answer': {'prefix': 'Auto-answered under captain policy v{version}, rule {rule_id} (source: {source})'},
            'limits': {'max_auto_answers_per_pr_per_day': limit,
                       'max_auto_ci_runs_per_decision': ci_limit}},
        'escalate_always': [{'id': 'danger', 'keywords': ['merge', 'deploy', '--yes']}],
        'rules': [{'id': 'regenerate', 'title': 'Synthetic artifact regeneration',
            'match': {'kinds': ['scope', 'approval', 'blocked_decision'],
                      'keywords_any': ['regenerat'], 'option_match': '^Proceed$'},
            'answer': 'Proceed with synthetic artifact regeneration.',
            'source': {'ruling': 'Invented fixture ruling', 'date': '2026-01-02'}},
            {'id': 'ci', 'match': {'kinds': ['approval'], 'keywords_any': ['CI'],
                                  'option_match': '^One run$'},
             'ci_runs': 1, 'answer': 'Perform one CI run.',
             'source': {'ruling': 'Invented one-run fixture ruling', 'date': '2026-01-02'}}]}


def catalog():
    return api(ROOT, captain=True)


def draft(document, **kwargs):
    return api(ROOT + '/drafts', {'policy': document}, captain=True, **kwargs)['policy']


def approve(version, **kwargs):
    return api(ROOT + '/versions/' + version['id'] + '/approve',
               {'sha256': version['sha256']}, captain=True, **kwargs)


def activate(version, generation=None, **kwargs):
    if generation is None:
        generation = catalog()['state']['generation']
    return api(ROOT + '/versions/' + version['id'] + '/activate',
               {'sha256': version['sha256'], 'generation': generation}, captain=True, **kwargs)


def install(document):
    version = draft(document)
    approve(version)
    activate(version)
    return version


def task(suffix, *, actor=OWNER, pr=None):
    identifier = 'policy-' + suffix
    data = {'id': identifier, 'title': 'Synthetic policy ' + suffix, 'repo': 'fixture/policy'}
    if pr:
        data['pr_url'] = pr
    api('tasks', data, actor=actor)
    api('tasks/' + identifier + '/claim', {}, actor=actor)
    return identifier


def request(task_id, *, question='Regenerate fixture artifacts?', findings='',
            options=None, kind='scope', gate=None, **fields):
    data = {'task': task_id, 'question': question, 'findings': findings,
            'options': ['Proceed', 'Defer'] if options is None else options, 'kind': kind}
    if gate:
        data['gate'] = gate
    data.update(fields)
    return api('decisions', data)['decision']


def decision(identifier):
    return api('decisions/' + identifier)['decision']


def explain(identifier, document=None):
    payload = {} if document is None else {'policy': document}
    return api(ROOT + '/explain/' + identifier, payload, captain=True)['evaluation']


def apply(identifier, evaluation=None, **kwargs):
    evaluation = explain(identifier) if evaluation is None else evaluation
    payload = {key: evaluation[key] for key in
               ('policy_id', 'generation', 'source_version', 'day', 'answer_sha256')}
    return api(ROOT + '/apply/' + identifier, payload, captain=True, **kwargs)


def ledger(identifier):
    return api(ROOT + '/ledger?' + urllib.parse.urlencode({'decision_id': identifier}),
               captain=True)['ledger']


def drain():
    return rpc('Oban.drain_queue(queue: :decision_policy, with_scheduled: true)')


def effects(identifier):
    return json.loads(sql("SELECT json_build_object('messages',(SELECT count(*) FROM messages "
        "WHERE id=(SELECT message_id FROM decision_requests WHERE id='%s')),"
        "'events',(SELECT count(*) FROM task_events WHERE kind='decision_answered' "
        "AND data->>'decision_id'='%s'),'wakes',(SELECT count(*) FROM decision_wakes "
        "WHERE request_id='%s'),'answered',(SELECT count(*) FROM decision_policy_ledger "
        "WHERE decision_id='%s' AND result='answered'))" % ((identifier,) * 4)))


def no_answer(identifier):
    assert decision(identifier)['status'] == 'open'
    assert effects(identifier) == {'messages': 0, 'events': 0, 'wakes': 0, 'answered': 0}


def answered(identifier, version=None):
    value = decision(identifier)
    assert value['status'] == 'answered' and value['on_behalf_of'] == 'captain', {
        'decision': value, 'evaluation': explain(identifier), 'ledger': ledger(identifier),
        'jobs': sql("SELECT jsonb_agg(jsonb_build_object('id',id,'state',state,'args',args,'errors',errors)) "
                    "FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + identifier + "%'"),
    }
    assert effects(identifier) == {'messages': 1, 'events': 1, 'wakes': 1, 'answered': 1}
    row = next(row for row in ledger(identifier) if row['result'] == 'answered')
    assert row['answer'] == value['answer']
    assert row['answer_sha256'] == hashlib.sha256(value['answer'].encode()).hexdigest()
    assert row['day'] == datetime.fromisoformat(row['created_at'].replace('Z', '+00:00')).astimezone(timezone.utc).date().isoformat()
    if version:
        assert row['policy_id'] == version['id'] and row['policy_sha256'] == version['sha256']
    assert value['answer'].startswith('Auto-answered under captain policy v')
    return row


class RowLock:
    """A real lock barrier: a held transaction must actually block its contender."""
    def __init__(self, statement):
        self.process = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-XqAt', '-v', 'ON_ERROR_STOP=1'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.output = queue.Queue()
        threading.Thread(target=self._drain, daemon=True).start()
        self.send("BEGIN; " + statement + "; SELECT 'LOCKED:' || pg_backend_pid();")
        self.pid = int(self.until('LOCKED:').split(':')[1])

    def _drain(self):
        for line in self.process.stdout:
            self.output.put(line.strip())
        self.output.put('PROCESS_EXITED')

    def send(self, statement):
        self.process.stdin.write(statement + '\n')
        self.process.stdin.flush()

    def until(self, prefix):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            line = self.output.get(timeout=max(0.1, deadline - time.monotonic()))
            assert line != 'PROCESS_EXITED', ('Lock fixture exited', self.process.stderr.read())
            if line.startswith(prefix):
                return line
        raise AssertionError('No PostgreSQL acknowledgment for ' + prefix)

    def blocked(self, future):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            assert not future.done(), ('Mutation did not wait for canonical lock', future.result())
            if int(sql('SELECT count(*) FROM pg_stat_activity WHERE %d = ANY(pg_blocking_pids(pid)) '
                       "AND wait_event_type='Lock'" % self.pid)):
                return
            time.sleep(0.025)
        raise AssertionError('No mutation blocked on fixture lock')

    def execute(self, statement):
        self.send(statement + "; SELECT 'EXECUTED';")
        self.until('EXECUTED')

    def close(self):
        self.send('COMMIT;')
        self.process.stdin.close()
        assert self.process.wait(timeout=15) == 0, self.process.stderr.read()


@contextmanager
def locked(statement):
    lock = RowLock(statement)
    try:
        yield lock
    finally:
        lock.close()


@contextmanager
def reject_insert(table, name, condition='TRUE'):
    sql("CREATE FUNCTION %s() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN "
        "IF %s THEN RAISE EXCEPTION 'synthetic policy rollback'; END IF; RETURN NEW; END $$; "
        "CREATE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION %s()" %
        (name, condition, name, table, name))
    try:
        yield
    finally:
        sql('DROP TRIGGER %s ON %s; DROP FUNCTION %s()' % (name, table, name))


def checkpoint(label):
    print('decision_policy: ' + label, flush=True)


def test_schema_and_lifecycle():
    document = policy()
    baseline = snapshot()
    # Validate the shipped bytes, not a copied fixture that can drift from the
    # user-facing example (in particular JSON escaping of option regexes).
    example_path = Path(__file__).parents[2] / 'docs/examples/decision-policy.json'
    example = json.loads(example_path.read_text(encoding='utf-8'))
    example_result = api(ROOT + '/validate', {'policy': example}, captain=True)
    assert example_result['valid'] is True and example_result['policy'] == example
    example_canonical = json.dumps(example, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    assert example_result['sha256'] == hashlib.sha256(example_canonical.encode()).hexdigest()
    validated = api(ROOT + '/validate', {'policy': document}, captain=True)
    assert validated['valid'] is True and validated['policy'] == document
    canonical = json.dumps(document, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    assert validated['sha256'] == hashlib.sha256(canonical.encode()).hexdigest()
    reordered = {key: document[key] for key in reversed(document)}
    assert api(ROOT + '/validate', {'policy': reordered}, captain=True)['sha256'] == validated['sha256']
    invalid = [dict(document, unexpected=True)]
    for path, value in [(('metadata', 'unexpected'), True), (('engine', 'server_mode'), 'APPLY'),
                        (('engine', 'timezone'), 'America/New_York')]:
        candidate = copy.deepcopy(document)
        candidate[path[0]][path[1]] = value
        invalid.append(candidate)
    unsafe = copy.deepcopy(document)
    unsafe['rules'][0]['match']['option_match'] = '(a+)+$'
    invalid.append(unsafe)
    missing = copy.deepcopy(document)
    del missing['rules'][0]['source']['date']
    invalid.append(missing)
    duplicate = copy.deepcopy(document)
    duplicate['rules'].append(copy.deepcopy(duplicate['rules'][0]))
    invalid.append(duplicate)
    for candidate in invalid:
        api(ROOT + '/validate', {'policy': candidate}, captain=True, status=422)
    assert snapshot() == baseline, 'Read-only schema validation changed board state'

    for mode in ('off', 'observe', 'enforce'):
        setting('agent_auth_mode', mode)
        for fake in [dict(actor='captain', token=None), dict(actor=COORDINATOR, token=TOKENS[COORDINATOR]),
                     dict(headers={'X-Agentboard-Role': 'captain', 'X-Agentboard-Decision-Policy-Admin': 'true'})]:
            api(ROOT + '/drafts', {'policy': document}, status=(401, 403), **fake)
        forged = copy.deepcopy(document)
        forged['metadata'].update(status='approved', approved_by='captain', approved_at='2026-01-02T00:00:00Z')
        api(ROOT + '/drafts', {'policy': forged}, captain=True, status=422)
    setting('agent_auth_mode', 'enforce')
    version = draft(document)
    assert version['sha256'] == validated['sha256'] and version['status'] == 'draft'
    assert draft(document)['id'] == version['id']
    conflict = copy.deepcopy(document)
    conflict['rules'][0]['answer'] = 'Changed answer under retained identity.'
    api(ROOT + '/drafts', {'policy': conflict}, captain=True, status=409)
    skipped = policy(version=3)
    api(ROOT + '/drafts', {'policy': skipped}, captain=True, status=409)
    initial = catalog()['state']
    assert initial['active_id'] is None
    activate(version, status=(409, 422))
    for mode in ('off', 'observe', 'enforce'):
        setting('agent_auth_mode', mode)
        before = snapshot(POLICY_TABLES)
        for path, data in [
            (ROOT + '/versions/' + version['id'] + '/approve', {'sha256': version['sha256']}),
            (ROOT + '/versions/' + version['id'] + '/activate',
             {'sha256': version['sha256'], 'generation': initial['generation']}),
            (ROOT + '/deactivate', {'generation': initial['generation']}),
        ]:
            for fake in [dict(actor='captain', token=None), dict(actor=COORDINATOR),
                         dict(headers={'X-Agentboard-Decision-Policy-Admin': 'true'})]:
                api(path, data, status=(401, 403), **fake)
        assert snapshot(POLICY_TABLES) == before, ('Lifecycle auth failure wrote state', mode)
    setting('agent_auth_mode', 'enforce')
    api(ROOT + '/versions/' + version['id'] + '/approve', {'sha256': '0' * 64}, captain=True, status=409)
    approve(version)
    before_approval_retry = snapshot(POLICY_TABLES)
    approve(version)
    assert snapshot(POLICY_TABLES) == before_approval_retry
    active = activate(version, generation=initial['generation'])['state']
    assert active['generation'] == initial['generation'] + 1 and active['active_id'] == version['id']
    deactivated = api(ROOT + '/deactivate', {'generation': active['generation']}, captain=True)['state']
    activate(version, generation=initial['generation'], status=409)
    assert catalog()['state'] == deactivated, 'Old activation retry resurrected deactivated policy'
    activate(version)
    second = draft(policy(version=2))
    assert second['status'] == 'draft' and second.get('approved_by') is None
    activate(second, status=(409, 422))
    assert catalog()['state']['active_id'] == version['id']
    checkpoint('strict schema, captain boundaries, exact approval and activation CAS')
    return version, second


def test_readonly_and_modes(version):
    setting('decision_policy_mode', 'dry_run')
    value = request(task('dry-run'))
    identifier = value['id']
    assert sql("SELECT count(*) FROM oban_jobs WHERE queue='decision_policy'") == '0'
    read_tables = POLICY_TABLES + SOURCE_TABLES + [
        'agents', 'agents_versions', 'agent_auth_observations', 'board_action_events']
    for auth_mode in ('off', 'observe', 'enforce'):
        setting('agent_auth_mode', auth_mode)
        for captain in (False, True):
            before_reads = snapshot(read_tables)
            api(ROOT + '/validate', {'policy': policy()}, captain=captain)
            first_plan = api(ROOT + '/plan', {}, captain=captain, raw=True)[2]
            second_plan = api(ROOT + '/plan', {}, captain=captain, raw=True)[2]
            assert first_plan == second_plan, ('Plan bytes changed', auth_mode, captain)
            api(ROOT + '/explain/' + identifier, {}, captain=captain)
            api(ROOT + '/ledger?decision_id=' + identifier, captain=captain)
            api(ROOT + '/versions/' + version['id'], captain=captain)
            api(ROOT, captain=captain)
            api(ROOT + '/validate', {'policy': {}}, captain=captain, status=422)
            api(ROOT + '/plan', {'unknown': True}, captain=captain, status=422)
            api(ROOT + '/explain/' + identifier, {'unknown': True}, captain=captain, status=422)
            assert snapshot(read_tables) == before_reads, ('Read-only policy changed state', auth_mode, captain)
        if auth_mode == 'observe':
            before_observations = int(sql('SELECT count(*) FROM agent_auth_observations'))
            api(ROOT + '/drafts', {'policy': policy()}, token=None, status=(401, 403))
            assert int(sql('SELECT count(*) FROM agent_auth_observations')) == before_observations + 1, 'Lifecycle attempt lost observe audit'
    before = snapshot()
    first = api(ROOT + '/plan', {}, captain=True, raw=True)[2]
    second = api(ROOT + '/plan', {}, captain=True, raw=True)[2]
    assert first == second, 'Unchanged board must produce byte-stable plan'
    assert explain(identifier) == explain(identifier)
    api(ROOT + '/ledger?decision_id=' + identifier, captain=True)
    api(ROOT + '/versions/' + version['id'], captain=True)
    assert snapshot() == before, 'Plan/explain/list/show/ledger wrote state'
    for mode in (None, '', 'APPLY', 'unexpected', 'off', 'dry_run'):
        setting('decision_policy_mode', mode)
        before = snapshot()
        apply(identifier, status=(200, 409, 422))
        no_answer(identifier)
        assert snapshot() == before, ('Disabled apply wrote state', mode)
    setting('decision_policy_mode', 'apply')
    dry_document = policy('fixture-document-dry', server_mode='dry_run')
    dry_version = install(dry_document)
    dry_decision = request(task('document-dry'))
    before = snapshot()
    apply(dry_decision['id'], status=(200, 409, 422))
    no_answer(dry_decision['id'])
    assert snapshot() == before, 'Document dry-run was overridden by server apply'
    activate(version)
    assert catalog()['state']['active_id'] != dry_version['id']
    checkpoint('read-only byte-stable plans and both fail-closed mode fences')


def test_jobs_and_currentness(version):
    fresh = request(task('job-fresh'))
    identifier = fresh['id']
    assert sql("SELECT count(*) FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + identifier + "%' ") == '1'
    drain()
    answered(identifier, version)
    before = snapshot()
    drain()
    assert snapshot() == before, 'Repeated drain duplicated retained answer'

    for suffix, mutate in [
        ('source', lambda value: api('tasks/' + value['task_id'] + '/update', {'note': 'Changed source revision'})),
        ('pr', lambda value: api('tasks/' + value['task_id'] + '/link', {'pr_url': 'https://github.com/fixture/policy/pull/400'})),
        ('recommend', lambda value: api('decisions/' + value['id'] + '/recommend', {'body': 'Captain is considering a different answer.'}, captain=True)),
    ]:
        value = request(task('stale-' + suffix))
        mutate(value)
        drain()
        no_answer(value['id'])
        assert ledger(value['id']) == [], 'Stale job poisoned future evaluation identity'
        apply(value['id'])
        answered(value['id'], version)

    changed = request(task('queued-mode'))
    setting('decision_policy_mode', 'dry_run')
    drain()
    no_answer(changed['id'])
    assert ledger(changed['id']) == []
    setting('decision_policy_mode', 'apply')
    apply(changed['id'])
    answered(changed['id'], version)

    old_generation = request(task('queued-generation'))
    state = catalog()['state']
    api(ROOT + '/deactivate', {'generation': state['generation']}, captain=True)
    activate(version)
    drain()
    no_answer(old_generation['id'])
    assert ledger(old_generation['id']) == []
    apply(old_generation['id'])
    answered(old_generation['id'], version)

    human = request(task('human-wins'))
    api('decisions/' + human['id'] + '/answer', {'answer': 'The human answer must remain exact.'}, captain=True)
    drain()
    assert decision(human['id'])['answer'] == 'The human answer must remain exact.'
    assert ledger(human['id']) == []
    assert effects(human['id']) == {'messages': 1, 'events': 1, 'wakes': 1, 'answered': 0}
    expired = request(task('queued-expiry'), expires_in=60)
    sql("UPDATE decision_requests SET expires_at=clock_timestamp()-interval '1 second' "
        "WHERE id='%s'" % expired['id'])
    drain()
    no_answer(expired['id'])
    assert ledger(expired['id']) == []
    lost_owner = request(task('queued-owner'))
    sql("UPDATE tasks SET assignee_id='%s',revision=revision+1 WHERE id='%s'" %
        (OTHER, lost_owner['task_id']))
    drain()
    no_answer(lost_owner['id'])
    assert ledger(lost_owner['id']) == []
    checkpoint('real create jobs, post-block snapshot, stale source/mode/generation and human answers')


def test_apply_fences_and_races(version):
    value = request(task('plan-tokens'))
    original = explain(value['id'])
    for field, forged in [('source_version', '0' * 64), ('generation', original['generation'] - 1),
                          ('answer_sha256', '0' * 64),
                          ('day', (datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat())]:
        edited = dict(original, **{field: forged})
        before = snapshot()
        apply(value['id'], edited, status=(200, 409))
        no_answer(value['id'])
        assert snapshot() == before, ('Forged or stale plan token wrote state', field)
    api('tasks/' + value['task_id'] + '/update', {'note': 'Plan source changed'})
    apply(value['id'], original, status=(200, 409))
    apply(value['id'])
    answered(value['id'], version)

    duplicate = request(task('duplicate-apply'))
    exact = explain(duplicate['id'])
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        outcomes = list(pool.map(lambda _: apply(duplicate['id'], exact, status=(200, 409)), range(2)))
    assert len(outcomes) == 2
    answered(duplicate['id'], version)
    drain()
    answered(duplicate['id'], version)

    blocked = request(task('locked-source'))
    exact = explain(blocked['id'])
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        with locked("SELECT id FROM tasks WHERE id='%s' FOR UPDATE" % blocked['task_id']) as lock:
            future = pool.submit(apply, blocked['id'], exact, status=(200, 409))
            lock.blocked(future)
            lock.execute("UPDATE tasks SET revision=revision+1 WHERE id='%s'" % blocked['task_id'])
        future.result()
    no_answer(blocked['id'])
    assert ledger(blocked['id']) == []

    disabled = request(task('locked-mode'))
    exact = explain(disabled['id'])
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        with locked("SELECT id FROM tasks WHERE id='%s' FOR UPDATE" % disabled['task_id']) as lock:
            future = pool.submit(apply, disabled['id'], exact, status=(200, 409))
            lock.blocked(future)
            setting('decision_policy_mode', 'dry_run')
        future.result()
    no_answer(disabled['id'])
    assert ledger(disabled['id']) == []
    setting('decision_policy_mode', 'apply')

    captain_race = policy('fixture-captain-rotation')
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        with locked('SELECT id FROM decision_policy_state FOR UPDATE') as lock:
            future = pool.submit(api, ROOT + '/drafts', {'policy': captain_race}, captain=True, status=403)
            lock.blocked(future)
            setting('captain_token', CAPTAIN + '-rotated')
        future.result()
    setting('captain_token', CAPTAIN)
    assert all(item['name'] != 'fixture-captain-rotation' for item in catalog()['versions'])
    checkpoint('exact plan recomputation, duplicate apply, task-lock and captain-rotation races')


def test_shared_budgets(version, second):
    pr = 'https://github.com/fixture/policy/pull/500'
    values = [request(task('budget-' + str(index), pr=pr if index % 2 else pr.replace('fixture/policy', 'Fixture/Policy')))
              for index in range(4)]
    plans = [explain(value['id']) for value in values]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        list(pool.map(lambda pair: apply(pair[0]['id'], pair[1], status=(200, 409)), zip(values, plans)))
    retained = [value for value in values if decision(value['id'])['status'] == 'answered']
    assert len(retained) == 2, 'Concurrent requests overspent shared normalized PR/day budget'
    for value in retained:
        answered(value['id'], version)
    approve(second)
    activate(second)
    cross_version = request(task('budget-version', pr=pr))
    drain()
    no_answer(cross_version['id'])
    independent = request(task('budget-independent', pr='https://github.com/fixture/policy/pull/501'))
    apply(independent['id'])
    answered(independent['id'], second)

    for suffix, count in [('missing', MISSING), ('large', 2)]:
        fields = {} if count is MISSING else {'requested_ci_runs': count}
        value = request(task('ci-' + suffix), kind='approval', question='Approve one CI run?',
                        options=['One run', 'Defer'], **fields)
        drain()
        no_answer(value['id'])
        assert ledger(value['id'])[-1]['result'] == 'escalated'
    ci = request(task('ci-bounded'), kind='approval', question='Approve one CI run?',
                 options=['One run', 'Defer'], requested_ci_runs=1)
    apply(ci['id'])
    row = answered(ci['id'], second)
    assert row['ci_runs'] == 1
    before = effects(ci['id'])
    drain()
    assert effects(ci['id']) == before
    checkpoint('concurrent shared PR/day budget across versions and bounded CI intent')
    return second


def test_creation_intake(version):
    def informal(suffix):
        identifier = task(suffix)
        api('tasks/' + identifier + '/update',
            {'status': 'blocked', 'note': 'CAPTAIN DECISION: regenerate fixture artifacts'})
        source = api('decisions/waiting?task=' + identifier)['decisions'][0]
        return identifier, source

    def promotion(identifier, source):
        return {'task': identifier, 'source_type': source['source_type'],
                'source_id': source['source_id'], 'revision': source['revision'],
                'kind': 'scope', 'question': 'Regenerate fixture artifacts?',
                'options': ['Proceed', 'Defer']}

    identifier, source = informal('owner-promote')
    value = api('decisions/promote', promotion(identifier, source))['decision']
    assert value['requester_id'] == OWNER and value['promoted_by'] == OWNER
    assert sql("SELECT count(*) FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + value['id'] + "%' ") == '1'
    drain()
    answered(value['id'], version)

    identifier, source = informal('captain-live-promote')
    jar = http.cookiejar.CookieJar()
    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    page = Page()
    page.feed(browser.open(URL + '/settings', timeout=15).read().decode())
    unlock = urllib.request.Request(URL + '/settings/unlock',
        data=urllib.parse.urlencode({'token': CAPTAIN, '_csrf_token': page.csrf}).encode(),
        headers={'Content-Type': 'application/x-www-form-urlencoded', 'Origin': URL})
    assert browser.open(unlock, timeout=15).status == 200
    cookies = '; '.join(cookie.name + '=' + cookie.value for cookie in jar)
    live = LiveView(URL, '/tasks/' + identifier, cookies)
    try:
        fields = promotion(identifier, source)
        fields['options'] = 'Proceed\nDefer'
        live.send(['1', 'policy-promote', live.topic, 'event',
                   {'type': 'form', 'event': 'decision_promote', 'value': urllib.parse.urlencode(fields)}])
        assert live.wait(lambda event: event[3] == 'phx_reply' and event[1] == 'policy-promote')
    finally:
        live.close()
    value = api('decisions?task=' + identifier)['decisions'][0]
    assert value['promoted_by'] == 'captain' and value['requester_id'] == OWNER
    assert sql("SELECT count(*) FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + value['id'] + "%' ") == '1'
    drain()
    answered(value['id'], version)

    # Seed only retained provider evidence; the real duplicate-request API owns
    # request creation. No provider calls or synthetic production hooks are used.
    replay_task = task('duplicate-pr-intake', pr='https://github.com/fixture/policy/pull/800')
    task('duplicate-pr-original', pr='https://github.com/fixture/policy/pull/799')
    replay_pr = sql("SELECT id FROM delivery_pull_requests WHERE url='https://github.com/fixture/policy/pull/800'")
    original_pr = sql("SELECT id FROM delivery_pull_requests WHERE url='https://github.com/fixture/policy/pull/799'")
    snapshots = [str(uuid.uuid4()), str(uuid.uuid4())]
    for identifier, pr_id, lifecycle in [(snapshots[0], replay_pr, 'open'), (snapshots[1], original_pr, 'merged')]:
        sql("INSERT INTO delivery_ci_snapshots(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) "
            "VALUES ('%s','%s',1,clock_timestamp(),'%s','%s','%s','unknown','{}')" %
            (identifier, pr_id, 'a' * 40, 'b' * 40, lifecycle))
    sql("INSERT INTO delivery_duplicate_findings(id,merged_pull_request_id,basis,snapshot_id,merged_snapshot_id,created_at,notified_recipients) "
        "VALUES ('%s','%s','head_branch','%s','%s',clock_timestamp(),'{}')" %
        (replay_pr, original_pr, snapshots[0], snapshots[1]))
    value = api('prs/' + replay_pr + '/duplicate-decision', {'task': replay_task})['decision']
    retry = api('prs/' + replay_pr + '/duplicate-decision', {'task': replay_task})['decision']
    assert retry['id'] == value['id']
    assert sql("SELECT count(*) FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + value['id'] + "%' ") == '1'
    drain()
    no_answer(value['id'])
    rows = ledger(value['id'])
    assert len(rows) == 1 and rows[0]['result'] == 'escalated'
    assert rows[0]['source_version'] == explain(value['id'])['source_version'], 'Intake captured pre-block revision'
    checkpoint('owner promotion, captain LiveView promotion and duplicate-PR intake all enqueue')


def test_coordinator_authority(version):
    value = request(task('coordinator-boundary'), question='CAPTAIN-ONLY: regenerate fixture artifacts?')
    before = snapshot()
    forbidden = [
        (ROOT, MISSING), (ROOT + '/plan', {}), (ROOT + '/validate', {'policy': policy()}),
        (ROOT + '/drafts', {'policy': policy('fixture-runner-forgery')}),
        (ROOT + '/versions/' + version['id'] + '/approve', {'sha256': version['sha256']}),
        (ROOT + '/versions/' + version['id'] + '/activate',
         {'sha256': version['sha256'], 'generation': catalog()['state']['generation']}),
        ('decisions/' + value['id'] + '/answer', {'answer': 'Unauthorized runner answer'}),
    ]
    for path, payload in forbidden:
        api(path, payload, actor=COORDINATOR, status=403)
    exact = explain(value['id'])
    api(ROOT + '/apply/' + value['id'],
        {key: exact[key] for key in ('policy_id', 'generation', 'source_version', 'day', 'answer_sha256')},
        actor=COORDINATOR, status=403)
    assert snapshot() == before, 'Runner access rejection changed decision or policy state'
    no_answer(value['id'])
    drain()
    retained = ledger(value['id'])
    assert len(retained) == 1 and retained[0]['result'] == 'escalated'
    evaluation = explain(value['id'])
    assert evaluation['escalation_delivery'] == 'unavailable'
    assert evaluation['reason'] == 'captain_only'
    shown = api('coordinator/decisions/' + value['id'], actor=COORDINATOR)
    projection = shown['item']['policy_evaluation']
    assert projection['status'] == 'escalated'
    assert projection['policy_id'] == version['id'] and projection['reason'] == 'captain_only'
    assert projection['escalation_delivery'] == 'unavailable'
    page = api('coordinator/tick?limit=100&max_bytes=65536', actor=COORDINATOR)
    assert page['policy_evaluation'] == 'server_available'
    projected = next(item for item in page['items'] if item['id'] == value['id'])
    assert projected['policy_evaluation'] == projection
    assert 'CAPTAIN-ONLY' not in json.dumps(projected), 'Tick leaked question instead of bounded summary'
    api('tasks/' + value['task_id'] + '/update', {'note': 'Source revision no longer covered by retained evaluation'})
    assert api('coordinator/decisions/' + value['id'], actor=COORDINATOR)['item']['policy_evaluation']['status'] == 'not_evaluated'
    setting('decision_policy_mode', 'dry_run')
    assert api('coordinator/decisions/' + value['id'], actor=COORDINATOR)['item']['policy_evaluation']['status'] == 'dry_run'
    setting('decision_policy_mode', 'apply')
    state = catalog()['state']
    api(ROOT + '/deactivate', {'generation': state['generation']}, captain=True)
    assert api('coordinator/decisions/' + value['id'], actor=COORDINATOR)['item']['policy_evaluation']['status'] == 'inactive'
    activate(version)
    checkpoint('coordinator runner cannot read lifecycle surfaces, administer policy or answer')


def test_atomicity_and_immutability(version):
    identifier = task('enqueue-rollback')
    before = snapshot()
    with reject_insert('oban_jobs', 'fixture_reject_policy_enqueue', "NEW.queue='decision_policy'"):
        api('decisions', {'task': identifier, 'kind': 'scope', 'question': 'Regenerate fixture artifacts?',
                         'options': ['Proceed', 'Defer']}, status=(500, 503))
    assert snapshot() == before, 'Failed enqueue committed request/task/audit state'

    value = request(task('ledger-rollback'))
    exact = explain(value['id'])
    before = snapshot()
    with reject_insert('decision_policy_ledger', 'fixture_reject_policy_ledger'):
        apply(value['id'], exact, status=503)
    assert snapshot() == before, 'Ledger failure committed answer/message/event/wake'
    no_answer(value['id'])
    apply(value['id'], exact)
    template = answered(value['id'], version)

    # The normal role cannot commit either half of a policy answer by itself.
    unpaired = request(task('unpaired-answer'))
    before_unpaired = snapshot()
    sql("UPDATE decision_requests SET status='answered',answer='Unpaired fixture answer',"
        "answered_by='system-decision-policy',answered_at=clock_timestamp(),on_behalf_of='captain' "
        "WHERE id='%s'" % unpaired['id'], reject=True)
    sql("INSERT INTO decision_policy_ledger SELECT (jsonb_populate_record(NULL::decision_policy_ledger, "
        "to_jsonb(l) || jsonb_build_object('id','%s','decision_id','%s','task_id','%s',"
        "'gate_ref','%s'))).* FROM decision_policy_ledger l WHERE id='%s'" %
        (str(uuid.uuid4()), unpaired['id'], unpaired['task_id'], unpaired['gate_ref'], template['id']), reject=True)
    assert snapshot() == before_unpaired, 'Unpaired answer/ledger write committed'
    drain()
    answered(unpaired['id'], version)

    retry = request(task('worker-ledger-retry'))
    job_id = int(sql("SELECT id FROM oban_jobs WHERE queue='decision_policy' AND args::text LIKE '%" + retry['id'] + "%'"))
    before = snapshot(include_jobs=False)
    with reject_insert('decision_policy_ledger', 'fixture_reject_policy_worker_ledger',
                       "NEW.decision_id='%s'::uuid" % retry['id']):
        drained = drain()
        assert drained['failure'] >= 1, 'Worker reported success after ledger insert failed'
    assert snapshot(include_jobs=False) == before, 'Failed worker committed answer state'
    no_answer(retry['id'])
    assert ledger(retry['id']) == []
    rpc('Oban.retry_job(' + str(job_id) + '); true')
    drain()
    answered(retry['id'], version)

    for table, assignment in [('decision_policy_versions', "sha256=repeat('0',64)"),
                              ('decision_policy_approvals', "approved_by='forged'"),
                              ('decision_policy_ledger', "reason='forged'")]:
        before = snapshot([table])
        for statement in ['UPDATE ' + table + ' SET ' + assignment, 'DELETE FROM ' + table, 'TRUNCATE ' + table]:
            sql(statement, reject=True)
        assert snapshot([table]) == before, ('Normal role mutated immutable evidence', table)
    for resource in ('Version', 'Approval', 'Ledger'):
        assert rpc('Ash.Resource.Info.actions(Agentboard.DecisionPolicy.' + resource +
                   ') |> Enum.all?(fn action -> action.type in [:read, :create] end)') is True
    checkpoint('enqueue and answer/ledger rollback plus normal-role immutability')


def test_utc_day_budget(version):
    # Seed two internally consistent prior-day answer/ledger pairs in this
    # disposable DB. They model retained history; only today's public apply
    # calls below are claimed as canonical answer-delivery execution.
    template = json.loads(sql("SELECT to_jsonb(l) FROM decision_policy_ledger l "
        "WHERE result='answered' AND policy_id='%s' AND ci_runs=0 ORDER BY id LIMIT 1" % version['id']))
    pr = 'https://github.com/fixture/policy/pull/900'
    setting('decision_policy_mode', 'dry_run')
    for index in range(2):
        old = request(task('prior-day-' + str(index), pr=pr))
        source = explain(old['id'])['source_version']
        sql("BEGIN; UPDATE decision_requests SET status='answered',"
            "answer=(SELECT answer FROM decision_policy_ledger WHERE id='%s'),"
            "answered_by='system-decision-policy',answered_at=clock_timestamp()-interval '1 day',"
            "on_behalf_of='captain' WHERE id='%s'; "
            "INSERT INTO decision_policy_ledger SELECT (jsonb_populate_record(NULL::decision_policy_ledger,"
            "to_jsonb(l) || jsonb_build_object('id','%s','decision_id','%s','task_id','%s',"
            "'gate_ref','%s','source_version','%s','generation',%d,'limit_key','pr:%s',"
            "'day',(clock_timestamp() AT TIME ZONE 'UTC')::date-1,"
            "'created_at',clock_timestamp()-interval '1 day'))).* "
            "FROM decision_policy_ledger l WHERE id='%s'; COMMIT" %
            (template['id'], old['id'], str(uuid.uuid4()), old['id'], old['task_id'],
             old['gate_ref'], source, catalog()['state']['generation'], pr, template['id']))
    setting('decision_policy_mode', 'apply')
    fresh = [request(task('today-' + str(index), pr=pr)) for index in range(3)]
    assert explain(fresh[0]['id'])['answers_used'] == 0, 'Prior UTC day consumed today budget'
    for value in fresh[:2]:
        apply(value['id'])
        answered(value['id'], version)
    drain()
    no_answer(fresh[2]['id'])
    assert ledger(fresh[2]['id'])[-1]['reason'] == 'answer_budget_exhausted'
    assert sql("SELECT count(DISTINCT day) FROM decision_policy_ledger WHERE result='answered' "
               "AND limit_key='pr:%s'" % pr) == '2'
    checkpoint('UTC day budget excludes prior-day evidence and still enforces today limit')


def main():
    assert os.environ.get('PGSSLMODE') == 'verify-full'
    assert sql('SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()') == 't'
    assert sql('SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls '
               'FROM pg_roles WHERE rolname=current_user') == 'f', 'Normal database role required'
    setting('captain_token', CAPTAIN)
    setting('coordinator_id', COORDINATOR)
    setting('agent_auth_mode', 'off')
    for actor in (OWNER, OTHER, COORDINATOR):
        api('agents/register', {'name': actor}, actor=actor)
    for actor, scope in [(OWNER, 'agent'), (OTHER, 'agent'), (COORDINATOR, 'coordinator_runner')]:
        issued = api('agents/' + actor + '/tokens/issue', {'scope': scope}, captain=True)
        TOKENS[actor] = issued['token']
        SECRETS.append(issued['token'])
    assert api('meta')['schema_version'] >= 41
    assert catalog()['mode'] == 'dry_run', 'Default must not permit automatic answers'
    rpc('Oban.pause_queue(queue: :decision_policy); true')
    version, second = test_schema_and_lifecycle()
    test_readonly_and_modes(version)
    test_jobs_and_currentness(version)
    test_apply_fences_and_races(version)
    version = test_shared_budgets(version, second)
    test_creation_intake(version)
    test_coordinator_authority(version)
    test_atomicity_and_immutability(version)
    test_utc_day_budget(version)
    checkpoint('PASS')


if __name__ == '__main__':
    main()
