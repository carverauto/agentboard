"""Packaged HTTPS/Ash/PG -> API/CLI/dashboard/inbox/worker-frame conflict contract.

Owns base-move and once-per-head conflict delivery, distinct from CI normalization,
policy recovery and merge disposition. Provider data and credentials are invented.
"""
import concurrent.futures
import http.server
import json
import os
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
HEAD, NEXT, BASE, MOVED = (c * 40 for c in 'abcd')
prs = {101: dict(head=HEAD, base=BASE, mergeable=False, mergeable_state='dirty')}
branch_sha = BASE
requests = []
reads = {}
compute = False
slow = False
slow_pull = False
entered, release = threading.Event(), threading.Event()
branch_status = 200


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=45)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def ab(*args, owner='conflict-owner'):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'DATABASE_'))}
    env.update(AGENT_ID=owner, AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')
    p = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                       capture_output=True, text=True, timeout=25)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return json.loads(p.stdout)


def api(path, body=None, token=None, captain=False):
    headers = {'Content-Type': 'application/json', 'x-agentboard-worker-protocol': '1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = 'fixture-captain-capability-32-characters'
    request = urllib.request.Request(URL + '/api/v1' + path, headers=headers,
                                    data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def _strip_scripts(html):
    # Remove script elements with a real parser so variants like
    # `<SCRIPT>` or `</script >` cannot slip through a filtering regexp.
    class Stripper(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=False)
            self.parts = []
            self.depth = 0
        def handle_starttag(self, tag, attrs):
            if tag.lower() == 'script':
                self.depth += 1
            elif self.depth == 0:
                self.parts.append(self.get_starttag_text())
        def handle_startendtag(self, tag, attrs):
            if tag.lower() != 'script' and self.depth == 0:
                self.parts.append(self.get_starttag_text())
        def handle_endtag(self, tag):
            if tag.lower() == 'script':
                self.depth = max(0, self.depth - 1)
            elif self.depth == 0:
                self.parts.append('</' + tag + '>')
        def handle_data(self, data):
            if self.depth == 0:
                self.parts.append(data)
        def handle_comment(self, data):
            if self.depth == 0:
                self.parts.append('<!--' + data + '-->')
        def handle_decl(self, decl):
            if self.depth == 0:
                self.parts.append('<!' + decl + '>')
    stripper = Stripper()
    stripper.feed(html)
    return ''.join(stripper.parts)


def export_page(path, filename):
    # Capture generated public SSR and its release-fingerprinted CSS, never source.
    html = urllib.request.urlopen(URL + path, timeout=10).read().decode()
    stylesheet = re.search(r'<link rel="stylesheet"[^>]*href="([^"]+)"', html).group(1)
    css = urllib.request.urlopen(URL + stylesheet, timeout=10).read().decode()
    html = re.sub(r'<link rel="stylesheet"[^>]+>', lambda _: '<style>' + css + '</style>', html)
    html = _strip_scripts(html)
    Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'], filename).write_text(html)


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        assert self.headers.get('Authorization') == 'Bearer invented-conflict-token'
        path = urllib.parse.urlparse(self.path).path
        requests.append(path)
        status, headers = 200, {}
        if path == '/repos/fixture/repo/branches/main':
            sampled = branch_sha
            if slow:
                entered.set()
                assert release.wait(15), 'branch fixture never released'
            status = branch_status
            body = dict(name='main', commit=dict(sha=sampled))
            if status == 429:
                headers['Retry-After'] = '180'
        elif '/pulls/' in path:
            number = int(path.rsplit('/', 1)[1])
            p = dict(prs[number])
            reads[number] = reads.get(number, 0) + 1
            mergeable = None if compute and reads[number] % 2 else p['mergeable']
            body = dict(number=number, state=p.get('state', 'open'), merged=p.get('merged', False),
                        draft=False, head=dict(sha=p['head']), base=dict(sha=p['base'], ref='main'),
                        mergeable=mergeable, mergeable_state=p['mergeable_state'])
        elif path.endswith('/check-suites'):
            body = dict(total_count=0, check_suites=[])
        elif path.endswith('/statuses'):
            body = []
        else:
            raise AssertionError(path)
        if slow_pull and '/pulls/' in path and reads[number] % 2 == 0:
            entered.set()
            assert release.wait(15), 'PR fixture never released'
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(encoded)


def reset_budget():
    sql("UPDATE delivery_provider_budgets SET remaining=60,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")


def poll(pr):
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + pr + "'")
    return rpc('IO.puts(inspect(Agentboard.Delivery.Scheduling.poll(' + json.dumps(pr) + ')))')


def detail(pr):
    return ab('pr', 'show', pr)


def check_branch(watch):
    sql("UPDATE delivery_base_watches SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + watch + "'")
    return rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.check(' + json.dumps(watch) + ')))')


def invalidate(watch, revision, cursor=''):
    return rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.invalidate(%{id: ' +
               json.dumps(watch) + ', revision: ' + str(revision) + ', cursor: ' + json.dumps(cursor) + '})))')


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); Application.put_env(:agentboard, :cooperation_enabled, false)')
for owner in ('conflict-owner', 'conflict-peer'):
    ab('agent', 'register', owner=owner)
ab('task', 'create', '--id', 'conflict-source', '--title', 'Already delivered original', '--repo', 'fixture/repo', '--pr', 'https://github.com/fixture/repo/pull/101')
ab('task', 'claim', 'conflict-source')
ab('task', 'update', 'conflict-source', '--status', 'done', '--body', 'Original delivered')
ab('task', 'create', '--id', 'next-assignment', '--title', 'Unrelated current work')
ab('task', 'claim', 'next-assignment')
ab('agent', 'heartbeat', '--status', 'busy', '--task', 'next-assignment')
source_query = "SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(t ORDER BY id) FROM tasks t WHERE id IN ('conflict-source','next-assignment')),'events',(SELECT jsonb_agg(t ORDER BY id) FROM task_events t WHERE task_id IN ('conflict-source','next-assignment')),'links',(SELECT jsonb_agg(t ORDER BY id) FROM delivery_task_links t WHERE task_id='conflict-source'))"
source_before = sql(source_query)
pr = sql("SELECT id FROM delivery_pull_requests WHERE number='101'")
with tls_provider(Provider) as (api_url, ca, server):
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(api_url) + ', token: "invented-conflict-token", ca_file: ' + json.dumps(ca) + '])')
    # Computing -> definitive within one unchanged revision must not discard CI.
    compute = True
    reset_budget()
    assert 'observed' in poll(pr)
    compute = False
    observed = detail(pr)
    assert observed['mergeable'] is False and observed['mergeable_state'] == 'dirty'
    assert observed['merge_state'] == 'conflicting' and observed['ci_state'] == 'unknown', observed
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '0'
    assert sql('SELECT count(*) FROM messages') == '0'
    watch = sql('SELECT id FROM delivery_base_watches')
    assert watch
    html = urllib.request.urlopen(URL + '/prs').read().decode()
    assert 'Merge conflicting' in html
    assert ab('pr', 'list')['prs'][0]['merge_state'] == 'conflicting'
    # Enablement plus concurrent retries produce exactly one owned repair and inbox
    # notice even though the source is Done and its submitter moved to another task.
    rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
    reset_budget()
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        list(pool.map(lambda _: poll(pr), range(2)))
    follow = detail(pr)['rebase_follow_up']
    repair = follow['repair_task_id']
    assert follow['responsible_id'] == 'conflict-owner'
    assert ab('task', 'show', repair)['task']['status'] == 'assigned'
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '1'
    assert sql("SELECT count(*) FROM messages WHERE recipient_id='conflict-owner' AND task_id='" + repair + "'") == '1'
    assert sql("SELECT count(*) FROM cooperation_events WHERE kind='pr_conflict'") == '1'
    assert sql('SELECT count(*) FROM delivery_obligations') == '0', 'Conflict was treated as CI failure'
    reset_budget()
    poll(pr)
    assert sql('SELECT count(*) FROM messages') == '1'
    # Actual provision/binding/reservation returns the conflict in a normal frozen
    # worker frame, with server-produced receipt values, rather than a fake wake.
    rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
    host = api('/workers/provision', dict(worker_id='conflict-owner', host_id='fixture-host', repos=['fixture/repo'], model='fixture-model', harness='codex', idempotency_key='conflict-provision'), captain=True)['host_token']
    caps = {name: dict(supported=name in ('receipt', 'recovery'), reason='Manual fixture') for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
    api('/workers/conflict-owner/bind', dict(idempotency_key='conflict-bind', expected_epoch=0, host_id='fixture-host', session_id='fixture-session', pane_id='fixture-pane', adapter='manual', adapter_version='1', capabilities=caps), token=host)
    batch = api('/workers/conflict-owner/reserve', dict(binding_epoch=1, idempotency_key='conflict-reserve'), token=host)['batch']
    assert repair in batch['payload'] and 'pr_conflict' in batch['payload'], batch
    assert sql('SELECT count(*) FROM cooperation_deliveries') == '1'
    export_page('/prs', 'pr-conflicts.html')
    # Unknown, behind, blocked and unstable never manufacture a new dirty repair
    # or falsely resolve retained conflict proof. Null requests a 60-second retry.
    for mergeable, state in [(None, 'unknown'), (False, 'behind'), (False, 'blocked'), (False, 'unstable')]:
        prs[101].update(mergeable=mergeable, mergeable_state=state)
        reset_budget()
        poll(pr)
        assert detail(pr)['mergeable_state'] == state
        assert sql('SELECT resolved_at IS NULL FROM delivery_rebase_follow_ups') == 't'
        assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '1'
        if mergeable is None:
            assert sql("SELECT next_poll_at-observed_at=interval '60 seconds' FROM delivery_poll_states WHERE id='" + pr + "'") == 't'
    # Changed base becomes visibly stale immediately, before its durable page.
    prs[101].update(mergeable=False, mergeable_state='dirty')
    reset_budget()
    poll(pr)
    rpc('{:ok, _} = Agentboard.Delivery.BaseMonitor.tick()')
    assert requests.count('/repos/fixture/repo/branches/main') == 0, 'Scheduler performed provider I/O inside its transaction'
    branch_sha = MOVED
    reset_budget()
    assert 'changed: true' in check_branch(watch)
    assert detail(pr)['merge_state'] == 'stale'
    generation = sql("SELECT generation FROM delivery_poll_states WHERE id='" + pr + "'")
    assert 'invalidated' in invalidate(watch, 1)
    assert sql("SELECT expected_base_sha FROM delivery_poll_states WHERE id='" + pr + "'") == MOVED
    assert int(sql("SELECT generation FROM delivery_poll_states WHERE id='" + pr + "'")) > int(generation)
    assert 'superseded' in poll(pr), 'Old-base result was committed'
    # A valid new-base observation clears stale evidence. Replaying the same page
    # must retain a newly reserved attempt rather than repeatedly canceling work.
    prs[101]['base'] = MOVED
    sql("UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL WHERE id='" + pr + "'")
    reset_budget()
    poll(pr)
    assert detail(pr)['merge_state'] == 'conflicting'
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + pr + "'")
    rpc('{:ok, [_]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(pr) + ')')
    reserved = sql("SELECT generation||','||attempt_id FROM delivery_poll_states WHERE id='" + pr + "'")
    invalidate(watch, 1)
    assert sql("SELECT generation||','||attempt_id FROM delivery_poll_states WHERE id='" + pr + "'") == reserved
    sql("UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL WHERE id='" + pr + "'")
    # Shared HTTP admission also fences branches and honors Retry-After across jobs.
    reset_budget()
    branch_status = 429
    assert 'rate_limited' in check_branch(watch)
    count = len(requests)
    check_branch(watch)
    assert len(requests) == count
    assert sql("SELECT blocked_until>clock_timestamp()+interval '170 seconds' FROM delivery_provider_budgets WHERE id='github'") == 't'
    branch_status = 200
    reset_budget()
    sql("UPDATE delivery_provider_budgets SET remaining=0 WHERE id='github'")
    check_branch(watch)
    assert len(requests) == count
    # A slow branch response may not overwrite a newer reservation. Board writes
    # remain available during provider I/O, proving there is no singleton gate.
    reset_budget()
    slow = True
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        future = pool.submit(check_branch, watch)
        assert entered.wait(5)
        ab('task', 'create', '--id', 'independent-conflict-write', '--title', 'Available during branch HTTP')
        sql("UPDATE delivery_base_watches SET generation=generation+1,attempt_id=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '120 seconds' WHERE id='" + watch + "'")
        release.set()
        assert 'superseded' in future.result(timeout=25)
    slow = False
    sql("UPDATE delivery_base_watches SET attempt_id=NULL,lease_expires_at=NULL WHERE id='" + watch + "'")
    # Unknown/failed samples do not resolve; definitive mergeable evidence suppresses
    # pending wake delivery, while the repair task still needs explicit completion.
    prs[101].update(mergeable=True, mergeable_state='clean')
    reset_budget()
    poll(pr)
    assert detail(pr)['merge_state'] == 'mergeable'
    assert sql('SELECT resolved_at IS NOT NULL FROM delivery_rebase_follow_ups') == 't'
    assert sql("SELECT state FROM cooperation_deliveries") == 'suppressed'
    assert ab('task', 'show', repair)['task']['status'] == 'assigned'
    # Same head never duplicates after resolution; a new conflicting head does.
    prs[101].update(mergeable=False, mergeable_state='dirty')
    reset_budget()
    poll(pr)
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '1'
    prs[101]['head'] = NEXT
    # An inbox write failure must roll back the complete task/evidence/event unit.
    sql("CREATE FUNCTION fixture_reject_conflict_message() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture message unavailable'; END $$; CREATE TRIGGER fixture_message_failure BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION fixture_reject_conflict_message()")
    reset_budget()
    assert '{:error,' in poll(pr)
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '1'
    assert sql("SELECT count(*) FROM tasks WHERE 'rebase-repair'=ANY(labels)") == '1'
    assert sql("SELECT count(*) FROM cooperation_events WHERE kind='pr_conflict'") == '1'
    sql('DROP TRIGGER fixture_message_failure ON messages; DROP FUNCTION fixture_reject_conflict_message()')
    sql("UPDATE delivery_poll_states SET attempt_id=NULL,lease_expires_at=NULL WHERE id='" + pr + "'")
    reset_budget()
    poll(pr)
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '2'
    assert sql("SELECT count(*) FROM messages WHERE recipient_id='conflict-owner'") == '2'
    assert sql(source_query) == source_before, 'Original Done/current work/attribution changed'
    # An old in-flight PR response is fenced after a real base check/page;
    # the branch request and unrelated board write can proceed while HTTP waits.
    entered.clear()
    release.clear()
    reads[101] = 0
    slow_pull = True
    reset_budget()
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        future = pool.submit(poll, pr)
        assert entered.wait(5)
        branch_sha = 'e' * 40
        assert 'changed: true' in check_branch(watch)
        invalidate(watch, 2)
        release.set()
        assert 'superseded' in future.result(timeout=25)
    slow_pull = False
    prs[101]['base'] = branch_sha
    reset_budget()
    poll(pr)
    # Terminal metadata does not create conflicts, and a branch used by no open PR
    # stops consuming GitHub admission. Historical cards remain available explicitly.
    # An advanced watch must not fence terminal evidence as superseded.
    prs[101].update(state='closed', merged=True)
    branch_sha = '9' * 40
    reset_budget()
    assert 'changed: true' in check_branch(watch)
    reset_budget()
    assert 'observed' in poll(pr)
    assert sql("SELECT enabled FROM delivery_poll_states WHERE id='" + pr + "'") == 'f'
    assert detail(pr)['ci_state'] == 'unknown'
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '2'
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups WHERE resolved_at IS NULL') == '1'
    before = len(requests)
    check_branch(watch)
    assert len(requests) == before
    assert ab('pr', 'list')['prs'] == []
    assert ab('pr', 'list', '--show-terminal')['prs'][0]['merge_state'] == 'not_applicable'
    assert detail(pr)['merge_state'] == 'not_applicable'
    assert detail(pr)['fresh'] is True
    # Closed-unmerged metadata with an older base than the advanced watch also
    # commits as complete terminal evidence without CI certification or repairs.
    import hashlib
    closed_url = 'https://github.com/fixture/repo/pull/102'
    closed_pr = hashlib.sha256(closed_url.encode()).hexdigest()
    sql("INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES ('" + closed_pr + "','fixture','repo','102','" + closed_url + "',clock_timestamp()); INSERT INTO delivery_poll_states(id,registered_at,next_poll_at,enabled,lifecycle,head_sha,base_sha,base_ref,expected_base_sha) VALUES ('" + closed_pr + "',clock_timestamp(),clock_timestamp()-interval '1 second',true,'open','" + HEAD + "','" + HEAD + "','main','" + HEAD + "')")
    prs[102] = dict(head=HEAD, base=HEAD, mergeable=False, mergeable_state='dirty', state='closed', merged=False)
    reset_budget()
    assert 'observed' in poll(closed_pr)
    assert sql("SELECT enabled FROM delivery_poll_states WHERE id='" + closed_pr + "'") == 'f'
    assert detail(closed_pr)['ci_state'] == 'unknown'
    assert detail(closed_pr)['merge_state'] == 'not_applicable'
    assert detail(closed_pr)['fresh'] is True
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups') == '2'
    # More than one page of canonical open inventory must be invalidated and
    # queued even without current task links. Invented persisted baseline rows
    # exercise paging; HTTP collection normalization belongs to its sibling.
    import hashlib
    cohort = []
    for number in range(201, 302):
        url = f'https://github.com/fixture/repo/pull/{number}'
        pid = hashlib.sha256(url.encode()).hexdigest()
        cohort.append(pid)
        sql("INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) VALUES ('" + pid + "','fixture','repo','" + str(number) + "','" + url + "',clock_timestamp()); INSERT INTO delivery_poll_states(id,registered_at,next_poll_at,enabled,lifecycle,head_sha,base_sha,base_ref,expected_base_sha) VALUES ('" + pid + "',clock_timestamp(),clock_timestamp()+interval '10 minutes',true,'open','" + HEAD + "','" + branch_sha + "','main','" + branch_sha + "')")
    branch_sha = 'f' * 40
    reset_budget()
    check_branch(watch)
    invalidate(watch, 4)
    assert sql("SELECT count(*) FROM delivery_poll_states WHERE enabled AND expected_base_sha='" + branch_sha + "'") == '100'
    continuation = json.loads(sql("SELECT args FROM oban_jobs WHERE worker='Agentboard.Delivery.BaseInvalidationWorker' AND args->>'revision'='4' AND args->>'cursor'<>'' ORDER BY id DESC LIMIT 1"))
    # Simulated discarded continuation is recovered after actual Oban restart;
    # retained base state, not process memory, determines the catch-up revision.
    sql("UPDATE oban_jobs SET state='discarded',discarded_at=clock_timestamp() WHERE worker='Agentboard.Delivery.BaseInvalidationWorker' AND args->>'revision'='4'")
    rpc('Application.put_env(:agentboard, :pr_observation_enabled, false); :ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban)')
    # Queue startup is asynchronous: first observe real paused producers, then
    # stop them and wait for both process teardown and in-flight jobs to settle.
    deadline = time.monotonic() + 15
    while True:
        output = rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling); paused = Enum.all?([:delivery_scheduler, :delivery_polling], fn q -> match?(%{paused: true}, Oban.check_queue(queue: q)) end); IO.puts("PAUSED=" <> to_string(paused))')
        if 'PAUSED=true' in output:
            break
        assert time.monotonic() < deadline, 'Restarted producers did not pause'
        time.sleep(.05)
    rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling)')
    while True:
        output = rpc('IO.puts("QUIET=" <> to_string(Enum.all?([:delivery_scheduler, :delivery_polling], fn q -> is_nil(Oban.check_queue(queue: q)) end)))')
        if 'QUIET=true' in output and sql("SELECT count(*) FROM oban_jobs WHERE queue IN ('delivery_scheduler','delivery_polling') AND state='executing'") == '0':
            break
        assert time.monotonic() < deadline, 'Restarted pollers did not quiesce'
        time.sleep(.05)
    rpc('Application.put_env(:agentboard, :pr_observation_enabled, true)')
    assert sql('SELECT invalidated_revision<revision FROM delivery_base_watches') == 't'
    rpc('{:ok, _} = Agentboard.Delivery.BaseMonitor.tick()')
    assert sql("SELECT count(*)>0 FROM oban_jobs WHERE worker='Agentboard.Delivery.BaseInvalidationWorker' AND state IN ('available','scheduled','retryable') AND args->>'revision'='4' AND args->>'cursor'=''") == 't'
    invalidate(watch, 4)
    invalidate(watch, 4, continuation['cursor'])
    assert sql("SELECT count(*) FROM delivery_poll_states WHERE enabled AND expected_base_sha='" + branch_sha + "'") == '101'
    assert sql("SELECT invalidated_revision=revision FROM delivery_base_watches") == 't'
    assert sql("SELECT count(DISTINCT args->>'id') FROM oban_jobs WHERE worker='Agentboard.Delivery.PollWorker' AND state IN ('available','scheduled','retryable') AND args->>'id'<>'" + pr + "'") == '101'
    # A newer base supersedes any old continuation without restoring old SHA.
    branch_sha = '0' * 40
    reset_budget()
    check_branch(watch)
    before = sql('SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_poll_states s')
    assert 'superseded' in invalidate(watch, 4, continuation['cursor'])
    assert sql('SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_poll_states s') == before
    # Canonical inventory without an immutable task link is explicitly unknown
    # ownership. GitHub's human author must not be guessed as a board seat.
    invalidate(watch, 5)
    next_page = json.loads(sql("SELECT args FROM oban_jobs WHERE worker='Agentboard.Delivery.BaseInvalidationWorker' AND args->>'revision'='5' AND args->>'cursor'<>'' ORDER BY id DESC LIMIT 1"))
    invalidate(watch, 5, next_page['cursor'])
    unknown_pr = hashlib.sha256(b'https://github.com/fixture/repo/pull/202').hexdigest()
    prs[202] = dict(head='1' * 40, base=branch_sha, mergeable=False, mergeable_state='dirty')
    reset_budget()
    poll(unknown_pr)
    unknown_follow = detail(unknown_pr)['rebase_follow_up']
    assert unknown_follow['responsible_id'] is None
    assert ab('task', 'show', unknown_follow['repair_task_id'])['task']['status'] == 'open'
    assert sql("SELECT count(*) FROM messages WHERE task_id='" + unknown_follow['repair_task_id'] + "'") == '0'
    assert sql("SELECT count(*) FROM cooperation_events WHERE kind='pr_conflict' AND task_id='" + unknown_follow['repair_task_id'] + "'") == '1'
    export_page('/prs?show_terminal=true', 'pr-conflicts-inventory.html')
print('Conflict observations, independent CI, base revision fences, owner inbox/worker frame, once per head, rollback and terminal pruning passed.')
