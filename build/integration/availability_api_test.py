"""Availability admission at the packaged HTTP/CLI/PG boundary.

Invented actors and capability. This fixture owns policy precedence, authorization,
expiry, admission and eligible fanout; cooperation owns receipt lifecycle proof.
"""
import concurrent.futures
import http.cookiejar
from html.parser import HTMLParser
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from liveview_client import LiveView, RenderedView, Page, contains

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
# Modal behavior through the real HTTP session, LiveView transport, pinned SDK
# diff consumer, and persisted Ash policies. Parse generated DOM contracts only.
class AvailabilityDocument(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.dialog = None
        self.dialogs = {}
        self.buttons = {}
        self.forms = []
        self.fields = {}
        self.alerts = []
        self.current_alert = None
        self.feed(document)
    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'dialog':
            self.dialog = attrs.get('id')
            self.dialogs[self.dialog] = attrs
        if tag == 'button' and attrs.get('id'):
            self.buttons[attrs['id']] = attrs
        if tag == 'form' and attrs.get('phx-submit') == 'set_availability':
            self.forms.append(self.dialog)
        if tag == 'input' and attrs.get('name'):
            self.fields[attrs['name']] = attrs.get('value', '')
        if attrs.get('role') == 'alert':
            self.current_alert = [self.dialog, '']
            self.alerts.append(self.current_alert)
    def handle_data(self, value):
        if self.current_alert is not None:
            self.current_alert[1] += value
    def handle_endtag(self, tag):
        if tag == 'dialog':
            self.dialog = None
        if tag in ('p', 'aside'):
            self.current_alert = None

# The public view must have neither availability actions nor a writable modal.
public = RenderedView(URL, '/agents')
page = AvailabilityDocument(public.document)
assert not page.forms and not page.dialogs
assert not any(b.get('phx-click') == 'open_availability' for b in page.buttons.values())
prior = api('availability')

# Real CSRF-protected captain unlock and signed cookie, not a forged assign.
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
with opener.open(URL + '/settings') as response:
    csrf = Page(); csrf.feed(response.read().decode())
with opener.open(urllib.request.Request(URL + '/settings/unlock', data=urllib.parse.urlencode(
        {'token': CAPTAIN, '_csrf_token': csrf.csrf}).encode())) as response:
    assert response.status == 200
cookie = '; '.join(c.name + '=' + c.value for c in jar)
api('agents/register', {'name': 'Modal fixture'}, actor='availability-ui-target', harness='pi')
roster = RenderedView(URL, '/agents', cookie)
def ui_event(name, fields=None, form=False):
    payload = {'type': 'form' if form else 'click', 'event': name,
               'value': urllib.parse.urlencode(fields or {}) if form else fields or {}}
    return AvailabilityDocument(roster.request('event', payload))

page = AvailabilityDocument(roster.document)
assert not page.forms and not page.dialogs, 'Form is still permanently visible'
assert page.buttons['availability-open']['phx-click'] == 'open_availability'
row_button = 'availability-open-availability-ui-target'
assert page.buttons[row_button]['phx-value-id'] == 'availability-ui-target'
public.request('event', {'type': 'click', 'event': 'open_availability',
                         'value': {'id': 'reserved-b'}})
assert not AvailabilityDocument(public.document).dialogs
assert api('availability') == prior
public.close()
prior = api('availability')
page = ui_event('open_availability', {'id': 'availability-ui-target'})
assert page.forms == ['availability-dialog'], (page.forms, page.dialogs)
assert page.fields['agent_id'] == 'availability-ui-target'
assert 'reason' not in page.fields and 'until' not in page.fields
assert page.dialogs['availability-dialog']['data-return-focus'] == row_button
assert page.dialogs['availability-dialog']['data-close-event'] == 'close_availability'
draft = {'agent_id': 'availability-ui-target', 'state': 'reserved', 'reason': 'Draft survives refresh'}
page = ui_event('availability_draft', draft, form=True)
assert page.fields['reason'] == draft['reason'] and 'until' not in page.fields
# Drive the actual fallback reload, then consume its diff before a no-op event.
time.sleep(5.2)
page = ui_event('column_page', {'status': 'invalid', 'direction': 'next'})
assert page.forms == ['availability-dialog'] and page.fields['reason'] == draft['reason']
assert api('availability') == prior, 'Editing a draft wrote a policy'
page = ui_event('close_availability')
assert not page.dialogs and not page.forms
assert api('availability') == prior, 'Cancel saved a policy'

# Header opens the same modal with blank selectors, not the previous row id.
page = ui_event('open_availability')
assert page.fields['agent_id'] == '' and page.fields['harness'] == ''
assert page.dialogs['availability-dialog']['data-return-focus'] == 'availability-open'
invalid = {'agent_id': 'availability-ui-target', 'state': 'reserved', 'reason': ''}
page = ui_event('set_availability', invalid, form=True)
assert page.forms == ['availability-dialog']
assert page.fields['agent_id'] == 'availability-ui-target'
assert len(page.alerts) == 1 and page.alerts[0][0] == 'availability-dialog'
assert api('availability') == prior, 'Invalid reserved policy was saved'
invalid.update(state='out_of_service', reason='Fixture maintenance', until='not-a-timestamp')
page = ui_event('set_availability', invalid, form=True)
assert page.fields['reason'] == 'Fixture maintenance' and page.fields['until'] == 'not-a-timestamp'
assert len(page.alerts) == 1 and page.alerts[0][0] == 'availability-dialog'
assert 'RFC3339' in page.alerts[0][1]
assert api('availability') == prior, 'Invalid until was saved'
valid = {'agent_id': 'availability-ui-target', 'state': 'reserved', 'reason': 'Named work only'}
page = ui_event('set_availability', valid, form=True)
assert not page.dialogs and not page.forms and not page.alerts
assert 'Availability updated.' in roster.document
assert show('availability-ui-target')['availability']['state'] == 'reserved'
assert show('availability-ui-target')['availability']['reason'] == 'Named work only'
assert api('agents/availability-ui-target')['availability_history']
roster.close()

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
