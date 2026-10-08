"""Real Phoenix + Go host + Codex bridge; native model peer remains invented."""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

URL = os.environ['AGENTBOARD_URL']
WORKER = 'fixture-codex-worker'
CAPTAIN = 'fixture-codex-captain-capability-32-characters'
ACTOR = {'x-agentboard-agent': WORKER, 'x-agentboard-model': 'fixture-model', 'x-agentboard-harness': 'codex'}


def api(path, body=None, token=None, captain=False):
    headers = dict(ACTOR, **{'x-agentboard-worker-protocol': '1'})
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
        if path == '/availability':
            headers['Authorization'] = 'Bearer ' + CAPTAIN
    if body is not None:
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(URL + '/api/v1' + path, headers=headers,
                                    data=json.dumps(body).encode() if body is not None else None)
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    value = json.load(response)
    assert response.status == 200, (path, response.status, value.get('error', {}).get('code'))
    return value


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, 'Packaged fixture initialization failed'


def atomic_json(file, value):
    temp = file.with_suffix('.next')
    temp.write_text(json.dumps(value))
    temp.chmod(0o600)
    temp.replace(file)


def until(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('Required packaged conformance condition did not arrive')


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
api('/agents/register', {'name': 'Invented isolated Codex conformance'})
host = api('/workers/provision', {'worker_id': WORKER, 'host_id': 'fixture-codex-host',
           'repos': ['fixture/codex'], 'model': 'fixture-model', 'harness': 'codex',
           'idempotency_key': 'fixture-codex-provision'}, captain=True)['host_token']

with tempfile.TemporaryDirectory(prefix='ab-cp-', dir='/tmp') as temporary:
    root = pathlib.Path(temporary)
    root.chmod(0o700)
    socket = root / 's'
    config = root / 'worker.json'
    control = root / 'control.json'
    log = root / 'native.jsonl'
    native = root / 'native'
    shutil.copyfile(os.environ['CODEX_TEST_FIXTURE'], native)
    native.chmod(0o700)
    token = root / 'host-token'
    token.write_text(host)
    token.chmod(0o600)
    binding = {'agent_id': WORKER, 'model': 'fixture-model', 'harness': 'codex',
               'host_id': 'fixture-codex-host', 'server_id': 'fixture-server',
               'session_id': 'unbound', 'adapter_generation': 'unbound',
               'adapter': 'codex-app-server-v1', 'socket_path': str(socket),
               'token_file': str(token), 'binding_epoch': 0}
    cfg = {'version': 1, 'url': URL, 'journal_dir': str(root / 'journal'), 'bindings': [binding]}
    atomic_json(config, cfg)
    atomic_json(control, {})
    profile = root / 'profile.json'
    atomic_json(profile, {'version': 1, 'worker_id': WORKER, 'worker_config': str(config),
                'worker_binary': os.environ['AB_BINARY'], 'codex_binary': str(native),
                'codex_sha256': hashlib.sha256(native.read_bytes()).hexdigest(),
                'cwd': str(root), 'socket_path': str(socket), 'sandbox': 'read-only',
                'approval_policy': 'on-request'})
    # The bridge, host and invented native child receive no database inputs.
    child_env = {key: value for key, value in os.environ.items()
                 if not key.startswith(('DATABASE_', 'PG', 'FIXTURE_'))}
    child_env.update(CODEX_FIXTURE_CONTROL=str(control), CODEX_FIXTURE_LOG=str(log))
    bridge = subprocess.Popen([os.environ['CODEX_TEST_NODE'], os.environ['CODEX_TEST_BRIDGE'],
                               '--activate', str(profile)], env=child_env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process = None

    def cli(*args, success=True):
        result = subprocess.run([os.environ['AB_BINARY'], 'worker', *args, '--config', str(config), '--json'],
                                env=child_env, capture_output=True, text=True, timeout=15)
        if not success:
            return result
        assert result.returncode == 0, 'Scoped worker CLI failed'
        return json.loads(result.stdout)

    def records():
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def model_tool(name, arguments, result_count):
        atomic_json(control, {'revision': str(time.monotonic()), 'tool': {'name': name, 'args': arguments}})
        replies = until(lambda: (values if len(values := [r['native']['result'] for r in records()
                           if 'native' in r and 'method' not in r['native'] and 'result' in r['native']]) >= result_count else None))
        return replies[-1]

    try:
        descriptor = pathlib.Path(str(socket) + '.identity.json')
        until(lambda: descriptor.exists() and socket.exists())
        identity = json.loads(descriptor.read_text())
        binding.update(session_id=identity['session_id'], adapter_generation=identity['generation'])
        atomic_json(config, cfg)
        bound = cli('bind', '--key', 'fixture-codex-bind')
        assert bound['binding_epoch'] == 1
        cli('doctor')
        # This independent assertion deliberately fails on the old server:
        # absent availability cannot establish the approved pre-write fence.
        state = cli('state')['state']
        assert state['worker'].get('availability', {}).get('state') == 'active', 'scoped state must expose effective availability'
        # Availability follows the current registered Agent, not its old enrollment.
        policy = api('/availability', {'harness': 'codex', 'model_pattern': 'fixture-changed-model',
                     'state': 'reserved', 'reason': 'Invented current-model policy'}, captain=True)['policy']
        ACTOR['x-agentboard-model'] = 'fixture-changed-model'
        api('/agents/register', {'name': 'Invented isolated Codex conformance'})
        ACTOR['x-agentboard-model'] = 'fixture-model'
        changed = cli('state')['state']['worker']
        assert changed['model'] == 'fixture-model', 'enrollment model is retained'
        assert changed['availability']['state'] == 'reserved'
        assert changed['availability']['source'] == policy['id']
        assert changed['availability'] == api('/agents/' + WORKER)['agent']['availability'], 'effective map is preserved'
        api('/agents/register', {'name': 'Invented isolated Codex conformance'})
        assert cli('state')['state']['worker']['availability']['state'] == 'active'
        rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
        for task in ['fixture-codex-source-a', 'fixture-codex-source-b']:
            api('/tasks', {'id': task, 'title': 'Invented Codex source', 'repo': 'fixture/codex'})
        process = subprocess.Popen([os.environ['AB_BINARY'], 'worker', 'serve', '--config', str(config), '--json'],
                                   env=child_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        frozen = until(lambda: (state if ((state := api('/workers/' + WORKER + '/state', token=host)).get('active_attempt') or {}).get('status') == 'submitted' else None))['active_batch']
        assert len(frozen['delivery_ids']) == 2
        assert len([r for r in records() if r.get('native', {}).get('method') == 'turn/start']) == 1
        pending = api('/workers/' + WORKER + '/pending', token=host)['deliveries']
        assert all(d['state'] == 'pending' for d in pending), 'native acceptance manufactures no receipt'
        api('/availability', {'agent_id': WORKER, 'state': 'out_of_service', 'reason': 'Invented conformance maintenance'}, captain=True)
        assert cli('state')['state']['worker']['availability']['state'] == 'out_of_service'
        checked = model_tool('agentboard_check_in', {}, 1)
        assert checked['success'] is True
        assert len(checked['contentItems']) == 1
        explicit = json.loads(checked['contentItems'][0]['text'])
        assert explicit['state']['worker']['availability']['state'] == 'out_of_service'
        assert 'AGENTBOARD SOURCE FRAME' not in checked['contentItems'][0]['text']
        denied = model_tool('agentboard_ack', {'kind': 'handled', 'ids': ['invented-foreign-delivery'], 'key': 'fixture-foreign'}, 2)
        assert denied['success'] is False
        received = model_tool('agentboard_ack', {'kind': 'received', 'ids': frozen['delivery_ids'], 'key': 'fixture-received'}, 3)
        assert received['success'] is True, 'unavailable workers retain exact receipt access'
        handled = model_tool('agentboard_ack', {'kind': 'handled', 'ids': frozen['delivery_ids'], 'key': 'fixture-handled'}, 4)
        assert handled['success'] is True
        assert api('/workers/' + WORKER + '/pending', token=host)['deliveries'] == []
        assert len([r for r in records() if r.get('native', {}).get('method') == 'turn/start']) == 1
    finally:
        if process:
            process.terminate()
            output, error = process.communicate(timeout=5)
            assert host.encode() not in output + error
        bridge.terminate()
        try:
            output, error = bridge.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            bridge.kill()
            output, error = bridge.communicate()
        assert host.encode() not in output + error

print('Packaged Phoenix + actual Go host/receipts + Codex bridge conformance passed; native model peer invented, no installed-model or production enrollment claim')
