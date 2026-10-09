"""Real HTTP/PG coverage for admin bootstrap, worker captain wire and token custody.

Only invented fixture identities and disposable capabilities are used. No native
adapter, Unix socket, service activation, or production enrollment is required.
"""
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-admin-worker-captain-0123456789012345'
WORKER = 'admin-enrollment-fixture'
ROOT = Path(os.environ['TEST_TMPDIR']) / 'admin-worker'
ROOT.mkdir(mode=0o700)
CAPFILE = ROOT / 'captain.token'
CAPFILE.write_text(CAPTAIN)
CAPFILE.chmod(0o600)
TOKEN = ROOT / 'host.token'
ENV = dict(os.environ, AGENT_ID=WORKER, AGENTBOARD_MODEL='fixture-model',
           AGENTBOARD_HARNESS='codex', AGENTBOARD_CAPTAIN_TOKEN_FILE=str(CAPFILE),
           AGENTBOARD_TOKEN='', AGENTBOARD_TOKEN_FILE='')
SECRETS = [CAPTAIN]


def rpc(expr):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expr],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, 'Fixture RPC failed'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def cli(*args, code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=ENV,
                            capture_output=True, text=True, timeout=20)
    assert not any(secret in result.stdout + result.stderr for secret in SECRETS)
    assert result.returncode == code, ('CLI result', args[:3], result.returncode, code)
    return json.loads(result.stdout) if result.stdout.strip() else None


def worker_read(token, status=200):
    request = urllib.request.Request(URL + '/api/v1/workers/' + WORKER + '/doctor',
              headers={'Authorization': 'Bearer ' + token, 'X-Agentboard-Worker-Protocol': '1'})
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    assert response.status == status, ('Worker HTTP status', response.status, status)
    return json.load(response)


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard, :agent_auth_mode, "enforce")')
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
# The ordinary bearer bootstrap and independent worker-captain boundaries both
# run under enforced auth; a generic mocked provision handler cannot prove this.
cli('admin', 'agent', 'register', WORKER)
create = ['admin', 'worker', 'create', WORKER, '--host', 'fixture-host',
          '--repo', 'fixture/repo', '--model', 'fixture-model', '--harness', 'codex',
          '--token-file', str(TOKEN)]
first = cli(*create)
host = TOKEN.read_text().strip()
SECRETS.append(host)
assert host not in json.dumps(first)
assert TOKEN.stat().st_mode & 0o777 == 0o600
state = worker_read(host)
assert state['scope'] == 'host' and state['worker']['host_id'] == 'fixture-host'
assert state['binding']['binding_epoch'] == 0
assert cli(*create)['result']['capability_verified'] is True
assert cli(*create, '--dry-run', code=2)['result']['converged'] is False

# Known bad credential destinations cannot create a one-shot remote capability.
before = sql('SELECT count(*) FROM cooperation_credentials')
bad = create.copy()
bad[-1] = str(ROOT / 'missing' / 'host.token')
cli(*bad, code=1)
assert sql('SELECT count(*) FROM cooperation_credentials') == before

config = ROOT / 'config.json'
config.write_text(json.dumps({'version': 1, 'url': URL, 'journal_dir': str(ROOT / 'journal'),
    'bindings': [{'agent_id': WORKER, 'model': 'fixture-model', 'harness': 'codex',
       'host_id': 'fixture-host', 'server_id': 'fixture-server', 'session_id': 'fixture-session',
       'adapter_generation': 'fixture-generation', 'adapter': 'manual',
       'socket_path': str(ROOT / 'unused.sock'), 'token_file': str(TOKEN), 'binding_epoch': 0}]}))
config.chmod(0o600)
enroll = ['admin', 'worker', 'enroll', WORKER, '--host', 'fixture-host', '--repo', 'fixture/repo',
          '--model', 'fixture-model', '--harness', 'codex', '--config', str(config),
          '--home', str(ROOT / 'home'), '--platform', 'linux']
for _ in range(2):
    result = cli(*enroll, code=2)['result']
    assert result['setup_converged'] and not result['converged']
    assert not result['runtime_verified'] and len(result['pending_steps']) == 3
    assert worker_read(host)['binding']['binding_epoch'] == 0
assert not (ROOT / 'unused.sock').exists()

# Rotation scope rejection must leave the old host capability live.
changed = create.copy()
changed[changed.index('--host') + 1] = 'different-host'
cli(*changed, '--rotate', code=1)
assert worker_read(host)['worker']['host_id'] == 'fixture-host'
TOKEN.unlink()
cli(*changed, '--rotate', code=1)
assert worker_read(host)['worker']['host_id'] == 'fixture-host'
cli(*create, '--rotate')
rotated = TOKEN.read_text().strip()
SECRETS.append(rotated)
assert rotated != host
worker_read(host, status=401)
worker_read(rotated)
cli('admin', 'worker', 'revoke', WORKER)
worker_read(rotated, status=401)
cli('admin', 'worker', 'revoke', WORKER)
print('Packaged admin worker bootstrap, scoped captain wire, safe token reuse/rotation and pending runtime status passed')
