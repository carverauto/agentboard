"""Durable exact branch/card attribution at the public API boundary."""
import concurrent.futures
import json
import http.server
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
from provider_fixture import tls_provider

env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
env.update(AGENT_ID='codex-binding-alpha', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args, actor='codex-binding-alpha', code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args],
        env=dict(env, AGENT_ID=actor), text=True, capture_output=True, timeout=15)
    assert result.returncode == code, (args, result.stdout, result.stderr)
    return json.loads(result.stderr)['error'] if code else json.loads(result.stdout)


def bind(task, branch='feat/bound', actor='codex-binding-alpha', **extra):
    payload = dict(task=task, repo='fixture/project', head_repo='fixture/project', branch=branch)
    payload.update(extra)
    request = urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/publications/bind',
        data=json.dumps(payload).encode(), headers={'Content-Type':'application/json',
        'X-Agentboard-Agent':actor,'X-Agentboard-Model':'fixture-model','X-Agentboard-Harness':'codex'})
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if response.headers.get('Content-Type','').startswith('application/json') else None


for actor in ('codex-binding-alpha', 'codex-binding-beta'):
    ab('agent','register','--name','Invented binding seat',actor=actor)
for task in ('binding-one','binding-two'):
    ab('task','create','--id',task,'--title','Invented binding card','--repo','fixture/project')
    ab('task','claim',task)

before = ab('task','show','binding-one')
first = ab('publication','bind','binding-one','--repo','fixture/project','--branch','feat/bound')
row = first['binding']
assert row['task_id'] == 'binding-one' and row['branch'] == 'feat/bound' and row['generation'] == 1
assert row['bound_by_id'] == 'codex-binding-alpha' and row['repo'] == row['head_repo'] == 'fixture/project'
assert first['idempotent'] is False
assert bind('binding-one') == (200, dict(binding=row, idempotent=True))
assert ab('task','show','binding-one') == before, 'Binding changed source ownership, lease or timeline'

# Exact branch identity cannot be silently rebound to another card, even when
# the caller owns both. Concurrent registrations elect only one durable owner.
assert bind('binding-two')[0] == 409
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda task: bind(task, 'feat/contended'), ('binding-one','binding-two')))
assert sorted(code for code, _ in results) == [200,409], results
assert bind('binding-one', actor='codex-binding-beta')[0] == 409
assert bind('binding-one', repo='fixture/other')[0] == 409
for branch in ('','refs/heads/feature','feat/../bad','feat//bad','feat/@{bad','feat/secret\nvalue'):
    assert bind('binding-one', branch)[0] == 422, branch

ab('task','release','binding-one')
assert bind('binding-one')[0] == 409, 'Retained attribution authorized a released claim'
ab('task','claim','binding-one',actor='codex-binding-beta')
assert bind('binding-one',actor='codex-binding-beta')[0] == 200, 'New live owner could not reuse same-card attribution'
assert bind('binding-one')[0] == 409, 'Previous owner retained publication permission'

ab('task','create','--id','binding-expired','--title','Expiring publication','--repo','fixture/project')
ab('--ttl','200ms','task','claim','binding-expired')
time.sleep(0.3)
assert bind('binding-expired','feat/expired')[0] == 409

with tempfile.NamedTemporaryFile(mode='w') as findings:
    findings.write('Invented decision fixture'); findings.flush()
    ab('decision','request','--task','binding-two','--kind','other','--gate','binding-fixture',
       '--question','Invented held publication question','--findings-file',findings.name)
assert bind('binding-two','feat/held')[0] == 409

def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1',
                                    '-c',statement],text=True).strip()

assert sql('SELECT count(*) FROM delivery_publication_bindings') == '2'
assert sql('SELECT count(*) FROM delivery_publication_bindings_versions') == '2'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PublicationBinding'") == '2'
assert json.loads(sql('SELECT provenance FROM delivery_publication_bindings_versions LIMIT 1')) == \
    dict(agent='codex-binding-alpha',model='fixture-model',harness='codex',operation_version=1)

# Attribution/history must be part of the same commit. An audit failure cannot
# leave an unreviewable binding that later authorizes another publication.
sql("CREATE FUNCTION reject_binding_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Delivery.PublicationBinding' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Invented audit refusal'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER fixture_binding_audit_guard BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_binding_audit()')
assert bind('binding-one','feat/audit-failure',actor='codex-binding-beta')[0] == 409
assert sql('SELECT count(*) FROM delivery_publication_bindings') == '2'
assert sql('SELECT count(*) FROM delivery_publication_bindings_versions') == '2'

print('Durable same-card branch attribution, live-owner fencing, idempotency and concurrent uniqueness passed')


# A native publisher may stop after GitHub opens the PR but before returning
# its URL. Exercise the existing durable discovery entrypoint against a real
# TLS provider and the public card read, not a test-created inventory receipt.
sql('DROP TRIGGER fixture_binding_audit_guard ON board_action_events; DROP FUNCTION reject_binding_audit()')


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout



def invented_pr(number, branch, state='open'):
    return dict(number=number, state=state,
                html_url=f'https://github.com/fixture/project/pull/{number}',
                user=dict(login='shared-fixture-login'),
                head=dict(ref=branch, sha='a'*40, repo=dict(full_name='fixture/project')),
                base=dict(ref='main', sha='b'*40, repo=dict(full_name='fixture/project')))


recovery_prs = {801: invented_pr(801, 'feat/bound')}


class RecoveryProvider(http.server.BaseHTTPRequestHandler):
    calls = []
    limit_once = False

    def log_message(self, *_):
        pass

    def do_GET(self):
        assert self.headers.get('Authorization') == 'Bearer fixture-recovery-provider'
        path = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(path.query)
        self.calls.append(self.path)
        if query.get('head') == ['fixture:feat/rate'] and type(self).limit_once:
            type(self).limit_once = False
            self.send_response(429)
            self.send_header('Retry-After', '61')
            self.end_headers()
            return
        if path.path == '/repos/fixture/project/pulls':
            head = query.get('head', [''])[0]
            page = int(query.get('page', ['1'])[0])
            if head == 'fixture:feat/paged' and page == 1:
                # A full page is not a completed uniqueness search.
                body = [invented_pr(1000+n, 'feat/paged', state='closed') for n in range(100)]
            elif head == 'fixture:feat/paged' and page == 2:
                body = [recovery_prs[806]]
            elif page > 1:
                body = []
            else:
                body = [pr for pr in recovery_prs.values() if not head or
                        head == 'fixture:'+pr['head']['ref']]
        elif path.path.startswith('/repos/fixture/project/pulls/'):
            body = recovery_prs.get(int(path.path.rsplit('/',1)[1]))
            if body is None:
                self.send_response(404); self.end_headers(); return
        else:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)


def wait_for(query, expected='t', seconds=25):
    deadline = time.monotonic()+seconds
    while time.monotonic() < deadline:
        actual = sql(query)
        if actual == expected:
            return
        time.sleep(.1)
    raise AssertionError((query, expected, actual,
        sql("SELECT json_agg(json_build_object('id',id,'state',state,'args',args,'attempted_at',attempted_at,'scheduled_at',scheduled_at,'errors',errors)) FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state<>'completed'"),
        rpc('IO.inspect(Oban.check_queue(queue: :delivery_discovery))')))


def discovery_sweep():
    rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
    wait_for("SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state IN ('available','executing','scheduled','retryable')", '0')


with tls_provider(RecoveryProvider) as (url, ca, _):
    rpc('Application.put_env(:agentboard, :github, [api_url: '+json.dumps(url)+
        ', token: "fixture-recovery-provider", ca_file: '+json.dumps(ca)+']); '+
        'Application.put_env(:agentboard, :pr_observation_enabled, true); '+
        'Application.put_env(:agentboard, :pr_discovery_enabled, true); '+
        'Application.put_env(:agentboard, :publication_recovery_enabled, true); '+
        ':ok = Oban.resume_queue(queue: :delivery_discovery)')
    before_recovery = ab('task','show','binding-one')['task']
    rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
    deadline = time.monotonic()+15
    while time.monotonic() < deadline:
        recovered = ab('task','show','binding-one')['task']
        if recovered['pr_url']:
            break
        time.sleep(.15)
    assert recovered['pr_url'] == 'https://github.com/fixture/project/pull/801',         ('Registered-branch crash recovery left the public card unlinked', recovered,
         RecoveryProvider.calls)
    for key in ('assignee_id','claimed_at','claim_expires_at','status'):
        assert recovered[key] == before_recovery[key], 'Recovery changed source claim'
    assert sql("SELECT count(*) FROM delivery_task_links WHERE task_id='binding-one' AND attribution='unknown' AND submitted_by_id IS NULL AND source_event_id IS NULL") == '1'
    assert sql("SELECT bound_by_id FROM delivery_publication_bindings WHERE branch='feat/bound'") == 'codex-binding-alpha'
    assert sql('SELECT count(*) FROM delivery_publication_grants') == '0', 'Discovery invented a write grant'
    assert sql("SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Delivery.PollWorker' AND args->>'id'=(SELECT id FROM delivery_pull_requests WHERE number='801')") == '1', 'Recovery did not enqueue ordinary observation'


    # Extend the primary API fixture for ambiguity and existing metadata, using
    # real binding/link entrypoints. Never manufacture an admission or author.
    cases = {'ambiguous': [802,803], 'different': [804], 'multiple': [805],
             'paged': [806]}
    originals = {}
    for name, numbers in cases.items():
        task = 'recovery-'+name
        ab('task','create','--id',task,'--title','Invented recovery case','--repo','fixture/project')
        ab('task','claim',task)
        ab('publication','bind',task,'--repo','fixture/project','--branch','feat/'+name)
        if name == 'different':
            ab('task','link',task,'--pr','https://github.com/fixture/project/pull/999')
        originals[name] = ab('task','show',task)['task']
        for number in numbers:
            recovery_prs[number] = invented_pr(number, 'feat/'+name)
    ab('task','create','--id','already-linked','--title','Explicit existing card','--repo','fixture/project')
    ab('task','link','already-linked','--pr','https://github.com/fixture/project/pull/805')
    # GitHub's shared login cannot supply a missing branch/card mapping.
    recovery_prs[808] = invented_pr(808, 'feat/unregistered')
    discovery_sweep()
    for name, reason in [('ambiguous','multiple_open_prs'), ('different','existing_different_url'),
                         ('multiple','multiple_cards')]:
        current = ab('task','show','recovery-'+name)['task']
        assert current == originals[name], ('Refused recovery changed card', name)
        assert sql("SELECT count(*) FROM decision_requests WHERE task_id='recovery-"+name+
                   "' AND question LIKE '%"+reason+"%'") == '1'
    waiting = ab('decision','waiting','--task','recovery-ambiguous')
    assert waiting['total'] == 1 and waiting['decisions'][0]['requester_id'] == 'ci-accountability'
    assert 'unknown' in waiting['decisions'][0]['findings'], 'Captain lane guessed a PR author'
    paged = ab('task','show','recovery-paged')['task']
    assert paged['pr_url'] == 'https://github.com/fixture/project/pull/806'
    assert any(urllib.parse.parse_qs(urllib.parse.urlparse(call).query).get('page') == ['2']
               for call in RecoveryProvider.calls
               if 'feat%2Fpaged' in call), 'Recovery did not read the complete provider page'
    wait_for("SELECT count(*)>0 FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PublicationRecoveryFinding' AND data->'facts'->'urls' @> '[\"https://github.com/fixture/project/pull/808\"]'::jsonb")
    assert sql("SELECT count(*) FROM tasks WHERE pr_url='https://github.com/fixture/project/pull/808'") == '0', 'Shared login guessed a card'
    assert sql("SELECT count(*) FROM delivery_task_links WHERE submitted_by_id='shared-fixture-login'") == '0'

    # A retained successful recovery cannot hide a later second PR from the
    # same branch. Keep the original URL and retain the new attribution gap.
    before_second_pr = ab('task','show','binding-one')['task']
    recovery_prs[809] = invented_pr(809, 'feat/bound')
    discovery_sweep()
    wait_for("SELECT count(*)>0 FROM decision_requests WHERE task_id='binding-one' AND question LIKE '%existing_different_url%'")
    assert ab('task','show','binding-one')['task'] == before_second_pr

    # Replay the durable sweep: no new link, decision or attribution history.
    count_query = """SELECT json_build_array((SELECT count(*) FROM delivery_task_links),
        (SELECT count(*) FROM task_events),(SELECT count(*) FROM decision_requests),
        (SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PublicationRecoveryFinding'))"""
    retained_counts = sql(count_query)
    discovery_sweep()
    assert sql(count_query) == retained_counts, 'Recovery replay duplicated retained effects'
    assert sql('SELECT count(*) FROM delivery_publication_grants') == '0'


    # Audited link/inventory/history are one transaction. A late finding-audit
    # failure must enter Oban's actual retry path with no partial PR or card.
    ab('task','create','--id','recovery-audit','--title','Invented audited recovery','--repo','fixture/project')
    ab('task','claim','recovery-audit')
    ab('publication','bind','recovery-audit','--repo','fixture/project','--branch','feat/audit')
    recovery_prs[807] = invented_pr(807, 'feat/audit')
    before_audit = ab('task','show','recovery-audit')
    sql("CREATE FUNCTION reject_recovery_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Delivery.PublicationRecoveryFinding' AND NEW.data->'facts'->>'url'='https://github.com/fixture/project/pull/807' THEN RAISE EXCEPTION 'Invented recovery audit refusal'; END IF; RETURN NEW; END $$")
    sql('CREATE TRIGGER fixture_recovery_audit_guard BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_recovery_audit()')
    rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
    wait_for("SELECT count(*)>0 FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state='retryable'")
    assert ab('task','show','recovery-audit') == before_audit, 'Failed audit left a partial public link or timeline'
    assert sql("SELECT count(*) FROM delivery_pull_requests WHERE number='807'") == '0', 'Failed audit left a canonical PR'
    assert sql("SELECT count(*) FROM delivery_task_links WHERE task_id='recovery-audit'") == '0'
    sql('DROP TRIGGER fixture_recovery_audit_guard ON board_action_events; DROP FUNCTION reject_recovery_audit()')
    rpc('import Ecto.Query; Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "retryable", select: j.id) |> Enum.each(&Oban.retry_job/1)')
    wait_for("SELECT pr_url FROM tasks WHERE id='recovery-audit'", 'https://github.com/fixture/project/pull/807')
    wait_for("SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state IN ('available','executing','scheduled','retryable')", '0')

    # Terminal source cards stay immutable; their new open PR is a separate
    # attribution gap, not permission to resurrect a cancelled claim.
    ab('task','create','--id','recovery-terminal','--title','Invented cancelled publication','--repo','fixture/project')
    ab('task','claim','recovery-terminal')
    ab('publication','bind','recovery-terminal','--repo','fixture/project','--branch','feat/terminal')
    ab('task','update','recovery-terminal','--status','cancelled')
    terminal_before = ab('task','show','recovery-terminal')
    recovery_prs[811] = invented_pr(811, 'feat/terminal')
    discovery_sweep()
    assert ab('task','show','recovery-terminal') == terminal_before
    assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PublicationRecoveryFinding' AND data->'facts'->>'disposition'='terminal_bound_card'") == '1'

    # A real provider 429 persists the shared cooldown and snoozed binding
    # cursor. Restart the actual Oban supervisor, retry early, and prove no
    # provider call or metadata effect until that cooldown expires naturally.
    ab('task','create','--id','recovery-rate','--title','Invented deferred publication','--repo','fixture/project')
    ab('task','claim','recovery-rate')
    ab('publication','bind','recovery-rate','--repo','fixture/project','--branch','feat/rate')
    recovery_prs[810] = invented_pr(810, 'feat/rate')
    RecoveryProvider.limit_once = True
    rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
    wait_for("SELECT blocked_until>clock_timestamp() FROM delivery_provider_budgets WHERE id='github'")
    wait_for("SELECT count(*)>0 FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state='scheduled'")
    rpc(':ok = Oban.pause_queue(queue: :delivery_discovery)')
    calls_during_cooldown = len(RecoveryProvider.calls)
    assert sql("SELECT pr_url IS NULL FROM tasks WHERE id='recovery-rate'") == 't'
    snoozed = json.loads(sql("SELECT row_to_json(j) FROM (SELECT id,attempted_at FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state='scheduled' ORDER BY id LIMIT 1) j"))
    assert sql("SELECT scheduled_at>clock_timestamp() FROM oban_jobs WHERE id="+str(snoozed['id'])) == 't'
    rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban)')
    # Resume is a notification; wait for the restarted queue producer and
    # observe its state before retrying. A startup broadcast is not evidence
    # that a callback ran.
    ready_deadline = time.monotonic()+10
    while time.monotonic() < ready_deadline:
        state = rpc('case Oban.check_queue(queue: :delivery_discovery) do %{paused: paused} -> IO.puts("READY=" <> to_string(not paused)); _ -> IO.puts("NOT_READY") end')
        if 'READY=true' in state:
            break
        rpc(':ok = Oban.resume_queue(queue: :delivery_discovery)')
        time.sleep(.1)
    assert 'READY=true' in state, state
    rpc('import Ecto.Query; Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "scheduled", select: j.id) |> Enum.each(&Oban.retry_job/1)')
    wait_for("SELECT state='scheduled' AND attempted_at>timestamptz'"+snoozed['attempted_at']+"' FROM oban_jobs WHERE id="+str(snoozed['id']), seconds=45)
    assert len(RecoveryProvider.calls) == calls_during_cooldown, 'Restart/early retry bypassed shared provider cooldown'
    wait_for("SELECT blocked_until<=clock_timestamp() FROM delivery_provider_budgets WHERE id='github'", seconds=75)
    rpc('import Ecto.Query; Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "scheduled", select: j.id) |> Enum.each(&Oban.retry_job/1)')
    wait_for("SELECT pr_url FROM tasks WHERE id='recovery-rate'", 'https://github.com/fixture/project/pull/810')
    wait_for("SELECT count(*) FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state IN ('available','executing','scheduled','retryable')", '0')

    # The dedicated default-off recovery switch fences already-queued work.
    ab('task','create','--id','recovery-disabled','--title','Invented disabled recovery','--repo','fixture/project')
    ab('task','claim','recovery-disabled')
    ab('publication','bind','recovery-disabled','--repo','fixture/project','--branch','feat/disabled')
    recovery_prs[812] = invented_pr(812, 'feat/disabled')
    rpc(':ok = Oban.pause_queue(queue: :delivery_discovery); Application.put_env(:agentboard, :publication_recovery_enabled, false); AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links, action_arguments: %{publication_phase: true})')
    calls_before_disable = len(RecoveryProvider.calls)
    rpc(':ok = Oban.resume_queue(queue: :delivery_discovery)')
    wait_for("SELECT count(*)>0 FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks' AND state='scheduled'")
    assert len(RecoveryProvider.calls) == calls_before_disable
    assert sql("SELECT pr_url IS NULL FROM tasks WHERE id='recovery-disabled'") == 't'
    rpc('Application.put_env(:agentboard, :publication_recovery_enabled, true); import Ecto.Query; Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "scheduled", select: j.id) |> Enum.each(&Oban.retry_job/1)')
    wait_for("SELECT pr_url FROM tasks WHERE id='recovery-disabled'", 'https://github.com/fixture/project/pull/812')
    assert sql('SELECT count(*) FROM delivery_publication_grants') == '0'

print('Registered branch crash recovery, unknown PR author and preserved source claim passed')
