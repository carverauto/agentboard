"""Repository default roles from real, fenced workflow collection and local reads.

All repositories, workflow runs, tokens and HTTPS responses are invented. The
fixture exercises the packaged release against disposable normal-role PostgreSQL;
no GitHub, live board, credentials or extra metadata producer is involved.
"""
from collections import Counter, deque
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import urllib.parse

from provider_fixture import tls_provider

REPOSITORY = 'metadata/retained'
SHA = 'a' * 40
ACTOR = '%{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}'
METADATA_TABLE = 'delivery_repository_metadata'
requests = []
repository_responses = deque()
run_responses = {}
runs = {}
provider_errors = []
provider_lock = threading.Lock()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def value(expression):
    marker = 'REPOSITORY_METADATA_RESULT='
    output = rpc('IO.puts(' + json.dumps(marker) + ' <> Jason.encode!(' + expression + '))')
    values = [line[len(marker):] for line in output.splitlines() if line.startswith(marker)]
    assert len(values) == 1, output
    return json.loads(values[0])


def sql(query):
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
                            input=query, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def quote(text):
    return "'" + str(text).replace("'", "''") + "'"


def expression(data):
    return 'Jason.decode!(' + json.dumps(json.dumps(data)) + ')'


def check(run_id):
    return value('case Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.WorkflowObservation, '
        ':check, %{"id" => ' + json.dumps(f'{REPOSITORY}/{run_id}') + '}) do '
        '{:ok, result} -> result; other -> %{fixture_error: inspect(other)} end')


def row(run_id):
    return value('Agentboard.Board.Operations.public(Ash.get!(Agentboard.Delivery.WorkflowRun, ' +
                 json.dumps(f'{REPOSITORY}/{run_id}') + '))')


def metadata():
    return value('Agentboard.Board.Operations.public(Ash.get!(Agentboard.Delivery.RepositoryMetadata, ' +
                 json.dumps(REPOSITORY.lower()) + '))')


def projection(params=None, held=None):
    options = '' if held is None else ', card_repositories: ' + expression(held)
    result = value('case Agentboard.Delivery.BranchFlow.list(' + expression(params or {}) + options +
                   ') do {:ok, result} -> result; other -> %{fixture_error: inspect(other)} end')
    assert 'fixture_error' not in result, result
    return result


def role():
    return projection({'repo': REPOSITORY.lower()})['repository_roles'][REPOSITORY.lower()]


def assert_current(expected_ref, source_run, generation=None):
    result = role()
    assert result['default_ref'] == result['retained_default_ref'] == expected_ref, result
    assert result['fresh'] and result['available'] and result['health'] == 'unknown', result
    assert result['source_generation'] == result['generation'], result
    assert result['source_run_id'] == f'{REPOSITORY}/{source_run}', result
    assert result['source_run_generation'] == row(source_run)['generation'], result
    assert result['observed_at'] and result['source_url'] == (
        f'https://github.com/{REPOSITORY.lower()}/actions/runs/{source_run}'), result
    if generation is not None:
        assert result['generation'] == generation, result
    return result


def assert_unknown(retained_ref=None, generation=None, reason=None):
    result = role()
    assert result['default_ref'] is None and not result['available'], result
    assert result['retained_default_ref'] == retained_ref and result['health'] == 'unknown', result
    assert result['reason'], result
    if reason is not None:
        assert result['reason'] == reason, result
    if generation is not None:
        assert result['generation'] == generation, result
    return result


def reset_budget(remaining=60):
    rpc('b = Ash.get!(Agentboard.Delivery.ProviderBudget, "github"); '
        'Agentboard.Board.Operations.update(b, :consume, %{remaining: ' + str(remaining) +
        ', reset_at: DateTime.add(DateTime.utc_now(), 3600), blocked_until: nil}, %{})')


def prepare(run_id, branch='main', **overrides):
    runs[run_id] = dict(id=run_id, workflow_id=7, name='Invented release workflow',
        run_number=run_id, run_attempt=1, head_sha=SHA, head_branch=branch,
        head_repository=dict(full_name=REPOSITORY), status='completed',
        conclusion='success', event='push')
    runs[run_id].update(overrides)
    result = value('case Agentboard.Delivery.WorkflowMonitor.queue(' +
        json.dumps(REPOSITORY) + ', ' + json.dumps(str(run_id)) + ') do '
        '{:ok, result} -> result; other -> %{fixture_error: inspect(other)} end')
    assert result['queued'], result


def repo_response(default_ref, **options):
    repository_responses.append(dict(default_ref=default_ref, **options))


def expected_requests(run_id, count=4, failure=False):
    root = '/repos/' + REPOSITORY
    result = [root, f'{root}/actions/runs/{run_id}']
    if failure:
        result.extend([f'{root}/actions/runs/{run_id}/attempts/1/jobs', f'{root}/commits/{SHA}/pulls'])
    result.extend([f'{root}/actions/runs/{run_id}', root])
    return result[:count]


def observe(run_id, default_ref='main', *, after_ref=None, expected=4, failure=False):
    assert not repository_responses, list(repository_responses)
    repo_response(default_ref)
    if expected == (6 if failure else 4):
        repo_response(default_ref if after_ref is None else after_ref)
    before = len(requests)
    result = check(run_id)
    assert requests[before:] == expected_requests(run_id, expected, failure), requests[before:]
    assert not repository_responses, list(repository_responses)
    assert not provider_errors, provider_errors
    return result


class Gate:
    """Stop after all collector evidence was read, immediately before commit."""
    def __init__(self):
        self.arrived, self.release = threading.Event(), threading.Event()

    def wait(self):
        assert self.arrived.wait(10), 'Collector did not reach its final repository fence'


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            assert self.headers.get('Authorization') == 'Bearer invented-metadata-token'
            path = urllib.parse.urlparse(self.path).path
            with provider_lock:
                requests.append(path)
                if path == '/repos/' + REPOSITORY:
                    assert repository_responses, ('Unplanned repository request', path)
                    spec = repository_responses.popleft()
                    body = dict(full_name=spec.get('repository', REPOSITORY),
                                default_branch=spec['default_ref'])
                elif '/attempts/' in path:
                    spec = {}
                    run_id = int(path.split('/runs/')[1].split('/')[0])
                    body = dict(total_count=1, jobs=[dict(id=run_id * 100, run_id=run_id,
                        conclusion='failure', name='publish',
                        steps=[dict(name='Publish invented image', conclusion='failure')])])
                elif '/actions/runs/' in path:
                    spec = {}
                    run_id = int(path.rsplit('/', 1)[1])
                    responses = run_responses.get(run_id)
                    body = responses.popleft() if responses else dict(runs[run_id])
                elif '/commits/' in path and path.endswith('/pulls'):
                    spec, body = {}, []
                else:
                    raise AssertionError(path)
            gate = spec.get('gate')
            if gate:
                gate.arrived.set()
                assert gate.release.wait(9), 'Final-response gate exceeded the 10-second HTTP deadline'
            encoded = json.dumps(body).encode()
            self.send_response(spec.get('status', 200))
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except Exception as error:
            provider_errors.append(repr(error))
            try:
                self.send_error(500)
            except (BrokenPipeError, ConnectionError):
                pass


def expire_lease(run_id, bump_generation=False):
    action = ':reserve' if bump_generation else ':observe'
    generation = ', generation: r.generation + 1' if bump_generation else ''
    rpc('r = Ash.get!(Agentboard.Delivery.WorkflowRun, ' + json.dumps(f'{REPOSITORY}/{run_id}') +
        '); Agentboard.Board.Operations.update(r, ' + action +
        ', %{lease_expires_at: DateTime.add(DateTime.utc_now(), -1)' + generation + '}, ' + ACTOR + ')')


def fenced_commit(run_id, mutation, expected_ref='newdefault', ignored=False):
    """A successful HTTPS result must still lose a changed local commit fence."""
    prepare(run_id, branch='feature/ignored' if ignored else expected_ref)
    old = metadata()
    gate = Gate()
    repo_response(expected_ref)
    repo_response(expected_ref, gate=gate)
    before = len(requests)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(check, run_id)
        try:
            gate.wait()
            mutation(run_id)
        finally:
            gate.release.set()
        result = pending.result(timeout=30)
    assert result.get('superseded') or result.get('ignored'), result
    assert requests[before:] == expected_requests(run_id), requests[before:]
    current = metadata()
    assert current['generation'] == old['generation'] + 1, (old, current)
    for field in ('source_generation', 'default_ref', 'observed_at', 'source_run_id', 'source_run_generation'):
        assert current[field] == old[field], (field, old, current)
    assert row(run_id)['processed_at'] is None
    assert_unknown(expected_ref, current['generation'])
    assert not provider_errors, provider_errors


def instrumented_projection(held):
    code = r'''
      marker = make_ref()
      owner = self()
      handler = "repository-metadata-fixture-" <> Integer.to_string(System.unique_integer([:positive]))
      prefix = Agentboard.Repo.config()[:telemetry_prefix] || [:agentboard, :repo]
      :ok = :telemetry.attach(handler, prefix ++ [:query], fn _, _, data, {pid, ref} ->
        if self() == pid, do: send(pid, {ref, data})
      end, {owner, marker})
      result = try do Agentboard.Delivery.BranchFlow.list(%{}, card_repositories: HELD)
               after :telemetry.detach(handler) end
      collect = fn collect, acc ->
        receive do {^marker, metadata} -> collect.(collect, [metadata | acc])
        after 0 -> Enum.reverse(acc) end
      end
      queries = collect.(collect, []) |> Enum.map(fn metadata ->
        rows = case metadata.result do {:ok, %{num_rows: n}} when is_integer(n) -> n; _ -> 0 end
        %{sql: metadata.query, rows: rows, params: metadata.params}
      end)
      case result do
        {:ok, data} -> %{data: data, queries: queries}
        other -> %{fixture_error: inspect(other)}
      end
    '''.replace('HELD', expression(held))
    return value('(fn -> ' + code + ' end).()')


def liveview_read_failure(repository, failure):
    """Real mount/params/refresh paths, without browser or mocked projections."""
    assert failure in ('outer_transaction', METADATA_TABLE)
    if failure == 'outer_transaction':
        injection = r'''
          marker = make_ref()
          {:error, :fixture} = Agentboard.Repo.transaction(fn ->
            # An aborted outer transaction makes even the snapshot setup fail;
            # missing optional tables only degrade their own bounded sections.
            {:error, _} = Agentboard.Repo.statement("SELECT 1/0", [])
            {:noreply, failed} = AgentboardWeb.PRLive.handle_info(:refresh, socket)
            send(self(), {marker, failed})
            Agentboard.Repo.rollback(:fixture)
          end)
          failed = receive do
            {^marker, failed} -> failed
          after
            1000 -> raise "Missing failed LiveView socket"
          end
        '''
    else:
        injection = r'''
          Agentboard.Repo.statement!(
            "ALTER TABLE delivery_repository_metadata RENAME TO repository_metadata_fixture_missing", [])
          failed = try do
            {:noreply, failed} = AgentboardWeb.PRLive.handle_info(:refresh, socket)
            failed
          after
            Agentboard.Repo.statement!(
              "ALTER TABLE repository_metadata_fixture_missing RENAME TO delivery_repository_metadata", [])
          end
        '''
    code = r'''
      previous = Application.get_env(:agentboard, :branch_flow_enabled)
      Application.put_env(:agentboard, :branch_flow_enabled, true)
      try do
        {:ok, socket} = AgentboardWeb.PRLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
        {:noreply, socket} = AgentboardWeb.PRLive.handle_params(PARAMS, "/prs", socket)
        INJECTION
        {:noreply, recovered} = AgentboardWeb.PRLive.handle_info(:refresh, failed)
        %{before: socket.assigns.data, during: failed.assigns.data, error: failed.assigns.error,
          recovered: recovered.assigns.data, recovered_error: recovered.assigns.error}
      after
        if is_nil(previous),
          do: Application.delete_env(:agentboard, :branch_flow_enabled),
          else: Application.put_env(:agentboard, :branch_flow_enabled, previous)
      end
    '''.replace('PARAMS', expression({'repo': repository})).replace('INJECTION', injection)
    return value('(fn -> ' + code + ' end).()')


def assert_degraded_roles(data, previous=None):
    roles = list(data['repository_roles'].values())
    roles += [card['repository_role'] for card in data['cards']]
    roles.append(data['topology']['repository_role'])
    assert roles and all(roles), roles
    for item in roles:
        assert item['available'] is False and item['fresh'] is False, item
        assert item['default_ref'] is None and item['health'] == 'unknown', item
        assert item['reason'] == 'read_unavailable', item
        if previous:
            retained = previous['repository_roles'][item['repository']]
            for field in ('retained_default_ref', 'source_generation', 'source_run_id',
                          'source_run_generation', 'observed_at', 'source_url'):
                assert item[field] == retained[field], (field, item, retained)
    assert all(card['default_branch'] is None for card in data['cards']), data['cards']


def seed_bounded_inventory():
    """Producer-shaped synthetic rows give the UI more roles than its read budget."""
    statements = ['BEGIN;']
    for index in range(60):
        repository = f'bounded/repo-{index:02}'
        url = f'https://github.com/{repository}/pull/1'
        ident = hashlib.sha256(url.encode()).hexdigest()
        statements.append('INSERT INTO delivery_pull_requests '
            '(id,owner,repo,number,url,created_at) VALUES (' + ','.join(map(quote,
                [ident, 'bounded', f'repo-{index:02}', '1', url])) + ',now());')
        statements.append('INSERT INTO delivery_poll_states '
            '(id,registered_at,enabled,next_poll_at,generation,ci_state,lifecycle) VALUES (' +
            quote(ident) + ",now(),true,now()+interval '1 day',0,'unknown','open');")
        statements.append('INSERT INTO delivery_workflow_runs '
            '(id,repository,run_id,requested_at,next_poll_at,generation) VALUES (' +
            ','.join(map(quote, [repository + '/1', repository, '1'])) + ',now(),now(),1);')
        statements.append('INSERT INTO ' + METADATA_TABLE +
            ' (id,generation,source_generation,default_ref,observed_at,source_run_id,source_run_generation) VALUES (' +
            quote(repository) + ",1,1,'provider-default',now()," + quote(repository + '/1') + ',1);')
    statements.append('COMMIT;')
    sql('\n'.join(statements))


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); '
    'Application.put_env(:agentboard, :cooperation_enabled, false); '
    'Application.put_env(:agentboard, :pr_observation_enabled, true)')
reset_budget()

with tls_provider(Provider) as (api_url, ca, _):
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) +
        ', token: "invented-metadata-token", ca_file: ' + json.dumps(ca) + '])')

    # A canonical repository role is retained only after both run and repo fences.
    before = len(requests)
    missing = projection({'repo': 'metadata/not-retained'})['repository_roles']['metadata/not-retained']
    assert missing['reason'] == 'not_retained' and not missing['available'], missing
    assert missing['default_ref'] is None and missing['source_url'] is None, missing
    assert len(requests) == before
    prepare(10)
    assert observe(10)['observed'] == 'success'
    first = metadata()
    assert first['generation'] == first['source_generation'] == 1, first
    assert first['source_run_id'] == f'{REPOSITORY}/10' and first['source_run_generation'] == 1, first
    assert_current('main', 10, 1)
    before = len(requests)
    assert check(10)['skipped']
    assert len(requests) == before and metadata() == first, 'Skipped runs must not reserve a repository generation'

    # Ignored feature/PR runs still carry valid repository evidence, without
    # manufacturing a default-branch workflow result or obligation.
    prepare(11, branch='feature/invented', event='pull_request')
    assert observe(11, 'release')['ignored']
    assert row(11)['conclusion'] is None and row(11)['failed_at'] is None
    assert_current('release', 11, 2)

    # A is already waiting at its final repo response when B reserves and commits.
    # Their collector snapshots are each internally consistent. Only repository
    # metadata is superseded; A's independently valid red obligation still lands.
    prepare(20, branch='olddefault', conclusion='failure')
    prepare(21, branch='newdefault')
    gate = Gate()
    repo_response('olddefault')
    repo_response('olddefault', gate=gate)
    before = len(requests)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        older = pool.submit(check, 20)
        try:
            gate.wait()
            pending_role = assert_unknown('release', 3, 'collection_pending_or_superseded')
            assert pending_role['source_generation'] == 2 and not pending_role['fresh'], pending_role
            repo_response('newdefault')
            repo_response('newdefault')
            assert check(21)['observed'] == 'success'
            newest = metadata()
            assert newest['generation'] == newest['source_generation'] == 4, newest
        finally:
            gate.release.set()
        assert older.result(timeout=30)['observed'] == 'failure'
    assert Counter(requests[before:]) == Counter(expected_requests(20, 6, True) + expected_requests(21)), requests[before:]
    assert metadata() == newest, 'Late run A replaced newer run B repository metadata'
    assert_current('newdefault', 21, 4)
    red = row(20)
    assert red['conclusion'] == 'failure' and red['failed_at'] and red['resolved_at'] is None, red
    assert red['jobs'][0]['steps'] == ['Publish invented image'], red
    assert row(21)['conclusion'] == 'success'

    # New reservations invalidate freshness immediately; a pending/error result
    # never republishes retained metadata as current, including admission failure.
    prepare(30, branch='newdefault', status='in_progress', conclusion=None)
    assert observe(30, 'newdefault', expected=2)['deferred'] == 'pending'
    assert_unknown('newdefault', 5)
    assert metadata()['source_generation'] == 4
    prepare(31, branch='newdefault')
    repo_response('newdefault', status=503)
    before = len(requests)
    assert check(31)['deferred'] == 'unavailable'
    assert requests[before:] == ['/repos/' + REPOSITORY]
    assert_unknown('newdefault', 6)
    prepare(32, branch='newdefault')
    reset_budget(0)
    before = len(requests)
    assert check(32)['deferred'] == 'rate_limited'
    assert len(requests) == before
    assert_unknown('newdefault', 7)
    reset_budget()

    prepare(40, branch='newdefault')
    assert observe(40, 'newdefault')['observed'] == 'success'
    assert_current('newdefault', 40, 8)
    accepted = metadata()
    # A repository default change between before/after reads rejects everything.
    prepare(41, branch='newdefault')
    assert observe(41, 'newdefault', after_ref='changed-mid-read')['deferred'] == 'incomplete'
    assert row(41)['processed_at'] is None
    assert_unknown('newdefault', 9)
    # A changed run attempt rejects before the final repository read.
    prepare(42, branch='newdefault')
    run_responses[42] = deque([dict(runs[42]), dict(runs[42], run_attempt=2)])
    assert observe(42, 'newdefault', expected=3)['deferred'] == 'incomplete'
    assert row(42)['processed_at'] is None
    assert_unknown('newdefault', 10)
    # A foreign repository identity in the last response is equally rejected.
    prepare(43, branch='newdefault')
    repo_response('newdefault')
    repo_response('newdefault', repository='foreign/repository')
    before = len(requests)
    assert check(43)['deferred'] == 'incomplete'
    assert requests[before:] == expected_requests(43)
    assert_unknown('newdefault', 11)
    for field in ('source_generation', 'default_ref', 'observed_at', 'source_run_id', 'source_run_generation'):
        assert metadata()[field] == accepted[field], field

    # Local validity is checked again after successful provider collection.
    fenced_commit(50, expire_lease)
    fenced_commit(51, lambda run_id: expire_lease(run_id, bump_generation=True))
    fenced_commit(53, expire_lease, ignored=True)
    fenced_commit(52, lambda _: rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)'))
    rpc('Application.put_env(:agentboard, :pr_observation_enabled, true)')

    # A later reservation is authoritative even when its HTTPS collection fails.
    # Old A succeeding afterward must neither restore a current role nor erase
    # B's failure cue. A's separate workflow result may still be committed.
    reset_budget()
    retained_before_failure_race = metadata()
    prepare(70, branch='late-olddefault')
    prepare(71, branch='failed-newdefault')
    gate = Gate()
    repo_response('late-olddefault')
    repo_response('late-olddefault', gate=gate)
    before = len(requests)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        older = pool.submit(check, 70)
        try:
            gate.wait()
            repo_response('failed-newdefault', status=503)
            assert check(71)['deferred'] == 'unavailable'
            newest_failed = metadata()
            assert newest_failed['generation'] == retained_before_failure_race['generation'] + 2
            for field in ('source_generation', 'default_ref', 'observed_at',
                          'source_run_id', 'source_run_generation'):
                assert newest_failed[field] == retained_before_failure_race[field], field
        finally:
            gate.release.set()
        assert older.result(timeout=30)['observed'] == 'success'
    assert Counter(requests[before:]) == Counter(
        expected_requests(70) + ['/repos/' + REPOSITORY]), requests[before:]
    assert metadata() == newest_failed, 'Late A restored role evidence after newer B failed'
    failed_role = assert_unknown('newdefault', newest_failed['generation'],
                                'collection_pending_or_superseded')
    assert not failed_role['fresh'] and failed_role['last_error'] == 'unavailable', failed_role
    assert row(70)['conclusion'] == 'success'
    assert row(71)['processed_at'] is None and row(71)['last_error'] == 'unavailable'

    prepare(60, branch='newdefault')
    assert observe(60, 'newdefault')['observed'] == 'success'
    current = assert_current('newdefault', 60)

    # Local qualification does not need a provider call, and neither an old nor
    # future timestamp can claim current role evidence. Retained source remains.
    before = len(requests)
    sql('UPDATE ' + METADATA_TABLE + " SET observed_at=now()-interval '181 seconds' WHERE id=" + quote(REPOSITORY))
    assert not assert_unknown('newdefault', reason='stale')['fresh']
    sql('UPDATE ' + METADATA_TABLE + " SET observed_at=now()+interval '1 hour' WHERE id=" + quote(REPOSITORY))
    assert not assert_unknown('newdefault', reason='future_observation')['fresh']
    sql('UPDATE ' + METADATA_TABLE + ' SET observed_at=now() WHERE id=' + quote(REPOSITORY))
    assert_current('newdefault', 60)
    rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)')
    assert_unknown('newdefault', reason='observation_disabled')
    rpc('Application.put_env(:agentboard, :pr_observation_enabled, true)')
    assert_current('newdefault', 60)
    assert len(requests) == before

    # PR/default-watch collection is a second, not-yet-unified metadata source.
    # Its active modes never let a workflow-only generation claim current truth.
    before = len(requests)
    for mode in ('dry_run', 'apply'):
        rpc('Application.put_env(:agentboard, :conflict_routing_mode, ' + json.dumps(mode) + ')')
        blocked = assert_unknown('newdefault', reason='default_source_contract_pending')
        assert blocked['source_run_id'] == f'{REPOSITORY}/60' and blocked['source_url']
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "disabled")')
    assert_current('newdefault', 60)
    assert len(requests) == before

    # Audit coverage is from real reserve/commit actions, never direct SQL seed.
    audits = value('Ash.read!(Agentboard.Board.AuditEvent) |> Enum.map(&Agentboard.Board.Operations.public/1)')
    metadata_audits = [event for event in audits if 'RepositoryMetadata' in json.dumps(event)]
    assert any('reserve' in json.dumps(event) for event in metadata_audits), metadata_audits
    assert any('observe' in json.dumps(event) for event in metadata_audits), metadata_audits
    assert all('invented-metadata-token' not in json.dumps(event) for event in metadata_audits)

    # More retained repositories must not create an N+1 or expand the read's
    # cards+selection+inspection budget. Table-only repositories must not expand it.
    seed_bounded_inventory()
    all_repos = [f'bounded/repo-{index:02}' for index in range(60)]
    table_repos = sorted(all_repos, key=lambda repo: hashlib.sha256(
        f'https://github.com/{repo}/pull/1'.encode()).hexdigest())[:20]
    held = [repo for repo in all_repos if repo not in table_repos][:5]
    before = len(requests)
    before_audits = value('Enum.count(Ash.read!(Agentboard.Board.AuditEvent))')
    measured = instrumented_projection(held)
    assert 'fixture_error' not in measured, measured
    data = measured['data']
    assert len(data['table']['prs']) == 20 and len(data['cards']) == 5, data
    assert set(data['repository_roles']) == set(held), data['repository_roles']
    assert len(data['repository_roles']) == 5
    assert all(item['default_ref'] == 'provider-default' and item['available'] and
               item['health'] == 'unknown' for item in data['repository_roles'].values())
    queries = [query for query in measured['queries'] if METADATA_TABLE in query['sql'] and
               query['sql'].lstrip().upper().startswith(('SELECT', 'WITH'))]
    assert len(queries) == 1 and queries[0]['rows'] <= 7, queries
    chosen = next(repo for repo in all_repos if repo not in held)
    selected = projection({'repo': chosen}, held)
    assert set(selected['repository_roles']) == set(held + [chosen]), selected['repository_roles']
    assert len(requests) == before, 'BranchFlow must not fetch provider metadata'
    assert value('Enum.count(Ash.read!(Agentboard.Board.AuditEvent))') == before_audits
    Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'], 'repository-metadata-read-budget.json').write_text(
        json.dumps(dict(role_count=len(data['repository_roles']), queries=queries), indent=2))
    assert not provider_errors and not repository_responses, (provider_errors, list(repository_responses))

    # A total refresh failure must invalidate every retained role cue, while
    # preserving its provenance and the global red workflow already on screen.
    before = len(requests)
    failed_read = liveview_read_failure(chosen, 'outer_transaction')
    assert failed_read['error'] and failed_read['recovered_error'] is None, failed_read
    assert all(item['available'] and item['fresh']
               for item in failed_read['before']['repository_roles'].values())
    assert_degraded_roles(failed_read['during'], failed_read['before'])
    for data in (failed_read['before'], failed_read['during'], failed_read['recovered']):
        assert data['attention']['oldest']['id'] == f'{REPOSITORY}/20', data['attention']
        assert data['attention']['total'] == 1, data['attention']
    assert all(item['available'] and item['fresh']
               for item in failed_read['recovered']['repository_roles'].values())
    assert len(requests) == before

    # Metadata-table unavailability is an optional-section failure: local table
    # and topology evidence plus retained red attention stay independently usable.
    failed_roles = liveview_read_failure(chosen, METADATA_TABLE)
    assert failed_roles['error'] is None and failed_roles['recovered_error'] is None, failed_roles
    assert_degraded_roles(failed_roles['during'])
    assert failed_roles['during']['table']['error'] is None
    assert [item['pr']['id'] for item in failed_roles['during']['table']['prs']] == [
        item['pr']['id'] for item in failed_roles['before']['table']['prs']]
    assert failed_roles['during']['table']['prs']
    assert failed_roles['during']['topology']['error'] is None
    assert failed_roles['during']['attention']['oldest']['id'] == f'{REPOSITORY}/20'
    assert failed_roles['during']['attention']['total'] == 1
    assert all(item['available'] for item in failed_roles['recovered']['repository_roles'].values())
    assert len(requests) == before, 'Failed/recovered LiveView reads must not fetch providers'

    # Disabling that producer cannot erase its already retained source. Keep the
    # role unknown even when its observed ref happens to agree with workflow data.
    chosen_id = hashlib.sha256(f'https://github.com/{chosen}/pull/1'.encode()).hexdigest()
    sql("UPDATE delivery_poll_states SET default_ref='different-default',expected_default_sha=repeat('f',40) WHERE id=" + quote(chosen_id))
    for mode in ('disabled', 'dry_run', 'apply'):
        rpc('Application.put_env(:agentboard, :conflict_routing_mode, ' + json.dumps(mode) + ')')
        blocked = projection({'repo': chosen})['repository_roles'][chosen]
        assert blocked['reason'] == 'default_source_contract_pending', blocked
        assert not blocked['available'] and blocked['default_ref'] is None, blocked
        assert blocked['retained_default_ref'] == 'provider-default' and blocked['source_url'], blocked
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "disabled")')
    sql('UPDATE delivery_poll_states SET default_ref=NULL,expected_default_sha=NULL WHERE id=' + quote(chosen_id))
    assert projection({'repo': chosen})['repository_roles'][chosen]['available']
    assert len(requests) == before

    # Historical intake accepts case-exact repository names. Metadata alone uses
    # canonical lowercase identity; its provenance keeps the real raw run FK.
    reset_budget()
    original_repository = REPOSITORY
    REPOSITORY = 'MixedCase/Repo'
    exact_default = 'Release/共同'
    prepare(80, branch=exact_default)
    assert observe(80, exact_default)['observed'] == 'success'
    mixed = metadata()
    assert mixed['id'] == 'mixedcase/repo' and mixed['generation'] == 1, mixed
    assert mixed['source_run_id'] == 'MixedCase/Repo/80', mixed
    assert_current(exact_default, 80, 1)
    assert row(80)['repository'] == 'MixedCase/Repo' and row(80)['conclusion'] == 'success'
    assert value('is_nil(Ash.get!(Agentboard.Delivery.RepositoryMetadata, '
                 '"MixedCase/Repo", not_found_error?: false))')

    # A legacy name outside canonical metadata syntax can still satisfy the old
    # workflow collector. Optional role retention must not veto that result.
    metadata_count = value('Enum.count(Ash.read!(Agentboard.Delivery.RepositoryMetadata))')
    REPOSITORY = '.owner/repo'
    prepare(81, branch='legacy-default')
    assert observe(81, 'legacy-default')['observed'] == 'success'
    assert row(81)['conclusion'] == 'success' and row(81)['processed_at']
    assert value('Enum.count(Ash.read!(Agentboard.Delivery.RepositoryMetadata))') == metadata_count
    REPOSITORY = original_repository
    assert not provider_errors and not repository_responses, (provider_errors, list(repository_responses))

print('Repository metadata real-collector races, independent obligations, lease/off/freshness fences, '
      'audit actions and bounded provider-free BranchFlow reads passed')
