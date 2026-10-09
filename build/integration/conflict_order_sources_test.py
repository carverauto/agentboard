"""Canonical collector -> current orders -> selected source -> transactional consumer.

Owns authoritative source resolution and supersession, distinct from the legacy
per-head repairs and default-watch fanout tests. Fixtures only provide GitHub
metadata; orders, pointers, messages and audit relations come from production.
"""
import concurrent.futures
from datetime import datetime
import http.server
from html.parser import HTMLParser
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
import urllib.error
from provider_fixture import tls_provider
from liveview_client import RenderedView

HEAD, BASE, DEFAULT, MOVED = (c * 40 for c in 'abcd')
head, default_tip, target_tip = HEAD, DEFAULT, BASE
mergeable = False


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression], text=True, capture_output=True, timeout=45)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def ab(*args, owner='codex-order-owner'):
    env = {k:v for k,v in os.environ.items() if not k.startswith(('PG','DATABASE_'))}
    env.update(AGENT_ID=owner, AGENTBOARD_HARNESS='codex', AGENTBOARD_MODEL='fixture-model')
    p = subprocess.run([os.environ['AB_BINARY'],'--json',*args], env=env, text=True, capture_output=True, timeout=25)
    assert p.returncode == 0, (p.stdout,p.stderr)
    return json.loads(p.stdout)


def reject_audit(resource, typed=False):
    condition=" AND NEW.data->'source_ref' ? 'order_ref'" if typed else ''
    sql("CREATE OR REPLACE FUNCTION reject_fixture_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='"+resource+"'"+condition+" THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Invented audit failure'; END IF; RETURN NEW; END $$")
    sql('CREATE TRIGGER fixture_atomic_audit BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_fixture_audit()')


def release_failed_poll(pr):
    sql('DROP TRIGGER fixture_atomic_audit ON board_action_events')
    # Only advance the retained reservation clock after a failed observation.
    sql("UPDATE delivery_poll_states SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id='"+pr+"'")


def poll(pr):
    sql("UPDATE delivery_provider_budgets SET remaining=60,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+pr+"'")
    return rpc('IO.puts(inspect(Agentboard.Delivery.Scheduling.poll('+json.dumps(pr)+')))')


def consume(kind, identity, version, recipient='codex-order-owner', pause=False):
    callback = ('Agentboard.Repo.statement!("SELECT pg_sleep(1)", []); ' if pause else '') + 'ref'
    expr = ('r = Agentboard.Delivery.ConflictOrders.with_current_source('+','.join(
        json.dumps(x) for x in (kind,identity,version,recipient))+', fn ref -> '+callback+' end); '
        'IO.puts(Jason.encode!(case r do {:ok, ref} -> %{ref: ref}; {:error, code, _} -> %{error: code} end))')
    return json.loads(rpc(expr).strip().splitlines()[-1])


def provision():
    rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
    request=urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/workers/provision',
        data=json.dumps(dict(worker_id='codex-order-owner',host_id='fixture-order-host',repos=['fixture/orders'],
            model='fixture-model',harness='codex',idempotency_key='fixture-order-enrollment')).encode(),
        headers={'Content-Type':'application/json','Authorization':'Bearer fixture-captain-capability-32-characters','x-agentboard-captain-token':'fixture-captain-capability-32-characters','x-agentboard-worker-protocol':'1'})
    with urllib.request.urlopen(request,timeout=15) as response:
        assert response.status==200


def check_watch(ref):
    watch=sql("SELECT id FROM delivery_base_watches WHERE ref='"+ref+"'")
    sql("UPDATE delivery_base_watches SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+watch+"'")
    return rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.check('+json.dumps(watch)+')))')


def resolve_api(src, owner='codex-order-owner', **extra):
    data=dict(source_kind='board_message',source_id=src['message_id'],source_version=src['message_version'])
    data.update(extra)
    req=urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/conflicts/resolve-source',data=json.dumps(data).encode(),
        headers={'Content-Type':'application/json','X-Agentboard-Agent':owner,'X-Agentboard-Model':'fixture-model','X-Agentboard-Harness':'codex'})
    try: response=urllib.request.urlopen(req,timeout=15)
    except urllib.error.HTTPError as error: response=error
    with response: return response.status,json.load(response)


def rendered_order(path):
    class OrderPanel(HTMLParser):
        def __init__(self):
            super().__init__();self.depth=0;self.text=[];self.links=[];self.times=[]
        def handle_starttag(self,tag,attrs):
            attrs=dict(attrs)
            if tag=='section' and (self.depth or attrs.get('aria-label')=='Conflict repair order'):
                self.depth+=1
            if self.depth and tag=='a':self.links.append(attrs.get('href'))
            if self.depth and tag=='time':self.times.append(attrs.get('datetime'))
        def handle_endtag(self,tag):
            if tag=='section' and self.depth:self.depth-=1
        def handle_data(self,data):
            if self.depth:self.text.append(data)
    panel=OrderPanel()
    view=RenderedView(os.environ['AGENTBOARD_URL'],path)
    try:panel.feed(view.document)
    finally:view.close()
    return ' '.join(panel.text),panel.links,panel.times


def source():
    return json.loads(sql("SELECT to_jsonb(s) FROM delivery_conflict_sources s ORDER BY created_at DESC LIMIT 1"))


def order():
    return json.loads(sql("SELECT to_jsonb(o) FROM delivery_conflict_orders o WHERE state='open'"))


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def do_GET(self):
        assert self.headers['Authorization'] == 'Bearer invented-order-token'
        path = urllib.parse.urlparse(self.path).path
        if path == '/repos/fixture/orders':
            body = dict(full_name='fixture/orders',default_branch='staging')
        elif '/branches/' in path:
            ref = path.rsplit('/',1)[1]
            body = dict(name=ref,commit=dict(sha=default_tip if ref=='staging' else target_tip))
        elif '/pulls/' in path:
            body = dict(number=101,state='open',merged=False,draft=False,
                head=dict(sha=head,ref='feat/order',repo=dict(full_name='fixture/orders')),
                base=dict(sha=target_tip,ref='release'),mergeable=mergeable,
                mergeable_state='clean' if mergeable else 'dirty')
        elif path.endswith('/check-suites'): body = dict(total_count=0,check_suites=[])
        elif path.endswith('/statuses'): body = []
        else: raise AssertionError(path)
        data=json.dumps(body).encode();self.send_response(200)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
        self.end_headers();self.wfile.write(data)


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); '
    'Application.put_env(:agentboard, :cooperation_enabled, true); Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
for who in ('codex-order-owner','codex-order-peer'):
    ab('agent','register',owner=who)
    ab('agent','heartbeat','--status','idle',owner=who)
rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
# The scheduler uses captain-managed scope, never self-reported capabilities.
for who in ('codex-order-owner','codex-order-peer'):
    request=urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/agents/'+who+'/scope',method='PUT',
        data=json.dumps(dict(allowed_repos=['fixture/orders'],required_labels=[],allowed_labels=[],revision=0)).encode(),
        headers={'Content-Type':'application/json','X-Agentboard-Agent':'codex-order-owner',
            'X-Agentboard-Model':'fixture-model','X-Agentboard-Harness':'codex',
            'Authorization':'Bearer fixture-captain-capability-32-characters','x-agentboard-captain-token':'fixture-captain-capability-32-characters'})
    with urllib.request.urlopen(request,timeout=15) as response:assert response.status==200
ab('task','create','--id','order-source','--title','Invented conflict','--repo','fixture/orders')
ab('task','claim','order-source')
ab('task','link','order-source','--pr','https://github.com/fixture/orders/pull/101')
pr=sql('SELECT id FROM delivery_pull_requests')
source_before=ab('task','show','order-source')
with tls_provider(Provider) as (url,ca,_):
    rpc('Application.put_env(:agentboard, :github, [api_url: '+json.dumps(url)+', token: "invented-order-token", ca_file: '+json.dumps(ca)+'])')
    # Dry-run still commits ordinary provider observations, but emits only
    # attributable evaluation evidence: no repair, selected source or wake.
    effect_counts="SELECT jsonb_build_array((SELECT count(*) FROM tasks),(SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_rebase_follow_ups),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM delivery_publication_grants),(SELECT count(*) FROM messages),(SELECT count(*) FROM cooperation_events),(SELECT count(*) FROM wake_intents),(SELECT count(*) FROM decision_requests))"
    before_dry=sql(effect_counts)
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    assert 'observed' in poll(pr)
    evaluations=json.loads(sql("SELECT coalesce(jsonb_agg(data),'[]') FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'"))
    assert len(evaluations)==1, 'Dry-run omitted its attributable evaluation ledger'
    evaluation=evaluations[0]
    assert evaluation['pull_request_id']==pr
    facts=evaluation['facts']
    assert facts['phase']=='snapshot' and facts['plan']=='create_order'
    assert facts['author_id']=='codex-order-owner' and facts['source_tasks']==['order-source']
    assert facts['default_ref']=='staging' and facts['default_tip_sha']==DEFAULT
    assert facts['evaluation_base_ref']=='release' and facts['evaluation_base_sha']==BASE
    assert facts['head_sha']==HEAD and facts['queue_limit']==2
    assert facts['eligibility']['eligible'] is True and facts['eligibility']['queue_count']==1
    assert facts['eligibility']['scope_revision']==1
    assert facts['native_custody']=='unsupported'
    assert sql(effect_counts)==before_dry and ab('task','show','order-source')==source_before
    assert 'observed' in poll(pr)
    assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'")=='2'
    assert sql(effect_counts)==before_dry

    # Audit failure cannot commit a provider snapshot without its plan.
    snapshots_before=sql('SELECT count(*) FROM delivery_ci_snapshots')
    reject_audit('Elixir.Agentboard.Delivery.ConflictEvaluation')
    assert 'observed' not in poll(pr)
    assert sql('SELECT count(*) FROM delivery_ci_snapshots')==snapshots_before
    assert sql(effect_counts)==before_dry
    assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation'")=='2'
    release_failed_poll(pr)

    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
    # The typed wake commits with the Message, immutable source and snapshot.
    # A failure here must not leave a generic orphan or lose the retry signal.
    reject_audit('Elixir.Agentboard.Wake.Intent',typed=True)
    assert 'observed' not in poll(pr)
    assert sql('SELECT count(*) FROM delivery_ci_snapshots')==snapshots_before
    assert sql(effect_counts)==before_dry
    release_failed_poll(pr)
    assert 'observed' in poll(pr)
    initial, initial_source = order(), source()
    assert initial['default_tip_sha']==DEFAULT and initial['evaluation_base_sha']==BASE
    assert initial_source['disposition']=='sent'
    assert sql('SELECT count(*) FROM messages')=='1'
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups')=='1'
    assert ab('task','show','order-source')==source_before, 'Repair mutated source task/claim'
    ref=consume('board_message',initial_source['message_id'],initial_source['message_version'])['ref']
    assert ref == dict(kind='pr_conflict_order',order_id=initial['id'],order_revision=1,
        repair_task_id=initial['repair_task_id'],pull_request_id=pr,default_ref='staging',default_tip_sha=DEFAULT,
        evaluation_base_ref='release',evaluation_base_sha=BASE,recipient_id='codex-order-owner')
    assert resolve_api(initial_source)==(200,dict(order_ref=ref,native_publication='unsupported'))
    wake=json.loads(sql("SELECT to_jsonb(w) FROM wake_intents w WHERE source_kind='board_message' AND source_id='"+str(initial_source['message_id'])+"'"))
    assert wake['source_ref']==dict(order_ref=ref), 'Selected inbox wake lost its typed currentness reference'
    assert wake['source_version']==initial_source['message_version']
    assert sql("SELECT count(*) FROM wake_intents WHERE source_kind='board_message' AND source_id='"+str(initial_source['message_id'])+"'")=='1'
    # Public projection and real connected task/PR renders share retained order
    # evidence; no private component or fabricated ledger drives these pages.
    with urllib.request.urlopen(os.environ['AGENTBOARD_URL']+'/api/v1/prs',timeout=15) as response:
        projected=json.load(response)['prs'][0]['conflict_order']
    assert projected['order']['id']==initial['id'] and projected['repair_owner_id']=='codex-order-owner'
    assert projected['source_mode']=='sent' and projected['order']['rebaser_id'] is None
    for path in ('/prs/'+pr, '/tasks/order-source', '/tasks/'+initial['repair_task_id']):
        text,links,times=rendered_order(path)
        assert '/tasks/'+initial['repair_task_id'] in links, (path,links)
        assert datetime.fromisoformat(initial['deadline_at']) in [datetime.fromisoformat(t) for t in times], (path,times)
        assert 'codex-order-owner' in text and 'Not verified' in text, (path,text)
    assert resolve_api(initial_source,owner='codex-order-peer')[0]==409
    assert resolve_api(initial_source,order_ref=ref)[0]==422, 'Caller-provided reference was accepted as authority'
    assert resolve_api(initial_source,source_id='not-an-id')[0]==422
    assert consume('event',initial_source['id'],initial_source['source_key'])==dict(error='stale_order'), 'Inbox effect was also authorized as worker frame'
    assert consume('board_message',initial_source['message_id'],'invented-version')==dict(error='stale_order')
    assert consume('board_message',initial_source['message_id'],initial_source['message_version'],'codex-order-peer')==dict(error='stale_order')
    assert consume('event','11111111-1111-4111-8111-111111111111','invented')==dict(error='unsupported')

    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    before_effects=sql(effect_counts)
    assert 'observed' in poll(pr)
    assert json.loads(sql("SELECT data->'facts' FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation' ORDER BY id DESC LIMIT 1"))['plan']=='retain_order'
    assert sql(effect_counts)==before_effects
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
    assert 'observed' in poll(pr)
    assert order()['id']==initial['id'] and sql('SELECT count(*) FROM messages')=='1'
    head='e'*40;assert 'observed' in poll(pr)
    assert order()['id']==initial['id'] and sql('SELECT count(*) FROM messages')=='1', 'Another dirty head stacked an order'

    # A canonical watch advance is serialized behind an admitted consumer. The
    # exact frozen identity is rejected on the next reservation, before callback.
    default_tip=MOVED
    watch=sql("SELECT id FROM delivery_base_watches WHERE ref='staging'")
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        held=pool.submit(consume,'board_message',initial_source['message_id'],initial_source['message_version'],'codex-order-owner',True)
        deadline=time.monotonic()+10
        while time.monotonic()<deadline and sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'")=='0':
            time.sleep(0.05)
        assert sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'")!='0', 'Consumer never entered its fenced transaction'
        sql("UPDATE delivery_base_watches SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+watch+"'")
        moving=pool.submit(rpc,'IO.puts(inspect(Agentboard.Delivery.BaseMonitor.check('+json.dumps(watch)+')))')
        assert held.result()['ref']['order_id']==initial['id']
        assert 'changed: true' in moving.result()
    assert consume('board_message',initial_source['message_id'],initial_source['message_version'])==dict(error='stale_order')
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    before_effects=sql(effect_counts)
    assert 'observed' in poll(pr)
    assert json.loads(sql("SELECT data->'facts' FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation' ORDER BY id DESC LIMIT 1"))['plan']=='supersede_order'
    assert sql(effect_counts)==before_effects and order()['id']==initial['id']
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
    assert 'observed' in poll(pr)
    newer=order(); assert newer['id']!=initial['id'] and newer['revision']==2
    assert newer['deadline_at']==initial['deadline_at'] and newer['episode_id']==initial['episode_id']
    assert sql('SELECT count(*) FROM delivery_rebase_follow_ups')=='1'
    assert sql('SELECT count(*) FROM messages')=='2'
    assert sql("SELECT count(*) FROM delivery_conflict_orders WHERE state='open'")=='1'
    assert sql("SELECT state FROM delivery_conflict_orders WHERE id='"+initial['id']+"'")=='superseded'
    newest=source(); assert 'ref' in consume('board_message',newest['message_id'],newest['message_version'])

    # Target moves while default remains unchanged; distinct identities and
    # earliest deadline must survive a further same-default revision.
    target_tip='f'*40
    assert 'changed: true' in check_watch('release')
    assert 'observed' in poll(pr)
    assert order()['revision']==3 and order()['default_tip_sha']==MOVED and order()['evaluation_base_sha']==target_tip
    assert order()['deadline_at']==initial['deadline_at']
    latest=source()
    assert consume('board_message',newest['message_id'],newest['message_version'])==dict(error='stale_order')

    # Actual enrollment adopts the existing inbox effect. It does not recreate
    # a legacy rebase Event or turn that occurrence into a worker prompt.
    prior_events=sql("SELECT count(*) FROM cooperation_events WHERE kind='pr_conflict'")
    provision()
    assert sql("SELECT count(*) FROM cooperation_events WHERE kind='pr_conflict'")==prior_events
    assert sql("SELECT count(*) FROM cooperation_deliveries WHERE event_id='"+latest['id']+"'")=='0'
    messages_before=sql('SELECT count(*) FROM messages')
    default_tip='1'*40;assert 'changed: true' in check_watch('staging')
    assert 'observed' in poll(pr)
    worker_source=source()
    assert worker_source['disposition']=='worker' and worker_source['message_id'] is None
    assert sql('SELECT count(*) FROM messages')==messages_before, 'Worker selection emitted an extra inbox effect'
    assert 'ref' in consume('event',worker_source['id'],worker_source['source_key'])
    assert consume('board_message',latest['message_id'],latest['message_version'])==dict(error='stale_order')

    # Source/audit failure rolls back evidence, order supersession and the
    # selected effect together, leaving no half-retained source identity.
    before_atomic=sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_ci_snapshots),(SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM cooperation_events),(SELECT count(*) FROM messages))")
    reject_audit('Elixir.Agentboard.Delivery.ConflictSource')
    default_tip='2'*40;assert 'changed: true' in check_watch('staging')
    refused=poll(pr)
    assert 'observed' not in refused, refused
    assert sql("SELECT jsonb_build_array((SELECT count(*) FROM delivery_ci_snapshots),(SELECT count(*) FROM delivery_conflict_orders),(SELECT count(*) FROM delivery_conflict_sources),(SELECT count(*) FROM cooperation_events),(SELECT count(*) FROM messages))")==before_atomic
    release_failed_poll(pr)
    assert 'observed' in poll(pr)
    worker_source=source()

    repair=order()['repair_task_id']
    ab('task','claim',repair)
    ab('task','handoff',repair,'--to','codex-order-peer','--body','Invented reassignment')
    assert consume('event',worker_source['id'],worker_source['source_key'])==dict(error='stale_order')
    assert ab('task','show','order-source')==source_before
    assert sql('SELECT count(*) FROM delivery_publication_grants')=='0', 'Source resolution fabricated native custody'
    mergeable=True
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
    before_effects=sql(effect_counts)
    assert 'observed' in poll(pr)
    assert json.loads(sql("SELECT data->'facts' FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.ConflictEvaluation' ORDER BY id DESC LIMIT 1"))['plan']=='clear_order_without_rebaser_credit'
    assert sql(effect_counts)==before_effects
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "apply")')
    assert 'observed' in poll(pr)
    assert sql("SELECT count(*) FROM delivery_conflict_orders WHERE state='open'")=='0'
    assert sql("SELECT count(*) FROM delivery_conflict_orders WHERE rebaser_id IS NOT NULL")=='0', 'Unverified changed head invented rebaser credit'
    assert ab('task','show',repair)['task']['status']=='assigned', 'Clean evidence completed repair without attribution'

    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "disabled")')
    assert consume('board_message',latest['message_id'],latest['message_version'])==dict(error='unsupported')

print('Canonical source relation, one effect, superseding default/target fences, retained deadline, frozen-source rejection and repair-only assignment passed')
