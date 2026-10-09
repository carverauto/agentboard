"""Bounded branch-flow reads through real PostgreSQL, release RPC and LiveView.

All records, refs and provider endpoints are invented and confined to the disposable
normal-role database. This is a protocol/render regression, not a browser keyboard
or screen-reader test. No GitHub request or background producer is needed to view
retained evidence. Run independently: the fixture deliberately retains history.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request
import uuid
from html.parser import HTMLParser

from liveview_client import RenderedView
from provider_fixture import tls_provider
from branch_flow_parity import assert_batched_parity

URL = os.environ['AGENTBOARD_URL']
OUTPUT = Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'])
HEAD, BASE, NEW_HEAD = 'a' * 40, 'b' * 40, 'c' * 40
BUSIEST = 'branchflow/busiest'
OLDEST_REPO = 'branchflow/red-outside'
EXACT_BASE = 'release/Ünicode/共同'
EXACT_HEAD = 'feature/同じ-ref'
provider_requests = []


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def value(expression):
    output = rpc('IO.puts("BRANCH_FLOW_RESULT=" <> Jason.encode!(' + expression + '))')
    lines = [line.removeprefix('BRANCH_FLOW_RESULT=') for line in output.splitlines()
             if line.startswith('BRANCH_FLOW_RESULT=')]
    assert len(lines) == 1, output
    return json.loads(lines[0])


def sql(query):
    result = subprocess.run([os.environ['FIXTURE_PSQL'], '-X', '-At', '-v',
                             'ON_ERROR_STOP=1'], input=query, capture_output=True,
                            text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def quote(value):
    if value is None:
        return 'NULL'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    return "'" + str(value).replace("'", "''") + "'"


def identity(repository, number):
    url = f'https://github.com/{repository}/pull/{number}'
    return hashlib.sha256(url.encode()).hexdigest()


def params_expr(params):
    return 'Jason.decode!(' + json.dumps(json.dumps(params, ensure_ascii=False), ensure_ascii=False) + ')'


def projection(params=None):
    result = value('case Agentboard.Delivery.BranchFlow.list(' + params_expr(params or {}) + ') do '
                   '{:ok, data} -> data; other -> %{fixture_error: inspect(other)} end')
    assert 'fixture_error' not in result, result
    return result


def ids(data):
    return [row['pr']['id'] for row in data['table']['prs']]


def path(**params):
    return '/prs' + ('?' + urllib.parse.urlencode(params) if params else '')


def get(path):
    with urllib.request.urlopen(URL + path, timeout=20) as response:
        return response.read().decode()


class Element:
    def __init__(self, tag='', attributes=None, parent=None):
        self.tag, self.attributes, self.parent = tag, dict(attributes or []), parent
        self.children = []
        self.parts = []

    @property
    def text(self):
        return ' '.join(' '.join(self.parts).split())

    def findall(self, key, val=None):
        result = []
        if key in self.attributes and (val is None or self.attributes[key] == val):
            result.append(self)
        for child in self.children:
            result.extend(child.findall(key, val))
        return result

    def find(self, key, val):
        found = self.findall(key, val)
        assert len(found) == 1, (key, val, len(found))
        return found[0]


class Document(HTMLParser):
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link',
            'meta', 'param', 'source', 'track', 'wbr'}

    def __init__(self, document):
        super().__init__(convert_charrefs=True)
        self.root = Element()
        self.stack = [self.root]
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        node = Element(tag, attributes, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attributes):
        self.handle_starttag(tag, attributes)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        for node in self.stack:
            node.parts.append(data)


class BranchView(RenderedView):
    def __init__(self, route='/prs'):
        super().__init__(URL, route)
        self.route = route

    @property
    def dom(self):
        return Document(self.document).root

    def patch(self, route):
        self.request('live_patch', {'url': URL + route})
        self.route = route
        return self.dom

    def click_link(self, element):
        assert element.tag == 'a', element.tag
        assert element.attributes.get('data-phx-link') == 'patch', element.attributes
        return self.patch(element.attributes['href'])

    def event(self, name, values, kind='click'):
        return self.request('event', {'type': kind, 'event': name, 'value': values})

    def refresh(self):
        # Consume a real scheduled server refresh, including all intervening diffs.
        event = self.live.wait(lambda item: item[3] == 'diff', timeout=8)
        assert event, 'No scheduled LiveView refresh arrived'
        for received in self.live.events:
            if received[3] == 'diff':
                self.diffs.append(received[4])
            assert received[3] not in ('phx_error', 'phx_close'), received
        self.live.events.clear()
        self.document = self.render()
        return self.dom


def attr_values(root, attribute):
    return [node.attributes[attribute] for node in root.findall(attribute)]


def pager(root, section, direction):
    region = root.find('id', section)
    links = [node for node in region.findall('href')
             if direction.lower() in node.text.lower()]
    assert len(links) == 1, (section, direction, region.text)
    return links[0]


def snapshot(view, name):
    import re
    layout = get('/prs')
    styles = [get(css) for css in re.findall(r'<link[^>]*href="([^"]+\.css[^"]*)"', layout)]
    assert styles, 'Packaged stylesheet missing'
    page = ('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Branch flow isolated integration fixture</title><style>' +
            '\n'.join(styles) + '</style><body>' + view.document + '</body></html>')
    (OUTPUT / (name + '.html')).write_text(page)


def insert_prs(fixtures):
    """Insert invented producer-owned persisted evidence, never invoke providers."""
    prs, snapshots, polls = [], [], []
    for repository, number, options in fixtures:
        owner, repo = repository.split('/')
        ident = identity(repository, number)
        snapshot_id = str(uuid.uuid4())
        lifecycle = options.get('lifecycle', 'open')
        enabled = options.get('enabled', True)
        base_ref = options.get('base_ref', 'main')
        head_ref = options.get('head_ref', 'feature/' + str(number))
        ci_state = options.get('ci_state', 'unknown')
        payload = dict(base_ref=base_ref, head_ref=head_ref,
                       head_repo=options.get('head_repo', repository),
                       mergeable=options.get('mergeable', True),
                       mergeable_state=options.get('mergeable_state', 'clean'),
                       policy='unknown', attempts=[])
        prs.append('(' + ','.join(map(quote, [ident, owner, repo, number,
            f'https://github.com/{repository}/pull/{number}'])) + ',now())')
        if lifecycle is not None:
            snapshots.append('(' + ','.join(map(quote, [snapshot_id, ident])) +
                ',1,now(),' + ','.join(map(quote, [HEAD, BASE, lifecycle, ci_state,
                                                 json.dumps(payload, ensure_ascii=False)])) + '::jsonb)')
        else:
            snapshot_id = None
        poll_head = NEW_HEAD if options.get('mismatch') else HEAD
        polls.append('(' + ','.join(map(quote, [ident])) + ',now(),' + quote(enabled) +
            ",now()+interval '1 day',1," + ','.join(map(quote, [ci_state])) + ',now(),' +
            ','.join(map(quote, [poll_head, BASE, base_ref, BASE, snapshot_id, lifecycle])) + ')')
    statements = ['BEGIN;', 'INSERT INTO delivery_pull_requests '
        '(id,owner,repo,number,url,created_at) VALUES ' + ','.join(prs) + ';']
    if snapshots:
        statements.append('INSERT INTO delivery_ci_snapshots '
            '(id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) VALUES ' +
            ','.join(snapshots) + ';')
    statements.append('INSERT INTO delivery_poll_states '
        '(id,registered_at,enabled,next_poll_at,generation,ci_state,observed_at,head_sha,base_sha,'
        'base_ref,expected_base_sha,snapshot_id,lifecycle) VALUES ' + ','.join(polls) + '; COMMIT;')
    sql('\n'.join(statements))


def insert_workflows():
    values = []
    for number in range(1, 12):
        # All eleven obligations are outside the strip; the oldest must remain
        # visible on page two even when the PR table is filtered elsewhere.
        age = 24 - number
        jobs = [dict(name='Fixture failed job', steps=['Fixture failed step'],
                     url=f'https://github.com/{OLDEST_REPO}/actions/runs/{number}/job/1')]
        values.append('(' + ','.join(map(quote, [f'{OLDEST_REPO}/{number}', OLDEST_REPO,
            number])) + ",now(),now()+interval '1 day',now(),now()-interval '30 minutes',1," +
            ','.join(map(quote, ['7', 'Fixture workflow', 'release/old-main', HEAD])) +
            ',' + str(number) + ',2,' + ','.join(map(quote, ['failure',
            f'https://github.com/{OLDEST_REPO}/actions/runs/{number}'])) +
            ',ARRAY[' + quote(json.dumps(jobs[0])) + ']::jsonb[],' +
            "now()-interval '" + str(age) + " hours','fixture_collection_deferred')")
    sql('INSERT INTO delivery_workflow_runs '
        '(id,repository,run_id,requested_at,next_poll_at,processed_at,observed_at,generation,'
        'workflow_id,workflow_name,branch,head_sha,run_number,run_attempt,conclusion,source_url,jobs,'
        'failed_at,last_error) VALUES ' + ','.join(values) + ';' +
        "INSERT INTO delivery_workflow_runs (id,repository,run_id,requested_at,next_poll_at,last_error) "
        "VALUES ('branchflow/queued/1','branchflow/queued','1',now(),now()+interval '1 day',NULL),"
        "('branchflow/ignored/1','branchflow/ignored','1',now(),now()+interval '1 day','not_default_branch');")


def side_effects():
    # Exclude the unrelated housekeeping cron. Everything a view could schedule,
    # consume, resolve, route or mutate is included in the stable fixture digest.
    tables = ('delivery_poll_states', 'delivery_workflow_runs', 'delivery_provider_budgets',
              'delivery_poll_credits', 'delivery_obligations', 'delivery_rebase_follow_ups',
              'tasks', 'messages', 'cooperation_events', 'cooperation_deliveries')
    result = {}
    for table in tables:
        if sql('SELECT to_regclass(' + quote(table) + ') IS NOT NULL') == 't':
            result[table] = sql('SELECT count(*)::text || \':\' || '
                "coalesce(md5(string_agg(t::text, ',' ORDER BY t::text)), '') FROM " +
                '(SELECT to_jsonb(row) AS t FROM ' + table + ' row) records')
    result['jobs'] = sql("SELECT count(*)::text || ':' || coalesce(md5(string_agg(to_jsonb(j)::text, ',' "
        "ORDER BY id)), '') FROM oban_jobs j WHERE queue IN "
        "('delivery_scheduler','delivery_polling','delivery_discovery','cooperation')")
    return result


class UnexpectedProvider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        provider_requests.append(self.path)
        self.send_response(503)
        self.end_headers()
        self.wfile.write(b'Branch-flow read must never call a provider')

    do_POST = do_GET
    do_PATCH = do_GET
    do_PUT = do_GET
    do_DELETE = do_GET


def instrumented_projection(name, legacy=False):
    # Capture queries in this read's actual caller only; worker telemetry is not
    # part of the rendering budget. Plans execute after detaching the collector.
    expression = r'''
      marker = make_ref()
      owner = self()
      handler = "branch-flow-fixture-" <> Integer.to_string(System.unique_integer([:positive]))
      prefix = Agentboard.Repo.config()[:telemetry_prefix] || [:agentboard, :repo]
      :ok = :telemetry.attach(handler, prefix ++ [:query], fn _, measurements, metadata, {pid, ref} ->
        if self() == pid, do: send(pid, {ref, measurements, metadata})
      end, {owner, marker})
      started = System.monotonic_time()
      result = try do Agentboard.Delivery.BranchFlow.list(%{}) after :telemetry.detach(handler) end
      elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      collect = fn collect, acc ->
        receive do {^marker, measurements, metadata} -> collect.(collect, [{measurements, metadata} | acc])
        after 0 -> Enum.reverse(acc) end
      end
      queries = collect.(collect, [])
      records = Enum.map(queries, fn {measurements, metadata} ->
        rows = case metadata.result do {:ok, %{num_rows: count}} when is_integer(count) -> count; _ -> 0 end
        %{sql: metadata.query, rows: rows,
          microseconds: System.convert_time_unit(measurements.total_time, :native, :microsecond)}
      end)
      plans = queries |> Enum.uniq_by(fn {_, m} -> m.query end)
        |> Enum.filter(fn {_, m} -> Regex.match?(~r/^\s*(SELECT|WITH)\b/i, m.query) end)
        |> Enum.map(fn {_, m} ->
          case Agentboard.Repo.statement("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> m.query, m.params,
                                        timeout: 10_000) do
            {:ok, %{rows: rows}} -> %{sql: m.query, plan: rows}
            {:error, error} -> %{sql: m.query, error: Exception.message(error)}
          end
        end)
      case result do
        {:ok, data} -> %{elapsed_microseconds: elapsed, query_count: length(records),
          returned_rows: Enum.sum(Enum.map(records, & &1.rows)), queries: records, plans: plans,
          inventory_count: data.inventory_count, card_count: length(data.cards),
          table_count: length(data.table.prs), chooser_count: length(data.chooser.repositories),
          attention_count: length(data.attention.runs)}
        other -> %{fixture_error: inspect(other)}
      end
    '''
    if legacy:
        expression = expression.replace('Agentboard.Delivery.BranchFlow.list(%{})',
                                        'Agentboard.Delivery.Reads.list(%{})')
        expression = expression.replace('inventory_count: data.inventory_count, card_count: length(data.cards),\n          table_count: length(data.table.prs), chooser_count: length(data.chooser.repositories),\n          attention_count: length(data.attention.runs)',
          'inventory_count: nil, card_count: 0, table_count: length(data.prs), chooser_count: 0, attention_count: length(data.default_branch_health)')
    metrics = value('(fn -> ' + expression + ' end).()')
    assert 'fixture_error' not in metrics, metrics
    assert metrics['query_count'] > 0, metrics
    assert metrics['plans'] and not any('error' in plan for plan in metrics['plans']), metrics['plans']
    (OUTPUT / (name + '-query-budget.json')).write_text(json.dumps(metrics, indent=2))
    return metrics


def assert_global(data):
    assert data['projection_revision'] and all(data[name]['projection_revision'] == data['projection_revision'] for name in ('inventory', 'chooser', 'table', 'attention'))
    assert data['inventory_count'] == 28, data['inventory_count']
    assert data['overflow_count'] == 23, data['overflow_count']
    assert data['attention']['total'] == 11, data['attention']
    assert data['attention']['oldest']['id'] == OLDEST_REPO + '/1', data['attention']['oldest']
    assert len(data['cards']) == 5


def assert_empty_filter(params):
    result = projection(params)
    assert_global(result)
    assert result['table']['error'] and not result['table']['prs'], result['table']
    return result


def run():
    assert urllib.parse.urlparse(URL).hostname in ('127.0.0.1', 'localhost'), 'Fixture must be loopback'
    assert sql("SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls "
               "FROM pg_roles WHERE rolname=current_user") == 't', 'Normal DB role required'
    assert sql('SELECT count(*) FROM delivery_pull_requests') == '0', 'Use a fresh isolated database'
    rpc('for queue <- [:delivery_scheduler, :delivery_polling, :delivery_discovery, :cooperation] do '
        'Oban.stop_queue(queue: queue) end; '
        'Application.put_env(:agentboard, :cooperation_enabled, false); '
        'Application.put_env(:agentboard, :pr_observation_enabled, false)')
    # Pausing queues does not stop Cron enqueueing at the minute boundary. Stop
    # only this disposable fixture's supervisor so read-mutation digests exclude
    # unrelated scheduled work; any attempted view enqueue still fails the test.
    rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban)')
    assert value('Application.get_env(:agentboard, :branch_flow_enabled, false)') is False
    assert 'id="default-branch-health"' in get('/prs'), 'Default-off rollback presentation missing'
    rpc('Application.put_env(:agentboard, :branch_flow_enabled, true)')
    empty = projection()
    assert empty['inventory_count'] == 0 and not empty['cards'] and not empty['table']['prs'], empty
    empty_view = BranchView()
    assert not attr_values(empty_view.dom, 'data-branch-repo')
    assert 'Branch attention' in empty_view.dom.text
    empty_view.close()

    fixtures = []
    for repository, count in [(BUSIEST, 25), ('branchflow/beta', 6), ('branchflow/gamma', 5),
                              ('branchflow/delta', 4), ('branchflow/epsilon', 3), ('branchflow/zeta', 2)]:
        for number in range(1, count + 1):
            options = {}
            if repository == BUSIEST and number == 1:
                options.update(base_ref=EXACT_BASE, head_ref=EXACT_HEAD,
                               mergeable=False, mergeable_state='dirty', ci_state='failing')
            if repository == BUSIEST and number in (2, 3):
                options.update(head_ref='same-ref', head_repo=f'fork-{number}/shared')
            if repository == BUSIEST and number in (4, 6):
                options.update(mismatch=True, head_ref='MISMATCHED-HEAD-MUST-STAY-UNAVAILABLE')
            if repository in ('branchflow/beta', 'branchflow/gamma'):
                options.update(head_ref='same-ref', head_repo='fork-' + repository.split('/')[1] + '/shared')
            fixtures.append((repository, number, options))
    fixtures.extend([(BUSIEST, 90, dict(lifecycle='merged', enabled=False)),
                     (BUSIEST, 91, dict(lifecycle='closed', enabled=False)),
                     ('branchflow/terminal', 1, dict(lifecycle='merged', enabled=False)),
                     ('branchflow/terminal', 2, dict(lifecycle='closed', enabled=False)),
                     ('branchflow/unknown', 1, dict(lifecycle=None)),
                     ('branchflow/disabled', 1, dict(enabled=False))])
    fixtures.extend((f'chooser/repo-{i:02}', 1, dict(lifecycle='closed', enabled=False)) for i in range(19))
    insert_prs(fixtures)
    insert_workflows()

    with tls_provider(UnexpectedProvider) as (provider, ca, _):
        rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(provider) +
            ', ca_file: ' + json.dumps(ca) + ', token: "invented-branch-flow-fixture"])')
        before = side_effects()
        data = projection()
        assert_global(data)
        assert len(data['table']['prs']) == 20 and data['table']['next_cursor']
        assert len(data['attention']['runs']) == 10 and data['attention']['next_cursor']
        assert len(data['chooser']['repositories']) == 20 and data['chooser']['next_cursor']
        assert data['attention']['enabled'] is False
        assert all(run['stale'] and run['deferred'] and run['outside_strip']
                   for run in data['attention']['runs'])
        legacy_api = json.loads(get('/api/v1/prs'))
        assert len(legacy_api['prs']) == 20 and len(legacy_api['default_branch_health']) == 11
        assert all(run['last_error'] == 'fixture_collection_deferred' for run in data['attention']['runs'])

        # Eligible inventory is independent of the twenty-row table and includes
        # retained terminals/unknowns but not disabled nonterminal/ignored cues.
        chooser = data['chooser']['repositories'] + projection(
            {'chooser_cursor': data['chooser']['next_cursor']})['chooser']['repositories']
        repositories = {row['repository'] for row in chooser}
        assert len(repositories) == 28, repositories
        assert {'branchflow/terminal', 'branchflow/unknown', OLDEST_REPO} <= repositories
        assert not {'branchflow/disabled', 'branchflow/queued', 'branchflow/ignored'} & repositories
        unknown = next(row for row in chooser if row['repository'] == 'branchflow/unknown')
        assert unknown['unknown_lifecycle_count'] == 1 and unknown['open_count'] == 0
        retained_terminal = next(row for row in chooser if row['repository'] == 'branchflow/terminal')
        assert retained_terminal['terminal_count'] == 2 and retained_terminal['open_count'] == 0
        assert [card['repository'] for card in data['cards']] == [
            BUSIEST, 'branchflow/beta', 'branchflow/gamma', 'branchflow/delta', 'branchflow/epsilon']
        assert data['cards'][0]['open_count'] == 25, data['cards'][0]
        assert all(len(card['relations']) <= 3 for card in data['cards'])
        mismatch_relation = next(relation for relation in data['cards'][0]['relations']
                                 if relation['id'] == identity(BUSIEST, 6))
        assert not mismatch_relation['metadata_available']
        assert mismatch_relation['head_ref'] is None and mismatch_relation['head_sha'] is None
        mismatch_id = identity(BUSIEST, 6)
        sql("UPDATE delivery_poll_states SET ci_state='passing',last_error=NULL WHERE id=" + quote(mismatch_id))
        mismatch = projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': mismatch_id})['table']['prs'][0]
        assert mismatch['ci_state'] == 'unknown' and not mismatch['fresh']
        assert 'missing or mismatched' in mismatch['source_currentness_error']
        unproven_html = get(path(repo=BUSIEST, node_kind='pr', node=mismatch_id))
        assert 'Exact snapshot proof missing or mismatched' in unproven_html
        assert 'Fresh observation' not in unproven_html
        sql("UPDATE delivery_poll_states SET ci_state='failing' WHERE id=" + quote(mismatch_id))
        retained = projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': mismatch_id})['table']['prs'][0]
        assert retained['ci_state'] == 'failing' and not retained['fresh']
        assert_global(projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': mismatch_id}))
        sql("UPDATE delivery_poll_states SET ci_state='unknown' WHERE id=" + quote(mismatch_id))
        # Same head/base/time passes the legacy payload matcher, but a changed
        # source generation or ref cannot supply a qualified branch label here.
        proof_id = identity(BUSIEST, 1)
        original_snapshot = sql("SELECT snapshot_id FROM delivery_poll_states WHERE id=" + quote(proof_id))
        for generation, payload, poll_generation in (("2", "payload", "1"), ("3", "jsonb_set(payload,'{base_ref}','\"unproven/ref\"'::jsonb)", "3")):
            # Snapshot evidence is append-only. Retain a new fixture observation
            # and move only the mutable poll pointer, then restore that pointer.
            replacement = str(uuid.uuid4())
            sql("INSERT INTO delivery_ci_snapshots (id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload) SELECT " +
                quote(replacement) + ",pull_request_id," + generation + ",observed_at,head_sha,base_sha,lifecycle,ci_state," + payload +
                " FROM delivery_ci_snapshots WHERE id=" + quote(original_snapshot) + "; UPDATE delivery_poll_states SET snapshot_id=" +
                quote(replacement) + ",generation=" + poll_generation + " WHERE id=" + quote(proof_id))
            unproven = projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': proof_id})['table']['prs'][0]
            assert unproven['base_ref'] is None and unproven['draft'] is None
            assert unproven['source_currentness_error'] and not unproven['fresh']
            sql("UPDATE delivery_poll_states SET snapshot_id=" + quote(original_snapshot) + ",generation=1 WHERE id=" + quote(proof_id))
        assert all(relation['head_ref'] == 'same-ref' and relation['head_repo'] == 'fork-beta/shared'
                   for relation in data['cards'][1]['relations'])
        assert all(relation['head_ref'] == 'same-ref' and relation['head_repo'] == 'fork-gamma/shared'
                   for relation in data['cards'][2]['relations'])
        assert OLDEST_REPO not in {card['repository'] for card in data['cards']}
        assert_global(projection({'show_terminal': 'true', 'q': 'no matching PR'}))

        selected = projection({'repo': BUSIEST})
        assert selected['table']['total'] == 25
        first_ids = ids(selected)
        second = projection({'repo': BUSIEST, 'cursor': selected['table']['next_cursor']})
        assert second['table']['total'] == 25 and len(ids(second)) == 5
        assert not set(first_ids) & set(ids(second))
        previous = projection({'repo': BUSIEST, 'cursor': second['table']['previous_cursor']})
        assert ids(previous) == first_ids
        terminal = projection({'repo': BUSIEST, 'show_terminal': 'true'})
        assert terminal['table']['total'] == 27
        assert projection({'repo': 'branchflow/terminal'})['table']['total'] == 0
        assert projection({'repo': 'branchflow/terminal', 'show_terminal': 'true'})['table']['total'] == 2
        assert projection({'repo': 'branchflow/unknown'})['table']['total'] == 1
        base = projection({'repo': BUSIEST, 'node_kind': 'base', 'node': EXACT_BASE})
        assert ids(base) == [identity(BUSIEST, 1)]
        rejected_base = projection({'repo': BUSIEST, 'node_kind': 'base', 'node': EXACT_BASE.lower()})
        assert rejected_base['table']['error'] and rejected_base['table']['prs'] == []
        assert rejected_base['table']['total'] is None
        assert_global(rejected_base)
        for number in (1, 2, 3):
            exact = projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': identity(BUSIEST, number)})
            assert ids(exact) == [identity(BUSIEST, number)]
        mismatched = projection({'repo': BUSIEST, 'node_kind': 'pr', 'node': identity(BUSIEST, 4)})
        assert 'MISMATCHED-HEAD-MUST-STAY-UNAVAILABLE' not in json.dumps(mismatched['table'])
        assert mismatched['table']['prs'][0]['merge_state'] == 'unknown'
        for invalid in [dict(repo='bad/repo/extra'), dict(repo='missing/repo'),
                        dict(node_kind='base', node='main'), dict(repo=BUSIEST, node_kind='missing', node='main'),
                        dict(repo=BUSIEST, node_kind='base', node='x' * 256),
                        dict(repo=BUSIEST, node_kind='pr', node=identity('branchflow/beta', 1)),
                        dict(repo=BUSIEST, cursor='not-a-cursor'),
                        dict(repo='branchflow/beta', cursor=selected['table']['next_cursor']),
                        dict(repo=BUSIEST, show_terminal='true', cursor=selected['table']['next_cursor']),
                        dict(repo=BUSIEST, q='main', cursor=selected['table']['next_cursor']),
                        dict(repo=[BUSIEST]), dict(cursor='x' * 201),
                        dict(q='x' * 121), dict(show_terminal='possibly')]:
            assert_empty_filter(invalid)
        # Literal wildcard/control syntax must neither crash nor broaden search.
        for query in ('%_\\', '\" OR 1=1 --', '共同'):
            matching = projection({'repo': BUSIEST, 'q': query})
            assert matching['table']['total'] <= 1, (query, matching['table'])

        attention_second = projection({'repo': BUSIEST, 'cursor': selected['table']['next_cursor'],
                                      'attention_cursor': data['attention']['next_cursor']})
        assert len(attention_second['attention']['runs']) == 1
        assert attention_second['attention']['oldest']['id'] == OLDEST_REPO + '/1'
        assert ids(attention_second) == ids(second)
        assert_global(attention_second)
        assert projection({'attention_cursor': 'bad-cursor'})['attention']['error']
        assert projection({'chooser_cursor': 'bad-cursor'})['chooser']['error']
        assert projection({'chooser_q': 'no-such-repository'})['chooser']['total'] == 0
        chooser_search = projection({'chooser_q': 'chooser/repo-'})
        assert chooser_search['chooser']['total'] == 19
        assert projection({'chooser_q': '%_'})['chooser']['total'] == 0

        small = instrumented_projection('branch-flow-small')
        legacy_small = instrumented_projection('legacy-pr-small', legacy=True)
        assert small['query_count'] < legacy_small['query_count'], (small, legacy_small)
        view = BranchView(path(repo=BUSIEST))
        root = view.dom
        assert attr_values(root, 'data-branch-pr') == first_ids
        assert [node.text for node in root.findall('scope', 'col')] == [
            'Pull request / head', 'CI / mergeability', 'Responsible / repair', 'Delivery / progress']
        assert len(attr_values(root, 'data-branch-repo')) == 5
        assert len(attr_values(root, 'data-branch-relation')) <= 15
        assert len(attr_values(root, 'data-branch-run')) == 10
        assert len(attr_values(root, 'data-branch-chooser-repo')) == 20
        assert 'outside strip' in root.find('id', 'branch-oldest-failure').text.lower()
        assert 'absence of failures does not verify green' in root.find('id', 'branch-attention').text
        snapshot(view, 'branch-flow-overview')
        # Real node links, explicit clear, form events and terminal link retain
        # independent attention state and reset only the affected table page.
        relation = view.dom.find('data-branch-relation', identity(BUSIEST, 1))
        base_link = relation.find('aria-label', 'Filter ' + BUSIEST + ' by exact base ' + EXACT_BASE)
        base_link_route = base_link.attributes['href']
        view.click_link(base_link)
        assert attr_values(view.dom, 'data-branch-pr') == [identity(BUSIEST, 1)]
        view.patch(base_link_route)
        assert attr_values(view.dom, 'data-branch-pr') == [identity(BUSIEST, 1)]
        clear = [node for node in view.dom.findall('href') if node.text == 'Clear node filter']
        assert len(clear) == 1
        view.click_link(clear[0])
        assert attr_values(view.dom, 'data-branch-pr') == first_ids
        view.click_link(view.dom.find('id', 'branch-terminal-toggle'))
        assert '27 matching tracked PRs' in view.dom.text
        view.click_link(view.dom.find('id', 'branch-terminal-toggle'))
        assert '25 matching tracked PRs' in view.dom.text
        view.event('search_prs', urllib.parse.urlencode({'q': '共同'}), kind='form')
        assert attr_values(view.dom, 'data-branch-pr') == [identity(BUSIEST, 1)]
        view.event('search_prs', urllib.parse.urlencode({'q': ''}), kind='form')
        assert attr_values(view.dom, 'data-branch-pr') == first_ids
        view.event('search_repositories', urllib.parse.urlencode({'chooser_q': 'chooser/repo-'}), kind='form')
        assert len(attr_values(view.dom, 'data-branch-chooser-repo')) == 19
        assert attr_values(view.dom, 'data-branch-pr') == first_ids
        view.event('search_repositories', urllib.parse.urlencode({'chooser_q': ''}), kind='form')
        assert len(attr_values(view.dom, 'data-branch-chooser-repo')) == 20
        view.click_link(pager(view.dom, 'branch-chooser-pagination', 'Next'))
        assert len(attr_values(view.dom, 'data-branch-chooser-repo')) == 8
        assert attr_values(view.dom, 'data-branch-pr') == first_ids
        view.patch(path(repo=BUSIEST))
        first_route = view.route
        view.click_link(pager(view.dom, 'branch-table-pagination', 'Next'))
        second_route = view.route
        assert attr_values(view.dom, 'data-branch-pr') == ids(second)
        assert len(attr_values(view.dom, 'data-branch-run')) == 10
        view.click_link(pager(view.dom, 'branch-attention-pagination', 'Next'))
        attention_route = view.route
        assert attr_values(view.dom, 'data-branch-pr') == ids(second)
        assert attr_values(view.dom, 'data-branch-run') == [OLDEST_REPO + '/11']
        assert OLDEST_REPO in view.dom.find('id', 'branch-oldest-failure').text
        snapshot(view, 'branch-flow-attention-second')
        view.click_link(pager(view.dom, 'branch-table-pagination', 'Previous'))
        assert attr_values(view.dom, 'data-branch-pr') == first_ids
        assert attr_values(view.dom, 'data-branch-run') == [OLDEST_REPO + '/11']
        # These are the exact live_patch messages emitted for URL reconstruction
        # by browser Back/Forward, without claiming a browser was driven here.
        for route, expected in [(second_route, ids(second)), (first_route, first_ids),
                                (attention_route, ids(second)), (second_route, ids(second))]:
            view.patch(route)
            assert attr_values(view.dom, 'data-branch-pr') == expected
        exact_route = path(repo=BUSIEST, node_kind='base', node=EXACT_BASE)
        for _ in range(2):
            view.patch(exact_route)
            assert attr_values(view.dom, 'data-branch-pr') == [identity(BUSIEST, 1)]
            assert EXACT_BASE in view.dom.text and EXACT_HEAD in view.dom.text
        view.refresh()
        assert attr_values(view.dom, 'data-branch-pr') == [identity(BUSIEST, 1)]
        assert view.route == exact_route
        view.patch(path(repo=BUSIEST, cursor='bad-cursor'))
        assert not attr_values(view.dom, 'data-branch-pr')
        assert OLDEST_REPO in view.dom.find('id', 'branch-oldest-failure').text
        assert view.dom.findall('role', 'alert'), 'Invalid cursor must have a visible error/reset'
        view.patch(first_route)
        view.close()
        # Rejoin reconstructs the selected page using URL state alone.
        restored = BranchView(attention_route)
        assert attr_values(restored.dom, 'data-branch-pr') == ids(second)
        assert attr_values(restored.dom, 'data-branch-run') == [OLDEST_REPO + '/11']
        restored.close()
        assert side_effects() == before, 'View interactions changed persisted business/producer state'
        assert not provider_requests, provider_requests

        parity = assert_batched_parity(value, sql)
        print('Batched rich-record parity:', json.dumps(parity))

        # Grow to the specified 1,000-repository / 10,000-PR scale without an Ash
        # insert/audit loop. Historical records remain intact in this one-use DB.
        rank_view = BranchView(path(repo=BUSIEST))
        old_cards = attr_values(rank_view.dom, 'data-branch-repo')
        insert_prs([(f'load/repo-{repo:04}', number, {}) for repo in range(1000)
                    for number in range(1, 11)])
        sql('ANALYZE delivery_pull_requests; ANALYZE delivery_poll_states; '
            'ANALYZE delivery_ci_snapshots; ANALYZE delivery_workflow_runs;')
        before_large = side_effects()
        rank_view.refresh()
        assert attr_values(rank_view.dom, 'data-branch-repo') == old_cards
        assert 'disabled' not in rank_view.dom.find('id', 'branch-apply-order').attributes
        rank_view.event('apply_repository_order', {})
        assert attr_values(rank_view.dom, 'data-branch-repo') == [BUSIEST] + [
            f'load/repo-{repo:04}' for repo in range(4)]
        rank_view.close()
        large = instrumented_projection('branch-flow-large')
        legacy_large = instrumented_projection('legacy-pr-large', legacy=True)
        assert large['query_count'] < legacy_large['query_count'], (large, legacy_large)
        assert large['inventory_count'] == 1028
        assert large['card_count'] == 5 and large['table_count'] == 20
        assert large['chooser_count'] == 20 and large['attention_count'] == 10
        # Expected-base reads still use the authoritative projector, once per
        # distinct base identity in the bounded 20-row page (6 here vs20 at scale).
        assert large['query_count'] <= 85 and small['query_count'] <= 85, (small['query_count'], large['query_count'])
        assert large['returned_rows'] <= small['returned_rows'] + 100, (small['returned_rows'], large['returned_rows'])
        large_view = BranchView()
        assert len(attr_values(large_view.dom, 'data-branch-repo')) == 5
        assert len(attr_values(large_view.dom, 'data-branch-relation')) <= 15
        assert len(attr_values(large_view.dom, 'data-branch-pr')) == 20
        assert len(attr_values(large_view.dom, 'data-branch-run')) == 10
        assert len(attr_values(large_view.dom, 'data-branch-chooser-repo')) == 20
        snapshot(large_view, 'branch-flow-large')
        large_view.close()
        assert (after_read := side_effects()) == before_large, {key: (before_large[key], after_read[key]) for key in before_large if before_large[key] != after_read[key]}
        assert not provider_requests
        print('Branch-flow query budget:', json.dumps({
            'small': {k: small[k] for k in ('query_count', 'returned_rows', 'elapsed_microseconds')},
            'large': {k: large[k] for k in ('query_count', 'returned_rows', 'elapsed_microseconds')},
            'legacy_small': {k: legacy_small[k] for k in ('query_count', 'returned_rows', 'elapsed_microseconds')},
            'legacy_large': {k: legacy_large[k] for k in ('query_count', 'returned_rows', 'elapsed_microseconds')}}))

        # Real database failure, then restoration. This changes only fixture
        # schema temporarily and never destroys retained evidence or triggers a
        # producer. Error qualification must survive the LiveView timer boundary.
        failing = BranchView(path(repo=BUSIEST))
        sql('ALTER TABLE delivery_poll_states RENAME TO branch_flow_fixture_unavailable;')
        try:
            failing.refresh()
            assert failing.dom.findall('role', 'alert'), 'Read failure has no visible degraded notice'
            assert 'last known' in failing.dom.text.lower() or 'unavailable' in failing.dom.text.lower()
            assert 'Fresh observation' not in failing.dom.text
            failing.patch(path(repo='branchflow/beta'))
            assert not attr_values(failing.dom, 'data-branch-pr')
            assert 'Matching tracked PR count unavailable' in failing.dom.text
            assert OLDEST_REPO in failing.dom.find('id', 'branch-oldest-failure').text
            assert 'No tracked repositories.' not in failing.dom.text
            assert OLDEST_REPO in failing.dom.find('id', 'branch-oldest-failure').text
            snapshot(failing, 'branch-flow-read-error')
        finally:
            sql('ALTER TABLE branch_flow_fixture_unavailable RENAME TO delivery_poll_states;')
        failing.patch(path(repo=BUSIEST))
        assert len(attr_values(failing.dom, 'data-branch-pr')) == 20
        failing.close()
        assert (after_read := side_effects()) == before_large, {key: (before_large[key], after_read[key]) for key in before_large if before_large[key] != after_read[key]}
        assert not provider_requests
        # Rollback uses the same persisted evidence and does not clear workflow red.
        rpc('Application.put_env(:agentboard, :branch_flow_enabled, false)')
        legacy = get('/prs')
        assert 'id="default-branch-health"' in legacy and OLDEST_REPO in legacy
        assert 'id="branch-repositories"' not in legacy
        assert (after_read := side_effects()) == before_large, {key: (before_large[key], after_read[key]) for key in before_large if before_large[key] != after_read[key]}
    print('Branch-flow bounded inventory, exact filters, independent cursors, retained attention, '
          'LiveView route/refresh/rejoin, degraded reads, load plans and zero-provider/zero-job reads passed')


if __name__ == '__main__':
    run()
