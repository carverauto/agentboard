"""Collector-created repair routing at real API/PG/AshOban boundaries.

Owns eligibility, deterministic admission, repair-only lease transfer and retained
captain escalation. Sources/repair/orders/decisions are produced normally; SQL
only resets provider budget/due time or advances retained timestamps.
"""
import concurrent.futures
import http.server
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from provider_fixture import tls_provider

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-conflict-routing-captain-0123456789'
clean = set()


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expr):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expr], capture_output=True, text=True, timeout=45)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=None, actor='routing-captain', captain=False, method=None, status=200):
    headers = {'Content-Type': 'application/json', 'X-Agentboard-Agent': actor,
        'X-Agentboard-Model': 'fixture-model', 'X-Agentboard-Harness': 'codex'}
    if captain: headers['Authorization'] = 'Bearer ' + CAPTAIN
    request = urllib.request.Request(URL+'/api/v1/'+path, headers=headers,
        data=None if data is None else json.dumps(data).encode(), method=method)
    try: response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error: response = error
    with response:
        body = json.load(response)
        assert response.status == status, (path, response.status, body)
        return body


def register(agent, kind='seat', scope=True):
    api('agents/register', dict(name=agent,kind=kind,capabilities=['fixture/repair']), actor=agent)
    api('agents/'+agent+'/heartbeat', dict(status='idle'), actor=agent)
    if scope: set_scope(agent)


def set_scope(agent, repos=None, required=None):
    previous = api('agents/'+agent+'/scope')['scope']['revision']
    api('agents/'+agent+'/scope', dict(allowed_repos=repos or ['fixture/repair'],
        required_labels=required or [],allowed_labels=[],revision=previous), captain=True, method='PUT')


def policy(agent, state):
    api('availability', dict(agent_id=agent,state=state,reason='Invented routing policy'), captain=True)


def task(identity, owner=None, repo='fixture/repair'):
    api('tasks', dict(id=identity,title='Invented routing task',repo=repo))
    if owner: api('tasks/'+identity+'/claim', {}, actor=owner)


def poll(pr):
    sql("UPDATE delivery_provider_budgets SET remaining=60,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+pr+"'")
    assert 'observed' in rpc('IO.inspect(Agentboard.Delivery.Scheduling.poll('+json.dumps(pr)+'))')


def create_order(number, owner):
    identity = 'routing-source-'+str(number)
    task(identity, owner)
    api('tasks/'+identity+'/link', dict(pr_url='https://github.com/fixture/repair/pull/'+str(number)), actor=owner)
    pr = sql("SELECT pull_request_id FROM delivery_task_links WHERE task_id='"+identity+"'")
    before = api('tasks/'+identity)
    poll(pr)
    return current(pr), before


def current(pr):
    return json.loads(sql("SELECT to_jsonb(o) FROM delivery_conflict_orders o WHERE pull_request_id='"+pr+"' AND state='open'"))


def route(identity):
    # Invoke the production Ash action with its actual system authorization,
    # exactly as the persisted scheduled action does, not a test-only wrapper.
    output = rpc('result = Ash.run_action(Ash.ActionInput.for_action(Agentboard.Delivery.ConflictDisposition, :route, '
        '%{id: '+json.dumps(identity)+'}, actor: %{role: :system})); IO.inspect(result)')
    assert '{:ok,' in output, output
    return output


def perform_persisted(order):
    # Production enqueues this job in the canonical order transaction. Exercise
    # its generated worker and default system actor with the actual stored args.
    ids=json.loads(sql("SELECT coalesce(jsonb_agg(id),'[]') FROM oban_jobs WHERE worker='Agentboard.Delivery.RouteConflicts' AND args->'action_arguments'->>'id'='"+order['id']+"'"))
    assert len(ids)==1, 'Current order did not retain its unique deadline job'
    output=rpc('result = Agentboard.Delivery.RouteConflicts.perform(Agentboard.Repo.get!(Oban.Job, '+str(ids[0])+')); IO.puts("JOB_OK=" <> to_string(result == :ok))')
    assert 'JOB_OK=true' in output, output


def preview(order, plan, reason, candidate, source_id):
    effects="SELECT jsonb_build_array((SELECT count(*) FROM tasks),(SELECT count(*) FROM task_events),(SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM cooperation_events),(SELECT count(*) FROM cooperation_deliveries),(SELECT count(*) FROM wake_intents),(SELECT count(*) FROM decision_requests),(SELECT count(*) FROM delivery_publication_grants))"
    before_effects=sql(effects)
    before_repair=api('tasks/'+order['repair_task_id'])
    before_source=api('tasks/'+source_id)
    before_order=current(order['pull_request_id'])
    before_audits=int(sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    perform_persisted(order)
    rows=json.loads(sql("SELECT coalesce(jsonb_agg(data ORDER BY occurred_at,id),'[]') FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    assert len(rows)==before_audits+1, 'Dry-run deadline omitted its canonical selection evidence'
    evaluation=rows[-1]
    assert evaluation['pull_request_id']==order['pull_request_id']
    facts=evaluation['facts']
    assert facts['phase']=='deadline' and facts['plan']==plan and facts['reason']==reason
    assert facts['current_order_id']==order['id'] and facts['current_order_revision']==order['revision']
    assert facts['repair_task_id']==order['repair_task_id'] and facts['native_custody']=='unsupported'
    if candidate:
        assert facts['candidate']['agent_id']==candidate and facts['candidate']['eligible'] is True
    else: assert facts['candidate'] is None
    assert sql(effects)==before_effects
    assert api('tasks/'+order['repair_task_id'])==before_repair and api('tasks/'+source_id)==before_source
    assert current(order['pull_request_id'])==before_order
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')


def elapsed(order):
    # Advance only retained episode/deadline timestamps, modeling elapsed time.
    sql("UPDATE delivery_conflict_orders SET episode_started_at=episode_started_at-interval '1 hour',deadline_at=deadline_at-interval '1 hour' WHERE id='"+order['id']+"'")


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        assert self.headers['Authorization'] == 'Bearer invented-routing-token'
        path = urllib.parse.urlparse(self.path).path
        if path == '/repos/fixture/repair': body = dict(full_name='fixture/repair',default_branch='main')
        elif '/branches/' in path: body = dict(name='main',commit=dict(sha='b'*40))
        elif '/pulls/' in path:
            number = int(path.rsplit('/',1)[1]); mergeable = number in clean
            body = dict(number=number,state='open',merged=False,draft=False,
                head=dict(sha=f'{number:040x}',ref='feat/'+str(number),repo=dict(full_name='fixture/repair')),
                base=dict(sha='b'*40,ref='main'),mergeable=mergeable,
                mergeable_state='clean' if mergeable else 'dirty')
        elif path.endswith('/check-suites'): body = dict(total_count=0,check_suites=[])
        elif path.endswith('/statuses'): body = []
        else: raise AssertionError(path)
        data=json.dumps(body).encode();self.send_response(200)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
        self.end_headers();self.wfile.write(data)


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); '
    'Application.put_env(:agentboard, :cooperation_enabled, true); '
    'Application.put_env(:agentboard, :conflict_routing_mode, "apply"); '
    'Application.put_env(:agentboard, :captain_token, '+json.dumps(CAPTAIN)+')')
api('agents/register', dict(name='Fixture captain',kind='human'), actor='routing-captain')
for agent in ['author-1','author-2','author-3','author-4','author-5','author-6','author-7','author-8','good-a','good-b','good-c','good-d',
              'a-reject-stale','a-reject-reserved','a-reject-offline','a-reject-retired','a-reject-waiting','a-reject-repo','a-reject-label','a-reject-full']:
    register(agent)
register('a-reject-unmanaged', scope=False)
register('a-reject-system', kind='system')
sql("UPDATE agents SET last_heartbeat=clock_timestamp()-interval '21 minutes' WHERE id='a-reject-stale'")
policy('a-reject-reserved','reserved');policy('a-reject-offline','out_of_service')
api('agents/a-reject-retired/retire', dict(reason='Invented retirement'), captain=True)
set_scope('a-reject-repo', repos=['fixture/other']);set_scope('a-reject-label', required=['security'])
for n in range(2): task('full-'+str(n), 'a-reject-full')
task('unrelated-hold','a-reject-waiting')
api('decisions', dict(task='unrelated-hold',question='Invented unrelated approval?',kind='approval'), actor='a-reject-waiting')
for who in ['good-c','good-d','author-2','author-3','author-4','author-5','author-6','author-7','author-8']: policy(who,'reserved')
# Source authors may retain their named source claims through a captain's
# explicit assignment, but reserved availability excludes automatic repair.
for who in ['author-2','author-3','author-4','author-5','author-6','author-7','author-8']: policy(who,'active')
task('older-assignment','good-a')

with tls_provider(Provider) as (url,ca,_):
    rpc('Application.put_env(:agentboard, :github, [api_url: '+json.dumps(url)+', token: "invented-routing-token", ca_file: '+json.dumps(ca)+'])')
    first, source1 = create_order(101,'author-1')
    assert first['recipient_id']=='author-1'
    repair = first['repair_task_id']
    api('tasks/'+repair+'/claim', {}, actor='author-1')
    old_lease = api('tasks/'+repair)['task']['claim_expires_at']
    assert old_lease
    # Out of service routes before the future deadline. All rejected candidate
    # profiles are otherwise registered and have captain-authorized repo scope.
    policy('author-1','out_of_service')
    for who in ['author-2','author-3','author-4','author-5','author-6','author-7','author-8']: policy(who,'reserved')
    preview(first,'reassign_repair','recipient_ineligible','good-b','routing-source-101')
    preview(first,'reassign_repair','recipient_ineligible','good-b','routing-source-101')
    perform_persisted(first)
    replacement = current(first['pull_request_id'])
    assert replacement['recipient_id']=='good-b', replacement  # shortest queue
    assert replacement['author_id']=='author-1' and replacement['revision']==2
    assert replacement['deadline_at']==first['deadline_at'] and replacement['episode_id']==first['episode_id']
    assert replacement['selection_reason']=='recipient_ineligible'
    repaired = api('tasks/'+repair)['task']
    assert repaired['assignee_id']=='good-b' and repaired['claim_expires_at'] is None and repaired['claimed_at'] is None
    assert api('tasks/routing-source-101')==source1
    api('tasks/'+repair+'/link', dict(pr_url='https://github.com/fixture/repair/pull/999'), actor='good-b',status=409)
    assert replacement['escalation_decision_id']
    assert 'native_custody_unsupported' in api('decisions/'+replacement['escalation_decision_id'])['decision']['gate_ref']
    # Assignment does not manufacture a claim. The selected seat explicitly
    # claims only the existing repair through the normal ownership API.
    api('tasks/'+repair+'/claim', {}, actor='good-b')
    claimed_repair=api('tasks/'+repair)['task']
    assert claimed_repair['assignee_id']=='good-b' and claimed_repair['claim_expires_at']
    assert api('tasks/routing-source-101')==source1
    effects = sql('SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM decision_requests))')
    route(first['id']);route(replacement['id']);route(replacement['id'])
    assert current(first['pull_request_id'])['id']==replacement['id']
    assert sql('SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM decision_requests))')==effects
    assert sql("SELECT count(*) FROM task_events WHERE task_id='"+repair+"' AND kind='repair_routed'")=='1'

    # Deadline case: current active author, then equal queue counts on the two
    # eligible replacements. Older assignment wins independently of list order.
    policy('author-2','active')
    second, source2 = create_order(102,'author-2')
    assert second['recipient_id']=='author-2'
    api('agents/author-2/heartbeat', dict(status='busy',task='routing-source-102'), actor='author-2')
    elapsed(second)
    preview(second,'reassign_repair','author_deadline','good-a','routing-source-102')
    route(second['id'])
    selected = current(second['pull_request_id'])
    assert selected['recipient_id']=='good-a' and selected['selection_reason']=='author_deadline', selected
    assert api('tasks/routing-source-102')==source2
    policy('author-2','reserved')

    task('fill-good-b','good-b')

    # With no prior assignments, the stable full ID breaks the tie.
    policy('good-c','active');policy('good-d','active');policy('author-3','active')
    third, source3 = create_order(103,'author-3');elapsed(third);route(third['id'])
    assert current(third['pull_request_id'])['recipient_id']=='good-c'
    assert api('tasks/routing-source-103')==source3
    policy('author-3','reserved');policy('good-d','reserved')

    # Competing real orders, one remaining slot on good-c. Other healthy seats
    # are already full. At most one transaction may admit the last slot.
    policy('author-4','active');fourth, source4 = create_order(104,'author-4');elapsed(fourth)
    policy('author-5','active');fifth, source5 = create_order(105,'author-5');elapsed(fifth)
    policy('author-4','reserved');policy('author-5','reserved')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        list(pool.map(route,[fourth['id'],fifth['id']]))
    current4,current5 = current(fourth['pull_request_id']),current(fifth['pull_request_id'])
    assert [current4['recipient_id'],current5['recipient_id']].count('good-c')==1, (current4,current5)
    assert sql("SELECT count(*) FROM tasks WHERE assignee_id='good-c' AND status IN ('assigned','in_progress','blocked','review')")=='2'
    loser = current4 if current4['recipient_id']!='good-c' else current5
    assert loser['escalation_decision_id']
    retained = api('decisions/'+loser['escalation_decision_id'])['decision']
    assert 'no_eligible_seat' in retained['gate_ref']
    preview(loser,'escalate_no_eligible_seat','author_deadline',None,
        'routing-source-104' if loser['id']==fourth['id'] else 'routing-source-105')
    decisions = sql('SELECT count(*) FROM decision_requests')
    route(loser['id']);route(loser['id'])
    assert sql('SELECT count(*) FROM decision_requests')==decisions
    assert api('tasks/routing-source-104')==source4 and api('tasks/routing-source-105')==source5

    # Canonical resolution wins before a queued deadline: no new assignment,
    # source or grant may be issued by a frozen old timer after the clean poll.
    policy('author-6','active');sixth, source6 = create_order(106,'author-6')
    elapsed(sixth);clean.add(106);poll(sixth['pull_request_id'])
    counts = sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM task_events WHERE kind='repair_routed'))")
    route(sixth['id'])
    assert sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM task_events WHERE kind='repair_routed'))")==counts
    assert api('tasks/routing-source-106')==source6
    # Relevant captain hold and stale liveness both trigger early evaluation,
    # before the future deadline, while retaining the exact source lease.
    policy('author-7','active');seventh, _ = create_order(107,'author-7')
    api('decisions', dict(task='routing-source-107',question='Invented source approval?',kind='approval'), actor='author-7')
    held_source = api('tasks/routing-source-107')
    route(seventh['id'])
    held_order = current(seventh['pull_request_id'])
    assert held_order['escalation_decision_id'] and held_order['id']==seventh['id']
    assert api('tasks/routing-source-107')==held_source
    policy('author-8','active');eighth, source8 = create_order(108,'author-8')
    sql("UPDATE agents SET last_heartbeat=clock_timestamp()-interval '21 minutes' WHERE id='author-8'")
    stale_source = api('tasks/routing-source-108')
    route(eighth['id'])
    assert current(eighth['pull_request_id'])['escalation_decision_id']
    assert api('tasks/routing-source-108')==stale_source
    assert stale_source['task']['claim_expires_at']==source8['task']['claim_expires_at']
    assert sql('SELECT count(*) FROM delivery_publication_grants')=='0'
    # Retained earliest deadline still binds the current repair recipient after a
    # repair-only handoff. The reassigned seat stays eligible past the retained
    # deadline, so production AshOban routing must reassign again (never reset
    # the deadline, stack a duplicate, or touch the source claim).
    for who in ['good-a','good-b','good-c','author-6','author-7']: policy(who,'reserved')
    for who in ['retain-author','retain-a','retain-b']: register(who)
    retained_first, retained_source = create_order(109,'retain-author')
    assert retained_first['recipient_id']=='retain-author'
    policy('retain-author','out_of_service')
    perform_persisted(retained_first)
    retained_second = current(retained_first['pull_request_id'])
    assert retained_second['recipient_id']=='retain-a', retained_second
    assert retained_second['author_id']=='retain-author' and retained_second['revision']==2
    assert retained_second['deadline_at']==retained_first['deadline_at']
    assert retained_second['episode_id']==retained_first['episode_id']
    assert retained_second['selection_reason']=='recipient_ineligible'
    assert api('tasks/routing-source-109')==retained_source
    elapsed(retained_second)
    effects="SELECT jsonb_build_array((SELECT count(*) FROM tasks),(SELECT count(*) FROM task_events),(SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM cooperation_events),(SELECT count(*) FROM cooperation_deliveries),(SELECT count(*) FROM wake_intents),(SELECT count(*) FROM decision_requests),(SELECT count(*) FROM delivery_publication_grants))"
    before_effects=sql(effects)
    before_repair=api('tasks/'+retained_second['repair_task_id'])
    before_order=current(retained_first['pull_request_id'])
    before_audits=int(sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    route(retained_second['id'])
    rows=json.loads(sql("SELECT coalesce(jsonb_agg(data ORDER BY occurred_at,id),'[]') FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    assert len(rows)==before_audits+1, 'Dry-run retained deadline omitted its canonical selection evidence'
    evaluation=rows[-1]
    assert evaluation['pull_request_id']==retained_second['pull_request_id']
    facts=evaluation['facts']
    assert facts['phase']=='deadline' and facts['plan']=='reassign_repair' and facts['reason']=='retained_deadline'
    assert facts['current_order_id']==retained_second['id'] and facts['current_order_revision']==retained_second['revision']
    assert facts['candidate']['agent_id']=='retain-b' and facts['candidate']['eligible'] is True
    assert sql(effects)==before_effects
    assert api('tasks/'+retained_second['repair_task_id'])==before_repair
    assert current(retained_first['pull_request_id'])==before_order
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
    routed = sql("SELECT count(*) FROM task_events WHERE task_id='"+retained_second['repair_task_id']+"' AND kind='repair_routed'")
    route(retained_second['id'])
    retained_third = current(retained_first['pull_request_id'])
    assert retained_third['recipient_id']=='retain-b', retained_third
    assert retained_third['author_id']=='retain-author' and retained_third['revision']==3
    assert retained_third['deadline_at']==retained_first['deadline_at']
    assert retained_third['episode_id']==retained_first['episode_id']
    assert retained_third['selection_reason']=='retained_deadline'
    assert api('tasks/routing-source-109')==retained_source
    assert sql("SELECT count(*) FROM task_events WHERE task_id='"+retained_second['repair_task_id']+"' AND kind='repair_routed'")==str(int(routed)+1)
    superseded_effects = sql('SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM decision_requests))')
    route(retained_second['id'])
    assert current(retained_first['pull_request_id'])['id']==retained_third['id']
    assert sql('SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM decision_requests))')==superseded_effects
    repeat_effects = sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM task_events WHERE kind='repair_routed'),(SELECT count(*) FROM decision_requests))")
    repeat_audits=int(sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    route(retained_third['id'])
    route(retained_third['id'])
    assert current(retained_first['pull_request_id'])['id']==retained_third['id']
    assert current(retained_first['pull_request_id'])['selection_reason']=='retained_deadline'
    assert sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM messages),(SELECT count(*) FROM task_events WHERE kind='repair_routed'),(SELECT count(*) FROM decision_requests))")==repeat_effects
    assert int(sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))==repeat_audits
    assert api('tasks/routing-source-109')==retained_source
    assert sql('SELECT count(*) FROM delivery_publication_grants')=='0'

print('Shared eligibility profiles, queue/assignment/ID ties, repair-only lease transfer, duplicate timers, concurrent last-slot admission and owner-resolution fencing passed')
