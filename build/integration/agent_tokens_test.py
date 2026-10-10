"""Owns token lifecycle and observe attribution at packaged HTTP/Postgres boundary.
Invented actors and server-issued disposable fixture credentials only. Existing
captain/board fixtures own generic authorization and task lifecycle."""
import json
import http.cookiejar
import urllib.parse
import hashlib
import concurrent.futures
from pathlib import Path
from liveview_client import LiveView, Page, contains
import os
import subprocess
import urllib.error
import urllib.request

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-agent-token-captain-0123456789'

def rpc(expr):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expr], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, ('Fixture RPC failed', result.stderr[-2000:])
    return result.stdout

def rpc_out(expr):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expr], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, ('Fixture RPC failed', result.stderr[-2000:])
    return result.stdout + result.stderr

def api(path, body=None, actor='token-owner', captain=False, token=None, status=200):
    headers = {'content-type': 'application/json', 'x-agentboard-agent': actor,
               'x-agentboard-model': 'fixture', 'x-agentboard-harness': 'codex'}
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
    if token:
        headers['authorization'] = 'Bearer ' + token
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=headers,
              data=None if body is None else json.dumps(body).encode())
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    assert response.status == status, (path, response.status, status)
    return json.load(response)

rpc('Application.put_env(:agentboard,:captain_token,' + json.dumps(CAPTAIN) + ')')
for actor in ['token-owner', 'token-other']:
    api('agents/register', {'name': actor}, actor=actor)
# Unauthorized administration must reach the captain guard, not fail input validation.
api('agents/token-owner/tokens/issue', {}, status=403)
issued = api('agents/token-owner/tokens/issue', {}, captain=True)
assert issued['credential']['agent_id'] == 'token-owner'
assert len(issued['token']) >= 43
token = issued['token']
id = issued['credential']['id']

def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()

assert sql("SELECT token_hash FROM agent_api_credentials WHERE id='" + id + "'") == hashlib.sha256(token.encode()).hexdigest()
assert token not in sql("SELECT row_to_json(c)::text FROM agent_api_credentials c")
listed = api('agents/token-owner/tokens', captain=True)
assert 'token_hash' not in json.dumps(listed) and token not in json.dumps(listed)
api('agents/token-owner/tokens', status=403)
assert sql('SELECT count(*) FROM agent_auth_observations') == '0'

rpc('Application.put_env(:agentboard,:agent_auth_mode,"observe")')
def create(name, bearer=None, actor='token-owner'):
    return api('tasks', {'id': name, 'title': 'Observe fixture'}, actor=actor, token=bearer)
create('auth-anonymous')
create('auth-matched', token)
create('auth-mismatch', token, 'token-other')
assert api('tasks/auth-mismatch')['events'][0]['actor_id'] == 'token-other'
report = api('auth/observations')
assert report['counts']['anonymous'] == 1 and report['counts']['actor_mismatch'] == 1 and report['counts']['matched'] == 1
mismatch = next(row for row in report['recent'] if row['outcome']=='actor_mismatch')
assert mismatch['attributed_agent_id'] == 'token-other' and mismatch['verified_agent_id'] == 'token-owner'
assert mismatch['route'] == '/api/v1/tasks'
assert token not in json.dumps(report) and CAPTAIN not in json.dumps(report)
assert api('agents/token-owner/tokens', captain=True)['credentials'][0]['last_used_at'] is not None
view = LiveView(URL, '/agents')
assert contains(view.initial, 'API identity observations') and contains(view.initial, 'Actor mismatch')
view.close()

rotated = api('agents/token-owner/tokens/rotate', {}, captain=True)
new = rotated['token']
create('auth-old-token', token)
create('auth-new-token', new)
assert api('auth/observations')['counts']['invalid'] == 1
api('agents/token-owner/tokens/revoke', {'credential_id': rotated['credential']['id']}, captain=True)
create('auth-revoked', new)
assert api('auth/observations')['counts']['invalid'] == 2
api('agents/token-other/tokens/revoke', {'credential_id': id}, captain=True, status=404)
# A pair of simultaneous rotations cannot leave both newly returned tokens active.
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    race = list(pool.map(lambda _: api('agents/token-owner/tokens/rotate', {}, captain=True), range(2)))
assert sql("SELECT count(*) FROM agent_api_credentials WHERE agent_id='token-owner' AND revoked_at IS NULL") == '1'
for i, item in enumerate(race):
    create('auth-race-' + str(i), item['token'])
assert api('auth/observations')['counts']['invalid'] == 3
for actor in ['system-fixture','token-coordinator']:
    api('agents/register', {'name': actor}, actor=actor)
rpc('Application.put_env(:agentboard,:coordinator_id,"token-coordinator")')
api('agents/ci-accountability/tokens/issue', {}, captain=True, status=403)
api('agents/system-fixture/tokens/issue', {}, captain=True, status=403)
api('agents/token-owner/tokens/issue', {'scope':'system'}, captain=True, status=403)
api('agents/token-owner/tokens/issue', {'scope':'coordinator'}, captain=True, status=403)
api('agents/token-coordinator/tokens/issue', {'scope':'agent'}, captain=True, status=403)
assert api('agents/token-coordinator/tokens/issue', {}, captain=True)['credential']['scope']=='coordinator'

# Normal CLI transport and admin stdout/file custody at the actual packaged boundary.
root = Path(os.environ['TEST_TMPDIR'])
capfile = root / 'fixture-captain.token'; capfile.write_text(CAPTAIN); capfile.chmod(0o600)
base = dict(os.environ, AGENT_ID='token-owner', AGENTBOARD_MODEL='fixture', AGENTBOARD_HARNESS='codex', AGENTBOARD_CAPTAIN_TOKEN_FILE=str(capfile))
def cli(*args, env=None, code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env or base, capture_output=True, text=True, timeout=20)
    assert result.returncode == code, ('CLI failed', result.returncode, code)
    assert CAPTAIN not in result.stdout + result.stderr
    return result
outfile=root/'issued-agent.token'
issued_cli=cli('agent','token','issue','token-owner','--out',str(outfile))
cli_token=outfile.read_text().strip()
assert outfile.stat().st_mode & 0o777 == 0o600
assert cli_token not in issued_cli.stdout + issued_cli.stderr
assert json.loads(issued_cli.stdout)['token_file']==str(outfile)
before=sql('SELECT count(*) FROM agent_api_credentials')
cli('agent','token','issue','token-owner','--out',str(outfile),code=2)
assert sql('SELECT count(*) FROM agent_api_credentials')==before
dangling=root/'dangling-agent.token';missing=root/'dangling-target.token'
for path in (dangling,missing):
    try:
        if path.is_symlink() or path.exists(): path.unlink()
    except FileNotFoundError: pass
dangling.symlink_to(missing)
assert dangling.is_symlink() and not missing.exists()
before_dangling=sql('SELECT count(*) FROM agent_api_credentials')
before_dangling_active=sql("SELECT count(*) FROM agent_api_credentials WHERE agent_id='token-owner' AND revoked_at IS NULL")
dangling_issue=cli('agent','token','issue','token-owner','--out',str(dangling),code=2)
dangling_rotate=cli('agent','token','rotate','token-owner','--out',str(dangling),code=2)
assert not missing.exists() and dangling.is_symlink()
assert sql('SELECT count(*) FROM agent_api_credentials')==before_dangling
assert sql("SELECT count(*) FROM agent_api_credentials WHERE agent_id='token-owner' AND revoked_at IS NULL")==before_dangling_active
assert cli_token not in dangling_issue.stdout+dangling_issue.stderr+dangling_rotate.stdout+dangling_rotate.stderr
dangling.unlink()
cli('task','create','--id','auth-cli-env','--title','CLI transport',env=dict(base,AGENTBOARD_TOKEN=cli_token))
cli('task','create','--id','auth-cli-file','--title','CLI protected file',env=dict(base,AGENTBOARD_TOKEN='',AGENTBOARD_TOKEN_FILE=str(outfile)))
# Observe must retain effective attribution for CLI mismatch too.
cli('task','create','--id','auth-cli-mismatch','--title','CLI mismatch',env=dict(base,AGENT_ID='token-other',AGENTBOARD_TOKEN=cli_token))
assert api('tasks/auth-cli-mismatch')['events'][0]['actor_id']=='token-other'
assert api('auth/observations')['counts']['actor_mismatch']==2
outfile.chmod(0o644)
cli('meta',env=dict(base,AGENTBOARD_TOKEN='',AGENTBOARD_TOKEN_FILE=str(outfile)),code=2)
outfile.chmod(0o600)
link=root/'linked-agent.token';link.symlink_to(outfile)
cli('meta',env=dict(base,AGENTBOARD_TOKEN='',AGENTBOARD_TOKEN_FILE=str(link)),code=2)
metadata=cli('meta',env=dict(base,AGENTBOARD_TOKEN=cli_token))
assert cli_token not in metadata.stdout + metadata.stderr
assert json.loads(metadata.stdout)['schema_version']>=25
# Settings executes the same captain boundary through a CSRF-protected session.
locked=LiveView(URL,'/settings')
assert contains(locked.initial,'Unlock captain controls')
locked.send(['1','2',locked.topic,'event',{'type':'form','event':'list_credentials','value':'agent_id=token-owner'}])
reply=locked.wait(lambda event:event[3]=='phx_reply' and event[1]=='2')
assert reply and not contains(reply,cli_token)
locked.close()
jar=http.cookiejar.CookieJar()
browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
settings=Page();settings.feed(browser.open(URL+'/settings').read().decode())
unlock=urllib.request.Request(URL+'/settings/unlock',data=urllib.parse.urlencode({'token':CAPTAIN,'_csrf_token':settings.csrf}).encode(),headers={'Content-Type':'application/x-www-form-urlencoded','Origin':URL})
assert browser.open(unlock,timeout=10).status==200
cookie='; '.join(item.name+'='+item.value for item in jar)
unlocked=LiveView(URL,'/settings',cookie)
unlocked.send(['1','2',unlocked.topic,'event',{'type':'form','event':'list_credentials','value':'agent_id=token-owner'}])
reply=unlocked.wait(lambda event:event[3]=='phx_reply' and event[1]=='2')
assert reply and contains(reply,issued['credential']['fingerprint'])
assert all(not contains(reply,t) for t in [token,new,cli_token,CAPTAIN])
unlocked.close()
# A download contains a fixture token once; subsequent lists contain only metadata.
settings=Page();settings.feed(browser.open(URL+'/settings').read().decode())
request=urllib.request.Request(URL+'/settings/agent-tokens/rotate',data=urllib.parse.urlencode({'agent_id':'token-other','_csrf_token':settings.csrf}).encode(),headers={'Content-Type':'application/x-www-form-urlencoded','Origin':URL})
response=browser.open(request,timeout=10)
ui_token=response.read().decode().strip()
assert response.headers.get('Cache-Control')=='no-store' and response.headers.get('Content-Disposition').startswith('attachment')
create('auth-ui-download',ui_token,'token-other')
assert ui_token not in json.dumps(api('agents/token-other/tokens',captain=True))
request=urllib.request.Request(URL+'/settings/agent-tokens/revoke',data=urllib.parse.urlencode({'agent_id':'token-other','_csrf_token':settings.csrf}).encode(),headers={'Content-Type':'application/x-www-form-urlencoded','Origin':URL})
assert browser.open(request,timeout=10).status==200
create('auth-ui-revoked',ui_token,'token-other')
assert api('auth/observations')['recent'][0]['outcome']=='invalid'
# Observe degrades open with a nil principal when recording fails; readiness stays valid.
# An INSERT trigger keeps required tables present so Compatibility passes and record fails.
def plug_probe(bearer, actor='token-owner'):
    expr=('conn = Plug.Test.conn(:post, "/api/v1/tasks", "{}") |> Plug.Conn.put_req_header("content-type", "application/json")'
          ' |> Plug.Conn.put_req_header("x-agentboard-agent", "'+actor+'")'
          ' |> Plug.Conn.put_req_header("authorization", "Bearer '+bearer+'")'
          ' |> Plug.Conn.assign(:authenticated_agent, %{agent_id: "seeded"});'
          ' out = AgentboardWeb.Plugs.AgentAuth.call(conn, AgentboardWeb.Plugs.AgentAuth.init([]));'
          ' IO.inspect({out.assigns[:authenticated_agent], out.halted}, label: "plug_degraded")')
    return rpc_out(expr)

def telemetry_attach():
    return rpc('try do :telemetry.detach("fixture-auth-degraded") rescue _ -> :ok end; :persistent_term.put(:fixture_auth_events, []); :telemetry.attach("fixture-auth-degraded", [:agentboard, :auth, :write], fn event, measurements, metadata, _ -> :persistent_term.put(:fixture_auth_events, [{event, measurements, metadata} | :persistent_term.get(:fixture_auth_events, [])]) end, nil); IO.puts("telemetry_attached")')

def telemetry_detach():
    return rpc(':telemetry.detach("fixture-auth-degraded"); :persistent_term.erase(:fixture_auth_events); IO.puts("telemetry_detached")')

# An active fixture credential exercises the verification/update path during both outages.
# token-other's earlier UI credential was revoked, so issue a fresh one here.
fresh = api('agents/token-other/tokens/issue', {}, captain=True)['token']
UNTRUSTED = 'abt_' + 'u'*43
INVALID_A = 'abt_' + 'a'*43
INVALID_B = 'abt_' + 'b'*43
HEADER_SENTINEL = 'fixture-untrusted-header-1053'
secret_values = [token, new, cli_token, fresh, ui_token, CAPTAIN, INVALID_A, INVALID_B, UNTRUSTED, HEADER_SENTINEL] + [item['token'] for item in race]
secret_hashes = [hashlib.sha256(t.encode()).hexdigest() for t in secret_values]
LOG_PATH = Path(os.environ['TEST_TMPDIR'])/'web.log'
sql("CREATE FUNCTION fixture_reject_observation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='invalid_input', DETAIL='Synthetic observation rejected'; END $$ ")
sql('CREATE TRIGGER fixture_observation_guard BEFORE INSERT ON agent_auth_observations FOR EACH ROW EXECUTE FUNCTION fixture_reject_observation()')
telemetry_attach()
obs_before=sql('SELECT count(*) FROM agent_auth_observations')
try:
    degraded=api('tasks',{'id':'auth-degraded-record','title':'Degraded record'},actor='token-owner',token=token)
    assert degraded['task']['id']=='auth-degraded-record'
    assert api('tasks/auth-degraded-record')['events'][0]['actor_id']=='token-owner'
    degraded_invalid=api('tasks',{'id':'auth-degraded-invalid','title':'Degraded invalid'},actor='token-owner',token=INVALID_A)
    assert api('tasks/auth-degraded-invalid')['events'][0]['actor_id']=='token-owner'
    degraded_revoked=api('tasks',{'id':'auth-degraded-revoked','title':'Degraded revoked'},actor='token-owner',token=new)
    assert api('tasks/auth-degraded-revoked')['events'][0]['actor_id']=='token-owner'
    degraded_active=api('tasks',{'id':'auth-degraded-active','title':'Degraded active'},actor='token-other',token=fresh)
    assert api('tasks/auth-degraded-active')['events'][0]['actor_id']=='token-other'
    degraded_untrusted=api('tasks',{'id':'auth-degraded-untrusted','title':'Degraded untrusted'},actor='token-owner',token=UNTRUSTED)
    assert api('tasks/auth-degraded-untrusted')['events'][0]['actor_id']=='token-owner'
    assert sql('SELECT count(*) FROM agent_auth_observations')==obs_before
    api('agents/token-owner/tokens/issue',{},status=403)
    degraded_tokens=api('agents/token-owner/tokens',captain=True)
    assert token not in json.dumps(degraded_tokens) and CAPTAIN not in json.dumps(degraded_tokens)
    for bearer in (token, INVALID_A, new, fresh, UNTRUSTED):
        probe=plug_probe(bearer)
        assert 'plug_degraded: {nil, false}' in probe, probe
        assert bearer not in probe and CAPTAIN not in probe
    header_probe=plug_probe(fresh, HEADER_SENTINEL)
    assert 'plug_degraded: {nil, false}' in header_probe, header_probe
    assert fresh not in header_probe and HEADER_SENTINEL not in header_probe and CAPTAIN not in header_probe
    events_out=rpc_out('events = :persistent_term.get(:fixture_auth_events, []); IO.inspect(events, label: "auth_events")')
    assert 'observation_unavailable' in events_out, events_out
    assert all(t not in events_out for t in secret_values)
    assert all(h not in events_out for h in secret_hashes)
    web_log=LOG_PATH.read_bytes().decode('utf-8', errors='replace')
    assert 'observation_unavailable' in web_log
    assert all(t not in web_log for t in secret_values)
    assert all(h not in web_log for h in secret_hashes)
finally:
    sql('DROP TRIGGER fixture_observation_guard ON agent_auth_observations; DROP FUNCTION fixture_reject_observation()')
    telemetry_detach()
# Observe degrades open when verification fails; invalid bearers never yield a principal.
# A BEFORE UPDATE trigger breaks the last-used write while tables and readiness stay intact.
sql("CREATE FUNCTION fixture_reject_credential_use() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='invalid_input', DETAIL='Synthetic credential use rejected'; END $$ ")
sql('CREATE TRIGGER fixture_credential_use_guard BEFORE UPDATE ON agent_api_credentials FOR EACH ROW EXECUTE FUNCTION fixture_reject_credential_use()')
telemetry_attach()
verify_mark=LOG_PATH.stat().st_size
try:
    unverified=api('tasks',{'id':'auth-degraded-verify','title':'Degraded verify'},actor='token-owner',token=token)
    assert unverified['task']['id']=='auth-degraded-verify'
    assert api('tasks/auth-degraded-verify')['events'][0]['actor_id']=='token-owner'
    unverified_invalid=api('tasks',{'id':'auth-degraded-verify-invalid','title':'Degraded verify invalid'},actor='token-owner',token=INVALID_B)
    assert api('tasks/auth-degraded-verify-invalid')['events'][0]['actor_id']=='token-owner'
    unverified_active=api('tasks',{'id':'auth-degraded-verify-active','title':'Degraded verify active'},actor='token-other',token=fresh)
    assert api('tasks/auth-degraded-verify-active')['events'][0]['actor_id']=='token-other'
    api('agents/token-owner/tokens/issue',{},status=403)
    for bearer in (token, INVALID_B, new, fresh, UNTRUSTED):
        probe=plug_probe(bearer)
        assert 'plug_degraded: {nil, false}' in probe, probe
        assert bearer not in probe and CAPTAIN not in probe
    header_probe=plug_probe(fresh, HEADER_SENTINEL)
    assert 'plug_degraded: {nil, false}' in header_probe, header_probe
    assert fresh not in header_probe and HEADER_SENTINEL not in header_probe and CAPTAIN not in header_probe
    events_out=rpc_out('events = :persistent_term.get(:fixture_auth_events, []); IO.inspect(events, label: "auth_events")')
    assert 'observation_unavailable' in events_out, events_out
    assert all(t not in events_out for t in secret_values)
    assert all(h not in events_out for h in secret_hashes)
    verify_log=LOG_PATH.read_bytes()[verify_mark:].decode('utf-8', errors='replace')
    assert 'observation_unavailable' in verify_log, verify_log[-2000:]
    assert all(t not in verify_log for t in secret_values)
    assert all(h not in verify_log for h in secret_hashes)
finally:
    sql('DROP TRIGGER fixture_credential_use_guard ON agent_api_credentials; DROP FUNCTION fixture_reject_credential_use()')
    telemetry_detach()
# Report outage alone keeps the roster: rename only for the browser/direct report check.
sql('ALTER TABLE agent_auth_observations RENAME TO fixture_hidden_observations')
try:
    # Compatibility honestly reports the missing required table first; the
    # report's own unavailable error is exercised directly below.
    honest=api('auth/observations',status=503)
    assert honest['error']['code']=='schema_unavailable'
    direct=rpc_out('IO.inspect(Agentboard.Auth.report(), label: "direct_report")')
    assert 'direct_report: {:error, "unavailable"' in direct, direct
    assert token not in direct and fresh not in direct and UNTRUSTED not in direct and CAPTAIN not in direct
    assert all(h not in direct for h in secret_hashes)
    assert token not in json.dumps(honest) and CAPTAIN not in json.dumps(honest)
    assert all(h not in json.dumps(honest) for h in secret_hashes)
    degraded_view=LiveView(URL,'/agents')
    assert contains(degraded_view.initial,'token-owner') and contains(degraded_view.initial,'token-other')
    assert contains(degraded_view.initial,'unavailable')
    assert 'Actor mismatch' not in degraded_view.initial
    degraded_view.close()
finally:
    sql('ALTER TABLE fixture_hidden_observations RENAME TO agent_auth_observations')
assert api('auth/observations')['counts']['matched']>=1
# Off rollback stops new observations without deleting earlier evidence.
count=sql('SELECT count(*) FROM agent_auth_observations')
rpc('Application.put_env(:agentboard,:agent_auth_mode,"off")')
create('auth-off-rollback',cli_token,'token-other')
assert sql('SELECT count(*) FROM agent_auth_observations')==count
all_evidence=sql('SELECT row_to_json(o)::text FROM agent_auth_observations o')
assert all(t not in all_evidence for t in [token,new,cli_token,fresh,CAPTAIN]+[item['token'] for item in race])
# DB immutability is checked by executing mutations, not inspecting migration text.
for statement in ["UPDATE agent_auth_observations SET outcome='matched'", "DELETE FROM agent_auth_observations", "TRUNCATE agent_auth_observations", "UPDATE agent_api_credentials SET revoked_at=NULL WHERE revoked_at IS NOT NULL"]:
    result=subprocess.run([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',statement],capture_output=True,text=True)
    assert result.returncode != 0
print('Hash-only lifecycle, captain guards, off/observe attribution/audit, concurrent rotation, CLI secret custody and immutable evidence passed')

# Enforce mode authenticates every ordinary read/write and binds effective actor
# attribution to the current registered credential principal. No live credentials
# or external account is used by this fixture.
import http.client
import time

def enforce_api(path, body=None, bearer=None, actor='token-owner', model='fixture', harness='codex', status=200, protocol=False):
    headers = {'content-type': 'application/json'}
    if protocol:
        headers['x-agentboard-worker-protocol'] = '1'
    if actor is not None:
        headers.update({'x-agentboard-agent': actor, 'x-agentboard-model': model,
                        'x-agentboard-harness': harness})
    if bearer is not None:
        headers['authorization'] = 'Bearer ' + bearer
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=headers,
              data=None if body is None else json.dumps(body).encode())
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    payload = json.load(response)
    if path != 'meta':
        assert response.headers.get('Cache-Control') == 'no-store', path
    assert response.status == status, (path, response.status, status, payload.get('error'))
    assert all(secret not in json.dumps(payload) for secret in [CAPTAIN, cli_token, fresh])
    return payload

coordinator_token = api('agents/token-coordinator/tokens/issue', {}, captain=True)['token']
api('agents/register', {'name': 'Enforce lifecycle'}, actor='auth-lifecycle')
lifecycle_token = api('agents/auth-lifecycle/tokens/issue', {}, captain=True)['token']
rpc('Application.put_env(:agentboard,:agent_auth_mode,"enforce")')
try:
    enforce_api('meta', actor=None)
    enforce_api('tasks', status=401)
    enforce_api('tasks', bearer=INVALID_A, status=401)
    enforce_api('tasks', bearer=new, status=401)
    enforce_api('tasks', bearer=cli_token)
    enforce_api('tasks', {'id':'auth-enforce-bound','title':'Trusted attribution'}, bearer=cli_token, actor=None)
    events = enforce_api('tasks/auth-enforce-bound', bearer=cli_token)['events']
    assert events[0]['actor_id'] == 'token-owner'
    assert events[0]['harness'] == 'codex' and events[0]['model'] == 'fixture'
    for path, body in [('tasks', None), ('tasks', {'title':'Must not be created'}),
                       ('conversations/reads?channel_id=fixture', None),
                       ('conversations/send', {'message':'Must not be sent'}),
                       ('conversations/coverage/token-other/fixture', {'last_post_id':'fixture'})]:
        enforce_api(path, body, bearer=cli_token, actor='token-other', status=403)
    enforce_api('tasks', bearer=cli_token, model='forged-model', status=403)
    enforce_api('tasks', bearer=cli_token, harness='forged-harness', status=403)
    assert sql("SELECT count(*) FROM tasks WHERE title='Must not be created'") == '0'

    # Duplicate raw headers must be rejected rather than trusting the first one.
    origin = urllib.parse.urlsplit(URL)
    for headers in [
        [('authorization','Bearer '+cli_token), ('authorization','Bearer '+cli_token)],
        [('authorization','Bearer '+cli_token), ('x-agentboard-agent','token-owner'), ('x-agentboard-agent','token-other')],
        [('authorization','Bearer '+cli_token+', Bearer '+fresh)],
    ]:
        connection = http.client.HTTPConnection(origin.hostname, origin.port, timeout=10)
        connection.putrequest('GET', '/api/v1/tasks')
        for key, value in headers:
            connection.putheader(key, value)
        connection.endheaders()
        response = connection.getresponse()
        assert response.status == 401, (response.status, response.read())
        response.read(); connection.close()

    # Coordinator is a deliberately read-only capability in enforcement mode.
    for path in ['tasks', 'prs', 'decisions', 'decisions/waiting', 'decisions/wakes',
                 'agents', 'messages', 'messages?to=token-coordinator']:
        enforce_api(path, bearer=coordinator_token, actor='token-coordinator')
    for path in ['messages?to=token-owner', 'messages?task=auth-enforce-bound',
                 'messages?to=token-coordinator&task=auth-enforce-bound',
                 'conversations/reads?channel_id=fixture', 'conversations/diagnostics',
                 'conversations/coverage/token-coordinator/fixture', 'quota', 'context/feed']:
        enforce_api(path, bearer=coordinator_token, actor='token-coordinator', status=403)
    for path, body in [('tasks', {'title':'Observer cannot write'}),
                       ('agents/register', {}), ('messages', {'to':'token-owner','body':'No send'}),
                       ('agents/token-coordinator/heartbeat', {'status':'idle'})]:
        enforce_api(path, body, bearer=coordinator_token, actor='token-coordinator', status=403)
    rpc('Application.put_env(:agentboard,:coordinator_id,"another-coordinator")')
    enforce_api('tasks', bearer=coordinator_token, actor='token-coordinator', status=401)
    rpc('Application.put_env(:agentboard,:coordinator_id,"token-coordinator")')

    # Participant credentials are always explicit, channel-bounded, immutable,
    # and distinct from the read-only coordinator and protected runtime proof.
    participant_scope = 'coordinator_participant'
    grant = ['participant-channel']
    for invalid_grant in [None, [], 'participant-channel', [''], ['has space'],
                          ['slash/channel'], ['line\n'], ['é'], ['x'*129],
                          ['same', 'same'], ['channel-'+str(n) for n in range(21)]]:
        bad = {'scope': participant_scope, 'channel_ids': invalid_grant}
        before = sql('SELECT count(*) FROM agent_api_credentials')
        api('agents/token-coordinator/tokens/issue', bad, captain=True, status=422)
        assert sql('SELECT count(*) FROM agent_api_credentials') == before
    api('agents/token-owner/tokens/issue', {'scope':participant_scope,'channel_ids':grant}, captain=True, status=403)
    for identity, scope in [('token-owner','agent'), ('token-coordinator','coordinator')]:
        api('agents/'+identity+'/tokens/issue', {'scope':scope,'channel_ids':grant}, captain=True, status=422)
    participant_issued = api('agents/token-coordinator/tokens/issue',
        {'scope':participant_scope,'channel_ids':grant}, captain=True)
    participant_token = participant_issued['token']
    participant_id = participant_issued['credential']['id']
    assert participant_issued['credential']['channel_ids'] == grant
    listed = api('agents/token-coordinator/tokens', captain=True)
    assert participant_token not in json.dumps(listed) and 'token_hash' not in json.dumps(listed)
    for statement in ["UPDATE agent_api_credentials SET channel_ids=ARRAY['foreign-channel'] WHERE id='"+participant_id+"'",
                      "UPDATE agent_api_credentials SET channel_ids=ARRAY[]::text[] WHERE id='"+participant_id+"'"]:
        outcome = subprocess.run([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',statement],capture_output=True,text=True)
        assert outcome.returncode != 0, 'Credential channel grant was mutable'
    assert sql("SELECT channel_ids[1] FROM agent_api_credentials WHERE id='"+participant_id+"'") == grant[0]
    enforce_api('tasks', bearer=participant_token, actor='token-coordinator')
    enforce_api('agents/token-coordinator/heartbeat', {'status':'idle'}, bearer=participant_token, actor='token-coordinator')
    enforce_api('agents/token-owner/heartbeat', {'status':'idle'}, bearer=participant_token, actor='token-coordinator', status=403)
    enforce_api('agents/token-coordinator/heartbeat', {'status':'away'}, bearer=participant_token, actor='token-coordinator', status=422)
    enforce_api('agents/token-coordinator/heartbeat', {'status':'idle','backend':'profile-write'}, bearer=participant_token, actor='token-coordinator', status=422)
    enforce_api('agents/token-coordinator/heartbeat', {'status':'busy','task':'auth-enforce-bound'}, bearer=participant_token, actor='token-coordinator', status=409)
    own_notice = enforce_api('messages', {'to':'token-coordinator','body':'Participant exact inbox fixture'}, bearer=cli_token)['message']
    foreign_notice = enforce_api('messages', {'to':'token-other','body':'Foreign recipient fixture'}, bearer=cli_token)['message']
    for read_token in [coordinator_token, participant_token]:
        enforce_api('messages/'+str(own_notice['id']), bearer=read_token, actor='token-coordinator')
        enforce_api('messages/'+str(foreign_notice['id']), bearer=read_token, actor='token-coordinator', status=404)
        enforce_api('messages/'+str(foreign_notice['id'])+'/triage', bearer=read_token, actor='token-coordinator', status=404)
        enforce_api('messages?to=token-other', bearer=read_token, actor='token-coordinator', status=403)
        enforce_api('messages?task=auth-enforce-bound', bearer=read_token, actor='token-coordinator', status=403)
    enforce_api('messages/'+str(own_notice['id'])+'/read', {}, bearer=coordinator_token, actor='token-coordinator', status=403)
    acknowledged = enforce_api('messages/'+str(own_notice['id'])+'/read', {}, bearer=participant_token, actor='token-coordinator')['message']
    repeated = enforce_api('messages/'+str(own_notice['id'])+'/read', {}, bearer=participant_token, actor='token-coordinator')['message']
    for field in ['read_at','read_model','read_harness']:
        assert repeated[field] == acknowledged[field] and repeated[field] is not None
    enforce_api('messages/'+str(foreign_notice['id'])+'/read', {}, bearer=participant_token, actor='token-coordinator', status=409)
    for path, body in [('tasks', {'title':'Participant cannot create'}),
                       ('tasks/auth-enforce-bound/claim', {}), ('tasks/auth-enforce-bound/renew', {}),
                       ('tasks/auth-enforce-bound/assign', {'to':'token-owner'}),
                       ('agents/register', {}), ('availability', {}), ('quota', {}),
                       ('messages', {'to':'token-owner','body':'Participant cannot board-send'}),
                       ('decisions', {}), ('decisions/00000000-0000-4000-8000-000000000001/answer', {'answer':'No'}),
                       ('agents/token-coordinator/tokens/issue', {})]:
        enforce_api(path, body, bearer=participant_token, actor='token-coordinator', status=403)
    enforce_api('workers/token-coordinator/mattermost_read', {}, bearer=participant_token, actor='token-coordinator', status=401, protocol=True)
    enforce_api('workers/token-coordinator/mattermost_ack', {}, bearer=participant_token, actor='token-coordinator', status=401, protocol=True)

    # Actual loopback HTTP proves grant, global policy and current shared-bot
    # identity/membership all gate generic chat and coverage operations.
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    chat_state = {'channels':grant[:], 'bot':True, 'posts':0, 'history':0, 'flip_config':False, 'redirect_status':None}
    redirect_state={'requests':0,'credential_received':False}
    class ParticipantRedirectTarget(BaseHTTPRequestHandler):
        def log_message(self, *_args): pass
        def do_GET(self):
            redirect_state['requests']+=1
            redirect_state['credential_received'] |= self.headers.get('Authorization') is not None
            self.rfile.read(int(self.headers.get('Content-Length','0')))
            raw=json.dumps({'id':'redirected-post','order':[],'posts':{}}).encode()
            self.send_response(201 if self.command=='POST' else 200)
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)))
            self.end_headers();self.wfile.write(raw)
        do_POST=do_GET
    redirect_server=ThreadingHTTPServer(('127.0.0.1',0),ParticipantRedirectTarget)
    redirect_thread=threading.Thread(target=redirect_server.serve_forever,daemon=True);redirect_thread.start()
    class ParticipantChatFixture(BaseHTTPRequestHandler):
        def log_message(self, *_args): pass
        def send_json(self, value, status=200):
            raw=json.dumps(value).encode(); self.send_response(status)
            self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        def redirect(self):
            self.send_response(chat_state['redirect_status'])
            # Different host and port: following this would escape the verified
            # shared-bot destination and could forward its authorization header.
            self.send_header('Location','http://localhost:'+str(redirect_server.server_port)+'/redirected')
            self.send_header('Content-Length','0');self.end_headers()
        def do_GET(self):
            assert self.headers.get('Authorization') == 'Bearer fixture-participant-shared-bot'
            if self.path == '/api/v4/users/me':
                self.send_json({'id':'participant-bot','roles':'system_user','is_bot':chat_state['bot']})
            elif self.path == '/api/v4/users/me/channels':
                if chat_state['flip_config']:
                    chat_state['flip_config']=False
                    rpc('Application.put_env(:agentboard,:mattermost_base_url,"http://127.0.0.1:9")')
                self.send_json([{'id':channel,'delete_at':0} for channel in chat_state['channels']])
            elif self.path.startswith('/api/v4/channels/participant-channel/posts'):
                if chat_state['redirect_status']:return self.redirect()
                chat_state['history']+=1; self.send_json({'order':[],'posts':{}})
            else: self.send_json({},404)
        def do_POST(self):
            assert self.path == '/api/v4/posts'
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if chat_state['redirect_status']:return self.redirect()
            chat_state['posts']+=1
            self.send_json(dict(body,id='participant-post-'+str(chat_state['posts']),user_id='participant-bot'),201)
    chat_server=ThreadingHTTPServer(('127.0.0.1',0),ParticipantChatFixture)
    chat_thread=threading.Thread(target=chat_server.serve_forever,daemon=True);chat_thread.start()
    config_keys='[:mattermost_base_url,:mattermost_bot_token,:mattermost_bot_token_file,:mattermost_channel_allowlist]'
    rpc(':persistent_term.put(:participant_prior, Map.new('+config_keys+', &{&1, Application.fetch_env(:agentboard, &1)})); Application.put_env(:agentboard,:mattermost_base_url,"http://127.0.0.1:'+str(chat_server.server_port)+'"); Application.put_env(:agentboard,:mattermost_bot_token,"fixture-participant-shared-bot"); Application.delete_env(:agentboard,:mattermost_bot_token_file); Application.put_env(:agentboard,:mattermost_channel_allowlist,"participant-channel")')
    try:
        for path in ['conversations/reads?channel_id=foreign-channel', 'conversations/coverage/token-coordinator/foreign-channel',
                     'conversations/coverage/token-other/participant-channel']:
            enforce_api(path, bearer=participant_token, actor='token-coordinator', status=403)
        enforce_api('conversations/send', {'channel_id':'foreign-channel','body':'Denied'}, bearer=participant_token, actor='token-coordinator', status=403)
        enforce_api('conversations/coverage/token-coordinator/foreign-channel', {'last_post_id':'post'}, bearer=participant_token, actor='token-coordinator', status=403)
        enforce_api('conversations/coverage/token-other/participant-channel', {'last_post_id':'post'}, bearer=participant_token, actor='token-coordinator', status=422)
        assert chat_state['posts']==0 and chat_state['history']==0
        # A config replacement after membership verification cannot switch the
        # service used for the admitted generic read/send.
        chat_state['flip_config']=True
        enforce_api('conversations/reads?channel_id=participant-channel', bearer=participant_token, actor='token-coordinator')
        rpc('Application.put_env(:agentboard,:mattermost_base_url,"http://127.0.0.1:'+str(chat_server.server_port)+'")')
        chat_state['flip_config']=True
        enforce_api('conversations/send', {'channel_id':'participant-channel','body':'Participant generic chat'}, bearer=participant_token, actor='token-coordinator')
        rpc('Application.put_env(:agentboard,:mattermost_base_url,"http://127.0.0.1:'+str(chat_server.server_port)+'")')
        enforce_api('conversations/coverage/token-coordinator/participant-channel', {'last_post_id':'participant-post-1','last_version':1,'caught_up':True}, bearer=participant_token, actor='token-coordinator')
        own_coverage=enforce_api('conversations/coverage/token-coordinator/participant-channel', bearer=participant_token, actor='token-coordinator')
        assert own_coverage['agent_id']=='token-coordinator' and own_coverage['channel_id']=='participant-channel'
        assert chat_state['posts']==1 and chat_state['history']>=1
        for redirect_status in [307,308]:
            chat_state['redirect_status']=redirect_status
            enforce_api('conversations/reads?channel_id=participant-channel', bearer=participant_token, actor='token-coordinator', status=503)
            enforce_api('conversations/send', {'channel_id':'participant-channel','body':'Do not follow redirects'}, bearer=participant_token, actor='token-coordinator', status=503)
            enforce_api('conversations/send', {'channel_id':'participant-channel','body':'No redirect adoption','retry_key':'redirect-'+str(redirect_status)}, bearer=participant_token, actor='token-coordinator', status=503)
            assert redirect_state['requests']==0 and not redirect_state['credential_received'], 'Mattermost escaped its authorized destination'
            assert chat_state['posts']==1
        chat_state['redirect_status']=None
        for change in ['membership','policy','identity']:
            if change=='membership':chat_state['channels']=[]
            if change=='policy':rpc('Application.put_env(:agentboard,:mattermost_channel_allowlist,"another-channel")')
            if change=='identity':chat_state['bot']=False
            expected=503 if change=='identity' else 403
            for path, body in [('conversations/reads?channel_id=participant-channel',None),
                               ('conversations/send',{'channel_id':'participant-channel','body':'Must fail closed'}),
                               ('conversations/coverage/token-coordinator/participant-channel',None),
                               ('conversations/coverage/token-coordinator/participant-channel',{'last_post_id':'post'})]:
                enforce_api(path,body,bearer=participant_token,actor='token-coordinator',status=expected)
            diagnostics=enforce_api('conversations/diagnostics',bearer=participant_token,actor='token-coordinator')
            assert set(diagnostics)=={'bot','overrides'} and 'channels' not in json.dumps(diagnostics)
            chat_state['channels']=grant[:];chat_state['bot']=True
            rpc('Application.put_env(:agentboard,:mattermost_channel_allowlist,"participant-channel")')
        assert chat_state['posts']==1
    finally:
        rpc('Enum.each(:persistent_term.get(:participant_prior), fn {key, {:ok, value}} -> Application.put_env(:agentboard,key,value); {key, :error} -> Application.delete_env(:agentboard,key) end); :persistent_term.erase(:participant_prior)')
        chat_server.shutdown();chat_server.server_close();chat_thread.join(timeout=5)
        redirect_server.shutdown();redirect_server.server_close();redirect_thread.join(timeout=5)
    rpc('Application.put_env(:agentboard,:coordinator_id,"replacement-coordinator")')
    enforce_api('tasks',bearer=participant_token,actor='token-coordinator',status=401)
    rpc('Application.put_env(:agentboard,:coordinator_id,"token-coordinator")')
    # Failed rotation validation must not revoke either existing coordinator scope.
    api('agents/token-coordinator/tokens/rotate', {'scope':participant_scope,'channel_ids':[]}, captain=True, status=422)
    enforce_api('tasks', bearer=participant_token, actor='token-coordinator')
    enforce_api('tasks', bearer=coordinator_token, actor='token-coordinator')
    participant_outfile=root/'participant-rotated.token'
    participant_cli=cli('agent','token','rotate','token-coordinator','--scope',participant_scope,
        '--channel','rotated-channel','--out',str(participant_outfile))
    replacement_participant=participant_outfile.read_text().strip()
    replacement_metadata=json.loads(participant_cli.stdout)['credential']
    assert replacement_metadata['scope']==participant_scope and replacement_metadata['channel_ids']==['rotated-channel']
    assert participant_outfile.stat().st_mode & 0o777 == 0o600
    assert replacement_participant not in participant_cli.stdout+participant_cli.stderr
    enforce_api('tasks', bearer=participant_token, actor='token-coordinator', status=401)
    enforce_api('tasks', bearer=coordinator_token, actor='token-coordinator', status=401)
    enforce_api('tasks', bearer=replacement_participant, actor='token-coordinator')
    api('agents/token-coordinator/tokens/revoke', {'credential_id':replacement_metadata['id']}, captain=True)
    enforce_api('tasks', bearer=replacement_participant, actor='token-coordinator', status=401)
    default_rotation=api('agents/token-coordinator/tokens/rotate', {}, captain=True)
    assert default_rotation['credential']['scope']=='coordinator' and default_rotation['credential']['channel_ids']==[]
    coordinator_token=default_rotation['token']
    enforce_api('agents/token-coordinator/heartbeat', {'status':'idle'}, bearer=coordinator_token, actor='token-coordinator', status=403)
    print('Participant immutable grants, own heartbeat/inbox/ack, token rotation custody and live shared-bot channel intersection passed')

    # Dedicated captain reads and administration preserve their independent proof.
    for path in ['auth/observations', 'settings/archive', 'agents/token-owner/tokens']:
        enforce_api(path, status=403)
        enforce_api(path, bearer=cli_token, status=403)
        enforce_api(path, bearer=CAPTAIN)
    enforce_api('tasks', {'title':'Captain cannot impersonate'}, bearer=CAPTAIN, status=403)
    enforce_api('conversations/send', {'message':'Captain cannot impersonate'}, bearer=CAPTAIN, status=403)
    enforce_api('agents/auth-new-bootstrap', bearer=CAPTAIN, status=404)
    created = enforce_api('agents/register', {'name':'Captain provisioned'}, bearer=CAPTAIN, actor='auth-new-bootstrap')
    assert created['agent']['id'] == 'auth-new-bootstrap'
    enforce_api('agents/register', {}, bearer=CAPTAIN, actor='system-spoof', status=403)
    enforce_api('agents/auth-new-bootstrap', bearer=CAPTAIN)
    enforce_api('availability', bearer=CAPTAIN)
    cli_bootstrap = cli('admin','agent','register','auth-cli-bootstrap',
        env=dict(base, AGENT_ID='auth-cli-bootstrap', AGENTBOARD_TOKEN='', AGENTBOARD_TOKEN_FILE=''))
    assert 'auth-cli-bootstrap' in cli_bootstrap.stdout
    cli('admin','agent','register','auth-cli-bootstrap','--dry-run',
        env=dict(base, AGENT_ID='auth-cli-bootstrap', AGENTBOARD_TOKEN='', AGENTBOARD_TOKEN_FILE=''))
    bootstrap_token = api('agents/auth-new-bootstrap/tokens/issue', {}, captain=True)['token']
    enforce_api('tasks', bearer=bootstrap_token, actor='auth-new-bootstrap')
    enforce_api('availability', {'agent_id':'auth-new-bootstrap', 'state':'reserved',
        'reason':'Enforce captain fixture'}, bearer=CAPTAIN, actor='token-other')
    assert sql("SELECT changed_by FROM availability_policies WHERE agent_id='auth-new-bootstrap'") == 'captain'
    enforce_api('tasks', {'id':'auth-captain-assign','title':'Captain assignment'}, bearer=cli_token)
    assigned = enforce_api('tasks/auth-captain-assign/assign', {'to':'auth-new-bootstrap'},
        bearer=CAPTAIN, actor='token-other')
    assert assigned['task']['assignee_id'] == 'auth-new-bootstrap'
    assert enforce_api('tasks/auth-captain-assign', bearer=cli_token)['events'][-1]['actor_id'] == 'captain'
    enforce_api('tasks', {'id':'auth-captain-decision','title':'Captain decision'}, bearer=cli_token)
    enforce_api('tasks/auth-captain-decision/claim', {}, bearer=cli_token)
    decision = enforce_api('decisions', {'task':'auth-captain-decision','kind':'scope',
        'gate':'auth/enforce','question':'Proceed with local fixture?', 'findings':'Fixture only'}, bearer=cli_token)['decision']
    answered = enforce_api('decisions/'+decision['id']+'/answer', {'answer':'Approved fixture'},
        bearer=CAPTAIN, actor='token-other')['decision']
    assert answered['answered_by'] == 'captain'

    # Existing worker host/attempt and webhook proofs are never substituted by
    # ordinary agent/coordinator credentials.
    for bearer in [cli_token, coordinator_token]:
        req = urllib.request.Request(URL+'/api/v1/workers/unknown/state', headers={
            'authorization':'Bearer '+bearer, 'x-agentboard-worker-protocol':'1'})
        try:
            response = urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        assert response.status in (401, 404), response.status

    # Retirement and reserved identity changes invalidate an otherwise live token.
    enforce_api('agents/auth-lifecycle/retire', {'reason':'Auth enforcement fixture'}, bearer=CAPTAIN)
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle', status=401)
    api('agents/auth-lifecycle/tokens/issue', {}, captain=True, status=403)
    enforce_api('agents/auth-lifecycle/restore', {}, bearer=CAPTAIN)
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle')
    sql("UPDATE agents SET kind='system' WHERE id='auth-lifecycle'")
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle', status=401)
    sql("UPDATE agents SET kind='seat', harness='ash' WHERE id='auth-lifecycle'")
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle', status=401)
    sql("UPDATE agents SET harness='codex' WHERE id='auth-lifecycle'")
    rpc('Application.put_env(:agentboard,:coordinator_id,"auth-lifecycle")')
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle', status=401)
    rpc('Application.put_env(:agentboard,:coordinator_id,"token-coordinator")')

    # Revoking a live watch ends it at the next snapshot revalidation, rather
    # than leaking snapshots forever under the initial admission decision.
    request = urllib.request.Request(URL+'/api/v1/tasks/watch', headers={
        'authorization':'Bearer '+lifecycle_token, 'accept':'application/x-ndjson'})
    stream = urllib.request.urlopen(request, timeout=12)
    assert json.loads(stream.readline())['kind'] == 'snapshot'
    api('agents/auth-lifecycle/tokens/revoke', {}, captain=True)
    started = time.monotonic()
    while True:
        line = stream.readline()
        if not line:
            break
        assert not line.strip(), 'A revoked stream emitted another snapshot'
        assert time.monotonic() - started < 10
    stream.close()
    enforce_api('tasks', bearer=lifecycle_token, actor='auth-lifecycle', status=401)

    # Verification failure is fail-closed even when compatibility checks pass.
    sql("CREATE FUNCTION fixture_enforce_reject_use() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Synthetic auth unavailable'; END $$")
    sql('CREATE TRIGGER fixture_enforce_use_guard BEFORE UPDATE ON agent_api_credentials FOR EACH ROW EXECUTE FUNCTION fixture_enforce_reject_use()')
    try:
        enforce_api('tasks', {'id':'auth-enforce-unavailable','title':'Must fail closed'}, bearer=cli_token, status=503)
        assert sql("SELECT count(*) FROM tasks WHERE id='auth-enforce-unavailable'") == '0'
    finally:
        sql('DROP TRIGGER fixture_enforce_use_guard ON agent_api_credentials; DROP FUNCTION fixture_enforce_reject_use()')
    # Pre-authentication requests spend only an IP budget. Public metadata and
    # rejected forged attribution must never consume another identity's quota.
    enforce_api('agents/register', {'name':'Limiter fixture'}, bearer=CAPTAIN, actor='auth-limit-seat')
    limit_token = api('agents/auth-limit-seat/tokens/issue', {}, captain=True)['token']
    rpc(':persistent_term.put(:fixture_old_limits, Application.fetch_env!(:agentboard, :rate_limits)); Application.put_env(:agentboard, :rate_limits, Keyword.put(Application.fetch_env!(:agentboard, :rate_limits), :agent, 2))')
    try:
        # Synthetic addresses are passed through the actual pre-auth Plug; no
        # trusted-proxy override or forwarded-header trust is introduced.
        probe = rpc_out('for n <- 1..6 do conn = Plug.Test.conn(:get, if(rem(n, 2) == 0, do: "/api/v1/meta", else: "/api/v1/tasks")) |> Plug.Conn.put_req_header("x-agentboard-agent", "auth-limit-seat"); conn = %{conn | remote_ip: {192, 0, 2, n}}; out = conn |> AgentboardWeb.Plugs.RateLimit.call([]) |> AgentboardWeb.Plugs.AgentAuth.call([]); if out.status == 429, do: raise("spoof consumed agent budget") end; IO.puts("spoof_budget_isolated")')
        assert 'spoof_budget_isolated' in probe
        enforce_api('tasks', bearer=limit_token, actor=None)
        enforce_api('tasks', bearer=limit_token, actor=None)
        limited = enforce_api('tasks', bearer=limit_token, actor=None, status=429)
        assert limited['error']['code'] == 'rate_limited'
    finally:
        rpc('Application.put_env(:agentboard,:rate_limits,:persistent_term.get(:fixture_old_limits)); :persistent_term.erase(:fixture_old_limits)')
finally:
    rpc('Application.put_env(:agentboard,:agent_auth_mode,"off"); Application.put_env(:agentboard,:coordinator_id,"token-coordinator")')
print('Enforce principal binding, coordinator allowlist, captain bootstrap/admin, lifecycle invalidation, raw headers, stream revocation, verified-principal rate limiting and fail-closed outage passed')
