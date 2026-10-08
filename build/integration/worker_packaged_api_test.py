"""Remote-built public host CLI against packaged Phoenix; only native socket is invented."""
import json
import os
import pathlib
import selectors
import subprocess
import tempfile
import urllib.error
import urllib.request
from worker_runtime_test import Fixture, protected, until

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-host-captain-capability-32-characters'
WORKER = 'packaged-worker'
ACTOR = {'x-agentboard-agent': WORKER, 'x-agentboard-model': 'fixture-model', 'x-agentboard-harness': 'pi'}

def api(path, body=None, token=None, captain=False, expected=200):
    headers = dict(ACTOR, **{'x-agentboard-worker-protocol':'1'})
    if token: headers['Authorization'] = 'Bearer '+token
    if captain: headers['x-agentboard-captain-token'] = CAPTAIN
    if body is not None: headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(URL+'/api/v1'+path, headers=headers, data=json.dumps(body).encode() if body is not None else None)
    try: response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error: response = error
    value = json.load(response)
    assert response.status == expected, (path,response.status,value.get('error',{}).get('code'))
    return value

def rpc(expression):
    value = subprocess.run([os.environ['AGENTBOARD_BIN'],'rpc',expression],capture_output=True,text=True,timeout=30)
    assert value.returncode == 0, 'Packaged fixture initialization failed'

def report(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=10), 'Host did not report its connector state'
        line = process.stdout.readline()
    assert line, 'Host exited before reporting its connector state'
    return json.loads(line)

rpc('Application.put_env(:agentboard, :captain_token, '+json.dumps(CAPTAIN)+')')
api('/agents/register',{'name':'Isolated packaged host conformance'})
host = api('/workers/provision', {'worker_id':WORKER,'host_id':'fixture-host','repos':['fixture/runtime'],'model':'fixture-model','harness':'pi','idempotency_key':'packaged-provision'},captain=True)['host_token']
with tempfile.TemporaryDirectory(prefix='ab-pack-',dir='/tmp') as directory:
    fixture = Fixture(pathlib.Path(directory),(WORKER,))
    # Fixture RPC/setup retains SQL inputs; the API-only host child receives none.
    fixture.environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(('DATABASE_', 'PG'))}
    # The invented HTTP listener is shut down before any host command; all requests
    # now reach the actual packaged Phoenix endpoint and its scoped capabilities.
    fixture.http.shutdown(); fixture.http.server_close()
    process = None
    try:
        fixture.config['url'] = URL
        fixture.bindings[0]['binding_epoch'] = 0
        protected(pathlib.Path(fixture.bindings[0]['token_file']),host)
        pathlib.Path(fixture.bindings[0]['token_file']+'.receipt').unlink()
        protected(fixture.config_path,fixture.config)
        bound = fixture.run('bind','--key','packaged-bind-1')
        assert bound['binding_epoch'] == 1 and host not in json.dumps(bound)
        receipt = pathlib.Path(fixture.bindings[0]['token_file']+'.receipt').read_text().strip()
        assert receipt not in json.dumps(bound)
        fixture.run('doctor')
        # Global delivery is default-off; only the disposable packaged fixture
        # enables it, and source capture stays durable while it is off.
        assert fixture.run('check-in')['state']['worker']['enabled'] is False
        process = fixture.serve(); assert report(process)['connector_state']=='paused'; fixture.stop(process); process=None
        assert fixture.submissions == []
        for task in ['packaged-source-a','packaged-source-b']:
            api('/tasks',{'id':task,'title':'Actual packaged host source','repo':'fixture/runtime'})
        disabled = fixture.run('check-in')
        assert len(disabled['pending'][0]['deliveries']) == 2
        assert all(d['state']=='pending' for d in disabled['pending'][0]['deliveries'])
        process = fixture.serve(); assert report(process)['connector_state']=='paused'; fixture.stop(process); process=None
        assert fixture.submissions == [], 'global-off preserves source capture without dispatch'
        rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
        read = fixture.run('check-in')
        assert len(read['pending'][0]['deliveries']) == 2
        assert all(d['state']=='pending' for d in read['pending'][0]['deliveries'])
        process = fixture.serve(); until(lambda: len(fixture.submissions)==1)
        until(lambda: api('/workers/'+WORKER+'/state',token=host)['active_attempt']['status']=='submitted')
        output = fixture.stop(process); process=None
        assert host not in output and receipt not in output
        frozen = fixture.submissions[0][1]
        pending = api('/workers/'+WORKER+'/pending',token=host)['deliveries']
        assert set(frozen['delivery_ids']) == {d['id'] for d in pending}
        assert all(d['state']=='pending' for d in pending), 'turn end/submission cannot acknowledge'
        api('/tasks',{'id':'packaged-later','title':'Mid-batch arrival','repo':'fixture/runtime'})
        later = next(d['id'] for d in api('/workers/'+WORKER+'/pending',token=host)['deliveries'] if d['id'] not in frozen['delivery_ids'])
        assert fixture.run('ack','--ids',later,'--key','packaged-foreign',success=False).returncode != 0
        first = fixture.run('ack','--kind','received','--ids',frozen['delivery_ids'][0],'--key','packaged-received')
        repeat = fixture.run('ack','--kind','received','--ids',frozen['delivery_ids'][0],'--key','packaged-received')
        assert first['receipt'] == repeat['receipt'], 'receipt retries retain attribution and time'
        process = fixture.serve(); assert report(process)['connector_state']=='submitted'; fixture.stop(process); process=None
        assert len(fixture.submissions)==1, 'restart cannot replay a submitted frozen attempt'
        fixture.run('ack','--kind','handled','--ids',','.join(frozen['delivery_ids']),'--key','packaged-handled')
        remaining = api('/workers/'+WORKER+'/pending',token=host)['deliveries']
        assert [d['id'] for d in remaining] == [later]
        fixture.run('pause')
        process = fixture.serve(); assert report(process)['connector_state']=='paused'; fixture.stop(process); process=None
        assert len(fixture.submissions)==1
        fixture.run('resume')
        # Simulate native occupant replacement: old callback pins fail before I/O.
        old = json.loads(fixture.config_path.read_text())
        replacement = json.loads(fixture.config_path.read_text())
        replacement['bindings'][0]['session_id'] = 'replacement-native-session'
        replacement['bindings'][0]['adapter_generation'] = 'replacement-native-generation'
        fixture.bindings[0].update(session_id='replacement-native-session',adapter_generation='replacement-native-generation')
        protected(fixture.config_path,replacement)
        fixture.run('bind','--key','packaged-bind-2')
        assert fixture.run('check-in','--session-id',old['bindings'][0]['session_id'],'--adapter-generation',old['bindings'][0]['adapter_generation'],success=False).returncode != 0
        # Historical read must let the host retire positively handled old effects,
        # then deliver the preserved later arrival under the new binding.
        process = fixture.serve()
        until(lambda: json.loads((pathlib.Path(directory)/'journal'/ (WORKER+'.json')).read_text())['phase']=='complete')
        fixture.stop(process); process=None
        process = fixture.serve(); until(lambda: len(fixture.submissions)==2)
        until(lambda: api('/workers/'+WORKER+'/state',token=host)['active_attempt']['status']=='submitted')
        fixture.stop(process); process=None
        assert fixture.submissions[1][1]['binding_epoch']==2
        assert fixture.submissions[1][1]['delivery_ids']==[later]
        fixture.run('ack','--kind','handled','--ids',later,'--key','replacement-handled')
        assert api('/workers/'+WORKER+'/pending',token=host)['deliveries']==[]
        api('/workers/'+WORKER+'/revoke',{},captain=True)
        assert fixture.run('doctor',success=False).returncode != 0
        assert fixture.calls == [], 'host must never use the shut-down invented HTTP backend'
    finally:
        if process: fixture.stop(process)
        fixture.close()
print('Real packaged Phoenix + remote-built host CLI binding, frozen delivery, exact receipts, restart/pause/replacement/revocation passed')
