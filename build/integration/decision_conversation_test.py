"""Typed coordinator decision round-trip at packaged HTTP/CLI/Postgres boundary.

All identities, credentials, enrollment and Mattermost posts are synthetic. The
shared-bot HTTP fixture is real; a fenced RPC adapter calls the production inbound
observer instead of WebSocket transport. The existing mattermost_inbox_test owns
WebSocket/native-delivery transport coverage. This fixture proves no live pilot,
production enrollment, MESSAGE_MODE cutover, or native-adapter readiness.
"""
import concurrent.futures
import copy
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid

URL = os.environ['AGENTBOARD_URL'] + '/api/v1/'
CAPTAIN = 'fixture-roundtrip-captain-capability-012345'
BOT_TOKEN = 'fixture-roundtrip-shared-bot-token'
ELASTIC_TOKEN = 'fixture-roundtrip-unused-elastic-token'
REQUESTER = 'roundtrip-requester'
COORDINATOR = 'roundtrip-coordinator'
OTHER = 'roundtrip-other'
CHANNEL = 'coord-channel'
REPO = 'fixture/roundtrip'
MODEL = 'fixture-model'
LOCK = threading.RLock()
POSTS = {}
POST_ATTEMPTS = []
READ_ATTEMPTS = []
CHANNELS = [CHANNEL, 'foreign-channel']
HIDDEN = set()
UNAVAILABLE = set()
FAILURES = []
DROP_NEXT = False
NEXT_STATUS = None
MEMBERSHIP_CALLBACK = None
HISTORY_CALLBACK = None
REDIRECT_REQUESTS = []
BEFORE_RESPONSE = None
HISTORY_STATUS = 200
HISTORY_PAGE_STATUS = {}
HOST_TOKENS = {}
TOKENS = {}


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, ('Fixture RPC failed', result.stdout, result.stderr)
    return result.stdout


def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-qAt', '-v',
                                   'ON_ERROR_STOP=1', '-c', statement], text=True).strip()


def setting(name, value):
    rpc('Application.put_env(:agentboard, :' + name + ', Jason.decode!(' +
        json.dumps(json.dumps(value)) + '))')


def api(path, body=None, actor=REQUESTER, token=None, captain=False, status=200, method=None):
    headers = {'Content-Type': 'application/json', 'x-agentboard-agent': actor,
               'x-agentboard-model': MODEL, 'x-agentboard-harness': 'codex',
               'x-agentboard-worker-protocol': '1'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
        if not token:
            headers['Authorization'] = 'Bearer ' + CAPTAIN
    request = urllib.request.Request(URL + path, headers=headers, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        value = json.load(response)
        expected = status if isinstance(status, tuple) else (status,)
        assert response.status in expected, (path, response.status, expected, value)
        return value


def cli(*args, actor=REQUESTER, token=None, code=0):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_MODEL=MODEL,
               AGENTBOARD_HARNESS='codex', AGENTBOARD_TOKEN=token or TOKENS[actor])
    env.pop('AGENTBOARD_TOKEN_FILE', None)
    env.pop('AGENTBOARD_CAPTAIN_TOKEN_FILE', None)
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert all(secret not in result.stdout + result.stderr for secret in
               [CAPTAIN, BOT_TOKEN, ELASTIC_TOKEN, *TOKENS.values(), *HOST_TOKENS.values()])
    return json.loads(result.stdout if code == 0 else result.stderr)


def make_post(post_id, message, user='shared-bot', root='', props=None, channel=CHANNEL):
    return dict(id=post_id, channel_id=channel, user_id=user, root_id=root or '',
                message=message, props=props or {}, create_at=1000, update_at=1000,
                edit_at=0, delete_at=0, type='', file_ids=[])


class Mattermost(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        if status in (429, 503):
            self.send_header('Retry-After', '1')
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        # Active elastic rows exist below. Typed messages must still use this bot.
        valid = self.headers.get('Authorization') == 'Bearer ' + BOT_TOKEN
        if not valid:
            FAILURES.append('Unexpected Mattermost credential; shared bot required')
            self.respond({}, 401)
        return valid

    def do_GET(self):
        global MEMBERSHIP_CALLBACK, HISTORY_CALLBACK
        if not self.authorized():
            return
        parsed = urllib.parse.urlparse(self.path)
        with LOCK:
            READ_ATTEMPTS.append(self.path)
            if parsed.path == '/api/v4/users/me':
                return self.respond(dict(id='shared-bot', is_bot=True, roles='system_user'))
            if parsed.path == '/api/v4/users/me/channels':
                callback, MEMBERSHIP_CALLBACK = MEMBERSHIP_CALLBACK, None
                if callback:
                    callback()
                return self.respond([dict(id=channel, delete_at=0) for channel in CHANNELS])
            if parsed.path.startswith('/api/v4/channels/') and parsed.path.endswith('/posts'):
                if HISTORY_STATUS != 200:
                    return self.respond({}, HISTORY_STATUS)
                channel = parsed.path.split('/')[4]
                if channel not in CHANNELS:
                    return self.respond({}, 403)
                query = urllib.parse.parse_qs(parsed.query)
                page = int(query.get('page', ['0'])[0])
                if page in HISTORY_PAGE_STATUS:
                    return self.respond({}, HISTORY_PAGE_STATUS[page])
                per_page = int(query.get('per_page', ['60'])[0])
                selected = sorted((copy.deepcopy(post) for post in POSTS.values()
                                   if post['channel_id'] == channel and not post['delete_at']
                                   and post['id'] not in HIDDEN),
                                  key=lambda post: (post['create_at'], post['id']), reverse=True)
                selected = selected[page * per_page:(page + 1) * per_page]
                callback, HISTORY_CALLBACK = HISTORY_CALLBACK, None
                if callback:
                    callback()
                return self.respond(dict(order=[post['id'] for post in selected],
                                         posts={post['id']: post for post in selected}))
            if parsed.path.startswith('/api/v4/posts/'):
                post = POSTS.get(parsed.path.split('/')[-1])
                if not post or post['id'] in UNAVAILABLE or post['delete_at'] or post['channel_id'] not in CHANNELS:
                    return self.respond({}, 404)
                return self.respond(copy.deepcopy(post))
        self.respond({}, 404)

    def do_POST(self):
        global DROP_NEXT, BEFORE_RESPONSE, NEXT_STATUS
        if not self.authorized():
            return
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path != '/api/v4/posts':
            return self.respond({}, 404)
        with LOCK:
            post_id = 'typed-post-%04d' % (len(POST_ATTEMPTS) + 1)
            post = make_post(post_id, payload['message'], root=payload.get('root_id'),
                             props=payload['props'], channel=payload['channel_id'])
            post['create_at'] = 1000 + len(POST_ATTEMPTS)
            post['update_at'] = post['create_at']
            POST_ATTEMPTS.append(copy.deepcopy(payload))
            POSTS[post_id] = copy.deepcopy(post)
            drop, DROP_NEXT = DROP_NEXT, False
            response_status, NEXT_STATUS = NEXT_STATUS, None
            callback, BEFORE_RESPONSE = BEFORE_RESPONSE, None
        if callback:
            try:
                callback(copy.deepcopy(post))
            except Exception as error:
                FAILURES.append(repr(error))
        if drop:
            # Remote acceptance precedes an actual lost HTTP response.
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if response_status in (307, 308):
            self.send_response(response_status)
            self.send_header('Location', 'http://127.0.0.1:%d/api/v4/posts' % redirect_server.server_port)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'{}')
            return
        self.respond(post, response_status or 201)


class RedirectDestination(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        REDIRECT_REQUESTS.append((self.command, self.path))
        self.send_response(503)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'{}')

    do_GET = do_POST


def observe(post):
    encoded = json.dumps(json.dumps(post))
    result = rpc('''
    {:ok, cfg} = Agentboard.Mattermost.Inbound.config()
    {:ok, cfg} = Agentboard.Mattermost.InboundStore.claim(cfg)
    result = Agentboard.Mattermost.Inbound.observe(cfg, Jason.decode!(''' + encoded + '''))
    :ok = Agentboard.Mattermost.InboundStore.release(cfg, "fixture_manual_observer")
    IO.inspect(result, label: "OBSERVED")
    ''')
    assert 'OBSERVED: {:ok,' in result, result


def recover():
    result = rpc('''
    {:ok, cfg} = Agentboard.Mattermost.Inbound.config()
    {:ok, cfg} = Agentboard.Mattermost.InboundStore.claim(cfg)
    result = Agentboard.Mattermost.Inbound.reconcile(cfg)
    :ok = Agentboard.Mattermost.InboundStore.release(cfg, "fixture_manual_recovery")
    IO.inspect(result, label: "RECOVERED")
    ''')
    assert 'RECOVERED: {:ok,' in result, result


def inbox(worker=COORDINATOR):
    items, cursor = [], None
    while True:
        path = 'workers/' + worker + '/mattermost_inbox'
        if cursor:
            path += '?cursor=' + urllib.parse.quote(cursor, safe='')
        page = api(path, actor=worker, token=HOST_TOKENS[worker])
        items.extend(page['items'])
        cursor = page['next_cursor']
        if not cursor:
            return items


def find(post_id, worker=COORDINATOR, version=None):
    return next((item for item in inbox(worker) if item['post_id'] == post_id
                 and (version is None or item['version'] == version)), None)


def read(item, worker=COORDINATOR):
    return api('workers/' + worker + '/mattermost_read',
               dict(id=item['id'], version=item['version']), actor=worker,
               token=HOST_TOKENS[worker])['items'][0]


def acknowledge(item, worker):
    body = dict(items=[dict(id=item['id'], version=item['version'])])
    api('workers/' + worker + '/mattermost_ack', body, actor=worker, token=HOST_TOKENS[worker])
    receipt = sql("SELECT jsonb_build_array(handled_at,handled_model,handled_harness) "
                  "FROM mattermost_inbox WHERE id='%s'" % item['id'])
    assert json.loads(receipt)[0] is not None
    api('workers/' + worker + '/mattermost_ack', body, actor=worker, token=HOST_TOKENS[worker])
    assert sql("SELECT jsonb_build_array(handled_at,handled_model,handled_harness) "
               "FROM mattermost_inbox WHERE id='%s'" % item['id']) == receipt
    assert find(item['post_id'], worker, item['version']) is None


def conversation(decision):
    return 'decisions/' + decision['id'] + '/conversation'


def notify(decision, **kwargs):
    return api(conversation(decision), dict(channel_id=CHANNEL),
               token=TOKENS[REQUESTER], **kwargs)['intent']


def reply_body(item, key, body='Conversation only. Please inspect the canonical board decision.'):
    return dict(inbox_id=item['id'], version=item['version'], retry_key=key, body=body)


def reply(decision, body, **kwargs):
    result = api(conversation(decision) + '/replies', body, actor=COORDINATOR,
                 token=TOKENS[COORDINATOR], **kwargs)
    return result.get('intent', result)


def canonical(decision):
    return sql("SELECT jsonb_build_array((SELECT to_jsonb(d) FROM decision_requests d WHERE id='%s'),"
               "(SELECT to_jsonb(t) FROM tasks t WHERE id='%s'))" %
               (decision['id'], decision['task_id']))


def request_decision(suffix, repo=REPO):
    task = 'roundtrip-' + suffix
    api('tasks', dict(id=task, title='Synthetic conversation ' + suffix, repo=repo), token=TOKENS[REQUESTER])
    api('tasks/' + task + '/claim', {}, token=TOKENS[REQUESTER])
    return api('decisions', dict(task=task, kind='scope', question='Synthetic approval ' + suffix + '?',
                                findings='PRIVATE_FIXTURE_FINDINGS_' + suffix, options=['Proceed', 'Revise']),
               token=TOKENS[REQUESTER])['decision']


def assert_relation(item, decision, intent, operation):
    assert item is not None, (decision['id'], intent['post_id'], operation)
    assert item['decision_conversation'] == dict(decision_id=decision['id'], intent_id=intent['id'], operation=operation)
    assert 'message' not in item and item['task_id'] == decision['task_id']


redirect_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RedirectDestination)
threading.Thread(target=redirect_server.serve_forever, daemon=True).start()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Mattermost)
threading.Thread(target=server.serve_forever, daemon=True).start()
setting('captain_token', CAPTAIN)
setting('coordinator_id', COORDINATOR)
# Setup is the existing protected provisioning API, with invented captain capability.
for actor in (REQUESTER, COORDINATOR, OTHER):
    api('agents/register', dict(name=actor), actor=actor)
    HOST_TOKENS[actor] = api('workers/provision', dict(worker_id=actor, host_id='roundtrip-host',
        repos=[REPO], model=MODEL, harness='codex', idempotency_key='provision-' + actor),
        actor=actor, captain=True)['host_token']
for actor in (REQUESTER, OTHER):
    TOKENS[actor] = api('agents/' + actor + '/tokens/issue', {}, actor=actor, captain=True)['token']
legacy = api('agents/' + COORDINATOR + '/tokens/issue', {}, captain=True)
assert legacy['credential']['scope'] == 'coordinator'
for grants in ([], [CHANNEL, CHANNEL], ['bad channel'], ['x' * 129], ['channel-%d' % n for n in range(21)]):
    api('agents/' + COORDINATOR + '/tokens/issue', dict(scope='coordinator_participant', channel_ids=grants),
        captain=True, status=(403, 422))
api('agents/' + REQUESTER + '/tokens/issue', dict(scope='agent', channel_ids=[CHANNEL]), captain=True, status=(403, 422))
issued = api('agents/' + COORDINATOR + '/tokens/issue',
             dict(scope='coordinator_participant', channel_ids=[CHANNEL]), captain=True)
TOKENS[COORDINATOR] = issued['token']
assert issued['credential']['scope'] == 'coordinator_participant'
assert issued['credential']['channel_ids'] == [CHANNEL]
assert TOKENS[COORDINATOR] not in sql('SELECT row_to_json(c) FROM agent_api_credentials c')
immutable_grant = subprocess.run([os.environ['FIXTURE_PSQL'], '-qAt', '-v', 'ON_ERROR_STOP=1', '-c',
    "UPDATE agent_api_credentials SET channel_ids=ARRAY['foreign-channel'] WHERE id='%s'" % issued['credential']['id']],
    capture_output=True, text=True)
assert immutable_grant.returncode != 0, 'Issued channel grant must be immutable'
assert sql("SELECT array_to_json(channel_ids) FROM agent_api_credentials WHERE id='%s'" % issued['credential']['id']) == '["coord-channel"]'
# Stop only this disposable fixture's real stream before substituting the fenced
# observer. enabled=true still exercises real source materialization checks.
rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Agentboard.Mattermost.InboundStream)')
setting('mattermost_base_url', 'http://127.0.0.1:%d' % server.server_port)
setting('mattermost_bot_token', BOT_TOKEN)
setting('mattermost_inbound_repo', REPO)
setting('mattermost_inbound_history_start_ms', 0)
setting('mattermost_inbound_enabled', True)
setting('mattermost_channel_allowlist', CHANNEL + ',foreign-channel')
setting('coordinator_chat_channel_id', CHANNEL)
setting('agent_auth_mode', 'enforce')
# A synthetic active elastic token must never be selected by the typed path.
rpc('''
Agentboard.Mattermost.AgentBot |> Ash.Changeset.for_create(:open, %{
  id: Ash.UUID.generate(), agent_id: "''' + COORDINATOR + '''", mm_user_id: "elastic-bot",
  mm_username: "elastic-fixture", display_name: "Fixture elastic bot", token: "''' + ELASTIC_TOKEN + '''",
  state: "active", created_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}) |> Ash.create!()
''')
assert api('meta')['schema_version'] >= 39
api('agents/' + COORDINATOR + '/heartbeat', dict(status='idle'), actor=COORDINATOR, token=legacy['token'], status=403)
api('conversations/send', dict(channel_id=CHANNEL, body='Denied'), actor=COORDINATOR, token=legacy['token'], status=403)
api('agents/' + COORDINATOR + '/heartbeat', dict(status='idle'), actor=COORDINATOR, token=TOKENS[COORDINATOR])
api('agents/' + REQUESTER + '/heartbeat', dict(status='idle'), actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
api('tasks', dict(id='forbidden-task', title='Denied'), actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
api('agents/' + COORDINATOR + '/tokens/issue', {}, actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
api('messages?to=' + REQUESTER, actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
api('availability', dict(agent_id=COORDINATOR, state='available'), actor=COORDINATOR,
    token=TOKENS[COORDINATOR], status=403)
api('workers/' + COORDINATOR + '/revoke', {}, actor=COORDINATOR,
    token=TOKENS[COORDINATOR], status=403)
api('conversations/reads?channel_id=foreign-channel', actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
api('workers/' + COORDINATOR + '/mattermost_inbox', actor=COORDINATOR, token=TOKENS[COORDINATOR], status=401)

# Create the canonical request before enabling dual mode; typed notify owns its
# single board notice, preserving wake and shadow triage without legacy mirroring.
decision = request_decision('main')
setting('message_mode', 'dual')
api('settings/coordinator-triage', dict(mode='shadow', coordinator_id=COORDINATOR, revision=0),
    captain=True, method='PUT')
snapshot = canonical(decision)
for action in ('claim', 'renew', 'assign', 'handoff', 'update'):
    api('tasks/' + decision['task_id'] + '/' + action, {}, actor=COORDINATOR,
        token=TOKENS[COORDINATOR], status=403)
for action in ('answer', 'recommend', 'supersede', 'ack'):
    api('decisions/' + decision['id'] + '/' + action, {}, actor=COORDINATOR,
        token=TOKENS[COORDINATOR], status=403)
api('decisions', dict(task=decision['task_id'], kind='scope', question='Denied'),
    actor=COORDINATOR, token=TOKENS[COORDINATOR], status=403)
for mode in ('off', 'observe'):
    setting('agent_auth_mode', mode)
    api(conversation(decision), dict(channel_id=CHANNEL), token=TOKENS[REQUESTER], status=(401, 403))
setting('agent_auth_mode', 'enforce')
api(conversation(decision), dict(channel_id=CHANNEL), status=401)
api(conversation(decision), dict(channel_id=CHANNEL), token=HOST_TOKENS[REQUESTER], status=401)
api(conversation(decision), dict(channel_id=CHANNEL), actor=OTHER, token=TOKENS[OTHER], status=403)
api(conversation(decision), dict(channel_id=CHANNEL, body='Caller controlled'), token=TOKENS[REQUESTER], status=422)
api(conversation(decision), dict(channel_id='foreign-channel'), token=TOKENS[REQUESTER], status=(403, 409))


def early_arrival(post):
    observe(post)
    assert sql("SELECT count(*) FROM mattermost_post_versions WHERE post_id='%s'" % post['id']) == '1'
    assert sql("SELECT count(*) FROM mattermost_inbox WHERE post_id='%s'" % post['id']) == '0'
    HIDDEN.add(post['id'])
    UNAVAILABLE.add(post['id'])


BEFORE_RESPONSE = early_arrival
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    notifications = list(pool.map(lambda _: notify(decision), range(2)))
notice = next(item for item in notifications if item['state'] == 'sent')
assert all(item['id'] == notice['id'] for item in notifications)
assert len(POST_ATTEMPTS) == 1 and notice['state'] == 'sent'
assert notice['operation'] == 'notify' and notice['decision_id'] == decision['id']
assert notice['recipient_id'] == COORDINATOR and notice['channel_id'] == CHANNEL
board_id = str(notice['board_message_id'])
assert sql("SELECT count(*) FROM messages WHERE task_id='%s' AND recipient_id='%s'" % (decision['task_id'], COORDINATOR)) == '1'
assert sql("SELECT count(*) FROM wake_intents WHERE source_kind='board_message' AND source_id='%s'" % board_id) == '1'
assert sql("SELECT count(*) FROM coordinator_inbox_triage WHERE message_id=%s" % board_id) == '1'
assert sql("SELECT count(*) FROM mattermost_outbox WHERE source_key='message:%s'" % board_id) == '0'
root = copy.deepcopy(POSTS[notice['post_id']])
assert root['user_id'] == 'shared-bot' and not root['root_id']
assert root['props']['agent_id'] == REQUESTER and root['props']['task_id'] == decision['task_id']
assert '@' + COORDINATOR in root['message'] and decision['id'] in root['message']
assert 'PRIVATE_FIXTURE_FINDINGS' not in root['message'] and decision['question'] not in root['message']
assert not FAILURES, FAILURES
recover()  # Exact metadata must recover even though the HTTP history omits it.
source = find(root['id'])
assert_relation(source, decision, notice, 'notify')
assert read(source)['source_state'] == 'source_unavailable'
coverage = api('workers/' + COORDINATOR + '/mattermost_inbox', actor=COORDINATOR, token=HOST_TOKENS[COORDINATOR])['coverage']
assert any('known_post_unavailable' in item['incomplete_reason'] for item in coverage)
UNAVAILABLE.remove(root['id'])
assert read(source)['message'] == root['message']
assert_relation(find(root['id']), decision, notice, 'notify')
assert canonical(decision) == snapshot, 'Notify/read may not mutate decision or task'
assert cli('decision', 'conversation', 'notify', decision['id'], '--channel', CHANNEL)['intent']['id'] == notice['id']
assert len(POST_ATTEMPTS) == 1
receipt_view = cli('decision', 'conversation', 'show', decision['id'], actor=COORDINATOR)
assert any(item['id'] == notice['id'] for item in receipt_view['intents'])
assert all('body' not in item and 'message' not in item and 'token' not in item for item in receipt_view['intents'])

# Old coordinator remains read-only and addressed message acknowledgment stays
# separate from protected exact Mattermost handling.
api('messages/' + board_id + '/read', {}, actor=COORDINATOR, token=legacy['token'], status=403)
api('messages/' + board_id + '/read', {}, actor=COORDINATOR, token=TOKENS[COORDINATOR])
first_board_ack = sql('SELECT jsonb_build_array(read_at,read_model,read_harness) FROM messages WHERE id=' + board_id)
api('messages/' + board_id + '/read', {}, actor=COORDINATOR, token=TOKENS[COORDINATOR])
assert sql('SELECT jsonb_build_array(read_at,read_model,read_harness) FROM messages WHERE id=' + board_id) == first_board_ack
foreign = api('messages', dict(to=OTHER, body='Other recipient', task=decision['task_id']), token=TOKENS[REQUESTER])['message']
api('messages/' + str(foreign['id']), actor=COORDINATOR, token=TOKENS[COORDINATOR], status=404)
api('messages/' + str(foreign['id']) + '/read', {}, actor=COORDINATOR, token=TOKENS[COORDINATOR], status=409)

# Exact source, actual participant bearer and protected read/ack capabilities are
# independent. Invalid requests must cause no Mattermost post or canonical write.
body = reply_body(source, 'reply-main', 'Please inspect the board. @' + OTHER + ' is text, not a recipient.')
for bad in (dict(body, version='0' * 64), dict(body, inbox_id=str(uuid.uuid4()))):
    reply(decision, bad, status=(403, 409))
for bad in (dict(body, version='A' * 64), dict(body, inbox_id='not-a-uuid'),
            dict(body, retry_key='k' * 129), dict(body, body='😀' * 4001), dict(body, root_id='forged')):
    reply(decision, bad, status=422)
api(conversation(decision) + '/replies', body, actor=COORDINATOR, token=legacy['token'], status=403)
api(conversation(decision) + '/replies', body, token=TOKENS[REQUESTER], status=403)
api(conversation(decision) + '/replies', body, actor=COORDINATOR, token=HOST_TOKENS[COORDINATOR], status=401)
api('workers/' + COORDINATOR + '/mattermost_read', dict(id=source['id'], version=source['version']),
    actor=COORDINATOR, token=TOKENS[COORDINATOR], status=401)
api('workers/' + COORDINATOR + '/mattermost_ack', dict(items=[dict(id=source['id'], version=source['version'])]),
    actor=COORDINATOR, token=TOKENS[COORDINATOR], status=401)
other_decision = request_decision('other')
reply(other_decision, body, status=(403, 409))
assert len(POST_ATTEMPTS) == 1
BEFORE_RESPONSE = early_arrival
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    replies = list(pool.map(lambda _: reply(decision, body), range(2)))
reply_intent = next(item for item in replies if item['state'] == 'sent')
assert all(item['id'] == reply_intent['id'] for item in replies)
assert len(POST_ATTEMPTS) == 2
response = POSTS[reply_intent['post_id']]
assert response['root_id'] == root['id'] and response['user_id'] == 'shared-bot'
assert response['props']['agent_id'] == COORDINATOR
assert response['props']['task_id'] == decision['task_id']
recover()
received = find(response['id'], REQUESTER)
assert_relation(received, decision, reply_intent, 'reply')
assert read(received, REQUESTER)['source_state'] == 'source_unavailable'
UNAVAILABLE.remove(response['id'])
assert read(received, REQUESTER)['message'] == response['message']
assert find(response['id'], OTHER) is None, 'Typed body mentions cannot expand recipients'
assert find(root['id']) is not None and find(response['id'], REQUESTER) is not None
assert canonical(decision) == snapshot, 'Conversation/read must not answer, apply, release or reassign'
reply(decision, dict(body, body='Changed retry body'), status=409)
reply(other_decision, body, status=(403, 409))
assert len(POST_ATTEMPTS) == 2

# A human copying all typed markers retains ordinary human routing and cannot
# acquire canonical association. Wrong actual bot author likewise lacks authority.
for user in ('human-fixture', 'wrong-bot'):
    forged = copy.deepcopy(root)
    forged.update(id='copied-' + user, user_id=user, message='@' + COORDINATOR + ' copied markers')
    POSTS[forged['id']] = forged
    observe(forged)
    copied = find(forged['id'])
    assert copied and not copied.get('decision_conversation')
    reply(decision, reply_body(copied, 'forged-' + user), status=(403, 409))
assert len(POST_ATTEMPTS) == 2

# Existing packaged worker CLI checks the real protected checkpoint seam. Manual
# binding explicitly advertises no idle/turn/tool native injection readiness.
root_dir = Path(os.environ['TEST_TMPDIR']) / 'decision-roundtrip-worker'
root_dir.mkdir(mode=0o700)
capabilities = {name: dict(supported=name in ('receipt', 'recovery'), reason='Controlled manual fixture')
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bound = api('workers/' + REQUESTER + '/bind', dict(expected_epoch=0, host_id='roundtrip-host',
    idempotency_key='roundtrip-bind', session_id='roundtrip-session', pane_id='roundtrip-generation',
    adapter='manual', adapter_version='1', capabilities=capabilities), actor=REQUESTER, token=HOST_TOKENS[REQUESTER])
token_file = root_dir / 'token'
token_file.write_text(HOST_TOKENS[REQUESTER]); token_file.chmod(0o600)
receipt_file = root_dir / 'token.receipt'
receipt_file.write_text(bound['receipt_token']); receipt_file.chmod(0o600)
config = dict(version=1, url=os.environ['AGENTBOARD_URL'], journal_dir=str(root_dir / 'journal'), bindings=[
    dict(agent_id=REQUESTER, model=MODEL, harness='codex', host_id='roundtrip-host', server_id='roundtrip-server',
         session_id='roundtrip-session', adapter_generation='roundtrip-generation', adapter='manual',
         socket_path=str(root_dir / 'unused-socket'), token_file=str(token_file), binding_epoch=1)])
config_file = root_dir / 'config.json'
config_file.write_text(json.dumps(config)); config_file.chmod(0o600)
checkpoint = cli('worker', 'check-in', '--config', str(config_file), '--worker-id', REQUESTER)
assert any(item['id'] == received['id'] and item['decision_conversation']['decision_id'] == decision['id']
           for page in checkpoint['mattermost_inbox'] for item in page['items'])
assert find(response['id'], REQUESTER), 'CLI checkpoint must not auto-ack'
acknowledge(source, COORDINATOR)
acknowledge(received, REQUESTER)
assert canonical(decision) == snapshot

# A transaction failure after board-message creation must roll back the notice,
# ordinary wake, triage capture and intent together. No remote I/O is admitted.
rollback_decision = request_decision('rollback')
rollback_snapshot = canonical(rollback_decision)
rollback_before = len(POST_ATTEMPTS)
sql("CREATE FUNCTION fixture_reject_conversation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic conversation insert failure'; END $$")
sql('CREATE TRIGGER fixture_conversation_insert BEFORE INSERT ON decision_conversation_intents FOR EACH ROW EXECUTE FUNCTION fixture_reject_conversation()')
try:
    api(conversation(rollback_decision), dict(channel_id=CHANNEL), token=TOKENS[REQUESTER], status=503)
finally:
    sql('DROP TRIGGER fixture_conversation_insert ON decision_conversation_intents')
    sql('DROP FUNCTION fixture_reject_conversation()')
assert sql("SELECT count(*) FROM messages WHERE task_id='%s'" % rollback_decision['task_id']) == '0'
assert sql("SELECT count(*) FROM decision_conversation_intents WHERE decision_id='%s'" % rollback_decision['id']) == '0'
assert len(POST_ATTEMPTS) == rollback_before and canonical(rollback_decision) == rollback_snapshot

# Notification itself retains the canonical board notice across an unavailable
# chat acknowledgment. Retrying never creates a second board notice or POST.
outage_decision = request_decision('notify-outage')
outage_snapshot = canonical(outage_decision)
DROP_NEXT = True
outage = notify(outage_decision)
assert outage['state'] in ('uncertain', 'submitting'), (outage, len(POST_ATTEMPTS), [post['props'].get('msg_id') for post in POST_ATTEMPTS])
assert outage['board_message_id'] is not None
assert sql("SELECT count(*) FROM messages WHERE id=%s" % outage['board_message_id']) == '1'
outage_count = len(POST_ATTEMPTS)
assert notify(outage_decision)['id'] == outage['id']
assert len(POST_ATTEMPTS) == outage_count and canonical(outage_decision) == outage_snapshot
assert api(conversation(outage_decision) + '/reconcile', dict(intent_id=outage['id']),
           token=TOKENS[REQUESTER])['intent']['state'] == 'sent'

# Four-byte Unicode byte boundary, source edits at equal timestamps, deletion and
# membership loss are checked immediately before any fresh remote submission.
unicode_intent = reply(decision, reply_body(source, 'unicode-boundary', '😀' * 4000))
assert unicode_intent['state'] == 'sent'
assert len(POSTS[unicode_intent['post_id']]['message'].encode()) <= 65536
# A send receipt alone is not receive proof. Without exact observed metadata,
# neither hidden history nor an inaccessible post may synthesize recipient inbox.
unicode_post = unicode_intent['post_id']
HIDDEN.add(unicode_post)
UNAVAILABLE.add(unicode_post)
recover()
assert sql("SELECT count(*) FROM mattermost_post_versions WHERE post_id='%s'" % unicode_post) == '0'
assert find(unicode_post, REQUESTER) is None
UNAVAILABLE.remove(unicode_post)
observe(POSTS[unicode_post])
assert_relation(find(unicode_post, REQUESTER), decision, unicode_intent, 'reply')
before = len(POST_ATTEMPTS)
with LOCK:
    POSTS[root['id']]['message'] += ' edited without changing timestamp'
observe(POSTS[root['id']])
edited_version = sql("SELECT version FROM mattermost_post_versions WHERE post_id='%s' AND version<>'%s'" % (root['id'], source['version']))
assert len(edited_version) == 64
assert not any(item['post_id'] == root['id'] and item['version'] == edited_version for item in inbox())
reply(decision, reply_body(source, 'edited-original'), status=(403, 409))
reply(decision, dict(reply_body(source, 'edited-version'), version=edited_version), status=(403, 409))
assert read(source)['source_state'] == 'source_unavailable'
with LOCK:
    POSTS[root['id']] = copy.deepcopy(root)
    POSTS[root['id']]['delete_at'] = 5000
reply(decision, reply_body(source, 'deleted-source'), status=(403, 409))
with LOCK:
    POSTS[root['id']] = copy.deepcopy(root)
    CHANNELS.remove(CHANNEL)
reply(decision, reply_body(source, 'membership-revoked'), status=(403, 409))
CHANNELS.append(CHANNEL)
assert len(POST_ATTEMPTS) == before

# Remote acceptance followed by a lost response is retained, never blindly sent
# again. Explicit reconciliation alone can adopt the exact shared-bot post.
DROP_NEXT = True
uncertain = reply(decision, reply_body(source, 'lost-response'))
assert uncertain['state'] in ('uncertain', 'submitting') and not uncertain.get('post_id')
count = len(POST_ATTEMPTS)
assert cli('decision', 'conversation', 'reply', decision['id'], '--inbox-id', source['id'],
           '--version', source['version'], '--retry-key', 'lost-response',
           '--body', reply_body(source, 'lost-response')['body'], actor=COORDINATOR)['intent']['id'] == uncertain['id']
assert len(POST_ATTEMPTS) == count
adopted = cli('decision', 'conversation', 'reconcile', decision['id'],
              '--intent-id', uncertain['id'], actor=COORDINATOR)['intent']
assert adopted['state'] == 'sent' and adopted['post_id'] in POSTS
assert len(POST_ATTEMPTS) == count

# Two actual shared-bot matches are visibly ambiguous. Copied human markers may
# not be adopted, even with byte-identical payload and source association.
DROP_NEXT = True
duplicate = reply(decision, reply_body(source, 'duplicate-remote'))
duplicate_post = copy.deepcopy(POSTS['typed-post-%04d' % len(POST_ATTEMPTS)])
copy_post = copy.deepcopy(duplicate_post)
copy_post['id'] = 'duplicate-actual-shared-bot'
POSTS[copy_post['id']] = copy_post
count = len(POST_ATTEMPTS)
# A full first page already establishes two matches. A subsequent history error
# must not discard that positive duplicate evidence or weaken it to a mere gap.
for number in range(60):
    filler = make_post('duplicate-page-filler-%03d' % number, 'Unrelated earlier history', user='human-fixture')
    filler['create_at'] = filler['update_at'] = 500 + number
    POSTS[filler['id']] = filler
HISTORY_PAGE_STATUS[1] = 429
READ_ATTEMPTS.clear()
try:
    ambiguous = api(conversation(decision) + '/reconcile', dict(intent_id=duplicate['id']),
                    actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
finally:
    HISTORY_PAGE_STATUS.clear()
assert ambiguous['state'] == 'uncertain' and ambiguous['reason'] == 'duplicate_posts_observed'
assert ambiguous['duplicate_observed_at'] and len(ambiguous['duplicate_post_ids']) == 2
assert not ambiguous.get('post_id')
assert not any('page=1' in path for path in READ_ATTEMPTS), READ_ATTEMPTS
assert len(POST_ATTEMPTS) == count
# Duplicate uncertainty stays retained even after remote history later hides it.
HIDDEN.add(copy_post['id'])
sticky = api(conversation(decision) + '/reconcile', dict(intent_id=duplicate['id']),
             actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
assert sticky['state'] == 'uncertain' and sticky['reason'] == 'duplicate_posts_observed'
assert sticky['duplicate_observed_at'] and len(sticky['duplicate_post_ids']) == 2
HIDDEN.add(duplicate_post['id'])
# Independently submit another uncertain intent, leaving a copied human payload
# as its only history candidate. It must never be accepted as a shared-bot send.
DROP_NEXT = True
forged_reconcile = reply(decision, reply_body(source, 'human-reconcile'))
actual_post = copy.deepcopy(POSTS['typed-post-%04d' % len(POST_ATTEMPTS)])
HIDDEN.add(actual_post['id'])
human_copy = copy.deepcopy(actual_post)
human_copy.update(id='duplicate-copied-human', user_id='human-fixture')
POSTS[human_copy['id']] = human_copy
count = len(POST_ATTEMPTS)
untrusted = api(conversation(decision) + '/reconcile', dict(intent_id=forged_reconcile['id']),
                actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
assert untrusted['state'] != 'sent' and not untrusted.get('post_id')
assert len(POST_ATTEMPTS) == count

# A duplicate history observation wins over a delayed original 201; it remains
# visible instead of being overwritten by the later accepted receipt.
def duplicate_before_201(post):
    observe(post)
    duplicate_copy = copy.deepcopy(post)
    duplicate_copy['id'] = 'race-duplicate-before-201'
    POSTS[duplicate_copy['id']] = duplicate_copy
    view = api(conversation(decision) + '/reconcile',
               dict(intent_id=post['props']['agentboard_decision_intent']),
               actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
    assert view['state'] == 'uncertain' and view['reason'] == 'duplicate_posts_observed'


BEFORE_RESPONSE = duplicate_before_201
race_duplicate = reply(decision, reply_body(source, 'duplicate-before-201'))
assert race_duplicate['state'] == 'uncertain' and race_duplicate['reason'] == 'duplicate_posts_observed'
assert len(race_duplicate['duplicate_post_ids']) == 2
assert find('typed-post-%04d' % len(POST_ATTEMPTS), REQUESTER) is None

# Reverse commit order: freeze the already-running reconciliation history read,
# allow original 201 to commit, then deliver the duplicate scan to the server.
scan_started = threading.Event()
release_scan = threading.Event()
race_results = []
race_errors = []
race_thread = None


def scan_hold():
    scan_started.set()
    assert release_scan.wait(5), 'Fixture did not release in-flight duplicate scan'


def duplicate_after_201(post):
    global HISTORY_CALLBACK, race_thread
    duplicate_copy = copy.deepcopy(post)
    duplicate_copy['id'] = 'race-duplicate-after-201'
    POSTS[duplicate_copy['id']] = duplicate_copy
    HISTORY_CALLBACK = scan_hold

    def reconcile_while_submitting():
        try:
            race_results.append(api(conversation(decision) + '/reconcile',
                dict(intent_id=post['props']['agentboard_decision_intent']),
                actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent'])
        except Exception as error:
            race_errors.append(repr(error))

    race_thread = threading.Thread(target=reconcile_while_submitting, daemon=True)
    race_thread.start()
    assert scan_started.wait(5), 'Reconciliation did not reach history before original 201'


BEFORE_RESPONSE = duplicate_after_201
try:
    raced_sent = reply(decision, reply_body(source, 'duplicate-after-201'))
    assert raced_sent['state'] == 'sent'
finally:
    release_scan.set()
race_thread.join(10)
assert not race_errors and len(race_results) == 1, (race_errors, race_results)
assert race_results[0]['state'] == 'uncertain' and race_results[0]['reason'] == 'duplicate_posts_observed'
observe(POSTS[raced_sent['post_id']])
assert find(raced_sent['post_id'], REQUESTER) is None
retained = next(item for item in api(conversation(decision), actor=COORDINATOR,
                                    token=TOKENS[COORDINATOR])['intents'] if item['id'] == raced_sent['id'])
assert retained['state'] == 'uncertain' and retained['duplicate_observed_at']

# Neither redirects nor accepted-503 Retry-After are authority to repeat a typed
# POST. A second listener exposes cross-origin follow/credential-forward attempts.
for remote_status in (307, 308, 503):
    NEXT_STATUS = remote_status
    before = len(POST_ATTEMPTS)
    failed_ack = reply(decision, reply_body(source, 'http-status-%d' % remote_status))
    assert failed_ack['state'] in ('uncertain', 'submitting'), failed_ack
    assert len(POST_ATTEMPTS) == before + 1
    assert REDIRECT_REQUESTS == [], REDIRECT_REQUESTS
    assert reply(decision, reply_body(source, 'http-status-%d' % remote_status))['id'] == failed_ack['id']
    assert len(POST_ATTEMPTS) == before + 1

# Mutate only disposable fixture config during the last external membership
# preflight. Durable admission must reject the now-stale service/token snapshot.
for name, changed, original in (
        ('mattermost_base_url', 'http://127.0.0.1:%d/changed-service' % server.server_port,
         'http://127.0.0.1:%d' % server.server_port),
        ('mattermost_bot_token', 'fixture-changed-token', BOT_TOKEN)):
    MEMBERSHIP_CALLBACK = lambda name=name, changed=changed: setting(name, changed)
    before = len(POST_ATTEMPTS)
    try:
        reply(decision, reply_body(source, 'preflight-race-' + name), status=(403, 409, 503))
        assert len(POST_ATTEMPTS) == before
    finally:
        MEMBERSHIP_CALLBACK = None
        setting(name, original)

# A complete miss, a full five-page window and 429 cannot prove non-submission.
DROP_NEXT = True
missing = reply(decision, reply_body(source, 'history-miss'))
missing_post = 'typed-post-%04d' % len(POST_ATTEMPTS)
HIDDEN.add(missing_post)
count = len(POST_ATTEMPTS)
for status in (200, 429):
    HISTORY_STATUS = status
    checked = api(conversation(decision) + '/reconcile', dict(intent_id=missing['id']),
                  actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
    assert checked['state'] != 'sent' and not checked.get('post_id')
HISTORY_STATUS = 200
for number in range(310):
    filler = make_post('history-filler-%04d' % number, 'Unrelated public history', user='human-fixture')
    filler['create_at'] = filler['update_at'] = 10000 + number
    POSTS[filler['id']] = filler
READ_ATTEMPTS.clear()
checked = api(conversation(decision) + '/reconcile', dict(intent_id=missing['id']),
              actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
assert checked['state'] != 'sent' and not checked.get('post_id')
pages = [path for path in READ_ATTEMPTS if '/channels/' in path and '/posts' in path]
assert len(pages) == 5, pages
assert reply(decision, reply_body(source, 'history-miss'))['id'] == missing['id']
assert len(POST_ATTEMPTS) == count

# Finding exactly one candidate inside a bounded/incomplete scan cannot prove
# uniqueness. Keep uncertainty if a later page errors or all five pages are full.
DROP_NEXT = True
one_match = reply(decision, reply_body(source, 'one-match-incomplete-history'))
one_match_post = 'typed-post-%04d' % len(POST_ATTEMPTS)
POSTS[one_match_post]['create_at'] = POSTS[one_match_post]['update_at'] = 200000
count = len(POST_ATTEMPTS)
HISTORY_PAGE_STATUS[1] = 429
try:
    incomplete = api(conversation(decision) + '/reconcile', dict(intent_id=one_match['id']),
                     actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
    assert incomplete['state'] == 'uncertain' and not incomplete.get('post_id')
finally:
    HISTORY_PAGE_STATUS.clear()
READ_ATTEMPTS.clear()
bounded = api(conversation(decision) + '/reconcile', dict(intent_id=one_match['id']),
              actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']
assert bounded['state'] == 'uncertain' and bounded['reason'] == 'history_budget_exhausted'
assert not bounded.get('post_id')
assert len([path for path in READ_ATTEMPTS if '/channels/' in path and '/posts' in path]) == 5
assert reply(decision, reply_body(source, 'one-match-incomplete-history'))['id'] == one_match['id']
assert len(POST_ATTEMPTS) == count

# Current service/repository/channel/coordinator settings and rotation constrain
# existing receipt reads and reconciliation before remote reads or writes.
for name, value, restore in (
        ('mattermost_channel_allowlist', 'foreign-channel', CHANNEL + ',foreign-channel'),
        ('mattermost_inbound_repo', 'fixture/foreign', REPO),
        ('mattermost_base_url', 'http://127.0.0.1:%d/changed-service' % server.server_port,
         'http://127.0.0.1:%d' % server.server_port)):
    setting(name, value)
    api(conversation(decision) + '/reconcile', dict(intent_id=missing['id']), actor=COORDINATOR,
        token=TOKENS[COORDINATOR], status=(403, 409, 503))
    setting(name, restore)
# Canonical terminal states refuse new conversation replies even with a valid
# retained source and participant grant. These are synthetic board decisions.
for action, expected in (('withdraw', 'withdrawn'), ('supersede', 'superseded')):
    terminal_decision = request_decision('terminal-' + action)
    terminal_notice = notify(terminal_decision)
    assert terminal_notice['state'] == 'sent'
    observe(POSTS[terminal_notice['post_id']])
    terminal_source = find(terminal_notice['post_id'])
    assert_relation(terminal_source, terminal_decision, terminal_notice, 'notify')
    if action == 'withdraw':
        ended = api('decisions/' + terminal_decision['id'] + '/withdraw',
                    dict(reason='Synthetic requester withdrawal'), token=TOKENS[REQUESTER])['decision']
    else:
        ended = api('decisions/' + terminal_decision['id'] + '/supersede',
                    dict(reason='Synthetic captain supersession'), captain=True)['decision']
    assert ended['status'] == expected
    terminal_snapshot = canonical(terminal_decision)
    count = len(POST_ATTEMPTS)
    reply(terminal_decision, reply_body(terminal_source, 'terminal-' + action), status=409)
    assert len(POST_ATTEMPTS) == count and canonical(terminal_decision) == terminal_snapshot
    assert find(terminal_notice['post_id']), 'Terminal rejection must not acknowledge original source'

# Same-identity rotation may inspect/reconcile an old attempted receipt with the
# same channel, but it cannot revive a prepared send captured by a revoked key.
previous_token = TOKENS[COORDINATOR]
same_grant = api('agents/' + COORDINATOR + '/tokens/rotate',
                 dict(scope='coordinator_participant', channel_ids=[CHANNEL]), captain=True)
TOKENS[COORDINATOR] = same_grant['token']
api(conversation(decision), actor=COORDINATOR, token=TOKENS[COORDINATOR])
assert api(conversation(decision) + '/reconcile', dict(intent_id=missing['id']),
           actor=COORDINATOR, token=TOKENS[COORDINATOR])['intent']['id'] == missing['id']
reply(decision, reply_body(source, 'preflight-race-mattermost_base_url'), status=403)
api(conversation(decision), actor=COORDINATOR, token=previous_token, status=401)
assert len(POST_ATTEMPTS) == count
# Revoking the canonical requester's current enrollment prevents a fresh reply,
# despite a still-valid participant token and exact retained notification source.
api('workers/' + REQUESTER + '/revoke', {}, captain=True)
revoked_snapshot = canonical(decision)
reply(decision, reply_body(source, 'requester-enrollment-revoked'), status=403)
assert len(POST_ATTEMPTS) == count and canonical(decision) == revoked_snapshot
rotated = api('agents/' + COORDINATOR + '/tokens/rotate',
              dict(scope='coordinator_participant', channel_ids=['foreign-channel']), captain=True)
assert rotated['credential']['channel_ids'] == ['foreign-channel']
READ_ATTEMPTS.clear()
api(conversation(decision), actor=COORDINATOR, token=rotated['token'], status=403)
api(conversation(decision) + '/reconcile', dict(intent_id=missing['id']), actor=COORDINATOR,
    token=rotated['token'], status=403)
assert READ_ATTEMPTS == [], 'Foreign replacement grant must not reach remote reconciliation'
api(conversation(decision), actor=COORDINATOR, token=TOKENS[COORDINATOR], status=401)
setting('coordinator_id', OTHER)
api('agents/' + COORDINATOR + '/heartbeat', dict(status='idle'), actor=COORDINATOR,
    token=rotated['token'], status=401)
setting('coordinator_id', COORDINATOR)
default_rotation = api('agents/' + COORDINATOR + '/tokens/rotate', {}, captain=True)
assert default_rotation['credential']['scope'] == 'coordinator'
assert default_rotation['credential']['channel_ids'] == []
assert len(POST_ATTEMPTS) == count and not FAILURES, FAILURES
# Retained intent rows expose no chat bodies or reusable credentials.
persisted = sql('SELECT row_to_json(i) FROM decision_conversation_intents i')
for secret in (BOT_TOKEN, ELASTIC_TOKEN, CAPTAIN, *TOKENS.values(), body['body'], '😀'):
    assert secret not in persisted
print('decision conversation acceptance passed: packaged HTTP/CLI/Postgres; controlled fenced inbound adapter; no live/native proof')
server.shutdown()
redirect_server.shutdown()
