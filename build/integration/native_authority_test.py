"""Packaged server-native authority fixture; invented inventory, never a native connection.

The captain-approved descriptor is immutable. Runtime authority is current,
short-lived and default-off for live use. Reads cannot mint/rebind/dispatch.
"""
import concurrent.futures
import copy
import hashlib
import json
import os
import pathlib
import tempfile
import subprocess
import urllib.error
import urllib.request

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-native-captain-capability-32-characters'
WORKER = 'native-authority-fixture'
HOST = 'native-fixture-host'
ACTOR = {'x-agentboard-agent': WORKER, 'x-agentboard-model': 'fixture-model',
         'x-agentboard-harness': 'codex'}
PATH = '/workers/' + WORKER
AUTHORITY = '/hosts/' + HOST + PATH + '/native-authority'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=None, token=None, captain=False, status=200, raw=None, protocol='1', method=None):
    headers = dict(ACTOR, **{'x-agentboard-worker-protocol': protocol})
    if token:
        headers['authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
    if data is not None or raw is not None:
        headers['content-type'] = 'application/json'
    payload = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    request = urllib.request.Request(URL + '/api/v1' + path, data=payload, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    if status is not None:
        assert response.status == status, (path, response.status, body)
    if path.startswith('/hosts/') and response.status == 200:
        assert response.headers.get('cache-control') == 'no-store'
    return body if status is not None else (response.status, body)


def cli(action, document=None, expected_revision=None, key=None, require_manifest=False, succeeds=True):
    with tempfile.TemporaryDirectory(prefix='native-authority-cli-') as directory:
        root = pathlib.Path(directory)
        token = root / 'host-token'
        captain = root / 'captain-token'
        manifest_path = root / 'manifest.json'
        config = root / 'worker.json'
        token.write_text(host + '\n')
        captain.write_text(CAPTAIN + '\n')
        binding = {'agent_id': WORKER, 'model': 'fixture-model', 'harness': 'codex',
                   'host_id': HOST, 'server_id': 'fixture-native',
                   'session_id': '11111111-1111-4111-8111-111111111111',
                   'adapter_generation': 'fixture-pane', 'adapter': 'codex-app-server-v1',
                   'socket_path': str(root / 'absent.sock'), 'token_file': str(token),
                   'binding_epoch': 1, 'repos': ['fixture/repo']}
        config.write_text(json.dumps({'version': 1, 'url': URL, 'journal_dir': str(root / 'journal'),
                                      'bindings': [binding]}))
        if document is not None:
            manifest_path.write_text(json.dumps(document))
        for path in root.iterdir():
            path.chmod(0o600)
        environment = dict(os.environ, AGENT_ID=WORKER, AGENTBOARD_MODEL='fixture-model',
                           AGENTBOARD_HARNESS='codex', AGENTBOARD_CAPTAIN_TOKEN_FILE=str(captain),
                           AGENTBOARD_TOKEN='', AGENTBOARD_TOKEN_FILE='', AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE='')
        command = [os.environ['AB_BINARY'], 'worker', '--config', str(config), '--worker-id', WORKER, '--json']
        if action == 'read':
            command += ['native-authority']
            if require_manifest:
                command += ['--manifest-file', str(manifest_path)]
        else:
            command += ['native-approval', action]
            if document is not None:
                command += ['--manifest-file', str(manifest_path)]
            if expected_revision is not None:
                command += ['--expected-authority-revision', str(expected_revision), '--key', key]
        files = {path.name: path.read_bytes() for path in root.iterdir()}
        result = subprocess.run(command, capture_output=True, text=True, timeout=15, env=environment)
        assert (result.returncode == 0) == succeeds, (result.stdout, result.stderr)
        assert host not in result.stdout + result.stderr and CAPTAIN not in result.stdout + result.stderr
        assert files == {path.name: path.read_bytes() for path in root.iterdir()}
        assert not (root / 'journal').exists() and not (root / 'absent.sock').exists()
        return json.loads(result.stdout) if succeeds else None


def current():
    return api(AUTHORITY, token=host)


def counts():
    # Worker-related rows only: background schedulers cannot perturb this fence.
    return sql("SELECT json_build_array("
               "(SELECT count(*) FROM cooperation_credentials WHERE worker_id='%s'),"
               "(SELECT count(*) FROM cooperation_bindings_versions WHERE version_source_id='%s'),"
               "(SELECT count(*) FROM cooperation_native_approvals WHERE worker_id='%s'),"
               "(SELECT count(*) FROM cooperation_attempts WHERE worker_id='%s'),"
               "(SELECT count(*) FROM cooperation_receipts WHERE worker_id='%s'),"
               "(SELECT count(*) FROM cooperation_deliveries WHERE worker_id='%s'))" % ((WORKER,) * 6))


def manifest(snapshot, name):
    return {
        'manifest_version': 1, 'id': name, 'worker_id': WORKER, 'host_id': HOST,
        'enrollment_revision': snapshot['enrollment_revision'], 'binding_epoch': snapshot['binding_epoch'],
        'session_id': '11111111-1111-4111-8111-111111111111', 'pane_id': 'fixture-pane',
        'socket_path': '/invented/approved.sock', 'initialize_approved': True,
        'endpoint': {'serverId': 'fixture-native', 'endpointId': 'fixture-endpoint', 'generation': '',
                     'profile': 'codex-durable-advisory-v1', 'nativeVersion': '0.162.0',
                     'protocolSource': 'rust-v0.162.0', 'schemaSha256': 'a' * 64,
                     'experimentalApi': True, 'queueApi': True},
        'recipient': {'threadId': '11111111-1111-4111-8111-111111111111',
                      'identityKind': 'durable-conversation-v1',
                      'enrollmentRevision': snapshot['enrollment_revision'],
                      'bindingEpoch': snapshot['binding_epoch'], 'persistent': True, 'topLevel': True},
        'peer': {'pid': 1234, 'uid': os.geteuid(), 'bootId': '22222222-2222-4222-8222-222222222222',
                 'startTicks': 12345678, 'executableSha256': 'b' * 64}}


def request_for(snapshot, name):
    return {'expected_authority_revision': snapshot['authority_revision'],
            'idempotency_key': name + '-key', 'manifest': manifest(snapshot, name)}


def approve(body, **options):
    return api(PATH + '/native-approval', body, captain=True, **options)


def assert_snapshot(snapshot, approval=None):
    assert set(snapshot) == {'protocol_revision', 'authority_contract_revision', 'worker_id', 'host_id',
                             'authority_revision', 'approval_id', 'manifest_sha256', 'manifest',
                             'enrollment_revision', 'binding_epoch', 'permitted', 'reason_codes', 'valid_for_ms'}
    assert snapshot['protocol_revision'] == snapshot['authority_contract_revision'] == 1
    assert snapshot['worker_id'] == WORKER and snapshot['host_id'] == HOST
    assert snapshot['permitted'] is False and snapshot['valid_for_ms'] == 0
    assert 'native_profile_live_disabled' in snapshot['reason_codes']
    if approval is None:
        assert snapshot['approval_id'] is snapshot['manifest_sha256'] is snapshot['manifest'] is None
    else:
        assert snapshot['manifest'] == approval
        assert snapshot['approval_id'] == approval['id']
        canonical = json.dumps(approval, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()
        assert snapshot['manifest_sha256'] == hashlib.sha256(canonical).hexdigest()


rpc(f'Application.put_env(:agentboard, :captain_token, {json.dumps(CAPTAIN)})')
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
api('/agents/register', {'name': 'Native authority fixture'})
provision = {'worker_id': WORKER, 'host_id': HOST, 'repos': ['fixture/repo'],
             'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'native-enroll-1'}
host = api('/workers/provision', provision, captain=True)['host_token']
assert_snapshot(current())
assert current()['authority_revision'] == 0 and current()['binding_epoch'] == 0
caps = {name: {'supported': True, 'reason': 'Invented fixture only'}
        for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bind = {'idempotency_key': 'native-bind-1', 'expected_epoch': 0, 'host_id': HOST,
        'session_id': '11111111-1111-4111-8111-111111111111', 'pane_id': 'fixture-pane',
        'adapter': 'codex-app-server-v1', 'adapter_version': '1', 'capabilities': caps}
bound = api(PATH + '/bind', bind, token=host)
receipt = bound['receipt_token']
assert current()['authority_revision'] == 1
assert api(PATH + '/bind', bind, token=host)['idempotent'] is True
assert current()['authority_revision'] == 1
request = request_for(current(), 'native-approval-1')

# Every auth mode retains separate captain and host checks, without legacy identity trust.
for mode in ('off', 'observe', 'enforce'):
    rpc(f'Application.put_env(:agentboard, :agent_auth_mode, "{mode}")')
    api(PATH + '/native-approval', request, token=host, status=403)
    api(PATH + '/native-retire', {'expected_authority_revision': 1, 'idempotency_key': 'deny'}, token=host, status=403)
    api(AUTHORITY, status=401)
    api(AUTHORITY, token=receipt, status=403)
    api(AUTHORITY, token=CAPTAIN, status=401)
    api(AUTHORITY.replace(HOST, 'foreign-host'), token=host, status=403)
    api(AUTHORITY.replace(WORKER, 'foreign-worker'), token=host, status=401)
    api(AUTHORITY + '?limit=1', token=host, status=422)
    api(AUTHORITY, token=host, protocol='2', status=422)
    assert_snapshot(current())
rpc('Application.put_env(:agentboard, :agent_auth_mode, "off")')

# Closed schemas and exact type/range checks at each nested level.
for path, value in [(['unexpected'], True), (['manifest', 'extra'], True),
                    (['manifest', 'endpoint', 'extra'], True), (['manifest', 'recipient', 'extra'], True),
                    (['manifest', 'peer', 'extra'], True), (['expected_authority_revision'], 1.0),
                    (['manifest', 'manifest_version'], 1.0),
                    (['manifest', 'recipient', 'bindingEpoch'], 1.0),
                    (['manifest', 'peer', 'startTicks'], 9007199254740992),
                    (['manifest', 'peer', 'pid'], True),
                    (['manifest', 'socket_path'], '/invented/../socket'),
                    (['manifest', 'endpoint', 'generation'], 'caller-invented'),
                    (['manifest', 'endpoint', 'profile'], 'codex-native-queue-v1'),
                    (['manifest', 'initialize_approved'], False)]:
    invalid = copy.deepcopy(request)
    cursor = invalid
    for key in path[:-1]:
        cursor = cursor[key]
    cursor[path[-1]] = value
    approve(invalid, status=422)
for key in ('worker_id', 'host_id', 'session_id', 'pane_id'):
    invalid = copy.deepcopy(request)
    invalid['manifest'][key] = 'different-current-binding'
    approve(invalid, status=409)
raw = json.dumps(request).replace('"manifest_version": 1', '"manifest_version": 1, "manifest_version": 1').encode()
api(PATH + '/native-approval', captain=True, raw=raw, status=400)
api(PATH + '/native-approval', captain=True, raw=b'{"padding":"' + b'x' * 17000 + b'"}', status=400)

# Approval/pointer/audit are atomic and ordinary host reads produce no side effects.
before = counts()
sql("CREATE FUNCTION reject_native_approval() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure'; END $$")
sql("CREATE TRIGGER reject_native_pointer BEFORE UPDATE ON cooperation_bindings FOR EACH ROW WHEN (NEW.native_approval_id IS NOT NULL) EXECUTE FUNCTION reject_native_approval()")
approve(request, status=503)
assert counts() == before
sql('DROP TRIGGER reject_native_pointer ON cooperation_bindings')
validated = cli('validate', request['manifest'])
assert validated['validated'] and not validated['native_delivery_enabled']
result = cli('approve', request['manifest'], request['expected_authority_revision'], request['idempotency_key'])
assert set(result) == {'protocol_revision', 'authority_contract_revision', 'authority', 'idempotent'}
assert not result['idempotent'] and result['authority']['authority_revision'] == 2
assert_snapshot(result['authority'], request['manifest'])
assert approve(request)['idempotent']
changed = copy.deepcopy(request)
changed['manifest']['peer']['pid'] += 1
approve(changed, status=409)
before = counts()
for _ in range(3):
    assert_snapshot(current(), request['manifest'])
assert counts() == before
assert cli('read') == current()
cli('read', request['manifest'], require_manifest=True, succeeds=False)
# Approval never changes the separate activation gate.
assert not current()['permitted']
meta = api('/meta')
assert meta['native_authority_contract_revision'] == 1 and not meta['native_authority_live_enabled']
assert meta['schema_version'] == meta['required_schema_version'] == 48
# Real positive snapshots come only from this isolated fixture's explicit gate.
rpc('Application.put_env(:agentboard, :native_authority_enabled, true)')
before = counts()
positive = current()
assert positive['permitted'] is True and positive['reason_codes'] == [] and positive['valid_for_ms'] == 5000
assert positive['manifest'] == request['manifest'] and positive['authority_revision'] == 2
assert cli('read', request['manifest'], require_manifest=True) == positive
assert counts() == before
rpc('Application.put_env(:agentboard, :native_authority_enabled, false)')
assert_snapshot(current(), request['manifest'])

# SQL shape guards also reject partial retirement tuples (CHECK NULL is not true).
partial = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c',
                          "UPDATE cooperation_bindings SET native_retire_key='partial' WHERE id='" + WORKER + "'"],
                         capture_output=True, text=True)
assert partial.returncode != 0

# Immutable table rejects mutation/deletion, including raw database paths.
for statement in ["UPDATE cooperation_native_approvals SET manifest_sha256=repeat('c',64)",
                  'DELETE FROM cooperation_native_approvals', 'TRUNCATE cooperation_native_approvals CASCADE']:
    attempt = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', statement], capture_output=True, text=True)
    assert attempt.returncode != 0, statement

# Pause/resume fences are real transitions; neither changes enrollment or binding identity.
identity = (current()['enrollment_revision'], current()['binding_epoch'])
for operation, expected in [('pause', 3), ('pause', 3), ('resume', 4), ('resume', 4)]:
    api(PATH + '/' + operation, {'binding_epoch': 1}, token=host)
    snapshot = current()
    assert snapshot['authority_revision'] == expected
    assert (snapshot['enrollment_revision'], snapshot['binding_epoch']) == identity
    assert_snapshot(snapshot, request['manifest'])
    assert ('paused' in snapshot['reason_codes']) == (operation == 'pause')
approve(request, status=409)  # Old key cannot restore old authority.

# Retirement retains historical evidence, clears pointer, and has exact CAS/no-op retries.
retire = {'expected_authority_revision': 4, 'idempotency_key': 'native-retire-1'}
result = cli('retire', expected_revision=retire['expected_authority_revision'], key=retire['idempotency_key'])
assert result['authority']['authority_revision'] == 5
assert_snapshot(result['authority'])
assert api(PATH + '/native-retire', retire, captain=True)['idempotent']
api(PATH + '/native-retire', dict(retire, expected_authority_revision=5), captain=True, status=409)
assert sql("SELECT count(*) FROM cooperation_native_approvals WHERE worker_id='%s'" % WORKER) == '1'
noop = {'expected_authority_revision': 5, 'idempotency_key': 'native-retire-noop'}
assert cli('retire', expected_revision=5, key=noop['idempotency_key'])['authority']['authority_revision'] == 5
assert api(PATH + '/native-retire', noop, captain=True)['idempotent']

# One winner for concurrent approval at one expected authority revision.
requests = [request_for(current(), 'native-race-' + str(n)) for n in range(2)]
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda body: api(PATH + '/native-approval', body, captain=True, status=None), requests))
assert sorted(status for status, _ in results) == [200, 409], results
winner = next(body['authority']['manifest'] for status, body in results if status == 200)
assert current()['authority_revision'] == 6

# Model changes and managed-scope narrowing are reflected immediately, without granting new authority.
api('/agents/register', {'name': 'Native authority fixture'})
sql("UPDATE agents SET model='other-model' WHERE id='%s'" % WORKER)
assert 'enrollment_identity_stale' in current()['reason_codes']
sql("UPDATE agents SET model='fixture-model' WHERE id='%s'" % WORKER)
api('/availability', {'agent_id': WORKER, 'state': 'out_of_service', 'reason': 'Fixture'}, token=CAPTAIN)
assert 'agent_unavailable' in current()['reason_codes']
api('/availability', {'agent_id': WORKER, 'state': 'active', 'reason': 'Fixture'}, token=CAPTAIN)
rpc('Application.put_env(:agentboard, :native_authority_enabled, true)')
assert current()['permitted'] is True
scope_path = '/agents/' + WORKER + '/scope'
scope = {'revision': 0, 'allowed_repos': ['fixture/other'], 'required_labels': [], 'allowed_labels': []}
api(scope_path, scope, token=CAPTAIN, method='PUT')
before = counts()
narrowed = current()
assert narrowed['permitted'] is False and narrowed['valid_for_ms'] == 0
assert 'seat_scope_changed' in narrowed['reason_codes']
assert narrowed['authority_revision'] == 6  # Policy reads are not a lifecycle history.
assert counts() == before
api(scope_path, dict(scope, revision=1, allowed_repos=['fixture/repo']), token=CAPTAIN, method='PUT')
before = counts()
assert current()['permitted'] is True and current()['authority_revision'] == 6
assert counts() == before
rpc('Application.put_env(:agentboard, :native_authority_enabled, false)')


# Rebind, unbind, revoke and reenrollment invalidate descriptors and bump only their fences.
bind2 = dict(bind, expected_epoch=1, idempotency_key='native-bind-2')
api(PATH + '/bind', bind2, token=host)
assert current()['authority_revision'] == 7 and current()['binding_epoch'] == 2
assert_snapshot(current())
assert current()['enrollment_revision'] == identity[0]
request2 = request_for(current(), 'native-approval-2')
approve(request2)
assert current()['authority_revision'] == 8
api(PATH + '/unbind', {'binding_epoch': 2}, token=host)
assert current()['authority_revision'] == 9 and current()['binding_epoch'] == 3
assert_snapshot(current())
api(PATH + '/revoke', {}, captain=True)
assert sql("SELECT native_authority_revision FROM cooperation_bindings WHERE id='%s'" % WORKER) == '10'
api(PATH + '/revoke', {}, captain=True)
assert sql("SELECT native_authority_revision FROM cooperation_bindings WHERE id='%s'" % WORKER) == '10'
api(AUTHORITY, token=host, status=401)
host = api('/workers/provision', dict(provision, idempotency_key='native-enroll-2'), captain=True)['host_token']
assert current()['authority_revision'] == 11
assert current()['enrollment_revision'] != identity[0]
assert_snapshot(current())
assert 'host_token' not in api('/workers/provision', dict(provision, idempotency_key='native-enroll-2'), captain=True)
assert current()['authority_revision'] == 11
print('Native authority packaged fixture passed: closed manifest, captain/host auth, immutable CAS, lifecycle, read-only default-off snapshots')
