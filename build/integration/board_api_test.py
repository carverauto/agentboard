"""Public CLI/HTTP contracts against a packaged release and ephemeral TLS DB."""
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

cli_env = {k:v for k,v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
cli_env.update(AGENT_ID='alpha', AGENTBOARD_MODEL='model-a', AGENTBOARD_HARNESS='codex')

def ab(*args, actor='alpha', model='model-a', harness='codex', code=0, stdin=None):
    env = dict(cli_env, AGENT_ID=actor, AGENTBOARD_MODEL=model, AGENTBOARD_HARNESS=harness)
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env, capture_output=True, text=True, input=stdin, timeout=15)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    if code:
        assert not result.stdout, result.stdout
        return json.loads(result.stderr)['error']
    return json.loads(result.stdout)

def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',statement], text=True).strip()

def api(path, data, actor='alpha', model='model-a', harness='codex'):
    req=urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/'+path,data=data,
        headers={'Content-Type':'application/json','X-Agentboard-Agent':actor,'X-Agentboard-Model':model,'X-Agentboard-Harness':harness})
    try:
        with urllib.request.urlopen(req,timeout=15) as r: return r.status,json.load(r)
    except urllib.error.HTTPError as r: return r.code,json.load(r)

assert ab('task','list')['tasks']==[]
ab('agent','register','--name','Alpha')
ab('agent','register',actor='beta',harness='claude')
ab('agent','register',actor='gamma',harness='shell')
ab('agent','register',harness='claude',code=4)
assert ab('agent','show','alpha')['agent']['harness']=='codex'
before=sql('SELECT count(*) FROM tasks')
ab('task','create','--title','No actor',actor='',code=2)
ab('task','create','--title','Unknown',actor='missing',code=2)
assert api('tasks',b'{broken')[0]==400
assert api('tasks',b'{"title":"Invalid priority","priority":-1}')[0]==422
assert api('tasks',b'{"title":"Not a title"}',model='')[0]==422
assert sql('SELECT count(*) FROM tasks')==before

# Metadata edits and links preserve revision guards and attributed history.
generated=ab('task','create','--title','Generated slug')['task']
import re
assert re.fullmatch(r'generated-slug-[a-f0-9]{16}',generated['id'])
edited=ab('task','edit',generated['id'],'--title','Edited title','--description','Metadata fixture','--priority','7','--repo','metadata-fixture','--label','api,docs','--revision',str(generated['revision']))['task']
assert edited['title']=='Edited title' and edited['description']=='Metadata fixture' and edited['priority']==7 and edited['labels']==['api','docs']
ab('task','edit',edited['id'],'--title','Stale edit','--revision',str(generated['revision']),code=4)
linked=ab('task','link',edited['id'],'--issue','https://github.com/carverauto/agentboard/issues/1','--pr','https://github.com/carverauto/agentboard/pull/2')['task']
assert linked['issue_url'].endswith('/issues/1') and linked['pr_url'].endswith('/pull/2')
prior=ab('task','show',edited['id'])
for invalid in ['http://github.com/carverauto/agentboard/issues/1','https://evil.example/carverauto/agentboard/issues/1','javascript:alert(1)']:
    ab('task','link',edited['id'],'--issue',invalid,code=2)
    assert ab('task','show',edited['id'])==prior
assert [t['id'] for t in ab('task','list','--repo','metadata-fixture','--label','api')['tasks']]==[edited['id']]

task=ab('task','create','--id','contended','--title','Concurrent claim','--repo','sample')['task']
assert task['status']=='open' and task['assignee_id'] is None
ab('task','create','--id','contended','--title','Overwrite',code=4)
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    futures=[pool.submit(api,'tasks/contended/claim',b'{}',a,'model-a',h) for a,h in [('alpha','codex'),('beta','claude')]]
    results=[f.result() for f in futures]
assert sorted(r[0] for r in results)==[200,409],results
owner=ab('task','show','contended')['task']['assignee_id']
owner_harness='codex' if owner=='alpha' else 'claude'
assert sql("SELECT count(*) FROM task_events WHERE task_id='contended' AND kind='claim'")=='1'
ab('task','claim','contended',actor=owner,harness=owner_harness,code=4)
ab('task','update','contended','--body','Working',actor=owner,harness=owner_harness)
ab('agent','register',actor=owner,harness=owner_harness,model='model-new')
events=ab('task','show','contended')['events']
assert all(e['model']=='model-a' for e in events),events
ab('task','update','contended','--status','blocked',actor=owner,harness=owner_harness,code=2)
ab('task','update','contended','--status','blocked','--body','Waiting',actor=owner,harness=owner_harness)
ab('task','update','contended','--status','done',actor=owner,harness=owner_harness,code=4)
ab('task','update','contended','--status','review',actor=owner,harness=owner_harness)
finished=ab('task','update','contended','--status','done',actor=owner,harness=owner_harness)['task']
assert finished['claim_expires_at'] is None and finished['assignee_id']==owner
ab('task','edit','contended','--title','Terminal edit',actor=owner,harness=owner_harness,code=4)

ab('task','create','--id','assigned','--title','Assigned work')
ab('task','assign','assigned','--to','beta')
ab('task','claim','assigned',actor='gamma',harness='shell',code=4)
ab('task','claim','assigned',actor='beta',harness='claude')
ab('task','release','assigned',actor='beta',harness='claude')
assert ab('task','show','assigned')['task']['status']=='open'

ab('task','create','--id','expiring','--title','Short lease')
ab('--ttl','200ms','task','claim','expiring')
time.sleep(0.3)
expired=ab('task','show','expiring')['task']
assert expired['claim_expired'] and expired['status']=='in_progress' and expired['assignee_id']=='alpha'
ab('task','renew','expiring',code=4)
ab('task','reclaim','expiring',actor='beta',harness='claude')
ab('task','edit','expiring','--title','Old owner',code=4)
ab('task','renew','expiring',actor='beta',harness='claude')

# A failed event INSERT must roll back the task change as well.
sql("CREATE FUNCTION reject_test_event() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.body='reject-fixture' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Synthetic event rejected'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER fixture_event_guard BEFORE INSERT ON task_events FOR EACH ROW EXECUTE FUNCTION reject_test_event()')
prior=ab('task','show','expiring')
ab('task','update','expiring','--status','review','--body','reject-fixture',actor='beta',harness='claude',code=2)
after=ab('task','show','expiring')
assert prior['task']==after['task'] and prior['events']==after['events']

# A task-specific lock cannot serialize unrelated request-process SQL.
ab('task','create','--id','locked','--title','Locked task')
ab('task','create','--id','independent','--title','Independent task')
lock_env=dict(os.environ,PGAPPNAME='agentboard-fixture-row-lock')
locker=subprocess.Popen([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',"BEGIN; SELECT id FROM tasks WHERE id='locked' FOR UPDATE; SELECT pg_sleep(3); COMMIT;"],env=lock_env,stdout=subprocess.PIPE,text=True)
for _ in range(100):
    if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='agentboard-fixture-row-lock' AND wait_event='PgSleep'")=='1': break
    time.sleep(0.01)
else: raise AssertionError('Did not acquire fixture row lock')
with concurrent.futures.ThreadPoolExecutor(1) as pool:
    blocked=pool.submit(ab,'--ttl','500ms','task','claim','locked')
    time.sleep(0.1)
    started=time.monotonic()
    assert ab('task','show','independent')['task']['status']=='open'
    ab('task','claim','independent',actor='beta',harness='claude')
    assert time.monotonic()-started<2 and not blocked.done(), 'Independent requests waited behind another task lock'
    claimed=blocked.result()["task"]
    from datetime import datetime,timezone
    assert datetime.fromisoformat(claimed["claim_expires_at"])>datetime.now(timezone.utc), "Lease clock was sampled before the row lock"
assert locker.wait(timeout=10)==0

# Keyset pages must preserve filters and contain no duplicate/missing records.
page=ab('task','list','--limit','2')
ids=[]
while True:
    ids.extend(t['id'] for t in page['tasks'])
    if page['next_cursor'] is None: break
    cursor=page['next_cursor']
    ab('task','list','--repo','changed','--cursor',cursor,code=2)
    page=ab('task','list','--limit','2','--cursor',cursor)
assert len(ids)==len(set(ids))==int(sql('SELECT count(*) FROM tasks'))
ab('task','show','does-not-exist',code=3)
# State, version, Ash event, and compatibility timeline are one commit boundary.
def audit_counts(task_id):
    return sql(f"SELECT (SELECT count(*) FROM tasks_versions WHERE version_source_id='{task_id}')||','||(SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Board.Resources.Task' AND record_id='{task_id}')||','||(SELECT count(*) FROM task_events WHERE task_id='{task_id}')")
ab('task','create','--id','audit-rollback','--title','Audited task')
assert audit_counts('audit-rollback')=='1,1,1', audit_counts('audit-rollback')
version=json.loads(sql("SELECT row_to_json(v) FROM tasks_versions v WHERE version_source_id='audit-rollback'"))
assert version['version_action_name']=='create' and version['provenance']=={'agent':'alpha','model':'model-a','harness':'codex','operation_version':1}
audit=json.loads(sql("SELECT row_to_json(e) FROM board_action_events e WHERE resource='Elixir.Agentboard.Board.Resources.Task' AND record_id='audit-rollback'"))
assert audit['version']==1 and audit['metadata']==version['provenance']
for table, condition in [('board_action_events',"NEW.record_id='audit-rollback' AND NEW.action='edit'"),('tasks_versions',"NEW.version_source_id='audit-rollback' AND NEW.version_action_name='edit'")]:
    sql(f"CREATE FUNCTION reject_audit_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF {condition} THEN RAISE EXCEPTION 'Synthetic audit persistence failure'; END IF; RETURN NEW; END $$")
    sql(f'CREATE TRIGGER reject_audit_fixture BEFORE INSERT ON {table} FOR EACH ROW EXECUTE FUNCTION reject_audit_fixture()')
    before_task=ab('task','show','audit-rollback')
    before_audit=audit_counts('audit-rollback')
    ab('task','edit','audit-rollback','--title','Must roll back',code=1)
    assert ab('task','show','audit-rollback')==before_task and audit_counts('audit-rollback')==before_audit
    sql(f'DROP TRIGGER reject_audit_fixture ON {table}; DROP FUNCTION reject_audit_fixture()')
ab('task','edit','audit-rollback','--title','Committed audit')
assert audit_counts('audit-rollback')=='2,2,2'

# Hold one transaction inside its Ash event insert. Another task from the same
# caller must still read and mutate without a global event or actor-row bottleneck.
ab('task','create','--id','audit-locked','--title','Held audit transaction')
sql("CREATE FUNCTION hold_audit_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Board.Resources.Task' AND NEW.record_id='audit-locked' AND NEW.action='claim' THEN PERFORM pg_advisory_xact_lock(987654321::bigint); END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER hold_audit_fixture BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION hold_audit_fixture()')
locker=subprocess.Popen([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',"BEGIN; SELECT pg_advisory_xact_lock(987654321::bigint); SELECT pg_sleep(3); COMMIT;"],env=lock_env,stdout=subprocess.PIPE,text=True)
for _ in range(100):
    if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='agentboard-fixture-row-lock' AND wait_event='PgSleep'")=='1':break
    time.sleep(.01)
else:raise AssertionError('Audit fixture did not acquire barrier')
with concurrent.futures.ThreadPoolExecutor(1) as pool:
    blocked=pool.submit(ab,'task','claim','audit-locked')
    for _ in range(100):
        if sql("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=0 AND objid=987654321 AND NOT granted")=='1':break
        time.sleep(.01)
    else:raise AssertionError('Mutation did not reach its audit insert')
    started=time.monotonic()
    assert ab('task','show','audit-rollback')['task']['title']=='Committed audit'
    ab('task','edit','audit-rollback','--title','Independent audit')
    assert time.monotonic()-started<2 and not blocked.done(), 'Unrelated writes serialized behind audit/actor lock'
    assert blocked.result()['task']['assignee_id']=='alpha'
assert locker.wait(timeout=10)==0
sql('DROP TRIGGER hold_audit_fixture ON board_action_events; DROP FUNCTION hold_audit_fixture()')
print('API-only CLI, ownership concurrency, lifecycle, attribution, rollback, scoped audit and pagination passed')

# Heartbeats do not create durable audit noise.
heartbeat_audit=sql("SELECT (SELECT count(*) FROM agents_versions)||','||(SELECT count(*) FROM board_action_events)")

# Heartbeats do not renew, and freshness is independent of a short expired lease.
lease=ab('task','show','expiring')['task']['claim_expires_at']
ab('agent','heartbeat','--status','busy','--task','expiring','--backend','herdr',actor='beta',harness='claude',model='model-heartbeat')
assert ab('task','show','expiring')['task']['claim_expires_at']==lease
assert not ab('agent','show','beta')['agent']['stale']
assert sql("SELECT (SELECT count(*) FROM agents_versions)||','||(SELECT count(*) FROM board_action_events)")==heartbeat_audit
ab('agent','heartbeat','--status','busy','--task','expiring',code=4)
ab('agent','heartbeat','--status','busy','--task','missing',actor='beta',harness='claude',code=4)
ab('task','create','--id','fresh-expired','--title','Fresh agent with expired lease')
ab('--ttl','100ms','task','claim','fresh-expired',actor='beta',harness='claude')
ab('agent','heartbeat','--status','busy','--task','fresh-expired',actor='beta',harness='claude')
time.sleep(0.2)
assert not ab('agent','show','beta')['agent']['stale']
assert ab('task','show','fresh-expired')['task']['claim_expired']
human=subprocess.run([os.environ['AB_BINARY'],'task','show','fresh-expired'],env=cli_env,capture_output=True,text=True,timeout=10)
assert human.returncode==0 and 'expired=true' in human.stdout
assert ab('--stale-after','100ms','agent','show','beta')['agent']['stale']

# Durable inbox/thread semantics and recipient-only first acknowledgement.
message=ab('msg','send','--to','beta','--task','expiring','--body','Direct context')['message']
comment=ab('msg','send','--task','expiring','--body','Shared comment')['message']
assert message['read_at'] is None and comment['recipient_id'] is None
inbox=ab('msg','list','--unread',actor='beta',harness='claude')['messages']
assert [m['id'] for m in inbox]==[message['id']]
assert ab('msg','list')['messages']==[]
assert len(ab('msg','list','--task','expiring')['messages'])==2
ab('msg','read',str(message['id']),code=4)
ab('msg','read',str(comment['id']),actor='beta',harness='claude',code=4)
first=ab('msg','read',str(message['id']),actor='beta',harness='claude',model='read-model')['message']
assert first['read_model']=='read-model' and first['read_at']
again=ab('msg','read',str(message['id']),actor='beta',harness='claude',model='different')['message']
assert first==again
assert sql(f"SELECT count(*) FROM messages_versions WHERE version_source_id={message['id']} AND version_action_name='acknowledge'")=='1'
assert sql(f"SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Board.Resources.Message' AND record_id='{message['id']}'")=='2'
assert ab('msg','list','--unread',actor='beta',harness='claude')['messages']==[]
ab('msg','send','--to','unknown','--body','Invalid destination',code=2)
before=sql('SELECT count(*) FROM messages')
for body in [{'body':'Empty destination'},{'task_id':'unknown','body':'Unknown task'},{'recipient_id':'unknown','body':'Unknown peer'},{'recipient_id':'beta','body':''}]:
    assert api('messages',json.dumps(body).encode())[0]==422
    assert sql('SELECT count(*) FROM messages')==before

# A message failure cannot partially commit handoff ownership or its event.
sql("CREATE FUNCTION reject_test_message() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.body='reject-handoff' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Synthetic message rejected'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER fixture_message_guard BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION reject_test_message()')
prior=ab('task','show','expiring')
ab('task','handoff','expiring','--to','alpha','--body','reject-handoff',actor='beta',harness='claude',code=2)
assert ab('task','show','expiring')==prior
handoff=ab('task','handoff','expiring','--to','alpha','--body','Ready for peer',actor='beta',harness='claude')
assert handoff['task']['status']=='assigned' and handoff['task']['claim_expires_at'] is None
assert handoff['message_id'] in [m['id'] for m in ab('msg','list')['messages']]
ab('task','claim','expiring',actor='beta',harness='claude',code=4)
ab('task','claim','expiring')

import select
import signal
class Watch:
    def __init__(self,*args,url=None):
        env=dict(cli_env)
        if url:env['AGENTBOARD_URL']=url
        self.process=subprocess.Popen([os.environ['AB_BINARY'],'--json',*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        self.buffer=b''
    def wait(self,predicate,timeout=4):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            while b'\n' in self.buffer:
                line,self.buffer=self.buffer.split(b'\n',1)
                snapshot=json.loads(line)
                assert snapshot['kind']=='snapshot' and snapshot['next_cursor'] is None
                if predicate(snapshot): return snapshot
            ready,_,_=select.select([self.process.stdout],[],[],max(0,deadline-time.monotonic()))
            if ready:
                data=os.read(self.process.stdout.fileno(),65536)
                assert data, ('watch closed',self.process.poll(),self.process.stderr.read())
                self.buffer+=data
        return None
    def close(self):
        self.process.send_signal(signal.SIGINT)
        assert self.process.wait(timeout=3)==0
        self.process.stdout.close(); self.process.stderr.close()

watch=Watch('task','watch','--repo','watch-fixture')
assert watch.wait(lambda s:s['reason']=='initial' and s['tasks']==[])
ab('task','create','--id','watched','--title','Visible by notification','--repo','watch-fixture')
assert watch.wait(lambda s:s['reason']=='change' and any(t['id']=='watched' for t in s['tasks']),timeout=3), 'No committed push before fallback'
# Failed task/event transaction cannot produce a change notification.
ab('task','update','watched','--body','reject-fixture',code=2)
assert watch.wait(lambda s:s['reason']=='change',timeout=1) is None
# Killing only the dedicated listener connection forces reconnect and reloading.
assert sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='agentboard-board-listener' AND query LIKE 'LISTEN%' AND pid<>pg_backend_pid()")=='1'
sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='agentboard-board-listener' AND query LIKE 'LISTEN%' AND pid<>pg_backend_pid()")
assert watch.wait(lambda s:s['reason']=='reconnect',timeout=4), 'No listener reconnect reload'
watch.close()

# Snapshots are complete even when ordinary reads would need multiple pages.
def create_large(index):
    return ab('task','create','--id','large-'+str(index),'--title','Large snapshot '+str(index),'--repo','large-fixture','--priority','9')
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    list(pool.map(create_large,range(121)))
large=Watch('task','list','--watch','--limit','1','--repo','large-fixture')
ab('task','create','--id','large-race','--title','Startup race','--repo','large-fixture','--priority','9')
assert large.wait(lambda s:len(s['tasks'])==122 and any(t['id']=='large-race' for t in s['tasks']),timeout=4)
large.close()

# Stream admission is bounded; close frees slots on the next fallback write.
streams=[]
for _ in range(5):
    request=urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/tasks/watch',headers={'Accept':'application/x-ndjson','X-Agentboard-Agent':'stream-fixture'})
    response=urllib.request.urlopen(request,timeout=10)
    assert json.loads(response.readline())['kind']=='snapshot'
    streams.append(response)
try:
    urllib.request.urlopen(request,timeout=10)
    raise AssertionError('Sixth stream admitted')
except urllib.error.HTTPError as rejected:
    assert rejected.code==429 and int(rejected.headers['Retry-After'])>0 and rejected.headers['Cache-Control']=='no-store'
for response in streams: response.close()
time.sleep(6)
with urllib.request.urlopen(request,timeout=10) as response:
    assert json.loads(response.readline())['kind']=='snapshot'

# Explicit command flags replace invalid duration and URL environment settings.
override_env=dict(cli_env,AGENTBOARD_URL='https://invalid.example',AGENTBOARD_CLAIM_TTL='broken',AGENTBOARD_STALE_AFTER='broken')
result=subprocess.run([os.environ['AB_BINARY'],'--url',os.environ['AGENTBOARD_URL'],'--ttl','2h','--stale-after','10m','--json','task','list'],env=override_env,capture_output=True,text=True)
assert result.returncode==0 and json.loads(result.stdout)['tasks']
# Schema compatibility fails without the CLI attempting to migrate.
sql('DELETE FROM board_schema')
ab('task','list',code=1)
assert sql('SELECT count(*) FROM board_schema')=='0'
sql('INSERT INTO board_schema(id,version) VALUES(1,6)')
print('Heartbeats, messages, atomic handoff, commit-only snapshots, listener reconnect and stream cleanup passed')

from datetime import datetime, timedelta, timezone
import copy
from pathlib import Path
now=datetime.now(timezone.utc).replace(microsecond=0)
iso=lambda stamp:stamp.isoformat().replace('+00:00','Z')
report5=json.loads(Path(os.environ['QUOTA_FIXTURES'],'schema5.json').read_text())
report5['generatedAt']=iso(now)
created=ab('quota','push',stdin=json.dumps(report5))
assert not created['idempotent'] and created['report']['schema_version']==5
retry=ab('quota','push',model='new-model',stdin=json.dumps(report5,sort_keys=True))
assert retry['idempotent'] and retry['report']==created['report']
observations=ab('quota','list')['quota']
assert len(observations)==1 and observations[0]['account_key']=='default' and not observations[0]['observation_stale']
share=next(w for w in observations[0]['windows'] if w['id']=='share')
assert share['share_of']=='week' and 'percent_remaining' not in share
scope=observations[0]['scopes'][0]
assert scope['runway']=={'status':'through_reset'} and scope['selection']['spend_priority']==12
assert json.loads(sql('SELECT raw FROM quota_reports WHERE id='+str(created['report']['id'])))==report5

report6=json.loads(Path(os.environ['QUOTA_FIXTURES'],'schema6.json').read_text())
report6['generatedAt']=iso(now+timedelta(seconds=1))
input_file=Path(os.environ['TEST_TMPDIR'],'synthetic-quota6.json');input_file.write_text(json.dumps(report6))
ab('quota','push','--file',str(input_file))
work=ab('quota','list','--provider','codex','--account','work')['quota'][0]
assert work['account_keys']==['work','work-alias'] and work['state']['untrusted_window_ids']==['inherited']
assert any(s.get('bound_conflict') and s['status']=='unknown' for s in work['scopes'])
assert any(s['runway']['status']=='exhausted_now' for s in work['scopes'])
page=ab('quota','list','--limit','1')
keys=[]
while True:
    keys += [(q['provider'],q['account_key']) for q in page['quota']]
    if page['next_cursor'] is None:break
    page=ab('quota','list','--limit','1','--cursor',page['next_cursor'])
assert len(keys)==len(set(keys))==3

counts=lambda:sql("SELECT (SELECT count(*) FROM quota_reports)||','||(SELECT count(*) FROM quota_observations)||','||(SELECT count(*) FROM quota_windows)||','||(SELECT count(*) FROM quota_scopes)")
before=counts()
invalids=[]
unsupported=copy.deepcopy(report6);unsupported['schemaVersion']=7;invalids.append(unsupported)
duplicate=copy.deepcopy(report6);duplicate['providers'].append(duplicate['providers'][0]);invalids.append(duplicate)
badpercent=copy.deepcopy(report6);badpercent['providers'][0]['windows'][0]['percentRemaining']=101;invalids.append(badpercent)
badwindow=copy.deepcopy(report6);badwindow['providers'][0]['windows'].append(badwindow['providers'][0]['windows'][0]);invalids.append(badwindow)
for invalid in invalids:
    ab('quota','push',stdin=json.dumps(invalid),code=2)
    assert counts()==before
# Rollback is checked after the real report/provider insert, at the child scope.
sql("CREATE FUNCTION reject_test_quota() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.scope='reject-quota' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Synthetic scope rejected'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER fixture_quota_guard BEFORE INSERT ON quota_scopes FOR EACH ROW EXECUTE FUNCTION reject_test_quota()')
rejected=copy.deepcopy(report6);rejected['generatedAt']=iso(now+timedelta(seconds=2));rejected['providers'][0]['quotaSemantics']['effectiveAvailability'][0]['scope']='reject-quota'
ab('quota','push',stdin=json.dumps(rejected),code=2)
assert counts()==before
older=copy.deepcopy(report6);older['generatedAt']=iso(now-timedelta(hours=1));older['providers'][0]['windows'][0]['percentRemaining']=50
ab('quota','push',stdin=json.dumps(older))
assert ab('quota','list','--account','work')['quota'][0]['report_id']==work['report_id']

from liveview_client import LiveView, contains
quota_view=LiveView(os.environ['AGENTBOARD_URL'],'/quota?account=work')
assert contains(quota_view.initial,'Latest quota by provider') and contains(quota_view.initial,'Uncertain scope bounds')
assert not contains(quota_view.initial,'Quota details') and not contains(quota_view.initial,'Reported remaining')
quota_view.send(['1','2',quota_view.topic,'event',{'type':'click','event':'open_quota','value':{'id':str(work['id'])}}])
opened=quota_view.wait(lambda e:e[3]=='phx_reply' and e[1]=='2')
assert opened and opened[4]['status']=='ok' and contains(opened,'quota-detail-dialog') and contains(opened,'scope exhausted') and contains(opened,'Reported remaining'),opened
quota_view.send(['1','3',quota_view.topic,'event',{'type':'click','event':'close_quota','value':{}}])
closed=quota_view.wait(lambda e:e[3]=='phx_reply' and e[1]=='3')
assert closed and closed[4]['status']=='ok',closed
quota_view.send(['1','4',quota_view.topic,'event',{'type':'click','event':'open_quota','value':{'id':'999999'}}])
missing=quota_view.wait(lambda e:e[3]=='phx_reply' and e[1]=='4')
assert missing and missing[4]['status']=='ok' and not contains(missing,'quota-detail-dialog'),missing
quota_view.close()

quota_watch=Watch('quota','list','--watch','--account','work')
assert quota_watch.wait(lambda s:s['topic']=='ab_quota' and len(s['quota'])==1)
empty=copy.deepcopy(report6);empty['generatedAt']=iso(now+timedelta(seconds=3));empty['providers']=empty['providers'][:1]
empty['providers'][0]['windows']=[]
empty['providers'][0]['state']={'status':'unavailable','stale':True,'error':'Synthetic unavailable observation'}
empty['providers'][0]['quotaSemantics']={'status':'unknown','effectiveAvailability':[]}
ab('quota','push',stdin=json.dumps(empty))
assert quota_watch.wait(lambda s:s['reason']=='change' and s['quota'][0]['windows']==[] and s['quota'][0]['scopes']==[],timeout=3)
quota_watch.close()
latest=ab('quota','list','--account','work')['quota'][0]
assert latest['windows']==[] and latest['scopes']==[] and latest['state']['status']=='unavailable'
assert ab('quota','list','--account','sandbox')['quota'][0]['windows']

# The actual HTTP stream is interrupted, then reloads writes missed offline.
from watch_proxy import WatchProxy
proxy=WatchProxy(os.environ['AGENTBOARD_URL'])
task_reconnect=Watch('task','watch','--repo','offline-fixture',url=proxy.url)
quota_reconnect=Watch('quota','watch','--account','work',url=proxy.url)
assert task_reconnect.wait(lambda s:s['reason']=='initial')
assert quota_reconnect.wait(lambda s:s['reason']=='initial')
proxy.disconnect()
ab('task','create','--id','offline-write','--title','Committed during reconnect','--repo','offline-fixture')
recovered=copy.deepcopy(empty);recovered['generatedAt']=iso(now+timedelta(seconds=4));recovered['providers'][0]['state']['error']='Recovered quota stream fixture'
ab('quota','push',stdin=json.dumps(recovered))
proxy.resume()
assert task_reconnect.wait(lambda s:s['reason']=='reconnect' and any(t['id']=='offline-write' for t in s['tasks']),timeout=5)
assert quota_reconnect.wait(lambda s:s['reason']=='reconnect' and s['quota'][0]['state'].get('error')=='Recovered quota stream fixture',timeout=5)
task_reconnect.close();quota_reconnect.close()
proxy.close()
print('Quota schemas 5/6, canonical retries, raw retention, rollback, semantics, ordering and snapshot visibility passed')

from liveview_client import LiveView, contains
base=os.environ['AGENTBOARD_URL']
injected='<script>alert("fixture")</script>'
ab('task','create','--id','escaped-ui','--title',injected,'--description',injected,'--issue','https://github.com/carverauto/agentboard/issues/1')
counts_before=sql('SELECT count(*) FROM task_events')
unread=ab('msg','send','--to','beta','--body','Dashboard must leave unread')['message']
reads_before=sql('SELECT json_agg(row_to_json(m) ORDER BY id) FROM messages m')
board=LiveView(base,'/')
assert contains(board.initial,'&lt;script&gt;') and not contains(board.initial,injected), 'Task title is not escaped at the UI boundary'
assert contains(board.initial,'https://github.com/carverauto/agentboard/issues/1')
for route,text in [('/tasks/escaped-ui','Task history'),('/agents','codex'),('/messages?to=beta&unread=true','Dashboard must leave unread'),('/quota','Unavailable')]:
    view=LiveView(base,route)
    assert contains(view.initial,text),(route,view.initial)
    if route == '/quota':
        current=ab('quota','list','--account','work')['quota'][0]
        view.send(['1','2',view.topic,'event',{'type':'click','event':'open_quota','value':{'id':str(current['id'])}}])
        detail=view.wait(lambda e:e[3]=='phx_reply' and e[1]=='2')
        assert detail and contains(detail,'Recovered quota stream fixture'),detail
    view.close()
assert sql('SELECT count(*) FROM task_events')==counts_before, 'Read-only dashboard mutated history'
assert sql('SELECT json_agg(row_to_json(m) ORDER BY id) FROM messages m')==reads_before, 'Dashboard acknowledged or modified messages'
ab('task','create','--id','ui-push','--title','UI push fixture')
assert board.wait(lambda event:event[3]=='diff' and contains(event[4],'UI push fixture'),timeout=5)
# Disable only invalidation triggers to verify CLI writes through the fallback.
sql('ALTER TABLE tasks DISABLE TRIGGER tasks_notify; ALTER TABLE task_events DISABLE TRIGGER task_events_notify')
ab('task','create','--id','ui-fallback','--title','UI fallback fixture')
assert board.wait(lambda event:event[3]=='diff' and contains(event[4],'UI fallback fixture'),timeout=5.5)
sql('ALTER TABLE tasks ENABLE TRIGGER tasks_notify; ALTER TABLE task_events ENABLE TRIGGER task_events_notify')
# Documentation is an immutable public artifact contract; board reads omit content.
ab('task','create','--id','documented','--title','Documented feature')
ab('task','claim','documented')
from pathlib import Path
doc_file=Path(os.environ['TEST_TMPDIR'])/'diagram.html'
doc_html='<!doctype html><html><head><title>Diagram</title></head><body><button id="run">Run</button><script>document.body.dataset.ready="yes"</script></body></html>'
doc_file.write_text(doc_html)
doc_args=('doc','push','documented','--file',str(doc_file),'--title','Feature architecture','--pr','https://github.com/carverauto/agentboard/pull/3','--commit','a'*40)
prior=ab('task','show','documented')
ab(*doc_args,actor='beta',harness='claude',code=4)
assert ab('task','show','documented')==prior
document=ab(*doc_args)
assert not document['idempotent']
d=document['document']
assert d['task_id']=='documented' and d['source_agent_id']=='alpha' and d['harness']=='codex' and d['source_revision']=='a'*40
assert 'html' not in d and d['viewer_url']==f"/documents/{d['id']}"
assert ab(*doc_args)['idempotent']
after=ab('task','show','documented')
assert after['task']['revision']==prior['task']['revision']+1
assert len(after['events'])==len(prior['events'])+1 and after['documents']==[d]
assert ab('doc','list','documented')['documents']==[d]
assert doc_html not in json.dumps(ab('task','list'))
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Evidence.Resources.Document' AND data->>'html' IS NOT NULL")=='0'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Evidence.Resources.QuotaReport' AND data->>'raw' IS NOT NULL")=='0'
assert sql("SELECT count(*) FROM board_action_events WHERE changed_attributes ? 'html' OR changed_attributes ? 'raw'")=='0'
assert doc_html not in sql("SELECT changes FROM tasks_versions WHERE version_source_id='documented'")
base=os.environ['AGENTBOARD_URL']
with urllib.request.urlopen(base+d['viewer_url']) as r:
    wrapper=r.read().decode()
    assert 'sandbox="allow-scripts allow-downloads"' in wrapper and doc_html not in wrapper
with urllib.request.urlopen(base+f"/documents/{d['id']}/html") as r:
    assert r.read().decode()==doc_html
    csp=r.headers['Content-Security-Policy']
    assert "sandbox allow-scripts allow-downloads" in csp and "allow-same-origin" not in csp and "connect-src 'none'" in csp
    assert r.headers['X-Content-Type-Options']=='nosniff' and r.headers['Cache-Control']=='no-store'
with urllib.request.urlopen(base+d['download_url']) as r:
    assert r.headers['Content-Disposition'].startswith('attachment;') and r.read().decode()==doc_html
for invalid in [dict(kind='archify',title='Bad',html='plain text'),dict(kind='archify',title='Big',html='<html>'+('x'*(2<<20))+'</html>'),dict(kind='archify',title='Nul',html='<html>\x00</html>')]:
    assert api('tasks/documented/documents',json.dumps(invalid).encode())[0]==422
assert ab('task','show','documented')==after
assert sql("SELECT count(*) FROM task_documents WHERE task_id='documented'")=='1'
immutable=subprocess.run([os.environ['FIXTURE_PSQL'],'-v','ON_ERROR_STOP=1','-c',f"UPDATE task_documents SET title='tampered' WHERE id={d['id']}"],capture_output=True,text=True)
assert immutable.returncode!=0 and 'append-only' in immutable.stderr
ab('task','update','documented','--status','done')
assert ab(*doc_args)['idempotent']
ab('doc','push','documented','--file',str(doc_file),'--title','New version',code=4)
assert ab('doc','list','documented')['documents']==[d]
ab('task','create','--id','docs-full','--title','Documentation limit fixture')
ab('task','claim','docs-full')
sql("INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest) SELECT 'docs-full','alpha','fixture','codex','archify','Fixture '||i,'<html>Fixture</html>',lpad(i::text,64,'0') FROM generate_series(1,100) i")
full_before=ab('task','show','docs-full')
ab('doc','push','docs-full','--file',str(doc_file),'--title','Over limit',code=2)
assert ab('task','show','docs-full')==full_before
ab('task','create','--id','docs-expired','--title','Expired documentation claim')
ab('--ttl','100ms','task','claim','docs-expired')
time.sleep(.15)
expired_before=ab('task','show','docs-expired')
ab('doc','push','docs-expired','--file',str(doc_file),'--title','Expired upload',code=4)
assert ab('task','show','docs-expired')==expired_before
print('Documentation API/CLI ownership, retry, persistence, task links and sandbox serving passed')

# Throttling happens before a valid task write, with health/browser bypass.
for _ in range(2001):
    status,_=api('tasks',b'{broken',actor='rate-probe')
    if status==429:break
    assert status==400
else:raise AssertionError('API IP limit did not bound requests')
status,error=api('tasks',b'{"id":"throttled-task","title":"Must not commit"}')
assert status==429 and error['error']['code']=='rate_limited'
assert sql("SELECT count(*) FROM tasks WHERE id='throttled-task'")=='0'
with urllib.request.urlopen(base+'/health/live',timeout=10) as response:assert response.status==200
with urllib.request.urlopen(base+'/',timeout=10) as response:assert response.status==200
# Actual database outage: liveness stays healthy; UI retains previous data with an unavailable label.
import sys
prefix=[sys.executable,str(Path(os.environ['FIXTURE_DATA']).parent/'as_user.py')] if os.geteuid()==0 else []
subprocess.run(prefix+[os.environ['FIXTURE_CONTROL'],'-D',os.environ['FIXTURE_DATA'],'-m','immediate','stop'],check=True,capture_output=True)
with urllib.request.urlopen(base+'/health/live',timeout=10) as response:assert json.load(response)['status']=='live'
try:
    urllib.request.urlopen(base+'/health/ready',timeout=10)
    raise AssertionError('Ready despite database outage')
except urllib.error.HTTPError as response:assert response.code==503
assert board.wait(lambda event:event[3]=='diff' and contains(event[4],'Board unavailable'),timeout=7), ('No unavailable UI state after DB outage',board.events[-3:])
board.close()
print('LiveView routes, escaping, read-only inspection, push/fallback updates and database outage behavior passed')
