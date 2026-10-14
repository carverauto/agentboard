"""Intake import through the packaged release, real API/CLI, PostgreSQL and an HTTPS GitHub fixture.

Covers the issue-burndown contract: default-off route, captain-only access,
strict selection shapes, repository scope before any GitHub call, a list
selection that takes the first N open issues in GitHub's order that are not
yet on the board, named issue numbers in the caller's order with skip
reasons, replay without reading GitHub again, conflict, a GitHub failure that
writes nothing, the page bound, cancel, and the CLI. Import never creates an
issue. Every identity, repository and credential is invented.
"""
import http.server
import json
import os
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-import-captain-capability-0123456789'
INTAKE_TOKEN = 'import-fixture-token'
REPO = 'acme/widgets'
MISSING = object()


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1',
                                    '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=MISSING, *, captain=True, agent='import-human', status=200):
    headers = {'X-Agentboard-Agent': agent, 'X-Agentboard-Model': 'fixture-model',
               'X-Agentboard-Harness': 'codex', 'Content-Type': 'application/json'}
    if captain:
        headers['Authorization'] = 'Bearer ' + CAPTAIN
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=headers,
                                     data=None if data is MISSING else json.dumps(data).encode())
    try:
        response = urllib.request.urlopen(request, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    text = json.dumps(body)
    assert CAPTAIN not in text and INTAKE_TOKEN not in text, 'credential leaked'
    assert response.status == status, (path, response.status, status, body)
    return body


def imported(data, status=200):
    return api('intake/import', data, status=status)


def counts():
    return sql("SELECT (SELECT count(*) FROM tasks)||','||(SELECT count(*) FROM intake_requests)||','||"
               "(SELECT count(*) FROM intake_items)||','||(SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Intake.IssueWorker')")


def task(task_id):
    return api('tasks/' + task_id, captain=False)['task']


# GitHub fixture: issues 1-30 in acme/widgets, newest first in listings.
# 25 is a pull request, 20 is closed, 40 was transferred elsewhere, and
# html_url uses GitHub's own casing.
def issue(number, **extra):
    row = {'number': number, 'html_url': f'https://github.com/Acme/Widgets/issues/{number}',
           'title': f'Issue {number}', 'body': f'Body of {number}', 'state': 'open',
           'labels': [{'name': 'bug'}] if number % 3 == 0 else []}
    row.update(extra)
    return row


issues = {n: issue(n) for n in range(1, 31)}
issues[25] = issue(25, html_url='https://github.com/Acme/Widgets/pull/25', pull_request={})
issues[20] = issue(20, state='closed')
issues[12] = issue(12, title='  Fix\tthe\nwidget  ', body='  Steps\n\nto reproduce  ',
                   labels=[{'name': ' ui '}, {'name': 'bug'}, {'name': 'ui'}, {'name': 'x' * 51}])
issues[40] = issue(40, html_url='https://github.com/acme/other/issues/3')
gets = []
posts = []
mode = {'github': 'ok'}


class GitHub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def oversized(self):
        # Content-Length over the shared 1 MiB cap. The client rejects it
        # from the header, so the body does not have to fill that length.
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', '1048577')
        self.end_headers()
        try:
            self.wfile.write(b' ')
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        posts.append(self.path)
        self.reply(500, {'message': 'import must never create an issue'})

    def do_GET(self):
        assert self.headers['Authorization'] == 'Bearer ' + INTAKE_TOKEN
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        gets.append((parsed.path, query))
        if mode['github'] == 'outage':
            return self.reply(503, {'message': 'fixture outage'})
        assert parsed.path.startswith('/repos/acme/widgets/issues'), parsed.path
        tail = parsed.path[len('/repos/acme/widgets/issues'):]
        if tail:
            if mode['github'] == 'fat-issue':
                return self.oversized()
            row = issues.get(int(tail[1:]))
            return self.reply(200, row) if row else self.reply(404, {'message': 'Not Found'})
        assert query['state'] == ['open'] and query['sort'] == ['created'] and query['direction'] == ['desc'], query
        per_page, page = int(query['per_page'][0]), int(query['page'][0])
        if mode['github'] == 'pull-requests':
            # Every page is full of pull requests, so only the bound stops it.
            rows = [issue(1000 + page * per_page + i, pull_request={}) for i in range(per_page)]
            return self.reply(200, rows)
        if mode['github'] == 'resume':
            # The first 200 rows are pull requests. Older open issues start on page 21.
            if page <= 20:
                rows = [issue(10_000 + page * per_page + i, pull_request={}) for i in range(per_page)]
                return self.reply(200, rows)
            return self.reply(200, [issue(101), issue(102), issue(103)])
        if mode['github'] == 'fat':
            # A page larger than one issue is over the body cap. Issue 210 is
            # over the cap on its own; the other nine on that page are not.
            if per_page > 1 or (page - 1) * per_page == 0:
                return self.oversized()
            return self.reply(200, [issue(210 - ((page - 1) * per_page))])
        wanted = query.get('labels', [''])[0]
        rows = [issues[n] for n in sorted(issues, reverse=True)
                if issues[n]['state'] == 'open' and n != 40
                and (not wanted or all({'name': w} in issues[n]['labels'] for w in wanted.split(',')))]
        self.reply(200, rows[(page - 1) * per_page: page * per_page])


# --- Default off: route unavailable, nothing written. ----------------------
assert api('meta', captain=False)['intake_enabled'] is False
assert imported({'request_key': 'off', 'repository': REPO}, status=404)['error']['code'] == 'intake_disabled'
assert counts() == '0,0,0,0'

rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard, :intake_enabled, true)')
rpc('Application.put_env(:agentboard, :intake_repositories, ["acme/widgets"])')
rpc('Application.put_env(:agentboard, :rate_limits, Keyword.put(Application.fetch_env!(:agentboard, :rate_limits), :intake, 1000))')

# --- Captain only, strict shapes, scope before GitHub. ----------------------
assert api('intake/import', {'request_key': 'k', 'repository': REPO}, captain=False,
           status=403)['error']['code'] == 'forbidden'
for bad in [{'repository': REPO},
            {'request_key': 'k'},
            {'request_key': 'k', 'repository': REPO, 'issues': []},
            {'request_key': 'k', 'repository': REPO, 'issues': [0]},
            {'request_key': 'k', 'repository': REPO, 'issues': [3, 3]},
            {'request_key': 'k', 'repository': REPO, 'issues': ['3']},
            {'request_key': 'k', 'repository': REPO, 'issues': list(range(1, 12))},
            {'request_key': 'k', 'repository': REPO, 'issues': [3], 'limit': 2},
            {'request_key': 'k', 'repository': REPO, 'issues': [3], 'labels': ['bug']},
            {'request_key': 'k', 'repository': REPO, 'issues': [3], 'start_page': 2},
            {'request_key': 'k', 'repository': REPO, 'limit': 11},
            {'request_key': 'k', 'repository': REPO, 'limit': 0},
            {'request_key': 'k', 'repository': REPO, 'start_page': 0},
            {'request_key': 'k', 'repository': REPO, 'priority': -1},
            {'request_key': 'k', 'repository': REPO, 'items': []}]:
    assert imported(bad, status=422)['error']['code'] == 'invalid_input', bad
assert 'acme/secret' in imported({'request_key': 'k', 'repository': 'acme/secret'}, status=403)['error']['message']
# Without the intake credential nothing is read or written.
unconfigured = imported({'request_key': 'k', 'repository': REPO}, status=503)
assert unconfigured['error']['code'] == 'github_unconfigured', unconfigured
assert counts() == '0,0,0,0'

# Existing cards: issue 30 is already on the board (other casing); issue 28's
# card was cancelled, so 28 is free to import again.
api('agents/register', {'name': 'Import human'}, captain=False)
api('tasks', {'id': 'held-30', 'title': 'Already here', 'issue_url': 'https://github.com/ACME/widgets/issues/30'}, captain=False)
api('tasks', {'id': 'dropped-28', 'title': 'Dropped', 'issue_url': 'https://github.com/acme/widgets/issues/28'}, captain=False)
sql("UPDATE tasks SET status='cancelled' WHERE id='dropped-28'")

with tls_provider(GitHub) as (api_url, ca, _server):
    with tempfile.TemporaryDirectory() as secrets:
        token_file = os.path.join(secrets, 'intake-token')
        with open(token_file, 'w') as handle:
            handle.write(INTAKE_TOKEN + '\n')
        rpc('Application.put_env(:agentboard, :intake_github, [api_url: ' + json.dumps(api_url) +
            ', token: nil, token_file: ' + json.dumps(token_file) + ', ca_file: ' + json.dumps(ca) + '])')

        # --- Burndown: the first three open issues not yet on the board. ---
        first = imported({'request_key': 'burn-1', 'repository': 'Acme/Widgets', 'limit': 3})
        intake = first['intake']
        assert first['replayed'] is False and intake['filer_id'] == 'captain'
        assert [i['issue_number'] for i in intake['items']] == [29, 28, 27], intake['items']
        assert intake['import'] == {
            'repository': REPO, 'selection': {'labels': [], 'limit': 3, 'start_page': 1},
            'priority': 3, 'skipped': [], 'bounded': False, 'next_page': 1}, intake['import']
        for item in intake['items']:
            assert (item['issue'], item['issue_state'], item['reason']) == (True, 'created', 'imported'), item
            assert item['issue_url'] == f"https://github.com/Acme/Widgets/issues/{item['issue_number']}"
            card = task(item['task_id'])
            assert (card['repo'], card['priority'], card['status'], card['issue_url']) == \
                (REPO, 3, 'open', item['issue_url']), card
            assert card['title'] == f"Issue {item['issue_number']}" == item['title']
            assert card['description'] == f"Imported from {item['issue_url']}\n\nBody of {item['issue_number']}"
        assert task(intake['items'][1]['task_id'])['labels'] == []
        assert task(intake['items'][0]['task_id'])['labels'] == []
        # Refill orders by priority, then creation: the list order holds.
        created = sql("SELECT string_agg(i.issue_number::text, ',' ORDER BY t.created_at, t.id) FROM intake_items i "
                      "JOIN tasks t ON t.id = i.task_id WHERE i.request_id='" + intake['id'] + "'")
        assert created == '29,28,27', created
        assert posts == [] and counts().endswith(',0'), 'import creates no issue and no outbox job'
        assert all(path == '/repos/acme/widgets/issues' for path, _ in gets)

        # Replay reads nothing from GitHub; a changed selection conflicts.
        read = len(gets)
        again = imported({'request_key': 'burn-1', 'repository': 'acme/widgets', 'limit': 3, 'priority': 3,
                          'labels': []})
        assert again['replayed'] is True and again['intake']['id'] == intake['id'] and len(gets) == read
        # An explicit first page is the same normalized request as omitting it.
        same = imported({'request_key': 'burn-1', 'repository': REPO, 'limit': 3, 'start_page': 1})
        assert same['replayed'] is True and len(gets) == read
        assert imported({'request_key': 'burn-1', 'repository': REPO, 'limit': 4},
                        status=409)['error']['code'] == 'conflict'
        assert imported({'request_key': 'burn-1', 'repository': REPO, 'limit': 3, 'start_page': 2},
                        status=409)['error']['code'] == 'conflict'
        assert len(gets) == read
        # A filing can never replay an import under the same key.
        assert api('intake', {'request_key': 'burn-1', 'items': [{'repository': REPO, 'title': 'x'}]},
                   status=409)['error']['code'] == 'conflict'

        # The next burndown passes over what is on the board and the pull request.
        second = imported({'request_key': 'burn-2', 'repository': REPO, 'limit': 3, 'priority': 1})['intake']
        assert [i['issue_number'] for i in second['items']] == [26, 24, 23], second['items']
        assert all(task(i['task_id'])['priority'] == 1 for i in second['items'])

        # Label filter goes to GitHub; issue 12's labels are cleaned and bounded.
        labelled = imported({'request_key': 'burn-3', 'repository': REPO, 'labels': ['bug'], 'limit': 2})['intake']
        assert gets[-1][1]['labels'] == ['bug']
        assert [i['issue_number'] for i in labelled['items']] == [21, 18], labelled['items']

        # --- Named issues keep the caller's order and report every skip. ---
        held = intake['items'][0]['task_id']
        named = imported({'request_key': 'named-1', 'repository': REPO,
                          'issues': [12, 20, 25, 99, 40, 29, 11]})['intake']
        assert [i['issue_number'] for i in named['items']] == [12, 11], named['items']
        assert named['import']['skipped'] == [
            {'issue_number': 20, 'reason': 'closed'},
            {'issue_number': 25, 'reason': 'pull_request'},
            {'issue_number': 99, 'reason': 'not_found'},
            {'issue_number': 40, 'reason': 'moved'},
            {'issue_number': 29, 'reason': 'already_linked', 'task_id': held}], named['import']
        card = task(named['items'][0]['task_id'])
        assert card['title'] == 'Fix the widget' and card['labels'] == ['bug', 'ui'], card
        assert card['description'] == 'Imported from https://github.com/Acme/Widgets/issues/12\n\nSteps\n\nto reproduce'
        shown = api('intake/' + named['id'])['intake']
        assert shown['import']['skipped'] == named['import']['skipped'] and shown['items'][0]['reason'] == 'imported'

        # --- A GitHub failure writes nothing. ------------------------------
        before = counts()
        mode['github'] = 'outage'
        failed = imported({'request_key': 'outage-1', 'repository': REPO, 'issues': [10, 9]}, status=503)
        assert failed['error']['code'] == 'github_unavailable' and failed['error']['reason'] == 'provider_status:503', failed
        assert imported({'request_key': 'outage-2', 'repository': REPO}, status=503)['error']['code'] == 'github_unavailable'
        assert counts() == before
        mode['github'] = 'ok'
        # The failed key was never recorded, so the same key now succeeds.
        assert [i['issue_number'] for i in imported({'request_key': 'outage-1', 'repository': REPO,
                                                     'issues': [10, 9]})['intake']['items']] == [10, 9]

        # --- The page bound stops a listing that never finds an issue. -----
        mode['github'] = 'pull-requests'
        listed = len(gets)
        bounded = imported({'request_key': 'bound-1', 'repository': REPO})['intake']
        assert bounded['items'] == [] and bounded['import']['bounded'] is True
        assert bounded['import']['next_page'] == 21
        assert len(gets) - listed == 20

        # Two hundred skipped rows, then older open issues via the returned page.
        mode['github'] = 'resume'
        window = len(gets)
        stalled = imported({'request_key': 'resume-1', 'repository': REPO, 'limit': 3})['intake']
        assert stalled['items'] == [] and stalled['import']['bounded'] is True
        assert stalled['import']['next_page'] == 21
        assert [int(q['page'][0]) for _, q in gets[window:]] == list(range(1, 21))
        resumed = imported({'request_key': 'resume-2', 'repository': REPO, 'limit': 3,
                            'start_page': stalled['import']['next_page']})['intake']
        assert [i['issue_number'] for i in resumed['items']] == [101, 102, 103]
        assert resumed['import']['bounded'] is False and resumed['import']['next_page'] is None
        assert resumed['import']['selection']['start_page'] == 21
        assert [int(q['page'][0]) for _, q in gets[window + 20:]] == [21]

        # One oversized body does not hide the rest of its page, and does not
        # retry as an outage. Issue 210 is unreadable; 209, 208 and 207 are not.
        mode['github'] = 'fat'
        fat_at = len(gets)
        fat = imported({'request_key': 'fat-1', 'repository': REPO, 'limit': 3})['intake']
        fat_calls = [q for _, q in gets[fat_at:]]
        assert any(q['per_page'] == ['10'] for q in fat_calls) and any(q['per_page'] == ['1'] for q in fat_calls)
        assert [i['issue_number'] for i in fat['items']] == [209, 208, 207], fat['items']
        assert all(int(q['page'][0]) <= 10 for q in fat_calls)
        mode['github'] = 'fat-issue'
        before_fat = counts()
        fat_named = imported({'request_key': 'fat-named', 'repository': REPO, 'issues': [16]}, status=503)
        assert fat_named['error']['code'] == 'github_unavailable' and fat_named['error']['reason'] == 'too_large', fat_named
        assert counts() == before_fat
        mode['github'] = 'ok'

        # --- Cancel takes back unstarted imported cards; the issue stays. --
        cancelled = api('intake/' + second['id'] + '/cancel', {})
        assert cancelled['cancelled'] == [i['id'] for i in second['items']]
        assert all(task(i['task_id'])['status'] == 'cancelled' for i in second['items'])
        assert all(i['issue_state'] == 'created' for i in cancelled['intake']['items'])
        api('intake/' + second['id'] + '/items/' + second['items'][0]['id'] + '/reconcile', {}, status=409)
        # A cancelled card no longer holds its issue.
        back = imported({'request_key': 'back-1', 'repository': REPO, 'issues': [26]})['intake']
        assert [i['issue_number'] for i in back['items']] == [26]

        # --- CLI over the same contract (captain capability file). ---------
        with tempfile.TemporaryDirectory() as home:
            captain_file = os.path.join(home, 'captain')
            fd = os.open(captain_file, os.O_WRONLY | os.O_CREAT, 0o600)
            os.write(fd, CAPTAIN.encode())
            os.close(fd)
            env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
            env.update(AGENTBOARD_CAPTAIN_TOKEN_FILE=captain_file, AGENT_ID='', AGENTBOARD_MODEL='', AGENTBOARD_HARNESS='')

            def ab(*args, code=0):
                p = subprocess.run([os.environ['AB_BINARY'], *args], env=env, capture_output=True, text=True, timeout=60)
                assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
                return p.stdout

            cli = json.loads(ab('--json', 'intake', 'import', '--request-key', 'cli-1', '--repo', REPO,
                                '--issue', '8', '--issue', '20', '--priority', '2'))
            assert [i['issue_number'] for i in cli['intake']['items']] == [8]
            assert task(cli['intake']['items'][0]['task_id'])['priority'] == 2
            human = ab('intake', 'import', '--request-key', 'cli-1', '--repo', REPO, '--issue', '8', '--issue', '20',
                       '--priority', '2')
            assert 'replayed=true' in human and '#20' in human and 'closed' in human, human
            ab('intake', 'import', '--request-key', 'cli-1', '--repo', REPO, '--issue', '7', code=4)
            listed = json.loads(ab('--json', 'intake', 'import', '--request-key', 'cli-2', '--repo', REPO,
                                   '--label', 'bug', '--limit', '1'))
            # 24's card was cancelled above, so 24 is the first free bug issue.
            assert [i['issue_number'] for i in listed['intake']['items']] == [24]

assert posts == [], 'import never creates an issue'

# --- Disabling intake makes import unavailable again. ----------------------
rpc('Application.put_env(:agentboard, :intake_enabled, false)')
assert imported({'request_key': 'off-2', 'repository': REPO}, status=404)['error']['code'] == 'intake_disabled'
print('intake import contract verified')
