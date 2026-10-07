"""Packaged Ash poll -> real HTTPS provider -> fenced PostgreSQL observations.

Owns wire paging/revision/attempt truth, bounded transport and cross-poll rate
limits. Reservation races and recurring scheduling remain sibling contracts.
All source data/credentials are invented inside the remote executor.
"""
import concurrent.futures
import http.server
import json
import os
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=110)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def ab(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
    env.update(AGENT_ID='collector-owner', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')
    p = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                       capture_output=True, text=True, timeout=25)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return json.loads(p.stdout)


HEAD = 'a' * 40
OLD = 'b' * 40
BASE = 'c' * 40
NOW = '2026-10-01T00:00:00Z'
mode = 'normal'
requests = []
metadata_reads = 0
slow_entered = threading.Event()
slow_release = threading.Event()


def run(i, name, conclusion, head=HEAD, state='completed', completed=NOW):
    return dict(id=i, name=name, head_sha=head, app=dict(id=1), status=state,
                conclusion=conclusion, started_at=None if state == 'queued' else NOW,
                completed_at=completed if state == 'completed' else None,
                html_url=f'https://github.com/fixture/repo/actions/runs/1/job/{i}',
                details_url=f'https://carverauto.buildbuddy.io/invocation/fixture-{i}')


REPO_ID = '424242'


def live_status(path):
    prefix = '/repos/fixture/repo/commits/'
    if path.startswith(prefix) and path.endswith('/statuses'):
        sha = path[len(prefix):-len('/statuses')]
        if sha:
            return f'/repositories/{REPO_ID}/statuses/{sha}', sha
    return None, None


def next_link(path, page, filter_all):
    prefix = '/repos/fixture/repo'
    suffix = path[len(prefix):] if path.startswith(prefix) else ''
    canonical = f'/repositories/{REPO_ID}{suffix}'
    paging = f'per_page=100&page={page}' + ('&filter=all' if filter_all else '')
    live, sha = live_status(path)
    if mode == 'hostile-link':
        return f'<https://evil.invalid{path}?{paging}>; rel="next"'
    if mode == 'malformed-link':
        return 'rel="next"'
    if mode == 'suffix-link':
        return f'<{api_url}/repositories/{REPO_ID}/check-suites/999/check-runs?{paging}>; rel="next"'
    if mode == 'suite-suffix':
        return f'<{api_url}/repositories/{REPO_ID}/commits/{"e" * 40}/statuses?per_page=100&page={page}>; rel="next"'
    if mode == 'id-link':
        return f'<{api_url}/repositories/not-an-id{suffix}?{paging}>; rel="next"'
    if mode == 'query-link':
        query = f'per_page=100&page={page}' if filter_all else f'per_page=100&page={page}&filter=latest'
        return f'<{api_url}{canonical}?{query}>; rel="next"'
    if mode == 'page-link':
        bad = 'per_page=100&page=9' + ('&filter=all' if filter_all else '')
        return f'<{api_url}{path}?{bad}>; rel="next"'
    if mode == 'status-on-runs' and path.endswith('/check-runs'):
        return f'<{api_url}/repositories/{REPO_ID}/statuses/{HEAD}?per_page=100&page={page}&filter=all>; rel="next"'
    if live and mode == 'fail':
        advertised = f'{api_url}{live}?page={page}&per_page=100'
        return f'<{advertised}>; rel="next", <{advertised}>; rel="last"'
    if live and mode == 'status-sha':
        return f'<{api_url}/repositories/{REPO_ID}/statuses/{"d" * 40}?per_page=100&page={page}>; rel="next"'
    if live and mode == 'status-suffix':
        return f'<{api_url}/repositories/{REPO_ID}/commits/{sha}/check-suites?per_page=100&page={page}>; rel="next"'
    if live and mode == 'status-origin':
        return f'<https://evil.invalid/repositories/{REPO_ID}/statuses/{sha}?per_page=100&page={page}>; rel="next"'
    if live and mode == 'status-query':
        return f'<{api_url}{live}?per_page=100&page={page}&filter=all>; rel="next"'
    if live and mode == 'status-page':
        return f'<{api_url}{live}?per_page=100&page=9>; rel="next"'
    if mode in ('fail', 'partial') or (mode == 'canonical-suites' and path.endswith('/check-suites')):
        advertised = f'{api_url}{canonical}?page={page}&per_page=100' + ('&filter=all' if filter_all else '')
        return f'<{advertised}>; rel="next", <{advertised}>; rel="last"'
    return f'<{api_url}{path}?{paging}>; rel="next"'


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global metadata_reads
        if '\r' in self.path or '\n' in self.path:
            self.send_response(400)
            self.end_headers()
            return
        requests.append(self.path)
        assert self.headers['Authorization'] == 'Bearer invented-fixture-token'
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        page = int(q.get('page', ['1'])[0])
        status, headers = 200, {}
        if mode in ('401', '403', '429', 'reset', 'secondary'):
            status = 401 if mode == '401' else 429 if mode == '429' else 403
            body = {'message': 'secondary rate limit' if mode == 'secondary' else 'fixture denial'}
            if mode == '429':
                headers['Retry-After'] = '180'
            if mode == 'reset':
                headers.update({'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': str(int(time.time()) + 240)})
        elif mode == 'redirect':
            status, body = 302, {}
            headers['Location'] = f'https://127.0.0.1:{server.server_port}/must-not-follow'
        elif mode == 'oversize':
            body = {'ignored': 'x' * 1_048_576}
        elif mode == 'chunked':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            try:
                for _ in range(20):
                    chunk = b'x' * 65536
                    self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        elif '/pulls/' in u.path:
            metadata_reads += 1
            head = OLD if mode == 'changed-head' and metadata_reads > 1 else HEAD
            base = OLD if mode == 'changed-base' and metadata_reads > 1 else BASE
            body = dict(number=601, head=dict(sha=head), base=dict(sha=base), state='closed' if mode in ('closed', 'merged') else 'open', merged=mode == 'merged', draft=mode == 'draft' or (mode == 'changed-draft' and metadata_reads > 1))
            if mode == 'missing-draft':
                body.pop('draft')
            if mode == 'malformed-draft':
                body['draft'] = 'untrusted'
        elif u.path.endswith('/check-suites'):
            if mode == 'request-cap':
                body = dict(total_count=101, check_suites=[dict(id=i, head_sha=HEAD) for i in range((page-1)*100+1, min(page*100+1,102))])
            elif mode in ('canonical-suites', 'suite-suffix'):
                total = 101
                body = dict(total_count=total, check_suites=[dict(id=i, head_sha=HEAD) for i in range((page-1)*100+1, min(page*100+1, total+1))])
                if page * 100 < total:
                    headers['Link'] = next_link(u.path, page + 1, False)
            else:
                body = dict(total_count=1, check_suites=[dict(id=1, head_sha=HEAD)])
        elif u.path.endswith('/check-runs'):
            if mode == 'slow':
                slow_entered.set()
                slow_release.wait(8)
            runs = [run(i, f'job-{i}', 'success') for i in range(1, 102)]
            runs += [run(102, 'rerun', 'failure', completed='2030-01-01T00:00:00Z'),
                     run(103, 'rerun', 'success'), run(104, 'queued-rerun', 'failure'),
                     run(105, 'queued-rerun', None, state='queued')]
            if mode in ('fail', 'slow', 'malicious-url'):
                runs.append(run(106, 'failed-build', 'failure'))
            if mode == 'malicious-url':
                runs[-1]['details_url'] = 'https://evil.invalid/log?token=invented-fixture-token'
            if mode == 'old-head':
                runs.append(run(106, 'old-failure', 'failure', head=OLD))
            if mode == 'duplicate':
                runs.append(run(1, 'duplicate', 'failure'))
            if mode == 'request-cap':
                runs = []
            if mode == 'clean':
                runs = [run(1, 'security-only', 'success')]
            if mode == 'partial' and page == 2:
                status, body = 503, {'message': 'fixture outage'}
            else:
                body = dict(total_count=len(runs), check_runs=runs[(page-1)*100:page*100])
                if page * 100 < len(runs):
                    headers['Link'] = next_link(u.path, page + 1, True)
        elif u.path.endswith('/statuses'):
            body = [dict(id=i, context=f'context-{i}', state='success', created_at=NOW,
                         target_url=f'https://github.com/fixture/repo/actions/runs/{i}') for i in range(1, 101)]
            body += [dict(id=101, context='status-rerun', state='failure', created_at=NOW),
                     dict(id=102, context='status-rerun', state='success', created_at=NOW)]
            if mode == 'fail':
                body[0]['context'] = 'paged-status'
                body[0]['state'] = 'failure'
                body[0]['target_url'] = 'https://github.com/fixture/repo/actions/runs/paged-status'
            body = sorted(body, key=lambda x: -x['id'])[(page-1)*100:page*100]
            if page == 1:
                headers['Link'] = next_link(u.path, 2, False)
        else:
            raise AssertionError(self.path)
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(encoded)


with tempfile.TemporaryDirectory() as temp:
    key, cert, ca, ca_key, csr = [str(Path(temp) / name) for name in ('key.pem','cert.pem','ca.pem','ca-key.pem','csr.pem')]
    def openssl(*args):
        subprocess.run(['openssl', *args], check=True, capture_output=True)
    openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',ca_key,'-out',ca,'-subj','/CN=Fixture CA','-addext','basicConstraints=critical,CA:TRUE')
    openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout',key,'-out',csr,'-subj','/CN=fixture-provider')
    extensions = Path(temp) / 'extensions.txt'
    extensions.write_text('subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
    openssl('x509','-req','-in',csr,'-CA',ca,'-CAkey',ca_key,'-CAcreateserial','-out',cert,'-days','1','-extfile',str(extensions))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    api_url = f'https://127.0.0.1:{server.server_port}'
    rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) +
        ', token: "invented-fixture-token", ca_file: ' + json.dumps(ca) + '])')
    ab('agent', 'register')
    ab('task', 'create', '--id', 'collector-task', '--title', 'Collector fixture',
       '--pr', 'https://github.com/fixture/repo/pull/601')
    pr_id = sql('SELECT id FROM delivery_pull_requests')
    source_before = sql("SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(t) FROM tasks t),'events',(SELECT jsonb_agg(t) FROM task_events t),'links',(SELECT jsonb_agg(t) FROM delivery_task_links t))")

    def stop_pollers():
        rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling)')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = rpc('IO.puts("QUIET=" <> to_string(is_nil(Oban.check_queue(queue: :delivery_scheduler)) and is_nil(Oban.check_queue(queue: :delivery_polling))))')
            if 'QUIET=true' in state and sql("SELECT count(*) FROM oban_jobs WHERE state='executing' AND queue IN ('delivery_scheduler','delivery_polling')") == '0':
                return
            time.sleep(.05)
        raise AssertionError('poll queues did not stop')
    stop_pollers()

    def poll(next_mode, expected):
        global mode, metadata_reads
        mode, metadata_reads = next_mode, 0
        sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second'; UPDATE delivery_provider_budgets SET remaining=capacity,reset_at=clock_timestamp()+interval '60 seconds',blocked_until=NULL WHERE id='github'")
        output = rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.Observation, :poll, %{id: "' + pr_id + '"}, actor: %{role: :system}); {:ok, result} = Ash.run_action(input); IO.puts(Jason.encode!(result))')
        assert expected in output, (next_mode, output)
        return output

    poll('normal', 'pending')
    payload = json.loads(sql('SELECT payload FROM delivery_ci_snapshots ORDER BY generation DESC LIMIT 1'))
    attempts = payload['attempts']
    assert len(attempts) == 207
    latest = {a['name']: a for a in attempts if a['latest']}
    assert latest['rerun']['conclusion'] == 'success'
    assert latest['queued-rerun']['status'] == 'queued'
    assert latest['status-rerun']['conclusion'] == 'success'
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == '53', requests
    assert all(OLD not in url for url in requests)
    assert sql("SELECT head_sha||','||base_sha||','||lifecycle||','||last_error FROM delivery_poll_states") == f'{HEAD},{BASE},open,policy_unknown'
    start = len(requests)
    poll('fail', 'failing')
    seen = requests[start:]
    failed = json.loads(sql("SELECT payload FROM delivery_ci_snapshots ORDER BY generation DESC LIMIT 1"))
    failure = next(a for a in failed['attempts'] if a['name'] == 'failed-build')
    assert failure['source_url'].endswith('/job/106') and failure['latest']
    paged = next(a for a in failed['attempts'] if a['name'] == 'paged-status')
    assert paged['latest'] and paged['conclusion'] == 'failure' and paged['source_url'].endswith('/paged-status')
    assert next(a for a in failed['attempts'] if a['name'] == 'status-rerun' and a['latest'])['conclusion'] == 'success'
    assert f'/repos/fixture/repo/check-suites/1/check-runs?per_page=100&page=2&filter=all' in seen
    assert f'/repos/fixture/repo/commits/{HEAD}/statuses?per_page=100&page=2' in seen
    assert not any('/repositories/' in url or f'/statuses/{HEAD}' in url for url in seen)
    link_rejections = {'hostile-link', 'malformed-link', 'suffix-link', 'query-link', 'page-link', 'id-link', 'status-on-runs'}
    status_rejections = {'status-sha', 'status-suffix', 'status-origin', 'status-query', 'status-page'}
    for scenario, reason in [('old-head','incomplete'), ('changed-head','incomplete'),
                             ('changed-base','incomplete'), ('changed-draft','incomplete'), ('partial','unavailable'),
                             ('hostile-link','incomplete'), ('malformed-link','incomplete'),
                             ('suffix-link','incomplete'), ('query-link','incomplete'),
                             ('page-link','incomplete'), ('id-link','incomplete'),
                             ('status-on-runs','incomplete'),
                             ('status-sha','incomplete'), ('status-suffix','incomplete'),
                             ('status-origin','incomplete'), ('status-query','incomplete'),
                             ('status-page','incomplete'),
                             ('duplicate','incomplete'), ('request-cap','incomplete'), ('401','unauthorized'),
                             ('403','unauthorized'), ('redirect','incomplete'),
                             ('oversize','incomplete'), ('chunked','incomplete')]:
        before = sql('SELECT count(*) FROM delivery_ci_snapshots')
        projection = sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states')
        start = len(requests)
        poll(scenario, reason)
        seen = requests[start:]
        assert sql('SELECT count(*) FROM delivery_ci_snapshots') == before, scenario
        assert sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states') == projection, scenario
        if scenario in link_rejections:
            assert not any('/repositories/' in url or 'page=9' in url for url in seen), (scenario, seen)
            assert not any('check-runs' in url and 'page=2' in url for url in seen), (scenario, seen)
        if scenario in status_rejections:
            assert any('check-runs' in url and 'page=2' in url for url in seen), (scenario, seen)
            assert not any('/repositories/' in url or 'page=9' in url or f'/statuses/{HEAD}' in url for url in seen), (scenario, seen)
            assert not any(url.endswith(f'/commits/{HEAD}/statuses?per_page=100&page=2') for url in seen), (scenario, seen)
    for scenario, present in (('canonical-suites', True), ('suite-suffix', False)):
        before = sql('SELECT count(*) FROM delivery_ci_snapshots')
        projection = sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states')
        start = len(requests)
        poll(scenario, 'incomplete')
        seen = requests[start:]
        local = f'/repos/fixture/repo/commits/{HEAD}/check-suites?per_page=100&page=2'
        assert (local in seen) is present, (scenario, seen)
        assert not any('/repositories/' in url for url in seen), (scenario, seen)
        assert sql('SELECT count(*) FROM delivery_ci_snapshots') == before, scenario
        assert sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states') == projection, scenario
    # A certificate for 127.0.0.1 cannot authenticate localhost. HTTP is
    # rejected even when explicitly configured; no credential reaches the wire.
    for bad_url, reason in [(api_url.replace('127.0.0.1','localhost'), 'unavailable'),
                            (api_url.replace('https:', 'http:'), 'unauthorized')]:
        rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(bad_url) +
            ', token: "invented-fixture-token", ca_file: ' + json.dumps(ca) + '])')
        count = len(requests)
        poll('normal', reason)
        assert len(requests) == count
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) +
        ', token: "invented-fixture-token", ca_file: ' + json.dumps(ca) + '])')
    assert not any('/must-not-follow' in u or '/repositories/' in u or 'page=9' in u for u in requests)
    # 429/primary reset/secondary backoff are durable and block other polls too.
    for scenario, seconds in [('429',179), ('reset',238), ('secondary',59)]:
        poll(scenario, 'rate_limited')
        assert sql(f"SELECT blocked_until>=clock_timestamp()+interval '{seconds} seconds' FROM delivery_provider_budgets WHERE id='github'") == 't'
        count = len(requests)
        sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second'")
        rpc('Agentboard.Delivery.Scheduling.poll("' + pr_id + '")')
        assert len(requests) == count
        rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban); :ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
        stop_pollers()
        rpc('{:ok, %{allowed: false}} = Agentboard.Delivery.ProviderAdmission.acquire("github"); {:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.acquire("buildbuddy")')
    poll('malicious-url', 'failing')
    payload = json.loads(sql('SELECT payload FROM delivery_ci_snapshots ORDER BY generation DESC LIMIT 1'))
    assert next(a for a in payload['attempts'] if a['name'] == 'failed-build')['details_url'] is None
    assert 'invented-fixture-token' not in json.dumps(payload)
    for scenario, draft in [('draft', True), ('missing-draft', None), ('malformed-draft', None), ('normal', False)]:
        poll(scenario, 'pending')
        payload = json.loads(sql('SELECT payload FROM delivery_ci_snapshots ORDER BY generation DESC LIMIT 1'))
        assert payload['draft'] is draft, (scenario, payload)
    poll('clean', 'unknown')
    assert sql('SELECT ci_state FROM delivery_poll_states') == 'unknown'
    # The same actual HTTP evidence is certified only under explicit head policy.
    assert sql('SELECT resolved_at IS NULL FROM delivery_obligations') == 't'
    rpc('Application.put_env(:agentboard, :ci_policies, %{"fixture/repo" => %{"tested_ref" => "head", "required" => ["check:1:security-only"]}})')
    poll('clean', 'passing')
    assert sql("SELECT ci_state||','||(last_error IS NULL) FROM delivery_poll_states") == 'passing,true'
    assert sql('SELECT state FROM delivery_obligations') == 'resolved'
    assert sql("SELECT status FROM tasks WHERE 'ci-repair'=ANY(labels)") == 'assigned'
    rpc('Application.put_env(:agentboard, :ci_policies, %{})')
    poll('clean', 'unknown')
    # A late response may not append a snapshot after generation replacement.
    before = sql('SELECT count(*) FROM delivery_ci_snapshots')
    with concurrent.futures.ThreadPoolExecutor() as pool:
        future = pool.submit(poll, 'slow', 'superseded')
        assert slow_entered.wait(5)
        # No DB transaction/PR lock spans the TLS call. Ordinary board writes
        # and a replacement reservation both work while the provider is held.
        ab('task', 'create', '--id', 'independent-write', '--title', 'Independent write')
        sql("UPDATE delivery_poll_states SET lease_expires_at=clock_timestamp()-interval '1 second',next_poll_at=clock_timestamp()-interval '1 second'")
        rpc('{:ok, [_]} = Agentboard.Delivery.Polling.reserve_pr("' + pr_id + '")')
        slow_release.set()
        future.result(timeout=30)
    assert sql('SELECT count(*) FROM delivery_ci_snapshots') == before
    assert sql("SELECT snapshot_id IS NOT NULL AND attempt_id IS NOT NULL AND ci_state='unknown' FROM delivery_poll_states") == 't'
    # Failure of a meaningful Ash audit must roll back snapshot and projection.
    mode = 'fail'
    sql("UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL,next_poll_at=clock_timestamp()-interval '1 second'; UPDATE delivery_provider_budgets SET remaining=capacity,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    projection = sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states')
    sql("CREATE FUNCTION fixture_reject_observation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture audit unavailable'; END $$; CREATE TRIGGER fixture_audit_failure BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION fixture_reject_observation()")
    rpc('case Agentboard.Delivery.Scheduling.poll("' + pr_id + '") do {:error, _} -> IO.puts("ROLLED_BACK") end')
    assert sql('SELECT count(*) FROM delivery_ci_snapshots') == before
    assert sql('SELECT head_sha||base_sha||snapshot_id::text||observed_at::text||ci_state FROM delivery_poll_states') == projection
    sql('DROP TRIGGER fixture_audit_failure ON board_action_events; DROP FUNCTION fixture_reject_observation()')
    # Immutability is enforced in PostgreSQL, not solely by Ash action lists.
    immutable = subprocess.run([os.environ['FIXTURE_PSQL'], '-v', 'ON_ERROR_STOP=1', '-c',
                                "UPDATE delivery_ci_snapshots SET ci_state='failing'"], capture_output=True, text=True)
    assert immutable.returncode != 0 and 'append-only' in immutable.stderr
    assert sql("SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(t) FROM tasks t WHERE id='collector-task'),'events',(SELECT jsonb_agg(t) FROM task_events t WHERE task_id='collector-task'),'links',(SELECT jsonb_agg(t) FROM delivery_task_links t))") == source_before
    # Terminal lifecycle stop is observed through real TLS HTTP + the Ash
    # collector. Discovery must not defeat it on every minute's catch-up.
    # The preceding audit rollback leaves its separately committed reservation
    # live. Advance that fixture lease explicitly before testing a new sample.
    sql("UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL")
    start = len(requests)
    poll('closed', 'observed')
    assert requests[start:] == ['/repos/fixture/repo/pulls/601'], requests[start:]
    assert sql("SELECT enabled||','||lifecycle FROM delivery_poll_states") == 'false,closed'
    assert sql("SELECT next_poll_at-observed_at=interval '1 hour' FROM delivery_poll_states") == 't'
    assert sql("SELECT count(*)>0 FROM delivery_poll_states_versions WHERE version_action_name='observe_terminal'") == 't'
    count = len(requests)
    rpc('{:ok, _} = Agentboard.Delivery.discover()')
    rpc('Agentboard.Delivery.Scheduling.poll("' + pr_id + '")')
    assert len(requests) == count, 'Discovery restarted terminal CI polling immediately'
    html = urllib.request.urlopen(os.environ['AGENTBOARD_URL'] + '/prs').read().decode()
    assert 'fixture/repo #601' not in html and 'Show merged/closed' in html
    html = urllib.request.urlopen(os.environ['AGENTBOARD_URL'] + '/prs?show_terminal=true').read().decode()
    assert 'fixture/repo #601' in html and 'Hide merged/closed' in html
    html = urllib.request.urlopen(os.environ['AGENTBOARD_URL'] + '/prs/' + pr_id).read().decode()
    assert 'Immutable submission sources' in html
    # The independent scheduler catches closed inventory even if task URLs
    # are cleared. Once hourly eligibility expires, open metadata resumes CI.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second'")
    mode = 'clean'
    rpc('{:ok, _} = Agentboard.Delivery.Scheduling.tick()')
    assert sql('SELECT enabled FROM delivery_poll_states') == 't'
    assert sql("SELECT count(*)>0 FROM delivery_poll_states_versions WHERE version_action_name='resume'") == 't'
    poll('clean', 'unknown')
    assert sql("SELECT enabled||','||lifecycle FROM delivery_poll_states") == 'true,open'
    poll('clean', 'unknown')
    assert sql("SELECT next_poll_at-observed_at=interval '10 minutes' FROM delivery_poll_states") == 't'
    poll('normal', 'pending')
    assert sql("SELECT next_poll_at-observed_at=interval '60 seconds' FROM delivery_poll_states") == 't'
    # A fresh explicit PR submission can reconcile a closed row immediately.
    poll('closed', 'unknown')
    ab('task', 'create', '--id', 'reopen-link', '--title', 'Explicit reopen link',
       '--pr', 'https://github.com/fixture/repo/pull/601')
    assert sql('SELECT enabled FROM delivery_poll_states') == 't'
    start = len(requests)
    poll('merged', 'unknown')
    assert requests[start:] == ['/repos/fixture/repo/pulls/601']
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 day'")
    rpc('{:ok, _} = Agentboard.Delivery.discover(); {:ok, _} = Agentboard.Delivery.Scheduling.tick()')
    rpc('Agentboard.Delivery.Scheduling.poll("' + pr_id + '")')
    assert sql('SELECT enabled FROM delivery_poll_states') == 'f'
    assert len(requests) == start + 1, 'Merged PR resumed provider requests'
    # A prior operator capacity bump cannot exceed the safe per-minute cap.
    sql("UPDATE delivery_provider_budgets SET capacity=500,remaining=500,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    output = rpc('results = Enum.map(1..61, fn _ -> {:ok, r} = Agentboard.Delivery.ProviderAdmission.acquire("github"); r.allowed end); IO.puts("ALLOWED=" <> to_string(Enum.count(results, & &1)))')
    assert 'ALLOWED=60' in output, output
    server.shutdown()
print('Current-head all-page attempts/source links, no-policy unknown, fenced late reply, isolated writes and durable provider backoff passed.')
