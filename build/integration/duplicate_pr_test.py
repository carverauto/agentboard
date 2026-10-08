"""Actual HTTPS collector -> Ash transaction -> API/dashboard/once-only notice.

Owns accidental replay after merge, independently of conflict/CI normalization.
Fixtures are invented; no GitHub writes or production data are used.
"""
import concurrent.futures
import http.server
import json
import os
import subprocess
import urllib.parse
import urllib.request
from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
HEAD, BASE = 'a' * 40, 'b' * 40
prs = {}


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=45)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def ab(*args, owner='duplicate-owner'):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'DATABASE_'))}
    env.update(AGENT_ID=owner, AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')
    p = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                       capture_output=True, text=True, timeout=25)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return json.loads(p.stdout)


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        assert self.headers.get('Authorization') == 'Bearer invented-duplicate-token'
        path = urllib.parse.urlparse(self.path).path
        if '/pulls/' in path:
            number = int(path.rsplit('/', 1)[1])
            item = prs[number]
            body = dict(number=number, state='closed' if item['merged'] else 'open',
                        merged=item['merged'], draft=False,
                        head=dict(sha=HEAD, ref=item['branch'],
                                  repo=dict(full_name=item['head_repo'])),
                        base=dict(sha=BASE), mergeable=True, mergeable_state='clean')
        elif path.endswith('/check-suites'):
            body = dict(total_count=0, check_suites=[])
        elif path.endswith('/statuses'):
            body = []
        else:
            raise AssertionError(path)
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def create(number, task, branch='feat/replayed', head_repo='fixture/repo'):
    prs[number] = dict(merged=False, branch=branch, head_repo=head_repo)
    ab('task', 'create', '--id', task, '--title', task, '--repo', 'fixture/repo',
       '--pr', f'https://github.com/fixture/repo/pull/{number}')
    ab('task', 'claim', task)
    ab('task', 'update', task, '--status', 'review')
    return sql(f"SELECT id FROM delivery_pull_requests WHERE number='{number}'")


def poll(pr):
    sql("UPDATE delivery_provider_budgets SET remaining=60,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + pr + "'")
    return rpc('IO.puts(inspect(Agentboard.Delivery.Scheduling.poll(' + json.dumps(pr) + ')))')


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); Application.put_env(:agentboard, :cooperation_enabled, false)')
ab('agent', 'register')
ab('agent', 'register', owner='fixture-coordinator')
rpc('Application.put_env(:agentboard, :cooperation_coordinator_id, "fixture-coordinator")')
with tls_provider(Provider) as (api_url, ca, _):
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) +
        ', token: "invented-duplicate-token", ca_file: ' + json.dumps(ca) + '])')
    original = create(101, 'duplicate-original')
    prs[101]['merged'] = True
    assert 'observed' in poll(original)
    rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.MergeDisposition, :reconcile, %{}, actor: %{role: :system}); {:ok, _} = Ash.run_action(input)')
    assert ab('task', 'show', 'duplicate-original')['task']['status'] == 'done'
    replay = create(102, 'duplicate-replayed')
    assert 'observed' in poll(replay)
    detail = ab('pr', 'show', replay)
    finding = detail.get('duplicate_of')
    assert finding and finding['merged_pull_request_id'] == original, (
        'Replay after merged same head branch must retain a duplicate finding', detail)
    assert finding['basis'] == 'head_branch'
    assert ab('task', 'show', 'duplicate-replayed')['task']['status'] == 'review'
    assert sql("SELECT count(*) FROM messages WHERE body LIKE 'Possible duplicate PR:%'") == '0'
    # Enabling later and racing pollers produces one finding and one notice to
    # each recipient, even without worker enrollment; notices do not assign work.
    rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        list(pool.map(lambda _: poll(replay), range(2)))
    poll(replay)
    for owner in ('duplicate-owner', 'fixture-coordinator'):
        inbox = ab('msg', 'list', '--to', owner, owner=owner)['messages']
        notices = [m for m in inbox if m['body'].startswith('Possible duplicate PR:')]
        assert len(notices) == 1 and '/pull/101' in notices[0]['body'] and '/pull/102' in notices[0]['body'], notices
    assert ab('pr', 'list')['prs'][0].get('duplicate_of')
    html = urllib.request.urlopen(URL + '/prs').read().decode()
    assert 'Possible duplicate' in html and '/pull/101' in html
    board = urllib.request.urlopen(URL + '/?status=review').read().decode()
    assert 'Possible duplicate' in board
    assert ab('task', 'show', 'duplicate-replayed')['task']['status'] == 'review'
    # Branch names in other head repositories are independent, as are fresh
    # branches without a common merged task submission.
    other_fork = create(103, 'duplicate-other-fork', head_repo='other/repo')
    poll(other_fork)
    assert ab('pr', 'show', other_fork).get('duplicate_of') is None
    unrelated = create(104, 'duplicate-unrelated', branch='feat/new-work')
    poll(unrelated)
    assert ab('pr', 'show', unrelated).get('duplicate_of') is None
    # A task with retained merged submission is flagged even after changing
    # branch; the existing task lifecycle remains under explicit owner control.
    task_based = create(105, 'duplicate-task-source', branch='feat/source')
    prs[105]['merged'] = True
    poll(task_based)
    ab('task', 'link', 'duplicate-task-source', '--pr', 'https://github.com/fixture/repo/pull/106')
    prs[106] = dict(merged=False, branch='feat/different', head_repo='fixture/repo')
    later = sql("SELECT id FROM delivery_pull_requests WHERE number='106'")
    poll(later)
    assert ab('pr', 'show', later)['duplicate_of']['basis'] == 'task_submission'
    assert ab('task', 'show', 'duplicate-task-source')['task']['status'] == 'review'
    print('Merged-branch/task replay findings, fork isolation, board/API reads and once-only cooperation inbox notices passed')
