"""Actual captain HTTP/LiveView, normal-role PostgreSQL and AshOban worker boundaries."""
import concurrent.futures
import http.cookiejar
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from liveview_client import LiveView, Page, contains

base=os.environ['AGENTBOARD_URL']
token=os.environ['AGENTBOARD_CAPTAIN_TOKEN']
env=dict(os.environ,AGENT_ID='archive-worker',AGENTBOARD_MODEL='fixture-model',AGENTBOARD_HARNESS='codex')
def ab(*args):
    p=subprocess.run([os.environ['AB_BINARY'],'--json',*args],env=env,capture_output=True,text=True,timeout=15)
    assert p.returncode==0,(args,p.stderr)
    return json.loads(p.stdout)
def sql(query):return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',query],text=True).strip()
def api(path,data=None,method=None,authorized=True):
    headers={'Content-Type':'application/json'}
    if authorized:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+'/api/v1/'+path,data=json.dumps(data).encode() if data is not None else None,method=method,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=15) as r:return r.status,json.load(r)
    except urllib.error.HTTPError as r:return r.code,json.load(r)
def event(view,name,value):
    ref=str(len(view.events)+10)
    view.send(['1',ref,view.topic,'event',{'type':'click','event':name,'value':value}])
    response=view.wait(lambda e:e[1]==ref and e[3]=='phx_reply')
    assert response and response[4]['status']=='ok',response
    return response

assert sql('SELECT rolsuper FROM pg_roles WHERE rolname=current_user')=='f'
ab('agent','register')
for id in ['old-done','restored','recent','active']:
    ab('task','create','--id',id,'--title','Completed fixture '+id,'--repo','fixture/repo')
    ab('task','claim',id)
    if id!='active':ab('task','update',id,'--status','done','--body','Completed fixture evidence')
sql("UPDATE tasks SET updated_at=clock_timestamp()-interval '10 days' WHERE id IN ('old-done','restored')")
before=ab('task','show','old-done')
assert not api('settings/archive')[1]['enabled']
assert api('tasks/old-done/archive',{'revision':0},authorized=False)[0]==403
assert api('tasks/active/archive',{'revision':0})[0]==409
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    outcomes=list(pool.map(lambda _:api('tasks/old-done/archive',{'revision':0}),range(4)))
assert all(status==200 for status,_ in outcomes),outcomes
assert sql("SELECT count(*) FROM task_archives_versions WHERE version_source_id='old-done'")=='1'
after=ab('task','show','old-done')
assert after['task']['status']=='done' and after['task']['assignee_id']==before['task']['assignee_id']
assert after['task']['revision']==before['task']['revision'] and after['events']==before['events'] and after['documents']==before['documents']
assert after['archive']['archived_at']
assert 'old-done' in [t['id'] for t in ab('task','list')['tasks']], 'Canonical PR inventory lost archived task'
assert 'old-done' not in [t['id'] for t in api('tasks?archive=active')[1]['tasks']]
assert [t['id'] for t in api('tasks?archive=archived')[1]['tasks']]==['old-done']
board=LiveView(base,'/')
assert not contains(board.initial,'Completed fixture old-done') and contains(board.initial,'Completed fixture restored')
assert contains(event(board,'archive_task',{'id':'recent','archived':'true','revision':'0'}),'Unlock captain controls')
assert api('tasks/recent')[1]['archive']['archived_at'] is None
board.close()
archive=LiveView(base,'/archive');assert contains(archive.initial,'Completed fixture old-done');archive.close()
# Real CSRF-protected login and signed session; declare no agent as a captain.
jar=http.cookiejar.CookieJar();opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
with opener.open(base+'/settings') as r:page=Page();page.feed(r.read().decode())
try:opener.open(urllib.request.Request(base+'/settings/unlock',data=urllib.parse.urlencode({'token':token}).encode()))
except urllib.error.HTTPError as r:assert r.code==403
else:raise AssertionError('CSRF-less captain login accepted')
with opener.open(urllib.request.Request(base+'/settings/unlock',data=urllib.parse.urlencode({'token':token,'_csrf_token':page.csrf}).encode())) as r:assert r.status==200
cookie='; '.join(c.name+'='+c.value for c in jar)
task=LiveView(base,'/tasks/old-done',cookie)
assert contains(task.initial,'Restore to Done')
event(task,'archive_task',{'id':'old-done','archived':'false','revision':'1'})
assert api('tasks/old-done')[1]['archive']['archived_at'] is None
task.close()
assert api('tasks/old-done/archive',{'revision':1})[0]==409, 'Stale archive after restore accepted'
assert api('tasks/restored/archive',{'revision':0})[0]==200
assert api('tasks/restored/restore',{'revision':1})[0]==200
# Configure through the connected settings form, then force only fixture due-time.
view=LiveView(base,'/settings',cookie)
event(view,'save',{'enabled':'true','retention_days':'7','interval_hours':'1'})
policy=api('settings/archive')[1];assert policy['enabled'] and policy['interval_hours']==1
assert api('settings/archive',dict(enabled=False,retention_days=7,interval_hours=24,revision=1),method='PATCH')[0]==409
assert api('settings/archive',dict(enabled=True,retention_days=0,interval_hours=1,revision=policy['revision']),method='PATCH')[0]==422
view.close()
sql("UPDATE tasks SET updated_at=clock_timestamp()-interval '10 days' WHERE id='recent'")
sql("UPDATE archive_policy SET next_run_at=clock_timestamp()-interval '1 minute' WHERE id='board'")
def enqueue():
    expression='job = AshOban.schedule(Agentboard.Housekeeping.Policy, :archive_sweep); IO.puts("ARCHIVE_JOB_ID=" <> Integer.to_string(job.id))'
    p=subprocess.run([os.environ['ARCHIVE_RELEASE_BIN'],'rpc',expression],capture_output=True,text=True,timeout=20)
    assert p.returncode==0,(p.stderr,p.stdout)
    job_id=int(next(line.split('=',1)[1] for line in p.stdout.splitlines() if line.startswith('ARCHIVE_JOB_ID=')))
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        state=sql(f'SELECT state FROM oban_jobs WHERE id={job_id}')
        if state=='completed':return
        assert state not in ['discarded','cancelled'],(job_id,state)
        time.sleep(.1)
    raise AssertionError(f'Archive job {job_id} did not complete: {state}')
enqueue()
deadline=time.monotonic()+20
while time.monotonic()<deadline:
    if api('tasks/recent')[1]['archive']['archived_at']:break
    time.sleep(.1)
else:raise AssertionError('AshOban archive sweep did not run')
assert api('tasks/restored')[1]['archive']['archived_at'] is None, 'Restored card prematurely archived'
assert api('tasks/active')[1]['archive']['archived_at'] is None
assert sql("SELECT count(*) FROM housekeeping_events WHERE record_id='recent'")=='1'
enqueue()
assert sql("SELECT count(*) FROM housekeeping_events WHERE record_id='recent'")=='1', 'Duplicate scheduled job duplicated archive'
policy=api('settings/archive')[1]
assert api('settings/archive',dict(enabled=False,retention_days=7,interval_hours=24,revision=policy['revision']),method='PATCH')[0]==200
assert api('tasks/recent/restore',{'revision':1})[0]==200
sql("UPDATE task_archives SET restored_at=clock_timestamp()-interval '10 days' WHERE id='recent'")
enqueue()
assert api('tasks/recent')[1]['archive']['archived_at'] is None, 'Disabled policy ignored by queued job'
assert sql('SELECT count(*) FROM housekeeping_events')!='0'
for table in ['housekeeping_events','task_archives_versions','archive_policy_versions']:
    p=subprocess.run([os.environ['FIXTURE_PSQL'],'-v','ON_ERROR_STOP=1','-c',f'DELETE FROM {table}'],capture_output=True,text=True)
    assert p.returncode!=0 and 'append-only' in p.stderr
print('Captain authorization/CSRF, concurrent idempotency, archive/restore CAS, canonical PR inventory, immutable history and actual AshOban scheduling passed')
