"""Availability admission at the packaged HTTP/CLI/PG boundary.

Invented actors and capability. This fixture owns policy precedence, authorization,
expiry, admission and eligible fanout; cooperation owns receipt lifecycle proof.
"""
import concurrent.futures
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from liveview_client import LiveView, contains

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-availability-capability-0123456789'
TOKEN = Path(os.environ['TEST_TMPDIR'])/'captain.token'
TOKEN.write_text(CAPTAIN+'\n')
TOKEN.chmod(0o600)
BASE = dict(os.environ, AGENT_ID='routing-captain', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex', AGENTBOARD_CAPTAIN_TOKEN_FILE=str(TOKEN))

def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',query],text=True).strip()

def api(path,data=None,actor='routing-captain',harness='codex',captain=False,status=200):
    headers={'X-Agentboard-Agent':actor,'X-Agentboard-Model':'fixture-model','X-Agentboard-Harness':harness,'Content-Type':'application/json'}
    if captain: headers['Authorization']='Bearer '+CAPTAIN
    req=urllib.request.Request(URL+'/api/v1/'+path,data=json.dumps(data).encode() if data is not None else None,headers=headers)
    try: result=urllib.request.urlopen(req,timeout=10)
    except urllib.error.HTTPError as e: result=e
    body=json.load(result)
    assert result.status==status,(path,result.status,body)
    return body

def ab(*args, actor='routing-captain', harness='codex',code=0,env=None):
    result=subprocess.run([os.environ['AB_BINARY'],'--json',*args],env=dict(BASE,AGENT_ID=actor,AGENTBOARD_HARNESS=harness,**(env or {})),capture_output=True,text=True,timeout=15)
    assert result.returncode==code,(args,result.returncode,result.stdout,result.stderr)
    assert CAPTAIN not in result.stdout+result.stderr,'Capability leaked'
    return json.loads(result.stderr if code else result.stdout)

def policy(**fields):return api('availability',fields,captain=True)['policy']
def show(agent):return api('agents/'+agent)['agent']
def task(id):return api('tasks',{'id':id,'title':'Availability fixture','repo':'fixture/availability'})['task']

rpc=subprocess.run([os.environ['AGENTBOARD_BIN'],'rpc',f'Application.put_env(:agentboard, :captain_token, "{CAPTAIN}")'],capture_output=True,text=True,timeout=30)
assert rpc.returncode==0,(rpc.stdout,rpc.stderr)
for agent,harness,model in [('routing-captain','codex','fixture-model'),('reserved-a','claude','fixture-model'),('reserved-b','claude','fixture-model'),('unavailable','pi','glm-5'),('worker-active','codex','fixture-model'),('claude-active','claude','fixture-model'),('claude-oos','claude','fixture-model')]:
    env=dict(BASE,AGENT_ID=agent,AGENTBOARD_HARNESS=harness,AGENTBOARD_MODEL=model)
    p=subprocess.run([os.environ['AB_BINARY'],'--json','agent','register','--name',agent],env=env,capture_output=True,text=True,timeout=15)
    assert p.returncode==0,(p.stdout,p.stderr)
assert show('reserved-a')['availability']['state']=='active'
assert api('availability')['policies']==[]
task('legacy-pending')
api('tasks/legacy-pending/assign',{'to':'reserved-a'})
# Attribution and caller-supplied privileged fields cannot confer authority.
api('availability',{'harness':'claude','state':'reserved','reason':'Named work only'},status=403)
api('availability',{'harness':'claude','state':'reserved','reason':'Named work only','availability_admin':True},captain=True,status=422)
reserved=ab('agent','availability','set','--selector-harness','claude','--state','reserved','--reason','Named captain assignments')['policy']
assert show('reserved-a')['availability']['source']==reserved['id']
assert show('reserved-b')['availability']['state']=='reserved'
api('tasks/legacy-pending/claim',{},actor='reserved-a',harness='claude',status=409)
assert api('tasks/legacy-pending')['task']['status']=='assigned'
ab('agent','register',actor='reserved-a',harness='claude')
assert show('reserved-a')['availability']['state']=='reserved'
task('reserved-open')
before=api('tasks/reserved-open')
err=ab('task','claim','reserved-open',actor='reserved-a',harness='claude',code=4)
assert 'availability reserved' in err['error']['message']
assert api('tasks/reserved-open')==before
api('tasks/reserved-open/assign',{'to':'reserved-a'},status=409)
assert api('tasks/reserved-open')==before
assigned=ab('task','assign','reserved-open','--to','reserved-a','--captain')['task']
assert assigned['assignment_authorized'] and assigned['assigner_id']=='routing-captain'
assert ab('task','claim','reserved-open',actor='reserved-a',harness='claude')['task']['assignee_id']=='reserved-a'
task('reserved-reclaim')
api('tasks/reserved-reclaim/claim',{'ttl_seconds':0.05},actor='worker-active')
time.sleep(0.08)
api('tasks/reserved-reclaim/reclaim',{},actor='reserved-b',harness='claude',status=409)
assert api('tasks/reserved-reclaim')['task']['assignee_id']=='worker-active'
# Current work remains renewable/progressable after restriction, without opening new admission.
policy(agent_id='reserved-a',state='out_of_service',reason='Fixture unavailable')
ab('task','renew','reserved-open',actor='reserved-a',harness='claude')
ab('task','update','reserved-open','--status','blocked','--body','Retained owner disposition',actor='reserved-a',harness='claude')
task('unavailable-target')
policy(agent_id='unavailable',state='out_of_service',reason='Temporary maintenance')
for captain in [False,True]:api('tasks/unavailable-target/assign',{'to':'unavailable'},captain=captain,status=409)
api('tasks/unavailable-target/claim',{},actor='unavailable',harness='pi',status=409)
api('tasks/reserved-open/handoff',{'to':'unavailable','note':'Cannot route'},actor='reserved-a',harness='claude',captain=True,status=409)
# Exact-agent active overrides restricted defaults; model specificity is deterministic.
policy(agent_id='reserved-a',state='active',reason='Explicit override')
policy(model_pattern='glm-*',state='out_of_service',reason='Model outage')
policy(agent_id='unavailable',state='active',reason='Explicit exemption')
assert show('unavailable')['availability']['state']=='active'
policy(harness='pi',model_pattern='glm-5',state='reserved',reason='Exact model reservation')
assert show('reserved-a')['availability']['state']=='active'
assert show('reserved-b')['availability']['state']=='reserved'
# Genuine expiry restores an explicit active override and audits once under concurrent reads.
until=(datetime.now(timezone.utc)+timedelta(seconds=0.6)).isoformat()
expiring=policy(agent_id='reserved-b',state='out_of_service',reason='Short maintenance',until=until)
assert show('reserved-b')['availability']['state']=='out_of_service'
time.sleep(0.7)
with concurrent.futures.ThreadPoolExecutor(3) as pool:
    snapshots=list(pool.map(lambda _:show('reserved-b'),range(3)))
assert all(a['availability']['state']=='active' for a in snapshots)
assert sql("SELECT count(*) FROM availability_policies_versions WHERE version_source_id='"+expiring['id']+"' AND version_action_name='expire'")=='1'
assert sql("SELECT changed_by FROM availability_policies WHERE id='"+expiring['id']+"'")=='availability-expiry'
# Expired policy stays active despite its still-reserved harness parent.
api('tasks/unavailable-target/claim',{},actor='reserved-b',harness='claude')
policy(agent_id='reserved-b',state='reserved',reason='Return to named assignments')
# Eligible filtering occurs before keyset pagination; cursors are filter bound.
policy(agent_id='claude-active',state='active',reason='Named active exemption')
policy(agent_id='claude-oos',state='out_of_service',reason='Out of service fixture')
expected=['claude-active','reserved-a']
seen=[];path='agents?harness=claude&availability=active&limit=1'
while True:
    page=api(path);seen.extend(a['id'] for a in page['agents'])
    assert all(a['routing_eligible'] and a['availability']['state']=='active' for a in page['agents'])
    if not page['next_cursor']:break
    path='agents?harness=claude&availability=active&limit=1&cursor='+urllib.parse.quote(page['next_cursor'])
assert seen==expected,seen
orders=ab('msg','broadcast','--task','reserved-open','--body','Eligible work order','--selector-harness','claude')
assert orders['recipient_ids']==expected
assert sql("SELECT count(*) FROM messages WHERE kind='task_order'")==str(len(expected))
api('messages',{'to':'reserved-b','task':'reserved-open','body':'New task','kind':'task_order'},status=409)
ab('msg','send','--to','reserved-b','--body','Ordinary recovery message')
assert ab('msg','list','--to','reserved-b')['messages'][0]['body']=='Ordinary recovery message'
# LiveView exposes policy state and guards a spoofed privileged form event.
view=LiveView(URL,'/agents')
assert contains(view.initial,'Reserved') and contains(view.initial,'Return to named assignments'),view.initial
prior=api('availability')
view.send(['1','policy-spoof',view.topic,'event',{'type':'form','event':'set_availability','value':'agent_id=reserved-b&state=active'}])
assert view.wait(lambda e:e[3]=='phx_reply' and e[1]=='policy-spoof')
assert api('availability')==prior
view.close()
# Admission locks the registered model: a register cannot commit its model
# change while the claim is using that identity. A real row lock makes the
# ordering observable without adding any production injection seam.
task('model-lock-task')
locker=subprocess.Popen([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
locker.stdin.write("BEGIN; SELECT id FROM agents WHERE id='worker-active' FOR UPDATE; SELECT 'ready';\n")
locker.stdin.flush()
while locker.stdout.readline().strip()!='ready':
    assert locker.poll() is None
with concurrent.futures.ThreadPoolExecutor(1) as pool:
    pending=pool.submit(api,'tasks/model-lock-task/claim',{},'worker-active','codex')
    time.sleep(0.2)
    assert not pending.done(),'Claim admission ignored a concurrent identity write lock'
    locker.stdin.write("UPDATE agents SET model='glm-new' WHERE id='worker-active'; COMMIT;\n")
    locker.stdin.flush();locker.stdin.close()
    # The restricted model is in the previously stored glm-* policy.
    try:pending.result()
    except AssertionError as e:
        assert '409' in str(e) and 'out_of_service' in str(e),e
    else:raise AssertionError('Claim used a stale model while a concurrent identity writer committed')
assert locker.wait(timeout=10)==0,locker.stderr.read()
assert api('tasks/model-lock-task')['task']['status']=='open'

# Protected captain transport fails closed if a token file is world-readable.
TOKEN.chmod(0o644)
ab('agent','availability','set','--agent-id','reserved-b','--state','active',code=2)
assert show('reserved-b')['availability']['state']=='reserved'
TOKEN.chmod(0o600)
assert reserved['changed_by']=='routing-captain'
history=api('agents/reserved-b')['availability_history']
assert any(e['action']=='expire' and e['provenance']['agent']=='availability-expiry' for e in history),history
assert sql("SELECT count(*) FROM availability_policies_versions WHERE provenance->>'agent'='routing-captain'")!='0'
print('Availability authorization, reserved/OOS admission, expiry, roster pagination and broadcast contracts passed')
