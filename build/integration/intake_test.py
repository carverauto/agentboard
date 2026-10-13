"""Work intake through the packaged release, real API/CLI, PostgreSQL and an HTTPS GitHub fixture.

Covers the L1 contract: default-off routes, captain-only access even with
board auth off, request-key replay and conflict on the normalized payload,
out-of-scope rejection, transactional rollback, and the GitHub issue outbox
(outage, lost response with marker adoption, definitive rejection, duplicate
marker, abandon, reconcile, repository scope) plus cancel and rate limits.
The intake queue stays paused (intake is off at boot), so the test drives each
outbox job explicitly. Every identity, repository and credential is invented.
"""
import http.server
import json
import os
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-intake-captain-capability-0123456789'
INTAKE_TOKEN = 'intake-fixture-token'
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


def api(path, data=MISSING, *, captain=True, token=None, agent='intake-human', status=200):
    headers = {'X-Agentboard-Agent': agent, 'X-Agentboard-Model': 'fixture-model',
               'X-Agentboard-Harness': 'codex', 'Content-Type': 'application/json'}
    if captain:
        headers['Authorization'] = 'Bearer ' + CAPTAIN
    if token is not None:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=headers,
                                     data=None if data is MISSING else json.dumps(data).encode())
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    text = json.dumps(body)
    assert CAPTAIN not in text and INTAKE_TOKEN not in text, 'credential leaked'
    expected = status if isinstance(status, tuple) else (status,)
    assert response.status in expected, (path, response.status, status, body)
    if path.startswith('intake'):
        assert response.headers['cache-control'] == 'no-store'
    return body, response.headers


def file(request_key, items, status=200):
    return api('intake', {'request_key': request_key, 'items': items}, status=status)[0]


def counts():
    return sql("SELECT (SELECT count(*) FROM tasks)||','||(SELECT count(*) FROM intake_requests)||','||"
               "(SELECT count(*) FROM intake_items)||','||(SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Intake.IssueWorker')")


def work(item_id):
    """Run the item's outbox job exactly as Oban would."""
    out = rpc('{:ok, r} = Agentboard.Intake.IssueWorker.perform(%Oban.Job{args: %{"id" => "' + item_id +
              '"}}); IO.puts("R=" <> Jason.encode!(r))')
    return json.loads(out.split('R=', 1)[1].splitlines()[0])


def due(item_id):
    sql("UPDATE intake_items SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id='" + item_id + "'")


def item_row(item_id):
    return json.loads(sql("SELECT to_jsonb(i) FROM intake_items i WHERE id='" + item_id + "'"))


def task(task_id):
    return api('tasks/' + task_id, captain=False)[0]['task']


# GitHub fixture: issues live in memory; `mode` selects the next behavior.
issues = []
posts = []
lists = []
user_lookups = []
mode = {'post': 'ok', 'list': 'ok'}


class GitHub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body, headers=None):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def store(self, payload, repo):
        number = len(issues) + 1
        issue = {'number': number, 'html_url': f'https://github.com/{repo}/issues/{number}',
                 'title': payload['title'], 'body': payload['body'], 'labels': payload['labels']}
        issues.append(issue)
        return issue

    def do_POST(self):
        assert self.headers['Authorization'] == 'Bearer ' + INTAKE_TOKEN
        path = urllib.parse.urlparse(self.path).path
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        repo = path[len('/repos/'):-len('/issues')]
        posts.append((repo, payload))
        current = mode['post']
        if current == 'outage':
            return self.reply(503, {'message': 'fixture outage'})
        if current == 'rate':
            return self.reply(403, {'message': 'API rate limit exceeded'}, {'X-RateLimit-Remaining': '0'})
        if current == 'reject':
            return self.reply(422, {'message': 'Validation Failed'})
        if current in ('lost', 'lost-twice'):
            self.store(payload, repo)
            if current == 'lost-twice':
                self.store(payload, repo)
            self.close_connection = True
            return  # stored, but the response never arrives
        issue = self.store(payload, repo)
        self.reply(201, {'number': issue['number'], 'html_url': issue['html_url']})

    def do_GET(self):
        assert self.headers['Authorization'] == 'Bearer ' + INTAKE_TOKEN
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/user':
            user_lookups.append(parsed.path)
            return self.reply(200, {'login': 'mona_acme'})
        query = urllib.parse.parse_qs(parsed.query)
        lists.append(parsed.path)
        per_page = int(query['per_page'][0])
        assert query['state'] == ['all'] and query['creator'] == ['mona_acme'], query
        assert query['sort'] == ['created'] and query['direction'] == ['desc'] and 'since' in query, query
        assert 1 <= per_page <= 10, per_page
        if mode['list'] == 'outage':
            return self.reply(503, {'message': 'fixture outage'})
        page = int(query['page'][0])
        prefix = 'https://github.com' + parsed.path[len('/repos'):]
        rows = [{'number': i['number'], 'html_url': i['html_url'], 'body': i['body']}
                for i in issues if i['html_url'].startswith(prefix + '/')]
        if mode['list'] == 'endless':
            # Every page is full, so a bounded lookup cannot decide it is done.
            while len(rows) < page * per_page:
                number = 5000 + len(rows)
                rows.append({'number': number, 'html_url': f'{prefix}/{number}', 'body': 'padding'})
            return self.reply(200, rows[(page - 1) * per_page: page * per_page])
        # A pull request with the marker text must never be adopted.
        rows.append({'number': 999, 'html_url': 'https://github.com/acme/widgets/pull/999',
                     'body': ' '.join(i['body'] for i in issues), 'pull_request': {}})
        self.reply(200, rows[(page - 1) * per_page: page * per_page])


# --- Default off: routes unavailable, nothing written. ----------------------
assert api('meta', captain=False)[0]['intake_enabled'] is False
meta = api('meta', captain=False)[0]
assert meta['schema_version'] == meta['required_schema_version'] == 46
assert sql("SELECT kind||','||harness FROM agents WHERE id='system-intake'") == 'system,ash'
body, _ = api('intake', {'request_key': 'off', 'items': [{'repository': REPO, 'title': 'x'}]}, status=404)
assert body['error']['code'] == 'intake_disabled'
api('intake/00000000-0000-4000-8000-000000000000', status=404)
assert counts() == '0,0,0,0'

rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard, :intake_enabled, true)')
rpc('Application.put_env(:agentboard, :intake_repositories, ["acme/widgets", "acme/gadgets"])')
rpc('Application.put_env(:agentboard, :rate_limits, Keyword.put(Application.fetch_env!(:agentboard, :rate_limits), :intake, 1000))')
assert api('meta', captain=False)[0]['intake_enabled'] is True

# --- Captain only, even though board auth mode is off. ----------------------
assert api('intake', {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x'}]},
           captain=False, status=403)[0]['error']['code'] == 'forbidden'
api('intake', {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x'}]}, captain=False,
    token='not-the-captain-capability-000000000000', status=403)
api('intake/00000000-0000-4000-8000-000000000000', captain=False, status=403)
assert counts() == '0,0,0,0'

# --- Validation. -------------------------------------------------------------
for bad in [{'request_key': 'k', 'items': []},
            {'request_key': '', 'items': [{'repository': REPO, 'title': 'x'}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': ' '}]},
            {'request_key': 'k', 'items': [{'repository': 'not a repo', 'title': 'x'}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x', 'assignee': 'a'}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x', 'issue': 'yes'}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x', 'priority': -1}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x', 'body': '<!-- agentboard-intake:x -->'}]},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x'}] * 11},
            {'request_key': 'k', 'items': [{'repository': REPO, 'title': 'x'}], 'extra': 1}]:
    assert api('intake', bad, status=422)[0]['error']['code'] == 'invalid_input', bad
assert counts() == '0,0,0,0'

# --- Out-of-scope repository rejects the whole request. -------------------
body, _ = api('intake', {'request_key': 'scope', 'items': [
    {'repository': REPO, 'title': 'In scope'}, {'repository': 'acme/secret', 'title': 'Out'}]}, status=403)
assert 'acme/secret' in body['error']['message']
assert counts() == '0,0,0,0'

# --- A failure after some cards were written rolls everything back. -------
sql("""CREATE FUNCTION intake_fixture_fail() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN IF NEW.position = 1 THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'fixture rollback'; END IF; RETURN NEW; END $$;
CREATE TRIGGER intake_fixture_fail BEFORE INSERT ON intake_items FOR EACH ROW EXECUTE FUNCTION intake_fixture_fail();""")
api('intake', {'request_key': 'rollback', 'items': [{'repository': REPO, 'title': 'First'},
                                                     {'repository': REPO, 'title': 'Second'}]}, status=(409, 503))
assert counts() == '0,0,0,0'
assert sql("SELECT count(*) FROM task_events") == '0'
sql('DROP TRIGGER intake_fixture_fail ON intake_items; DROP FUNCTION intake_fixture_fail()')

# --- File, replay with an equivalent payload, conflict on a changed one. --
first = file('batch-1', [
    {'repository': REPO, 'title': '  Fix the widget  ', 'body': ' Steps to reproduce ', 'priority': 1,
     'labels': ['ui', 'bug', 'ui']},
    {'repository': 'acme/gadgets', 'title': 'Card only note', 'issue': False}])
intake = first['intake']
assert first['replayed'] is False and intake['filer_id'] == 'captain' and len(intake['items']) == 2
widget, note = intake['items']
assert widget['issue_state'] == 'pending' and note['issue_state'] == 'none' and note['issue'] is False
card = task(widget['task_id'])
assert (card['title'], card['description'], card['priority'], card['repo'], card['labels'], card['status']) == \
    ('Fix the widget', 'Steps to reproduce', 1, 'acme/widgets', ['bug', 'ui'], 'open')
assert task(note['task_id'])['priority'] == 3
assert sql("SELECT actor_id FROM task_events WHERE task_id='" + widget['task_id'] + "'") == 'captain'
# The issue intent's job commits with the card; the card-only item has none.
assert counts() == '2,1,2,1'

replay = file('batch-1', [
    {'repository': 'ACME/Widgets', 'title': 'Fix the widget', 'body': 'Steps to reproduce', 'priority': 1,
     'labels': ['bug', 'ui']},
    {'repository': 'acme/gadgets', 'title': 'Card only note', 'body': '', 'issue': False, 'labels': []}])
assert replay['replayed'] is True and replay['intake']['id'] == intake['id']
assert [i['task_id'] for i in replay['intake']['items']] == [widget['task_id'], note['task_id']]
assert counts() == '2,1,2,1'
conflict, _ = api('intake', {'request_key': 'batch-1', 'items': [{'repository': REPO, 'title': 'Fix the widget'}]}, status=409)
assert conflict['error']['code'] == 'conflict'
assert counts() == '2,1,2,1'
assert api('intake/' + intake['id'])[0]['intake']['items'][0]['id'] == widget['id']
api('intake/00000000-0000-4000-8000-000000000000', status=404)
api('intake/not-a-uuid', status=404)

with tls_provider(GitHub) as (api_url, ca, _server):
    rpc('Application.put_env(:agentboard, :intake_github, [api_url: ' + json.dumps(api_url) +
        ', token: nil, token_file: nil, ca_file: ' + json.dumps(ca) + '])')

    # Without the intake credential nothing is sent and the intent stays pending.
    assert work(widget['id'])['state'] == 'pending'
    assert item_row(widget['id'])['last_error'] == 'github_unconfigured' and posts == []
    assert item_row(widget['id'])['attempts'] == 0, 'no attempt counted without a credential'
    with tempfile.TemporaryDirectory() as secrets:
        token_file = os.path.join(secrets, 'intake-token')
        with open(token_file, 'w') as handle:
            handle.write(INTAKE_TOKEN + '\n')
        rpc('Application.put_env(:agentboard, :intake_github, [api_url: ' + json.dumps(api_url) +
            ', token: nil, token_file: ' + json.dumps(token_file) + ', ca_file: ' + json.dumps(ca) + '])')

        # Outage: the card already exists; the intent stays pending with backoff.
        mode['post'] = 'outage'
        due(widget['id'])
        assert work(widget['id'])['state'] == 'pending'
        row = item_row(widget['id'])
        assert row['issue_state'] == 'pending' and row['attempts'] == 1 and row['last_error'] == 'provider_status:503', row
        assert work(widget['id'])['skipped'] == 'not_due'
        assert task(widget['task_id'])['issue_url'] is None

        # The search during an outage is transient too.
        mode['list'] = 'outage'
        due(widget['id'])
        assert work(widget['id'])['state'] == 'pending' and len(posts) == 1
        assert item_row(widget['id'])['last_error'] == 'search_provider_status:503'

        # Recovery: marker scan finds nothing, one create, card linked.
        mode['post'], mode['list'] = 'ok', 'ok'
        due(widget['id'])
        assert work(widget['id'])['state'] == 'created'
        assert len(posts) == 2 and len(issues) == 1
        repo, payload = posts[-1]
        assert repo == 'acme/widgets' and payload['title'] == 'Fix the widget' and payload['labels'] == ['bug', 'ui']
        assert payload['body'] == 'Steps to reproduce\n\n<!-- agentboard-intake:' + widget['id'] + ' -->'
        assert task(widget['task_id'])['issue_url'] == 'https://github.com/acme/widgets/issues/1'
        assert sql("SELECT actor_id||','||kind FROM task_events WHERE task_id='" + widget['task_id'] + "' ORDER BY id DESC LIMIT 1") == 'system-intake,link'
        shown = api('intake/' + intake['id'])[0]['intake']['items'][0]
        assert (shown['issue_state'], shown['issue_number'], shown['reason']) == ('created', 1, None)
        assert work(widget['id'])['skipped'] == 'not_due'

        # Lost response: GitHub stored the issue; the retry adopts it by marker.
        lost = file('lost-1', [{'repository': REPO, 'title': 'Lost response'}])['intake']['items'][0]
        mode['post'] = 'lost'
        assert work(lost['id'])['state'] == 'pending'
        assert item_row(lost['id'])['last_error'] == 'response_lost' and len(issues) == 2
        mode['post'] = 'ok'
        due(lost['id'])
        posted = len(posts)
        assert work(lost['id'])['state'] == 'created'
        assert len(posts) == posted and len(issues) == 2, 'adopted, not created again'
        assert task(lost['task_id'])['issue_url'] == 'https://github.com/acme/widgets/issues/2'

        # A creator-scoped list that never ends parks uncertain with the marker
        # already seen. It does not stay pending, and it does not create again.
        stuck = file('stuck-1', [{'repository': REPO, 'title': 'Lookup cannot finish'}])['intake']['items'][0]
        mode['post'] = 'lost'
        assert work(stuck['id'])['state'] == 'pending'
        seen = issues[-1]['html_url']
        mode['post'], mode['list'] = 'ok', 'endless'
        due(stuck['id'])
        posted = len(posts)
        assert work(stuck['id'])['state'] == 'uncertain' and len(posts) == posted
        row = item_row(stuck['id'])
        assert row['reason'] == 'marker_search_incomplete' and row['duplicate_issue_urls'] == [seen], row
        assert row['next_attempt_at'] is None
        assert work(stuck['id'])['skipped'] == 'not_due'
        mode['list'] = 'ok'
        api('intake/' + sql("SELECT request_id FROM intake_items WHERE id='" + stuck['id'] + "'") +
            '/items/' + stuck['id'] + '/reconcile', {})
        assert work(stuck['id'])['state'] == 'created' and len(posts) == posted
        assert task(stuck['task_id'])['issue_url'] == seen

        # A crashed worker leaves `creating`; after the lease the sweep re-claims
        # it and the marker scan adopts the issue the crashed create stored.
        crashed = file('crash-1', [{'repository': REPO, 'title': 'Crashed worker'}])['intake']['items'][0]
        stored = len(issues) + 1
        issues.append({'number': stored, 'html_url': f'https://github.com/acme/widgets/issues/{stored}',
                       'title': 'Crashed worker', 'body': '<!-- agentboard-intake:' + crashed['id'] + ' -->', 'labels': []})
        sql("UPDATE intake_items SET issue_state='creating', attempts=1, generation=1, claim_run_id=gen_random_uuid(), "
            "claimed_at=clock_timestamp()-interval '10 minutes' WHERE id='" + crashed['id'] + "'")
        assert 'enqueued' in rpc('{:ok, r} = Ash.run_action(Ash.ActionInput.for_action(Agentboard.Intake.Dispatcher, :dispatch_due, %{}, actor: %{role: :system, id: "system-intake"})); IO.inspect(r)')
        posted = len(posts)
        assert work(crashed['id'])['state'] == 'created' and len(posts) == posted
        assert item_row(crashed['id'])['issue_number'] == stored

        # Duplicate marker: two stored issues park the item as uncertain.
        dup = file('dup-1', [{'repository': REPO, 'title': 'Duplicated'}])['intake']['items'][0]
        mode['post'] = 'lost-twice'
        assert work(dup['id'])['state'] == 'pending'
        mode['post'] = 'ok'
        due(dup['id'])
        posted = len(posts)
        assert work(dup['id'])['state'] == 'uncertain' and len(posts) == posted
        row = item_row(dup['id'])
        assert row['reason'] == 'duplicate_marker' and len(row['duplicate_issue_urls']) == 2
        assert task(dup['task_id'])['issue_url'] is None
        assert work(dup['id'])['skipped'] == 'not_due'
        # The status contract surfaces uncertainty (CLI exit 5 below).
        state = api('intake/' + sql("SELECT request_id FROM intake_items WHERE id='" + dup['id'] + "'"))[0]
        assert state['intake']['items'][0]['issue_state'] == 'uncertain'
        # Reconcile after a human closed one copy: still ambiguous, still parked.
        dup_request = state['intake']['id']
        api('intake/' + dup_request + '/items/' + dup['id'] + '/reconcile', {})
        assert work(dup['id'])['state'] == 'uncertain'
        # After the extra copy is deleted upstream, reconcile adopts the survivor.
        survivor = row['duplicate_issue_urls'][0]
        issues[:] = [i for i in issues if not (i['html_url'] in row['duplicate_issue_urls'] and i['html_url'] != survivor)]
        api('intake/' + dup_request + '/items/' + dup['id'] + '/reconcile', {})
        posted = len(posts)
        assert work(dup['id'])['state'] == 'created' and len(posts) == posted
        assert task(dup['task_id'])['issue_url'] == survivor
        adopted = api('intake/' + dup_request)[0]['intake']['items'][0]
        assert adopted['issue_state'] == 'created' and adopted['issue_url'] == survivor
        assert adopted['duplicate_issue_urls'] == []

        # Definitive rejection parks immediately; reconcile retries after a scan.
        rejected = file('reject-1', [{'repository': REPO, 'title': 'Rejected once'}])['intake']
        mode['post'] = 'reject'
        assert work(rejected['items'][0]['id'])['state'] == 'uncertain'
        assert item_row(rejected['items'][0]['id'])['reason'] == 'rejected:422'
        mode['post'] = 'ok'
        listed = len(lists)
        api('intake/' + rejected['id'] + '/items/' + rejected['items'][0]['id'] + '/reconcile', {})
        assert work(rejected['items'][0]['id'])['state'] == 'created' and len(lists) == listed + 1

        # Rate limits stay pending with the provider's backoff.
        limited = file('rate-1', [{'repository': REPO, 'title': 'Rate limited'}])['intake']['items'][0]
        mode['post'] = 'rate'
        assert work(limited['id'])['state'] == 'pending'
        assert item_row(limited['id'])['last_error'] == 'rate_limited'
        assert sql("SELECT next_attempt_at >= clock_timestamp()+interval '50 seconds' FROM intake_items WHERE id='" + limited['id'] + "'") == 't'

        # Abandon: no further GitHub calls; the card stays.
        mode['post'] = 'reject'
        abandon = file('abandon-1', [{'repository': REPO, 'title': 'Abandon me'}])['intake']
        assert work(abandon['items'][0]['id'])['state'] == 'uncertain'
        api('intake/' + abandon['id'] + '/items/' + abandon['items'][0]['id'] + '/abandon', {})
        assert item_row(abandon['items'][0]['id'])['issue_state'] == 'abandoned'
        due(abandon['items'][0]['id'])
        posted = len(posts)
        assert work(abandon['items'][0]['id'])['skipped'] == 'not_due' and len(posts) == posted
        api('intake/' + abandon['id'] + '/items/' + abandon['items'][0]['id'] + '/abandon', {}, status=409)
        api('intake/' + abandon['id'] + '/items/' + abandon['items'][0]['id'] + '/retry', {}, status=422)
        assert task(abandon['items'][0]['task_id'])['status'] == 'open'
        mode['post'] = 'ok'

        # The token is used only for configured repositories.
        scoped = file('scope-2', [{'repository': 'acme/gadgets', 'title': 'Scope removed later'}])['intake']['items'][0]
        rpc('Application.put_env(:agentboard, :intake_repositories, ["acme/widgets"])')
        requests = len(posts) + len(lists)
        assert work(scoped['id'])['state'] == 'uncertain'
        assert item_row(scoped['id'])['reason'] == 'repository_out_of_scope' and len(posts) + len(lists) == requests
        rpc('Application.put_env(:agentboard, :intake_repositories, ["acme/widgets", "acme/gadgets"])')

        # Card linked elsewhere first: the issue is recorded, the link is kept.
        manual = file('manual-1', [{'repository': REPO, 'title': 'Already linked'}])['intake']['items'][0]
        api('agents/register', {'name': 'Intake human'}, captain=False)
        api('tasks/' + manual['task_id'] + '/link', {'issue_url': 'https://github.com/acme/widgets/issues/77'}, captain=False)
        assert work(manual['id'])['state'] == 'created'
        assert item_row(manual['id'])['reason'] == 'card_linked_elsewhere'
        assert task(manual['task_id'])['issue_url'] == 'https://github.com/acme/widgets/issues/77'

        # --- Cancel unstarted cards only. -----------------------------------
        pair = file('cancel-1', [{'repository': REPO, 'title': 'Cancel me'},
                                 {'repository': REPO, 'title': 'Started work'}])['intake']
        cancel_me, started = pair['items']
        api('agents/register', {'name': 'Seat'}, captain=False, agent='intake-seat')
        api('tasks/' + started['task_id'] + '/claim', {}, captain=False, agent='intake-seat')
        result = api('intake/' + pair['id'] + '/cancel', {})[0]
        assert result['cancelled'] == [cancel_me['id']]
        assert result['skipped'] == [{'id': started['id'], 'reason': 'card_started'}]
        assert task(cancel_me['task_id'])['status'] == 'cancelled' and task(started['task_id'])['status'] == 'in_progress'
        assert item_row(cancel_me['id'])['issue_state'] == 'cancelled'
        posted = len(posts)
        assert work(cancel_me['id'])['skipped'] == 'not_due' and len(posts) == posted
        again = api('intake/' + pair['id'] + '/cancel', {'items': [cancel_me['id']]})[0]
        assert again['cancelled'] == [] and again['skipped'] == [{'id': cancel_me['id'], 'reason': 'already_cancelled'}]
        api('intake/' + pair['id'] + '/cancel', {'items': ['00000000-0000-4000-8000-000000000000']}, status=404)
        api('intake/' + pair['id'] + '/cancel', {'items': 'all'}, status=422)

        # --- CLI over the same contract (captain capability file). ----------
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

            cli = json.loads(ab('--json', 'intake', 'file', '--request-key', 'cli-1', '--repo', 'Acme/Widgets',
                                '--title', 'From the CLI', '--label', 'cli', '--priority', '2'))
            assert cli['replayed'] is False
            again = json.loads(ab('--json', 'intake', 'file', '--request-key', 'cli-1', '--repo', 'acme/widgets',
                                  '--title', ' From the CLI ', '--label', 'cli', '--priority', '2'))
            assert again['replayed'] is True and again['intake']['id'] == cli['intake']['id']
            ab('intake', 'file', '--request-key', 'cli-1', '--repo', 'acme/widgets', '--title', 'Changed', code=4)
            cli_item = cli['intake']['items'][0]
            assert work(cli_item['id'])['state'] == 'created'
            assert 'issue=created' in ab('intake', 'status', cli['intake']['id'])
            ab('intake', 'status', dup_request)
            ab('intake', 'status', rejected['id'])
            mode['post'] = 'reject'
            parked = json.loads(ab('--json', 'intake', 'file', '--request-key', 'cli-2', '--repo', REPO, '--title', 'Parks', '--no-issue'))
            assert parked['intake']['items'][0]['issue_state'] == 'none'
            bad = json.loads(ab('--json', 'intake', 'file', '--request-key', 'cli-3', '--repo', REPO, '--title', 'Rejected'))
            assert work(bad['intake']['items'][0]['id'])['state'] == 'uncertain'
            ab('intake', 'status', bad['intake']['id'], code=5)
            ab('--json', 'intake', 'resolve', bad['intake']['id'], bad['intake']['items'][0]['id'], '--action', 'abandon')
            ab('intake', 'status', bad['intake']['id'])
            cancelled = json.loads(ab('--json', 'intake', 'cancel', parked['intake']['id']))
            assert cancelled['cancelled'] == [parked['intake']['items'][0]['id']]
            mode['post'] = 'ok'

        assert user_lookups == ['/user'], user_lookups

assert len(issues) == len({i['body'] for i in issues}), 'no item has two issues once duplicates are resolved'

# --- Disabling intake again makes every route unavailable. ----------------
rpc('Application.put_env(:agentboard, :intake_enabled, false)')
api('intake/' + intake['id'], status=404)
assert work(widget['id'])['skipped'] == 'intake_disabled'
rpc('Application.put_env(:agentboard, :intake_enabled, true)')

# --- Per-filer intake write limit (last: it spends this minute's budget). --
rpc('Application.put_env(:agentboard, :rate_limits, Keyword.put(Application.fetch_env!(:agentboard, :rate_limits), :intake, 0))')
body, headers = api('intake', {'request_key': 'limited', 'items': [{'repository': REPO, 'title': 'x'}]}, status=429)
assert body['error']['code'] == 'rate_limited' and int(headers['retry-after']) >= 1
assert api('intake/' + intake['id'])[0]['intake']['id'] == intake['id'], 'reads are not intake-limited'
print('intake contract verified')
