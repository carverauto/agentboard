"""Packaged shared-bot inbound acceptance over real HTTP/WS and PostgreSQL.

Owns the new protected inbox contract: subscribe-before-reread, stable overlapping
history plus exact versions, verified attribution, ephemeral source inspection,
recovery gaps and scoped idempotent handling. Existing conversation tests own
send/read snapshots. All identities/messages/credentials are invented. No
production test-only injection or source-code assertions.
"""
import base64
import hashlib
import http.server
import json
import os
import socket
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ['AGENTBOARD_URL'] + '/api/v1'
TOKEN = 'fixture-shared-bot-token'
CAPTAIN = 'fixture-inbound-captain-capability-32'
LOCK = threading.RLock()
POSTS = {}
CHANNELS = ['room']
SOCKETS = []
FAILURES = []
AUTHENTICATED = threading.Event()
ACCEPT_WS = True
DENIED = set()
RACE = False
SEQ = 0
REQUESTS = []
RATE429 = False


def post(id, message='@worker-b hello', user='human-1', channel='room', root='', props=None):
    return dict(id=id, channel_id=channel, user_id=user, root_id=root, props=props or {},
                message=message, create_at=1000, update_at=1000, edit_at=0, delete_at=0,
                type='', file_ids=[])


def frame(sock, payload, opcode=1):
    data = json.dumps(payload).encode() if isinstance(payload, dict) else payload
    n = len(data)
    header = bytes([128 | opcode, n]) if n < 126 else bytes([128 | opcode, 126]) + struct.pack('!H', n)
    sock.sendall(header + data)


def exact(stream, n):
    data = stream.read(n)
    if len(data) != n:
        raise EOFError()
    return data


def receive(stream):
    a, b = exact(stream, 2)
    assert b & 128, 'client WebSocket frames must be masked'
    n = b & 127
    if n == 126:
        n = struct.unpack('!H', exact(stream, 2))[0]
    elif n == 127:
        n = struct.unpack('!Q', exact(stream, 8))[0]
    assert n <= 1 << 20
    mask = exact(stream, 4)
    return a & 15, bytes(c ^ mask[i % 4] for i, c in enumerate(exact(stream, n)))


def emit(kind, data):
    global SEQ
    with LOCK:
        SEQ += 1
        for sock in list(SOCKETS):
            try:
                frame(sock, dict(event=kind, seq=SEQ, data=data))
            except OSError:
                pass


class MM(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def rate_limited(self):
        self.send_response(429)
        self.send_header('Retry-After', '5')
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'{}')

    def do_GET(self):
        global RACE, SEQ
        REQUESTS.append(self.path)
        path = urllib.parse.urlparse(self.path)
        if path.path == '/api/v4/websocket':
            if not ACCEPT_WS:
                return self.reply({}, 503)
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            try:
                opcode, data = receive(self.rfile)
                auth = json.loads(data)
                assert opcode == 1 and auth['action'] == 'authentication_challenge'
                assert auth['data']['token'] == TOKEN
                with LOCK:
                    SEQ = 0
                    frame(self.connection, dict(seq_reply=1, status='OK'))
                    frame(self.connection, dict(event='hello', seq=0, data={'server_version': 'fixture'}))
                    SOCKETS.append(self.connection)
                    AUTHENTICATED.set()
                while True:
                    opcode, data = receive(self.rfile)
                    if opcode == 9:
                        frame(self.connection, data, 10)
                    elif opcode == 8:
                        frame(self.connection, b'', 8)
                        break
            except (EOFError, OSError):
                pass
            except Exception as error:
                FAILURES.append(repr(error))
            finally:
                with LOCK:
                    if self.connection in SOCKETS:
                        SOCKETS.remove(self.connection)
                self.close_connection = True
            return
        assert self.headers.get('Authorization') == 'Bearer ' + TOKEN
        if path.path == '/api/v4/users/me':
            return self.reply(dict(id='shared-bot', roles='system_user', is_bot=True))
        if path.path == '/api/v4/users/me/channels':
            assert AUTHENTICATED.is_set(), 'history discovery preceded authenticated subscription'
            return self.reply([dict(id=id) for id in CHANNELS])
        if path.path.startswith('/api/v4/channels/') and path.path.endswith('/posts'):
            assert AUTHENTICATED.is_set(), 'history preceded authenticated subscription'
            if RATE429:
                return self.rate_limited()
            channel = path.path.split('/')[4]
            if channel in DENIED:
                return self.reply({}, 403)
            query = urllib.parse.parse_qs(path.query)
            page = int(query.get('page', ['0'])[0])
            with LOCK:
                selected = sorted((p for p in POSTS.values() if p['channel_id'] == channel and not p['delete_at']),
                                  key=lambda p: (p['create_at'], p['id']), reverse=True)
                selected = selected[page * 60:(page + 1) * 60]
                response = dict(order=[p['id'] for p in selected], posts={p['id']: dict(p) for p in selected})
                if RACE and channel == 'room' and page == 0:
                    RACE = False
                    POSTS['zz-page-live'] = post('zz-page-live', '@worker-b concurrent live/page arrival')
                    emit('posted', {'post': json.dumps(POSTS['zz-page-live'])})
                    POSTS['p-001']['message'] = '@worker-b edited at the same timestamp'
                    emit('post_edited', {'post': json.dumps(POSTS['p-001'])})
            return self.reply(response)
        if path.path.startswith('/api/v4/posts/'):
            id = path.path.split('/')[-1]
            with LOCK:
                value = POSTS.get(id)
                if value is None or value['channel_id'] in DENIED or value['delete_at']:
                    return self.reply({}, 404)
                return self.reply(value)
        return self.reply({}, 404)


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def api(path, body=None, token=None, actor='worker-a', status=200, captain=False):
    headers = {'x-agentboard-agent': actor, 'x-agentboard-model': 'fixture-model', 'x-agentboard-harness': 'codex',
               'x-agentboard-worker-protocol': '1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
    if body is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    value = json.load(response)
    assert response.status == status, (path, response.status, value)
    return value


def wait(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('inbox condition did not converge: ' + sql("SELECT connected::text||':'||reason FROM mattermost_inbound_runs") + '; coverage=' + json.dumps(inbox()[1]) + '; WS failures=' + repr(FAILURES) + '; requests=' + repr(REQUESTS[-10:]) + '; config=' + rpc('IO.inspect(case Agentboard.Mattermost.Inbound.config() do {:ok, _} -> :ok; error -> error end)'))


def inbox(worker='worker-b'):
    result, cursor, coverage = [], '', []
    while True:
        page = api('/workers/' + worker + '/mattermost_inbox' + ('?cursor=' + cursor if cursor else ''), token=TOKENS[worker])
        result += page['items']
        coverage = page['coverage']
        cursor = page['next_cursor']
        if not cursor:
            return result, coverage


def find(id, worker='worker-b'):
    return next((i for i in inbox(worker)[0] if i['post_id'] == id), None)


def read(item, worker='worker-b'):
    return api('/workers/' + worker + '/mattermost_read', dict(id=item['id'], version=item['version']), token=TOKENS[worker])['items'][0]


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MM)
threading.Thread(target=server.serve_forever, daemon=True).start()
TOKENS = {}
rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
for worker in ('worker-a', 'worker-b'):
    api('/agents/register', dict(name=worker), actor=worker)
    TOKENS[worker] = api('/workers/provision', dict(worker_id=worker, host_id='fixture-host', repos=['fixture/repo'],
                      model='fixture-model', harness='codex', idempotency_key='provision-' + worker), captain=True)['host_token']
api('/tasks', dict(id='fixture-task', title='Fixture task', repo='fixture/repo'))
# Default-off acceptance does not touch Mattermost or consume inbox entries.
assert inbox()[0] == []
assert not AUTHENTICATED.is_set()
for i in range(70):
    POSTS['p-%03d' % i] = post('p-%03d' % i)
POSTS['own'] = post('own', user='shared-bot', props=dict(agent_id='worker-b', msg_id='own-msg', task_id='general'))
POSTS['bot-peer'] = post('bot-peer', user='shared-bot', props=dict(agent_id='worker-a', msg_id='peer-msg', task_id='fixture-task', kind='handoff'))
POSTS['human-forged'] = post('human-forged', user='human-2', props=dict(agent_id='worker-b', msg_id='fake', task_id='nonexistent'))
POSTS['root'] = post('root', '', user='shared-bot', props=dict(agent_id='worker-a', msg_id='root-msg', task_id='fixture-task'))
POSTS['reply'] = post('reply', 'human thread reply', root='root')
POSTS['bridge'] = post('bridge', user='shared-bot', props=dict(agentboard_event_marker='agentboard:message:1:notice'))
POSTS['zz-poison-1'] = post('zz-poison-1', '@worker-b ' + 'x' * 70000)
POSTS['zz-poison-2'] = post('zz-poison-2', '@worker-b poison root', root='missing-root-post')
POSTS['zz-poison-0-sibling'] = post('zz-poison-0-sibling', '@worker-b valid sibling after poison')
POSTS['zz-task-1'] = post('zz-task-1', '@worker-b task post', user='shared-bot', props=dict(agent_id='worker-a', msg_id='task-1-msg', task_id='fixture-task'))
RACE = True
rpc('Application.put_env(:agentboard, :mattermost_inbound_history_start_ms, 0)')
rpc('Application.put_env(:agentboard, :mattermost_base_url, ' + json.dumps('http://127.0.0.1:%d' % server.server_port) + ')')
rpc('Application.put_env(:agentboard, :mattermost_bot_token, ' + json.dumps(TOKEN) + ')')
rpc('Application.put_env(:agentboard, :mattermost_inbound_repo, "fixture/repo")')
rpc('Application.put_env(:agentboard, :mattermost_inbound_enabled, true)')
wait(lambda: any('uninspectable_post' in c['incomplete_reason'] for c in inbox()[1]))
items, coverage = inbox()
assert len([i for i in items if i['post_id'].startswith('p-')]) >= 70
assert len([i for i in items if i['post_id'] == 'zz-page-live']) == 1
assert not any(i['post_id'] in ('own', 'bridge') for i in items)
assert find('bot-peer')['sender_agent_id'] == 'worker-a'
assert find('bot-peer')['kind'] == 'handoff'
assert find('human-forged')['sender_agent_id'] is None
assert read(find('human-forged'))['user_id'] == 'human-2'
assert find('reply', 'worker-a')['task_id'] == 'fixture-task'
assert find('zz-task-1')['task_id'] == 'fixture-task'
room_cov = next(c for c in coverage if c['channel_id'] == 'room')
assert not room_cov['caught_up'] and not room_cov['history_complete']
assert 'uninspectable_post' in room_cov['incomplete_reason']
assert 'zz-poison-1' in room_cov['incomplete_reason'] and 'zz-poison-2' in room_cov['incomplete_reason']
assert find('zz-poison-1') is None and find('zz-poison-2') is None
assert all('message' not in i for i in items)
first = api('/workers/worker-b/mattermost_inbox', token=TOKENS['worker-b'])
assert first['next_cursor'], 'expected multiple inbox pages for bounded-walk proof'
with LOCK:
    POSTS['paged-race'] = post('paged-race', '@worker-b paged race arrival')
    emit('posted', {'post': json.dumps(POSTS['paged-race'])})
wait(lambda: find('paged-race'))
walk_ids = [i['post_id'] for i in first['items']]
page = api('/workers/worker-b/mattermost_inbox?cursor=' + urllib.parse.quote(first['next_cursor'], safe=''), token=TOKENS['worker-b'])
while True:
    walk_ids += [i['post_id'] for i in page['items']]
    if not page['next_cursor']:
        break
    page = api('/workers/worker-b/mattermost_inbox?cursor=' + urllib.parse.quote(page['next_cursor'], safe=''), token=TOKENS['worker-b'])
assert 'paged-race' not in walk_ids, 'bounded walk must exclude arrivals committed after it started'
assert find('paged-race') is not None, 'excluded arrival must remain visible on the next walk'
# A repeated history scan/WS replay cannot create another exact recipient/version.
assert len({(i['post_id'], i['version']) for i in items}) == len(items)
item = find('bot-peer')
api('/workers/worker-a/mattermost_read', dict(id=item['id'], version=item['version']), token=TOKENS['worker-a'], status=403)
api('/workers/worker-b/mattermost_read', dict(id=item['id'], version=item['version']), token=TOKENS['worker-a'], status=401)
assert read(item)['message'] == '@worker-b hello'
# Real portable CLI checkpoints read the new advertised seam with board-only credentials.
from pathlib import Path
root = Path(os.environ['TEST_TMPDIR']) / 'inbox-worker'
root.mkdir(mode=0o700)
token_file = root / 'token'
token_file.write_text(TOKENS['worker-b'])
token_file.chmod(0o600)
capabilities = {name: dict(supported=name in ('receipt', 'recovery'), reason='Manual fixture')
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bound = api('/workers/worker-b/bind', dict(expected_epoch=0, host_id='fixture-host', idempotency_key='bind-b',
            session_id='fixture-session', pane_id='fixture-generation', adapter='manual', adapter_version='1',
            capabilities=capabilities), token=TOKENS['worker-b'])
receipt_file = root / 'token.receipt'
receipt_file.write_text(bound['receipt_token'])
receipt_file.chmod(0o600)
config = dict(version=1, url=os.environ['AGENTBOARD_URL'], journal_dir=str(root / 'journal'),
              bindings=[dict(agent_id='worker-b', model='fixture-model', harness='codex', host_id='fixture-host',
                             server_id='fixture-server', session_id='fixture-session', adapter_generation='fixture-generation',
                             adapter='manual', socket_path=str(root / 'unused-socket'), token_file=str(token_file), binding_epoch=1)])
config_file = root / 'config.json'
config_file.write_text(json.dumps(config))
config_file.chmod(0o600)
cli = subprocess.run([os.environ['AB_BINARY'], 'worker', 'check-in', '--config', str(config_file), '--worker-id', 'worker-b', '--json'],
                     env=dict(os.environ, AGENT_ID='worker-b', AGENTBOARD_HARNESS='codex', AGENTBOARD_MODEL='fixture-model'),
                     capture_output=True, text=True, timeout=15)
assert cli.returncode == 0, cli.stderr
checkpoint = json.loads(cli.stdout)
assert TOKEN not in cli.stdout
assert any(i['post_id'] == 'bot-peer' for page in checkpoint['mattermost_inbox'] for i in page['items'])
assert find('bot-peer')['id'] == item['id'], 'reads must not acknowledge'
api('/workers/worker-b/mattermost_ack', dict(items=[dict(id=item['id'], version='0' * 64)]), token=TOKENS['worker-b'], status=403)
ack = dict(items=[dict(id=item['id'], version=item['version'])])
api('/workers/worker-b/mattermost_ack', ack, token=TOKENS['worker-b'])
stamp = sql("SELECT handled_at FROM mattermost_inbox WHERE id='%s'" % item['id'])
api('/workers/worker-b/mattermost_ack', ack, token=TOKENS['worker-b'])
assert sql("SELECT handled_at FROM mattermost_inbox WHERE id='%s'" % item['id']) == stamp
assert find('bot-peer') is None
# New bot-joined DM is discovered before its buffered post routes.
with LOCK:
    CHANNELS.append('new-dm')
    POSTS['dm'] = post('dm', channel='new-dm')
    emit('direct_added', {'channel_id': 'new-dm'})
    emit('posted', {'post': json.dumps(POSTS['dm'])})
wait(lambda: find('dm'))
dm_cov = next(c for c in inbox()[1] if c['channel_id'] == 'new-dm')
assert dm_cov['history_complete'] and dm_cov['incomplete_reason'] == 'historical_deletions_unprovable'
# Live edit with unchanged timestamps is a distinct version; old body is unavailable.
old = find('p-002')
with LOCK:
    POSTS['p-002']['message'] = '@worker-b newest source'
    emit('post_edited', {'post': json.dumps(POSTS['p-002'])})
new = wait(lambda: next((i for i in inbox()[0] if i['post_id'] == 'p-002' and i['version'] != old['version']), None))
assert read(old)['source_state'] == 'source_unavailable'
assert read(new)['message'] == '@worker-b newest source'
# A bad live event is dropped with gap evidence while a valid sibling routes and the stream stays up.
with LOCK:
    POSTS['live-poison'] = post('live-poison', '@worker-b bad\x00live event')
    emit('posted', {'post': json.dumps(POSTS['live-poison'])})
    POSTS['live-sibling'] = post('live-sibling', '@worker-b live sibling after bad event')
    emit('posted', {'post': json.dumps(POSTS['live-sibling'])})
wait(lambda: find('live-sibling'))
assert find('live-poison') is None
wait(lambda: any(c['live_connected'] for c in inbox()[1]))
# Buffered posts from a denied channel are dropped while allowed siblings continue.
rpc('Application.put_env(:agentboard, :mattermost_channel_allowlist, "room,new-dm")')
with LOCK:
    CHANNELS.append('late-denied')
    for i in range(5):
        POSTS['denied-%d' % i] = post('denied-%d' % i, '@worker-b denied %d' % i, channel='late-denied')
        emit('posted', {'post': json.dumps(POSTS['denied-%d' % i])})
    POSTS['allowed-after-deny'] = post('allowed-after-deny', '@worker-b kept after denied split')
    emit('posted', {'post': json.dumps(POSTS['allowed-after-deny'])})
wait(lambda: find('allowed-after-deny'))
assert find('denied-0') is None
wait(lambda: any(c['channel_id'] == 'late-denied' and ('live_channel_not_authorized' in c['incomplete_reason'] or 'membership_or_allowlist_revoked' in c['incomplete_reason']) for c in inbox()[1]))
assert any(c['live_connected'] for c in inbox()[1]), 'denied-channel split must not disconnect the stream'
# Controlled 429 retains Retry-After cooldown instead of immediate reclaim.
RATE429 = True
emit('direct_added', {'channel_id': 'new-dm'})
wait(lambda: any('rate_limited' in c['incomplete_reason'] for c in inbox()[1]))
takeover = rpc('IO.inspect(case Agentboard.Mattermost.Inbound.base_config() do {:ok, cfg} -> Agentboard.Mattermost.InboundStore.claim(cfg); error -> error end)')
assert 'another_owner' in takeover, 'takeover=' + takeover + ' lease=' + sql('SELECT reason || chr(58) || expires_at::text FROM mattermost_inbound_runs')
before = len([r for r in REQUESTS if '/posts?' in r])
time.sleep(3)
assert len([r for r in REQUESTS if '/posts?' in r]) == before, 'source requests must not immediately repeat during cooldown'
row = sql("SELECT reason || ':' || (expires_at > clock_timestamp())::text FROM mattermost_inbound_runs")
assert row.startswith('rate_limited:true'), 'durable delayed lease expiry required, got ' + row
RATE429 = False
wait(lambda: any(c['live_connected'] for c in inbox()[1]))
# Downtime/reconnect replays missed posts; deletes/retention remain explicit gaps.
ACCEPT_WS = False
with LOCK:
    for sock in list(SOCKETS):
        sock.shutdown(socket.SHUT_RDWR)
        sock.close()
wait(lambda: all(not c['live_connected'] for c in inbox()[1]))
with LOCK:
    POSTS['downtime'] = post('downtime', '@worker-b arrived offline')
    POSTS.pop('p-003')
ACCEPT_WS = True
wait(lambda: find('downtime'))
wait(lambda: any('known_post_unavailable' in c['incomplete_reason'] and 'p-003' in c['incomplete_reason'] for c in inbox()[1]))
assert read(find('p-003'))['source_state'] == 'source_unavailable'
DENIED.add('room')
assert read(find('downtime'))['source_state'] == 'source_unavailable'
assert find('downtime') is not None, 'unavailable inspection must retain pending state'
# Metadata capacity leaves an explicit gap instead of a crash loop; pending retained.
DENIED.discard('room')
source = sql("SELECT source FROM mattermost_inbound_runs")
sql("INSERT INTO mattermost_post_versions(source,channel_id,post_id,version,user_id,root_id,update_at,delete_at,observed_at) SELECT '%s','seed-chan','seed-'||g,'v'||g,'u','',0,0,clock_timestamp() FROM generate_series(1,100000) g ON CONFLICT DO NOTHING" % source)
assert int(sql("SELECT count(*) FROM mattermost_post_versions WHERE source='%s'" % source)) >= 100000
run_before = sql("SELECT run_id::text FROM mattermost_inbound_runs")
with LOCK:
    POSTS['cap-probe'] = post('cap-probe', '@worker-b capacity probe')
    emit('posted', {'post': json.dumps(POSTS['cap-probe'])})
wait(lambda: any('metadata_capacity_reached' in c['incomplete_reason'] for c in inbox()[1]))
assert find('cap-probe') is None, 'new versions are refused at capacity'
with LOCK:
    emit('posted', {'post': json.dumps(POSTS['dm'])})
time.sleep(2)
assert len([i for i in inbox()[0] if i['post_id'] == 'dm']) == 1, 'recorded versions replay idempotently'
assert find('downtime') is not None, 'pending versions retained at capacity'
time.sleep(6)
assert sql("SELECT run_id::text FROM mattermost_inbound_runs") == run_before, 'no hot re-claim loop at capacity'
assert any(c['live_connected'] for c in inbox()[1]), 'owner stays connected at capacity'
# Lease supersession aborts cleanly: typed owner_expired, no stale writes, reclaim recovers.
inbox_before = len(inbox()[0])
versions_before = int(sql("SELECT count(*) FROM mattermost_post_versions WHERE source='%s'" % source))
run_before = sql("SELECT run_id::text FROM mattermost_inbound_runs")
rpc('Application.put_env(:agentboard, :mattermost_inbound_enabled, false)')
wait(lambda: sql("SELECT reason FROM mattermost_inbound_runs") == 'disabled')
taken = rpc('IO.inspect(case Agentboard.Mattermost.Inbound.base_config() do {:ok, b} -> Agentboard.Mattermost.InboundStore.claim(b); e -> e end)')
assert ':ok' in taken, 'takeover of expired lease must succeed, got ' + taken
assert sql("SELECT run_id::text FROM mattermost_inbound_runs") != run_before, 'takeover must install a new run'
stale = rpc('IO.inspect(case Agentboard.Mattermost.Inbound.base_config() do {:ok, b} -> stale = Map.merge(b, %{source: Agentboard.Mattermost.InboundStore.source(b), run: Ecto.UUID.cast!("' + run_before + '")}); {Agentboard.Mattermost.InboundStore.coverage(stale, "room", nil, false, "stale-write-probe"), Agentboard.Mattermost.Inbound.reconcile(stale)}; e -> e end)')
assert stale.count('owner_expired') == 2, 'stale owner calls must return typed owner_expired, got ' + stale
assert len(inbox()[0]) == inbox_before, 'superseded owner must not persist inbox rows'
assert int(sql("SELECT count(*) FROM mattermost_post_versions WHERE source='%s'" % source)) == versions_before, 'superseded owner must not persist versions'
assert not any('stale-write-probe' in c['incomplete_reason'] for c in inbox()[1]), 'superseded owner must not persist coverage'
run_new = sql("SELECT run_id::text FROM mattermost_inbound_runs")
store = rpc('IO.inspect(case Agentboard.Mattermost.Inbound.base_config() do {:ok, b} -> cfg = Map.merge(b, %{source: Agentboard.Mattermost.InboundStore.source(b), run: Ecto.UUID.cast!("' + run_new + '")}); Agentboard.Mattermost.InboundStore.fenced(cfg, fn -> Agentboard.Repo.statement!("SELECT * FROM no_such_table_xyz") end); e -> e end)')
assert 'store_unavailable' in store, 'store failure must normalize to store_unavailable, got ' + store
sql("UPDATE mattermost_inbound_runs SET expires_at = clock_timestamp()")
rpc('Application.put_env(:agentboard, :mattermost_inbound_enabled, true)')
wait(lambda: any(c['live_connected'] for c in inbox()[1]))
# Deterministic fault at an unfenced read boundary (task repo lookup) disconnects cleanly.
sql("ALTER TABLE tasks RENAME TO tasks_hidden")
probe = rpc('IO.inspect(case Agentboard.Mattermost.Inbound.base_config() do {:ok, b} -> cfg = Map.merge(b, %{source: Agentboard.Mattermost.InboundStore.source(b), bot_id: "shared-bot"}); Agentboard.Mattermost.Inbound.observe(cfg, %{"id" => "probe-task-1", "channel_id" => "room", "user_id" => "shared-bot", "root_id" => "", "create_at" => 1000, "update_at" => 1000, "edit_at" => 0, "delete_at" => 0, "message" => "@worker-b probe", "type" => "", "props" => %{"agent_id" => "worker-b", "msg_id" => "probe-m", "task_id" => "fixture-task"}, "file_ids" => []}) end)')
assert 'store_unavailable' in probe, 'unfenced read failure must normalize, got ' + probe
assert find('probe-task-1') is None
emit('direct_added', {'channel_id': 'new-dm'})
wait(lambda: sql("SELECT reason FROM mattermost_inbound_runs") == 'store_unavailable')
assert find('downtime') is not None, 'refused scan must retain earlier inbox rows'
sql("ALTER TABLE tasks_hidden RENAME TO tasks")
wait(lambda: any('metadata_capacity_reached' in c['incomplete_reason'] for c in inbox()[1]))
# Transient lease-store fault keeps the owner process alive without crash or stale write.
pid_before = rpc('IO.inspect(Agentboard.Mattermost.InboundStream |> Process.whereis() |> :erlang.pid_to_list() |> to_string())')
sql("CREATE OR REPLACE FUNCTION lease_fault_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture transient lease fault'; END $$")
sql("CREATE TRIGGER lease_fault_trigger BEFORE UPDATE ON mattermost_inbound_runs FOR EACH ROW EXECUTE FUNCTION lease_fault_fn()")
try:
    sql("UPDATE mattermost_inbound_runs SET reason='probe'")
    raise AssertionError('lease fault trigger not active')
except subprocess.CalledProcessError:
    pass
time.sleep(12)
assert sql("SELECT count(*) FROM mattermost_inbound_runs WHERE reason='catch_up_failed'") == '0', 'lease fault must not crash the owner'
pid_after = rpc('IO.inspect(Agentboard.Mattermost.InboundStream |> Process.whereis() |> :erlang.pid_to_list() |> to_string())')
assert pid_after == pid_before, 'owner process must survive lease store fault'
sql("DROP TRIGGER lease_fault_trigger ON mattermost_inbound_runs; DROP FUNCTION lease_fault_fn()")
wait(lambda: any(c['live_connected'] for c in inbox()[1]))
assert not FAILURES, FAILURES
rpc('Application.put_env(:agentboard, :mattermost_inbound_enabled, false)')
server.shutdown()
print('PASS shared-bot subscription, overlapping equal-time history, page/live races, exact edits, human routing, new DM, outage, explicit gaps, scoped reads and exact receipts')
