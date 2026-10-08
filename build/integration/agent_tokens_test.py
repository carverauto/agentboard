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
def plug_probe(bearer):
    expr=('conn = Plug.Test.conn(:post, "/api/v1/tasks", "{}") |> Plug.Conn.put_req_header("content-type", "application/json")'
          ' |> Plug.Conn.put_req_header("x-agentboard-agent", "token-owner")'
          ' |> Plug.Conn.put_req_header("authorization", "Bearer '+bearer+'")'
          ' |> Plug.Conn.assign(:authenticated_agent, %{agent_id: "seeded"});'
          ' out = AgentboardWeb.Plugs.AgentAuth.call(conn, AgentboardWeb.Plugs.AgentAuth.init([]));'
          ' IO.inspect({out.assigns[:authenticated_agent], out.halted}, label: "plug_degraded")')
    return rpc_out(expr)

def telemetry_attach():
    return rpc('try do :telemetry.detach("fixture-auth-degraded") rescue _ -> :ok end; if :ets.whereis(:fixture_auth_events) != :undefined, do: :ets.delete(:fixture_auth_events); :ets.new(:fixture_auth_events, [:named_table, :public, :bag]); :telemetry.attach("fixture-auth-degraded", [:agentboard, :auth, :write], fn event, measurements, metadata, _ -> :ets.insert(:fixture_auth_events, {:event, event, measurements, metadata}) end, nil); IO.puts("telemetry_attached")')

def telemetry_detach():
    return rpc(':telemetry.detach("fixture-auth-degraded"); if :ets.whereis(:fixture_auth_events) != :undefined, do: :ets.delete(:fixture_auth_events); IO.puts("telemetry_detached")')

sql("CREATE FUNCTION fixture_reject_observation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='invalid_input', DETAIL='Synthetic observation rejected'; END $$ ")
sql('CREATE TRIGGER fixture_observation_guard BEFORE INSERT ON agent_auth_observations FOR EACH ROW EXECUTE FUNCTION fixture_reject_observation()')
telemetry_attach()
obs_before=sql('SELECT count(*) FROM agent_auth_observations')
try:
    degraded=api('tasks',{'id':'auth-degraded-record','title':'Degraded record'},actor='token-owner',token=token)
    assert degraded['task']['id']=='auth-degraded-record'
    assert api('tasks/auth-degraded-record')['events'][0]['actor_id']=='token-owner'
    degraded_invalid=api('tasks',{'id':'auth-degraded-invalid','title':'Degraded invalid'},actor='token-owner',token='abt_'+'a'*43)
    assert api('tasks/auth-degraded-invalid')['events'][0]['actor_id']=='token-owner'
    degraded_revoked=api('tasks',{'id':'auth-degraded-revoked','title':'Degraded revoked'},actor='token-owner',token=new)
    assert api('tasks/auth-degraded-revoked')['events'][0]['actor_id']=='token-owner'
    assert sql('SELECT count(*) FROM agent_auth_observations')==obs_before
    api('agents/token-owner/tokens/issue',{},status=403)
    degraded_tokens=api('agents/token-owner/tokens',captain=True)
    assert token not in json.dumps(degraded_tokens) and CAPTAIN not in json.dumps(degraded_tokens)
    for bearer in (token, 'abt_'+'a'*43, new):
        probe=plug_probe(bearer)
        assert 'plug_degraded: {nil, false}' in probe, probe
        assert bearer not in probe and CAPTAIN not in probe
    events_out=rpc_out('events = :ets.tab2list(:fixture_auth_events); IO.inspect(events, label: "auth_events")')
    assert 'observation_unavailable' in events_out, events_out
    assert token not in events_out and new not in events_out and cli_token not in events_out and CAPTAIN not in events_out
    web_log=(Path(os.environ['TEST_TMPDIR'])/'web.log').read_text()
    assert 'observation_unavailable' in web_log
    assert all(t not in web_log for t in [token, new, cli_token, CAPTAIN])
finally:
    sql('DROP TRIGGER fixture_observation_guard ON agent_auth_observations; DROP FUNCTION fixture_reject_observation()')
    telemetry_detach()
# Observe degrades open when verification fails; invalid bearers never yield a principal.
# A BEFORE UPDATE trigger breaks the last-used write while tables and readiness stay intact.
sql("CREATE FUNCTION fixture_reject_credential_use() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='invalid_input', DETAIL='Synthetic credential use rejected'; END $$ ")
sql('CREATE TRIGGER fixture_credential_use_guard BEFORE UPDATE ON agent_api_credentials FOR EACH ROW EXECUTE FUNCTION fixture_reject_credential_use()')
telemetry_attach()
try:
    unverified=api('tasks',{'id':'auth-degraded-verify','title':'Degraded verify'},actor='token-owner',token=token)
    assert unverified['task']['id']=='auth-degraded-verify'
    assert api('tasks/auth-degraded-verify')['events'][0]['actor_id']=='token-owner'
    unverified_invalid=api('tasks',{'id':'auth-degraded-verify-invalid','title':'Degraded verify invalid'},actor='token-owner',token='abt_'+'b'*43)
    assert api('tasks/auth-degraded-verify-invalid')['events'][0]['actor_id']=='token-owner'
    api('agents/token-owner/tokens/issue',{},status=403)
    for bearer in (token, 'abt_'+'b'*43, new):
        probe=plug_probe(bearer)
        assert 'plug_degraded: {nil, false}' in probe, probe
        assert bearer not in probe and CAPTAIN not in probe
    events_out=rpc_out('events = :ets.tab2list(:fixture_auth_events); IO.inspect(events, label: "auth_events")')
    assert 'observation_unavailable' in events_out, events_out
    assert token not in events_out and new not in events_out and CAPTAIN not in events_out
finally:
    sql('DROP TRIGGER fixture_credential_use_guard ON agent_api_credentials; DROP FUNCTION fixture_reject_credential_use()')
    telemetry_detach()
# Report outage alone keeps the roster: rename only for the browser/direct report check.
sql('ALTER TABLE agent_auth_observations RENAME TO fixture_hidden_observations')
try:
    honest=api('auth/observations',status=503)
    assert honest['error']['code']=='unavailable'
    assert token not in json.dumps(honest) and CAPTAIN not in json.dumps(honest)
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
assert all(t not in all_evidence for t in [token,new,cli_token,CAPTAIN]+[item['token'] for item in race])
# DB immutability is checked by executing mutations, not inspecting migration text.
for statement in ["UPDATE agent_auth_observations SET outcome='matched'", "DELETE FROM agent_auth_observations", "TRUNCATE agent_auth_observations", "UPDATE agent_api_credentials SET revoked_at=NULL WHERE revoked_at IS NOT NULL"]:
    result=subprocess.run([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',statement],capture_output=True,text=True)
    assert result.returncode != 0
print('Hash-only lifecycle, captain guards, off/observe attribution/audit, concurrent rotation, CLI secret custody and immutable evidence passed')
