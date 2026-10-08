"""Signed webhook -> admitted HTTPS -> audited Ash state -> public health/inbox.

Owns default-branch run accountability; PR-head normalization is covered elsewhere.
Providers, keys, repos and agent identities below are invented. No production data.
"""
import concurrent.futures
import hashlib
import hmac
import http.server
import json
import os
import re
from pathlib import Path
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
HOOK_BYTES = os.urandom(32)  # Ephemeral per-run HMAC material (no hardcoded credential).
SHA = 'a' * 40
runs = {}
requests = []
provider_status = 200
jobs_total = None
flap = False
reads = 0


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def value(expression):
    output = rpc('IO.puts(Jason.encode!(' + expression + '))')
    return json.loads(output.strip().splitlines()[-1])


def ab(*args, owner='workflow-owner'):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'DATABASE_'))}
    env.update(AGENT_ID=owner, AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')
    p = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                       capture_output=True, text=True, timeout=25)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return json.loads(p.stdout)


def hook(run_id, repo='fixture/repo', signature=True, event='workflow_run', raw=None):
    body = raw if raw is not None else json.dumps(dict(action='completed',
        repository=dict(full_name=repo), workflow_run=dict(id=run_id, conclusion='success'))).encode()
    digest = hmac.new(HOOK_BYTES, body, hashlib.sha256).hexdigest() if signature else '0' * 64
    req = urllib.request.Request(URL + '/api/v1/hooks/github', data=body, method='POST',
        headers={'Content-Type': 'application/json', 'X-Github-Event': event,
                 'X-Hub-Signature-256': 'sha256=' + digest})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def state(run_id, repo='fixture/repo'):
    return value('Agentboard.Board.Operations.public(Ash.get!(Agentboard.Delivery.WorkflowRun, ' +
                 json.dumps(f'{repo}/{run_id}') + '))')


def health():
    with urllib.request.urlopen(URL + '/api/v1/prs', timeout=10) as response:
        return json.load(response)['default_branch_health']


def reset_budget(remaining=60):
    rpc('b = Ash.get!(Agentboard.Delivery.ProviderBudget, "github"); '
        'Agentboard.Board.Operations.update(b, :consume, %{remaining: ' + str(remaining) +
        ', reset_at: DateTime.add(DateTime.utc_now(), 60), blocked_until: nil}, %{})')


def check(run_id, repo='fixture/repo'):
    return value('case Agentboard.Delivery.WorkerAction.run(Agentboard.Delivery.WorkflowObservation, '
        ':check, %{"id" => ' + json.dumps(f'{repo}/{run_id}') + '}) do '
        '{:ok, result} -> result; other -> inspect(other) end')


def retry_due(run_id, repo='fixture/repo'):
    rpc('r = Ash.get!(Agentboard.Delivery.WorkflowRun, ' + json.dumps(f'{repo}/{run_id}') + '); '
        'Agentboard.Board.Operations.update(r, :observe, %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)}, '
        '%{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"})')


def publish(run_id, **overrides):
    repo = overrides.pop('repo', 'fixture/repo')
    branch = 'staging' if repo == 'fixture/service' else 'main'
    runs[run_id] = dict(id=run_id, workflow_id=7, name='Container images', run_number=run_id,
        run_attempt=1, head_sha=SHA, head_branch=branch, head_repository=dict(full_name=repo),
        status='completed', conclusion='failure', event='push')
    runs[run_id].update(overrides)
    assert hook(run_id, repo)[0] == 202
    reset_budget()
    return check(run_id, repo)


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global reads
        assert self.headers.get('Authorization') == 'Bearer invented-workflow-provider-token'
        path = urllib.parse.urlparse(self.path).path
        requests.append(path)
        repo = 'fixture/service' if '/fixture/service' in path else 'fixture/repo'
        if path == '/repos/' + repo:
            body = dict(full_name=repo, default_branch='staging' if repo.endswith('/service') else 'main')
        elif '/attempts/' in path:
            run_id = int(path.split('/runs/')[1].split('/')[0])
            attempt = int(path.split('/attempts/')[1].split('/')[0])
            body = dict(total_count=1 if jobs_total is None else jobs_total, jobs=[dict(
                id=run_id * 100 + attempt, run_id=run_id, conclusion='failure', name='publish',
                steps=[dict(name=f'Test on BuildBuddy attempt {attempt}', conclusion='failure')])])
        elif '/actions/runs/' in path:
            run_id = int(path.rsplit('/', 1)[1])
            body = dict(runs[run_id])
            reads += 1
            if flap and reads % 2 == 0:
                body['run_attempt'] += 1
        elif '/commits/' in path and path.endswith('/pulls'):
            body = [] if '/commits/' + 'c' * 40 in path else [dict(number=101,
                merged_at='2026-01-01T00:00:00Z', merge_commit_sha=SHA,
                base=dict(ref='main', repo=dict(full_name='fixture/repo')))]
        else:
            raise AssertionError(path)
        encoded = json.dumps(body).encode()
        self.send_response(provider_status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        if provider_status == 429:
            self.send_header('Retry-After', '180')
        self.end_headers()
        self.wfile.write(encoded)


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); '
    'Application.put_env(:agentboard, :cooperation_enabled, false); '
    'Application.put_env(:agentboard, :workflow_repositories, ["fixture/repo", "fixture/service"])')
for owner in ('workflow-owner', 'workflow-coordinator', 'workflow-peer'):
    ab('agent', 'register', owner=owner)
rpc('Application.put_env(:agentboard, :coordinator_id, "workflow-coordinator")')
hook_file = Path(os.environ['TEST_TMPDIR'], 'workflow-hook-material')
hook_file.write_bytes(HOOK_BYTES)
rpc('Application.put_env(:agentboard, :workflow_webhook_secret_file, ' + json.dumps(str(hook_file)) + ')')
rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)')
assert hook(1)[0] == 503
rpc('Application.put_env(:agentboard, :pr_observation_enabled, true)')
assert hook(1, signature=False)[0] == 401
assert hook(1, event='push')[0] == 400
assert hook(1, event='ping') == (200, {'status': 'pong'})
assert hook(1, event='ping', signature=False)[0] == 401
assert hook(1, repo='foreign/repo')[0] == 403
assert hook(1, raw=b'x' * 1_048_577)[0] == 413
assert value('Enum.count(Ash.read!(Agentboard.Delivery.WorkflowRun))') == 0
ab('task', 'create', '--id', 'workflow-original', '--title', 'Original delivered source',
   '--repo', 'fixture/repo', '--pr', 'https://github.com/fixture/repo/pull/101')
ab('task', 'claim', 'workflow-original')
ab('task', 'update', 'workflow-original', '--status', 'done', '--body', 'Already delivered')
ab('task', 'create', '--id', 'workflow-next', '--title', 'Unrelated current task')
ab('task', 'claim', 'workflow-next')
ab('agent', 'heartbeat', '--status', 'busy', '--task', 'workflow-next')
before = ab('task', 'show', 'workflow-original')

with tls_provider(Provider) as (api_url, ca, _):
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) +
        ', token: "invented-workflow-provider-token", ca_file: ' + json.dumps(ca) + '])')
    assert publish(10)['observed'] == 'failure'
    failure = state(10)
    assert failure['responsible_id'] == 'workflow-owner' and failure['source_tasks'] == ['workflow-original']
    assert failure['failed_at'] and not failure['resolved_at'] and failure['message_id'] is None
    assert failure['jobs'][0]['steps'] == ['Test on BuildBuddy attempt 1']
    assert 'attempts/1/jobs' in ' '.join(requests)
    assert len(health()) == 1, health()
    rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        assert all(code == 202 for code, _ in pool.map(lambda _: hook(10), range(2)))
    reset_budget()
    check(10)
    reset_budget()
    assert check(10)['skipped']
    notices = ab('msg', 'list', '--to', 'workflow-owner')['messages']
    notices = [m for m in notices if m['body'].startswith('Default-branch CI failure:')]
    assert len(notices) == 1 and 'publish' in notices[0]['body'] and 'Test on BuildBuddy' in notices[0]['body'], notices
    message = state(10)['message_id']
    runs[10]['run_attempt'] = 2
    assert hook(10)[0] == 202
    reset_budget()
    check(10)
    assert state(10)['run_attempt'] == 2 and state(10)['message_id'] == message
    assert state(10)['jobs'][0]['steps'] == ['Test on BuildBuddy attempt 2']
    html = urllib.request.urlopen(URL + '/prs').read().decode()
    assert 'Default-branch health' in html and 'workflow-owner' in html and 'attempt 2' in html
    assert 'Test on BuildBuddy attempt 2' in html
    css_path = re.search(r'<link rel="stylesheet"[^>]*href="([^"]+)"', html).group(1)
    css = urllib.request.urlopen(URL + css_path, timeout=10).read().decode()
    preview = re.sub(r'<link rel="stylesheet"[^>]+>', lambda _: '<style>' + css + '</style>', html)
    Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'], 'default-branch-red-panel.html').write_text(preview)
    assert publish(20, head_sha='c' * 40)['observed'] == 'failure'
    assert state(20)['responsible_id'] == 'workflow-coordinator'
    assert len(ab('msg', 'list', '--to', 'workflow-coordinator', owner='workflow-coordinator')['messages']) == 1
    assert publish(21, repo='fixture/service', head_sha='c' * 40)['observed'] == 'failure'
    assert state(21, 'fixture/service')['branch'] == 'staging'
    # Branch/repository/event evidence is authoritative, not webhook claims.
    assert publish(22, head_branch='topic')['ignored']
    assert publish(23, event='pull_request')['ignored']
    assert publish(24, head_repository=dict(full_name='fork/repo'))['ignored']
    assert state(22)['failed_at'] is None
    # A different workflow's green does not resolve Container images.
    publish(30, conclusion='success', workflow_id=8, name='Lint')
    assert state(10)['resolved_at'] is None
    publish(31, conclusion='success', head_sha='d' * 40)
    assert state(10)['resolution_run_id'] == '31' and state(20)['resolved_at']
    assert state(21, 'fixture/service')['resolved_at'] is None
    # Out-of-order older failure is retained as resolved without a new notice.
    publish(25, head_sha='c' * 40)
    assert state(25)['resolution_run_id'] == '31' and state(25)['message_id'] is None
    # A same-run rerun can both recover and subsequently fail again; attempt
    # ordering must not mistake an older green attempt for recovery.
    publish(40, head_sha='c' * 40)
    runs[40].update(run_attempt=2, conclusion='success')
    hook(40); reset_budget(); check(40)
    assert state(40)['resolved_at']
    runs[40].update(run_attempt=3, conclusion='failure')
    hook(40); reset_budget(); check(40)
    assert state(40)['resolved_at'] is None
    publish(41, conclusion='success')
    assert state(40)['resolved_at']
    # Exhaustion admits no HTTPS call and leaves a durable retry cue.
    runs[50] = dict(runs[40], id=50, run_number=50, run_attempt=1)
    hook(50); reset_budget(0)
    count = len(requests)
    assert check(50)['deferred'] == 'rate_limited'
    assert len(requests) == count and state(50)['processed_at'] is None
    retry_due(50); reset_budget(); check(50)
    assert state(50)['conclusion'] == 'failure'
    # Rate-limit cooldown, incomplete page and changing attempt never publish
    # partial evidence or falsely resolve a retained red workflow.
    provider_status = 429
    runs[51] = dict(runs[50], id=51, run_number=51)
    hook(51); reset_budget()
    assert check(51)['deferred'] == 'rate_limited'
    provider_status = 200
    retry_due(51); reset_budget()
    jobs_total = 501
    assert check(51)['deferred'] == 'incomplete'
    assert state(51)['failed_at'] is None
    jobs_total = None
    retry_due(51); reset_budget(); flap = True; reads = 0
    assert check(51)['deferred'] == 'incomplete'
    assert state(51)['failed_at'] is None
    flap = False
    retry_due(51); reset_budget(); check(51)
    assert state(51)['conclusion'] == 'failure'
    # Restart recovery requeues a persisted cue without another GitHub event.
    runs[52] = dict(runs[50], id=52, run_number=52)
    hook(52)
    assert value('case Agentboard.Delivery.WorkflowMonitor.tick() do {:ok, x} -> x end')['scheduled'] >= 1
    reset_budget(); check(52)
    assert state(52)['conclusion'] == 'failure'
    assert ab('task', 'show', 'workflow-original') == before
    assert ab('task', 'show', 'workflow-next')['task']['status'] == 'in_progress'
    audits = value('Ash.read!(Agentboard.Board.AuditEvent) |> Enum.map(&Agentboard.Board.Operations.public/1)')
    assert any('WorkflowRun' in json.dumps(a) and 'observe' in json.dumps(a) for a in audits)
    assert all('invented-workflow-provider-token' not in json.dumps(row) for row in health())
    publish(60, conclusion='success')
    publish(61, repo='fixture/service', conclusion='success')
    assert health() == []

print('Signed default-branch intake, immutable attribution, retries/reruns, ordering, recovery and public health passed')
