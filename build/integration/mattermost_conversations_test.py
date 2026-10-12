"""Phase 1 shared-bot agent chat acceptance: API-backed send/reads.

Agents hold NO Mattermost credentials: the CLI calls the Agentboard API
and the server posts with the ONE shared bot, stamping per-agent
attribution (header line plus structured props). A stub Mattermost records
every post; all proof runs against the packaged release and TLS
PostgreSQL. Bodies stay authoritative in Mattermost; coverage receipts
stay explicit.
"""
import json
import os
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = 'fixture-bot-token'
PROVISION_TOKEN = 'fixture-provisioner-token'

state = {
    'posts': {},
    'order': [],
    'received': [],
    'overrides': True,
    'bots': {},
    'token_owner': {},
    'channels': {},
    'post_modes': [],
    'create_modes': [],
    'hidden': set(),
    'lock': threading.Lock(),
}


class Stub(BaseHTTPRequestHandler):
    server_version = 'FixtureMattermost/1'

    def log_message(self, *args):
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bearer(self):
        auth = self.headers.get('Authorization', '')
        return auth[7:] if auth.startswith('Bearer ') else ''

    def _authed(self):
        bearer = self._bearer()
        if bearer in (TOKEN, PROVISION_TOKEN):
            return True
        with state['lock']:
            return bearer in state['token_owner']

    def _provisioned(self):
        return self._bearer() == PROVISION_TOKEN

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        payload = json.loads(self.rfile.read(length) or b'{}')
        parts = self.path.strip('/').split('/')
        # Phase 2 elastic bot admin endpoints require the provisioner token.
        if len(parts) >= 3 and parts[:3] == ['api', 'v4', 'bots']:
            if not self._provisioned():
                return self._json(401, {'message': 'invalid credentials'})
            with state['lock']:
                if parts == ['api', 'v4', 'bots']:
                    uid = f"bot-{len(state['bots']) + 1}"
                    state['bots'][uid] = {'username': payload.get('username'),
                                          'display_name': payload.get('display_name'),
                                          'disabled': False, 'tokens': {},
                                          'teams': [], 'channels': []}
                    return self._json(201, {'user_id': uid, 'username': payload.get('username'),
                                            'display_name': payload.get('display_name')})
                uid = parts[3]
                if uid not in state['bots']:
                    return self._json(404, {'message': 'unknown bot'})
                bot = state['bots'][uid]
                if len(parts) == 5 and parts[4] == 'token':
                    tok = f"tok-{uid}-{len(bot['tokens']) + 1}"
                    bot['tokens'][tok] = True
                    state['token_owner'][tok] = uid
                    return self._json(200, {'token': tok})
                if len(parts) == 5 and parts[4] in ('enable', 'disable'):
                    bot['disabled'] = parts[4] == 'disable'
                    return self._json(200, {'status': 'OK'})
            return self._json(404, {'message': 'unknown fixture path'})
        if len(parts) == 6 and parts[:3] == ['api', 'v4', 'users'] and parts[5] == 'revoke':
            if not self._provisioned():
                return self._json(401, {'message': 'invalid credentials'})
            with state['lock']:
                uid = parts[3]
                tid = payload.get('token_id', '')
                tok = tid[4:] if tid.startswith('tid-') else tid
                if uid in state['bots'] and tok in state['bots'][uid]['tokens']:
                    state['bots'][uid]['tokens'][tok] = False
                    return self._json(200, {'status': 'OK'})
            return self._json(404, {'message': 'unknown token'})
        if len(parts) == 5 and parts[:3] == ['api', 'v4', 'teams'] and parts[4] == 'members':
            if not self._provisioned():
                return self._json(401, {'message': 'invalid credentials'})
            with state['lock']:
                uid = payload.get('user_id')
                if uid in state['bots'] and payload.get('team_id') == parts[3]:
                    if parts[3] in state['bots'][uid]['teams']:
                        return self._json(409, {'message': 'already a member'})
                    state['bots'][uid]['teams'].append(parts[3])
                    return self._json(201, {})
            return self._json(400, {'message': 'bad membership'})
        if len(parts) == 5 and parts[:3] == ['api', 'v4', 'channels'] and parts[4] == 'members':
            if not self._provisioned():
                return self._json(401, {'message': 'invalid credentials'})
            with state['lock']:
                uid = payload.get('user_id')
                if uid in state['bots']:
                    if parts[3] in state['bots'][uid]['channels']:
                        return self._json(409, {'message': 'already a member'})
                    state['bots'][uid]['channels'].append(parts[3])
                    return self._json(201, {})
            return self._json(400, {'message': 'bad membership'})
        if not self._authed():
            return self._json(401, {'message': 'invalid credentials'})
        # Private channel creation by the shared bot (phase 1 recipient routes).
        if parts == ['api', 'v4', 'channels']:
            with state['lock']:
                mode = state['create_modes'].pop(0) if state['create_modes'] else 'ok'
                name = payload.get('name')
                if any(c['name'] == name for c in state['channels'].values()):
                    return self._json(400, {'id': 'store.sql_channel.save_channel.exists.app_error'})
                cid = f"route-{len(state['channels']) + 1}"
                channel = {'id': cid, 'name': name, 'type': payload.get('type'),
                           'team_id': payload.get('team_id'), 'creator_id': 'shared-bot',
                           'display_name': payload.get('display_name')}
                state['channels'][cid] = channel
            if mode == 'lost':
                return self._json(500, {'message': 'response lost after create'})
            return self._json(201, channel)
        # /api/v4/posts
        if parts == ['api', 'v4', 'posts']:
            bearer = self._bearer()
            with state['lock']:
                owner = state['token_owner'].get(bearer)
                if owner is not None and not state['bots'][owner]['tokens'].get(bearer, False):
                    return self._json(401, {'message': 'revoked token'})
                if owner is not None and state['bots'][owner]['disabled']:
                    return self._json(403, {'message': 'bot disabled'})
                sender = owner or 'shared-bot'
            with state['lock']:
                mode = state['post_modes'].pop(0) if state['post_modes'] else 'ok'
            if mode == 'drop_500':
                return self._json(500, {'message': 'rejected before storing'})
            pid = f"post-{len(state['order']) + 1}"
            post = {
                'id': pid,
                'channel_id': payload.get('channel_id'),
                'user_id': sender,
                'message': payload.get('message'),
                'root_id': payload.get('root_id'),
                'props': payload.get('props', {}),
                'override_username': payload.get('override_username'),
                'override_icon_url': payload.get('override_icon_url'),
                'create_at': 1000 + len(state['order']),
            }
            with state['lock']:
                state['received'].append(dict(payload, _posted_with=bearer, _sender=sender))
                if not state['overrides']:
                    post.pop('override_username', None)
                    post.pop('override_icon_url', None)
                state['posts'][pid] = post
                state['order'].append(pid)
            if mode == 'accept_500':
                return self._json(500, {'message': 'stored, response lost'})
            if mode == 'accept_hang':
                time.sleep(3)
            return self._json(201, post)
        return self._json(404, {'message': 'unknown fixture path'})

    def do_GET(self):
        if not self._authed():
            return self._json(401, {'message': 'invalid credentials'})
        parts = self.path.strip('/').split('?')[0].strip('/').split('/')
        # GET /api/v4/users/<id>/tokens (provisioner only)
        if len(parts) == 5 and parts[:3] == ['api', 'v4', 'users'] and parts[4] == 'tokens':
            if not self._provisioned():
                return self._json(401, {'message': 'invalid credentials'})
            with state['lock']:
                toks = [{'id': f"tid-{t}"} for t in state['bots'].get(parts[3], {}).get('tokens', {})]
            return self._json(200, toks)
        # /api/v4/channels/<id>/posts?page=&per_page=
        if len(parts) == 5 and parts[:3] == ['api', 'v4', 'channels'] and parts[4] == 'posts':
            from urllib.parse import urlparse, parse_qs
            query = parse_qs(urlparse(self.path).query)
            page = int(query.get('page', ['0'])[0])
            per_page = int(query.get('per_page', ['60'])[0])
            with state['lock']:
                hidden = parts[3] in state['hidden']
                channel_posts = [p for p in (state['posts'][i] for i in state['order'])
                                 if p['channel_id'] == parts[3] and not hidden]
            channel_posts.sort(key=lambda p: p['create_at'], reverse=True)
            window = channel_posts[page * per_page:(page + 1) * per_page]
            return self._json(200, {
                'order': [p['id'] for p in window],
                'posts': {p['id']: p for p in window},
            })
        if parts == ['api', 'v4', 'system', 'ping']:
            return self._json(200, {'status': 'ok'})
        if parts == ['api', 'v4', 'users', 'me']:
            if self._bearer() != TOKEN:
                return self._json(403, {'message': 'not the shared bot'})
            return self._json(200, {'id': 'shared-bot', 'is_bot': True, 'roles': 'system_user'})
        # /api/v4/teams/<team>/channels/name/<name>
        if len(parts) == 7 and parts[:3] == ['api', 'v4', 'teams'] and parts[4:6] == ['channels', 'name']:
            with state['lock']:
                match = next((c for c in state['channels'].values()
                              if c['name'] == parts[6] and c['team_id'] == parts[3]), None)
            return self._json(200, match) if match else self._json(404, {'message': 'no channel'})
        return self._json(404, {'message': 'unknown fixture path'})


server = ThreadingHTTPServer(('127.0.0.1', 0), Stub)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
print(f'stub mattermost on 127.0.0.1:{port}')


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(method, path, body=None, headers=None):
    import urllib.request
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(os.environ['AGENTBOARD_URL'] + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, json.loads(resp.read() or b'null')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'null')


cli_env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG', 'AGENTBOARD_MATTERMOST_'))}
cli_env.update(AGENT_ID='worker-a', AGENTBOARD_MODEL='fixture', AGENTBOARD_HARNESS='codex')
# Deliberately NO Mattermost variables in the worker environment: agents
# hold no MM credentials in Phase 1. Non-secret harness config injected by
# the test runner (bridge flags, timeouts) is stripped above, so assert the
# credential-bearing seams specifically.
for key in list(cli_env):
    assert key not in ('AGENTBOARD_MATTERMOST_BASE_URL', 'AGENTBOARD_MATTERMOST_BOT_TOKEN', 'AGENTBOARD_MATTERMOST_BOT_TOKEN_FILE', 'AGENTBOARD_MATTERMOST_CA_FILE'), key


def ab(*args, success=True, agent_id=None):
    env = dict(cli_env)
    if agent_id is not None:
        env['AGENT_ID'] = agent_id
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=25)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)
    assert result.returncode != 0, (args, result.stdout)


WA = {'X-Agentboard-Agent': 'worker-a', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
WB = {'X-Agentboard-Agent': 'worker-b', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
GHOST = {'X-Agentboard-Agent': 'ghost', 'X-Agentboard-Model': 'f', 'X-Agentboard-Harness': 'c'}

rpc(f'Application.put_env(:agentboard, :mattermost_base_url, "http://127.0.0.1:{port}")')
# Phase 1 runs with provisioning held off so the shared-bot shape is
# deterministic; Phase 2 restores the provisioner token below.
rpc('Application.put_env(:agentboard, :mattermost_provisioner_token, nil)')
ab('agent', 'register')
ab('agent', 'register', agent_id='worker-b')

# Unknown agents authorize nothing.
status, _ = api('POST', '/api/v1/conversations/send',
                {'channel_id': 'chan-1', 'body': 'hi'}, GHOST)
assert status == 422, status

# Invalid kinds are rejected at the boundary, not stored.
status, _ = api('POST', '/api/v1/conversations/send',
                {'channel_id': 'chan-1', 'body': 'hi', 'kind': 'rm -rf'}, WA)
assert status == 422, status
status, _ = api('POST', '/api/v1/conversations/send', {'body': 'no channel'}, WA)
assert status == 422, status

# Channel ids are path-interpolated upstream: slashes or query strings
# must be rejected, not fetched as a different URL.
status, _ = api('POST', '/api/v1/conversations/send',
                {'channel_id': 'chan-1/extra', 'body': 'hi'}, WA)
assert status == 422, status
status, _ = api('GET', '/api/v1/conversations/reads?channel_id=x%3Fpage%3D9', None, WA)
assert status == 422, status

# Send through the API: the shared bot posts with props + header + override.
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'hello agents',
                    'task_id': 'task-9', 'kind': 'status', 'retry_key': 'key-1'}, WA)
assert status == 200, (status, body)
assert body['duplicate'] is False and body['post']['id'] == 'post-1', body
assert isinstance(body['msg_id'], str) and body['msg_id'], body
with state['lock']:
    stored = state['posts']['post-1']
assert stored['user_id'] == 'shared-bot', stored
assert stored['message'].startswith('[worker-a · task-9]\nhello agents'), stored['message']
assert stored['override_username'] == 'worker-a', stored
assert stored['props']['agent_id'] == 'worker-a', stored['props']
assert stored['props']['task_id'] == 'task-9', stored['props']
assert stored['props']['kind'] == 'status', stored['props']
assert stored['props']['msg_id'] == body['msg_id'], stored['props']
assert stored['props']['agentboard_retry_key'] == 'key-1', stored['props']
first_msg_id = body['msg_id']

# task_id values carrying header-forging newlines or brackets are rejected.
status, _ = api('POST', '/api/v1/conversations/send',
                {'channel_id': 'chan-1', 'body': 'hi', 'task_id': 't\nforged line'}, WA)
assert status == 422, status
status, _ = api('POST', '/api/v1/conversations/send',
                {'channel_id': 'chan-1', 'body': 'hi', 'task_id': 't[evil]'}, WA)
assert status == 422, status
with state['lock']:
    assert len(state['posts']) == 1, len(state['posts'])

# Retry with the same key adopts the post instead of duplicating, and the
# duplicate path returns the adopted post's msg_id for contract parity.
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'hello again', 'retry_key': 'key-1'}, WA)
assert status == 200 and body['duplicate'] is True and body['post']['id'] == 'post-1', (status, body)
assert body['msg_id'] == first_msg_id, (body, first_msg_id)
with state['lock']:
    assert len(state['posts']) == 1, len(state['posts'])

# Reads suppress the caller's own echo by props.agent_id and record
# explicit coverage. No cursor: bounded snapshot, not catch-up.
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&limit=50', None, WA)
assert status == 200, (status, body)
assert body['posts'] == [] and body['caught_up'] is False, body
assert body['incomplete_reason'] == 'bounded_snapshot', body
assert sql("SELECT caught_up FROM conversation_coverage WHERE agent_id='worker-a' AND channel_id='chan-1'") == 'f'
assert sql("SELECT incomplete_reason FROM conversation_coverage WHERE agent_id='worker-a' AND channel_id='chan-1'") == 'bounded_snapshot'
# No credential value is ever stored server-side for chat.
assert 'fixture' not in sql("SELECT row_to_json(c)::text FROM conversation_coverage c")

# A peer sees the post (own echo stays suppressed for the sender).
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&since=post-0', None, WB)
assert status == 200 and len(body['posts']) == 1 and body['posts'][0]['id'] == 'post-1', (status, body)
assert body['posts'][0]['props']['agent_id'] == 'worker-a', body
assert body['posts'][0]['user_id'] == 'shared-bot', body
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&since=post-1', None, WB)
assert status == 200 and body['caught_up'] is True and body['incomplete_reason'] is None, (status, body)
# Read-at-cursor still records a receipt: the ledger must show worker-b
# caught up at the cursor even though nothing newer existed.
assert sql("SELECT last_post_id FROM conversation_coverage WHERE agent_id='worker-b' AND channel_id='chan-1'") == 'post-1'
assert sql("SELECT caught_up FROM conversation_coverage WHERE agent_id='worker-b' AND channel_id='chan-1'") == 't'

# The packaged CLI drives the same API: send, then read past the cursor.
out = ab('chat', 'send', '--channel', 'chan-1', '--body', 'cli hello', '--task', 'task-9',
         '--kind', 'note', '--retry-key', 'key-cli')
assert out['duplicate'] is False, out
out = ab('chat', 'read', '--channel', 'chan-1', '--since', 'post-1')
assert out['caught_up'] is True and out['incomplete_reason'] is None, out

# A stale cursor that was never in the delivered window must not advance
# coverage past it: worker-b's receipt stays at post-1 with cursor_not_found.
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&since=post-999&limit=50', None, WB)
assert status == 200 and body['caught_up'] is False, (status, body)
assert body['incomplete_reason'] == 'cursor_not_found', body
assert sql("SELECT last_post_id FROM conversation_coverage WHERE agent_id='worker-b' AND channel_id='chan-1'") == 'post-1'
assert sql("SELECT caught_up FROM conversation_coverage WHERE agent_id='worker-b' AND channel_id='chan-1'") == 'f'
# The next read from the kept cursor still delivers everything after it.
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&since=post-1&limit=50', None, WB)
assert status == 200 and [p['id'] for p in body['posts']] == ['post-2'], (status, body)
assert body['caught_up'] is True and body['incomplete_reason'] is None, body

# A blank cursor is normalized to no cursor: bounded snapshot, not a miss.
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&since=%20&limit=50', None, WB)
assert status == 200 and body['caught_up'] is False, (status, body)
assert body['incomplete_reason'] == 'bounded_snapshot', body

# Channel allowlist gates send and reads when configured; empty means open.
rpc("Application.put_env(:agentboard, :mattermost_channel_allowlist, \"chan-1\")")
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-9', 'body': 'scoped out'}, WA)
assert status == 422 and body['error']['code'] == 'invalid_context', (status, body)
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-9', None, WA)
assert status == 422 and body['error']['code'] == 'invalid_context', (status, body)
status, _ = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&limit=5', None, WA)
assert status == 200, status
rpc('Application.put_env(:agentboard, :mattermost_channel_allowlist, "")')
status, _ = api('GET', '/api/v1/conversations/reads?channel_id=chan-9', None, WA)
assert status == 200, status

# Override detection: the stub mimics the server flags — when off it
# strips override fields from the stored post, like a Mattermost server
# with EnablePostUsernameOverride/EnablePostIconOverride false. TTL 0
# forces every send to re-observe; detection adds no extra requests.
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 0)")
status, diag = api('GET', '/api/v1/conversations/diagnostics', None, WA)
assert status == 200, (status, diag)
assert diag['overrides']['username'] is True, diag
assert diag['overrides']['username_source'] == 'observed', diag
state['overrides'] = False
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'off-mode probe',
                    'task_id': 'task-9', 'kind': 'note', 'retry_key': 'key-off-1'}, WA)
assert status == 200 and body['duplicate'] is False, (status, body)
with state['lock']:
    off_post = state['posts'][body['post']['id']]
assert off_post.get('override_username') is None, off_post
assert off_post['message'].startswith('[worker-a · task-9]\n'), off_post['message']
status, diag = api('GET', '/api/v1/conversations/diagnostics', None, WA)
assert status == 200 and diag['overrides']['username'] is False, (status, diag)
# Per-field independence: no send carried icon_url, so icon stays
# unobserved while username was observed off.
assert diag['overrides']['icon'] is None, diag
assert diag['overrides']['icon_source'] == 'unobserved', diag
# Cached-off sends omit the fields; props plus header still carry identity.
# TTL 0 keeps every observation stale (always re-probes), so switch to a
# fresh TTL here: the off observation just recorded stays fresh-off and
# the next send omits the field instead of re-probing.
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 3600)")
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'off-mode gated',
                    'task_id': 'task-9', 'kind': 'note', 'retry_key': 'key-off-2'}, WA)
assert status == 200 and body['duplicate'] is False, (status, body)
with state['lock']:
    raw = state['received'][-1]
assert 'override_username' not in raw, raw
assert raw['message'].startswith('[worker-a · task-9]\noff-mode gated'), raw['message']
assert raw['props']['agent_id'] == 'worker-a', raw['props']
# Flags back on: expiry re-observes and resumes overrides. With a fresh
# off cache the field would stay omitted, so expire it (TTL 0) and the
# next send re-probes.
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 0)")
state['overrides'] = True
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'on again',
                    'task_id': 'task-9', 'kind': 'note', 'retry_key': 'key-on-2'}, WA)
assert status == 200 and body['duplicate'] is False, (status, body)
with state['lock']:
    on_post = state['posts'][body['post']['id']]
assert on_post['override_username'] == 'worker-a', on_post
status, diag = api('GET', '/api/v1/conversations/diagnostics', None, WA)
assert status == 200 and diag['overrides']['username'] is True, (status, diag)
assert diag['overrides']['icon'] is None, diag
assert diag['overrides']['icon_source'] == 'unobserved', diag
# Unknown agents see nothing.
status, _ = api('GET', '/api/v1/conversations/diagnostics', None, GHOST)
assert status == 422, status
print('Phase 1 shared-bot chat: API send with props/header/override, retry-key adoption, echo-suppressed reads, explicit coverage and override diagnostics passed')

# ---------------------------------------------------------------------------
# 5.2 protected outbound spool. Every send is recorded before the network
# call; an accepted-post/lost-response reconciles by props.msg_id; ambiguity
# parks visibly as uncertain and needs explicit resolution. Overrides are on.
# ---------------------------------------------------------------------------
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 3600)")
SEND = '/api/v1/conversations/send'


def post_count():
    with state['lock']:
        return len(state['order'])


def ab_raw(*args, agent_id=None):
    env = dict(cli_env)
    if agent_id is not None:
        env['AGENT_ID'] = agent_id
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=40)
    return result.returncode, result.stdout, result.stderr


def spool(msg_id, column):
    return sql(f"SELECT {column} FROM conversation_spool WHERE msg_id='{msg_id}'")


# A verified send keeps metadata only: the body is dropped once Mattermost
# holds it, and the receipt never echoes it.
status, sent = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'spool body alpha',
                                  'task_id': 'task-9', 'retry_key': 'spool-1'}, WA)
assert status == 200 and sent['state'] == 'sent' and sent['duplicate'] is False, (status, sent)
assert sent['spool']['body_retained'] is False and sent['spool']['post_id'] == sent['post']['id'], sent
assert 'spool body alpha' not in json.dumps(sent['spool']), sent
assert spool(sent['msg_id'], "state||','||(body IS NULL)::text||','||retry_key") == 'sent,true,spool-1'
# Exact retry keys: the same key from another agent is a different message,
# the same agent's repeat adopts without posting, another channel conflicts.
before = post_count()
status, peer = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'peer body', 'retry_key': 'spool-1'}, WB)
assert status == 200 and peer['duplicate'] is False and peer['msg_id'] != sent['msg_id'], peer
assert post_count() == before + 1
status, again = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'spool body alpha', 'retry_key': 'spool-1'}, WA)
assert status == 200 and again['duplicate'] is True and again['msg_id'] == sent['msg_id'], again
assert again['post']['id'] == sent['post']['id'] and post_count() == before + 1, again
status, other = api('POST', SEND, {'channel_id': 'chan-2', 'body': 'x', 'retry_key': 'spool-1'}, WA)
assert status == 409 and other['error']['code'] == 'conflict', (status, other)

# Accepted-post/lost-response (5xx after storing, and a timeout after
# storing): the same request reconciles by msg_id and reports the one post.
for mode in ('accept_500', 'accept_hang'):
    with state['lock']:
        state['post_modes'].append(mode)
    before = post_count()
    status, body = api('POST', SEND, {'channel_id': 'chan-1', 'body': f'lost {mode}', 'retry_key': f'lost-{mode}'}, WA)
    assert status == 200 and body['state'] == 'sent' and body['duplicate'] is False, (mode, status, body)
    assert body['spool']['resolution'] == 'reconciled' and post_count() == before + 1, (mode, body)
    with state['lock']:
        stored = state['posts'][body['post']['id']]
    assert stored['props']['msg_id'] == body['msg_id'] and stored['props']['agent_id'] == 'worker-a', stored

# Unresolved ambiguity: nothing was stored and history cannot prove it, so
# the send parks as uncertain (202) with its body retained for a decision.
with state['lock']:
    state['post_modes'].append('drop_500')
before = post_count()
status, unsure = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'maybe posted', 'retry_key': 'unsure-1'}, WA)
assert status == 202 and unsure['state'] == 'uncertain' and unsure['reason'] == 'post_not_observed', (status, unsure)
assert unsure['post'] is None and unsure['spool']['body_retained'] is True, unsure
assert spool(unsure['msg_id'], 'body') == 'maybe posted'
# The same retry key reconciles again; it never blindly posts.
status, still = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'maybe posted', 'retry_key': 'unsure-1'}, WA)
assert status == 202 and still['state'] == 'uncertain' and still['msg_id'] == unsure['msg_id'], still
assert post_count() == before
# Machine-readable CLI: status prints the receipt and exits 5 while unresolved.
code, out, err = ab_raw('chat', 'status', '--msg-id', unsure['msg_id'])
assert code == 5 and json.loads(out)['send']['state'] == 'uncertain', (code, out, err)
assert json.loads(err)['error']['code'] == 'send_unresolved', err
assert 'maybe posted' not in out
# Other agents cannot see or resolve it; the list is metadata of own sends.
status, _ = api('GET', f"/api/v1/conversations/sends/{unsure['msg_id']}", None, WB)
assert status == 404, status
status, _ = api('POST', f"/api/v1/conversations/sends/{unsure['msg_id']}/resolve", {'action': 'retry'}, WB)
assert status == 404, status
status, listing = api('GET', '/api/v1/conversations/sends?state=uncertain', None, WA)
assert status == 200 and [s['msg_id'] for s in listing['sends']] == [unsure['msg_id']], listing
assert 'maybe posted' not in json.dumps(listing)
# Explicit manual retry records the possible duplicate, then posts once.
code, out, err = ab_raw('chat', 'resolve', '--msg-id', unsure['msg_id'], '--action', 'retry')
assert code == 0, (code, out, err)
retried = json.loads(out)
assert retried['state'] == 'sent' and retried['spool']['resolution'] == 'manual_retry_possible_duplicate', retried
assert retried['spool']['attempts'] == 2 and post_count() == before + 1, retried
assert spool(unsure['msg_id'], 'body IS NULL') == 't'

# Accepted but invisible: history later shows it, so a repeat adopts it.
with state['lock']:
    state['post_modes'].append('accept_500')
    state['hidden'].add('chan-1')
before = post_count()
status, hidden = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'hidden once', 'retry_key': 'hidden-1'}, WA)
assert status == 202 and hidden['state'] == 'uncertain', (status, hidden)
assert post_count() == before + 1
with state['lock']:
    state['hidden'].discard('chan-1')
status, adopted = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'hidden once', 'retry_key': 'hidden-1'}, WA)
assert status == 200 and adopted['duplicate'] is True and adopted['spool']['resolution'] == 'reconciled', adopted
assert post_count() == before + 1

# Duplicates are flagged, not hidden: two remote copies of one msg_id.
with state['lock']:
    state['post_modes'].append('accept_500')
    state['hidden'].add('chan-1')
status, twice = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'twice', 'retry_key': 'twice-1'}, WA)
assert status == 202, (status, twice)
with state['lock']:
    original = state['posts'][state['order'][-1]]
    copy_id = f"post-{len(state['order']) + 1}"
    state['posts'][copy_id] = dict(original, id=copy_id, create_at=original['create_at'] + 50)
    state['order'].append(copy_id)
    state['hidden'].discard('chan-1')
status, flagged = api('POST', f"/api/v1/conversations/sends/{twice['msg_id']}/resolve", {'action': 'reconcile'}, WA)
assert status == 200 and flagged['state'] == 'sent', (status, flagged)
assert flagged['spool']['resolution'] == 'reconciled_duplicate' and flagged['spool']['duplicate_post_ids'] == [copy_id], flagged

# Abandon is explicit and retires the key.
with state['lock']:
    state['post_modes'].append('drop_500')
status, gone = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'abandon me', 'retry_key': 'gone-1'}, WA)
assert status == 202, (status, gone)
code, out, _ = ab_raw('chat', 'resolve', '--msg-id', gone['msg_id'], '--action', 'abandon')
assert code == 0 and json.loads(out)['state'] == 'abandoned', (code, out)
assert spool(gone['msg_id'], 'body IS NULL') == 't'
status, refused = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'abandon me', 'retry_key': 'gone-1'}, WA)
assert status == 409, (status, refused)

# Configurable expiry purges bodies: unresolved rows become body-free
# `expired` markers that still block a blind replay; terminal rows go.
rpc('Application.put_env(:agentboard, :chat_spool_ttl_s, 1)')
with state['lock']:
    state['post_modes'].append('drop_500')
status, short = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'short lived', 'retry_key': 'short-1'}, WA)
assert status == 202 and spool(short['msg_id'], 'body') == 'short lived', (status, short)
status, brief = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'brief sent', 'retry_key': 'brief-1'}, WA)
assert status == 200, (status, brief)
time.sleep(2)
purged = rpc('input = Ash.ActionInput.for_action(Agentboard.Mattermost.Router, :purge_chat_spool, %{}, actor: %{role: :system}); IO.inspect(Ash.run_action(input))')
assert 'expired' in purged, purged
assert spool(short['msg_id'], "state||','||(body IS NULL)::text") == 'expired,true'
assert sql(f"SELECT count(*) FROM conversation_spool WHERE msg_id='{brief['msg_id']}'") == '0'
status, late = api('POST', f"/api/v1/conversations/sends/{short['msg_id']}/resolve", {'action': 'retry'}, WA)
assert status == 409 and 'expired' in late['error']['message'], (status, late)
before = post_count()
status, replay = api('POST', SEND, {'channel_id': 'chan-1', 'body': 'short lived', 'retry_key': 'short-1'}, WA)
assert status == 202 and replay['state'] == 'expired' and post_count() == before, (status, replay)
rpc('Application.put_env(:agentboard, :chat_spool_ttl_s, 86400)')

# Protected storage: no PUBLIC grant, no BM25/search index, and no spooled
# body anywhere but the bounded unresolved rows.
assert sql("SELECT has_table_privilege('public', 'conversation_spool', 'SELECT')") == 'f'
assert sql("SELECT count(*) FROM pg_indexes WHERE tablename='conversation_spool' AND indexdef ILIKE '%bm25%'") == '0'
assert sql("SELECT count(*) FROM conversation_spool WHERE body IS NOT NULL AND state <> 'uncertain'") == '0'

# Own-send suppression needs props.agent_id plus msg_id: a post that merely
# names worker-a without a server msg_id still reaches worker-a.
with state['lock']:
    forged_id = f"post-{len(state['order']) + 1}"
    state['posts'][forged_id] = {'id': forged_id, 'channel_id': 'chan-1', 'user_id': 'human-1',
                                 'message': 'forged attribution', 'root_id': None,
                                 'props': {'agent_id': 'worker-a'}, 'create_at': 9000}
    state['order'].append(forged_id)
status, body = api('GET', '/api/v1/conversations/reads?channel_id=chan-1&limit=200', None, WA)
seen = [p['id'] for p in body['posts']]
assert forged_id in seen and sent['post']['id'] not in seen, seen
assert peer['post']['id'] in seen, seen
print('5.2 spool: exact retry keys, accepted-then-500/timeout reconciliation, parked uncertainty, explicit retry/abandon, duplicate flagging, expiry, protection and own-send suppression passed')

# ---------------------------------------------------------------------------
# 5.1 private recipient routes through the shared bot. Off by default: a
# private notice captured while off stays parked and is never replayed.
# ---------------------------------------------------------------------------
def transport():
    with urllib.request.urlopen(os.environ['AGENTBOARD_URL'] + '/api/v1/meta') as response:
        return json.load(response)['message_transport']


blockers = set(transport()['blockers'])
assert 'private_recipient_routes_disabled' in blockers, blockers
assert not blockers & {'peer_identities_unavailable_5_1', 'headless_send_read_unavailable_5_2'}, blockers
assert 'inbox_catch_up_unavailable_5_3' in blockers, blockers
status, body = api('POST', SEND, {'to': 'worker-b', 'body': 'routes off'}, WA)
assert status == 422 and body['error']['code'] == 'invalid_context', (status, body)
rpc('Application.put_env(:agentboard, :message_mode, "dual")')
parked = ab('msg', 'send', '--to', 'worker-b', '--body', 'Parked before routes')['message']
assert sql(f"SELECT routing_revision||','||last_error FROM mattermost_outbox WHERE source_key='message:{parked['id']}'") == '1,recipient_route_unavailable'

rpc('Application.put_env(:agentboard, :mattermost_private_routes_enabled, true)')
assert 'private_recipient_routes_disabled' not in transport()['blockers']
# A lost create response is recovered by adopting the bot's own channel.
with state['lock']:
    state['create_modes'].append('lost')
status, body = api('POST', SEND, {'to': 'worker-b', 'body': 'first private', 'task_id': 'task-9', 'retry_key': 'dm-1'}, WA)
assert status == 503 and 'route' in body['error']['message'], (status, body)
assert sql("SELECT count(*) FROM mattermost_agent_routes") == '0'
code, out, err = ab_raw('chat', 'send', '--to', 'worker-b', '--body', 'first private', '--task', 'task-9', '--retry-key', 'dm-1')
assert code == 0, (code, out, err)
dm = json.loads(out)
route = sql("SELECT channel_id FROM mattermost_agent_routes WHERE agent_id='worker-b'")
with state['lock']:
    assert len(state['channels']) == 1 and state['channels'][route]['type'] == 'P', state['channels']
    dm_post = state['posts'][dm['post']['id']]
assert dm_post['channel_id'] == route and dm_post['user_id'] == 'shared-bot', dm_post
assert dm_post['message'] == '[worker-a · task-9]\n@worker-b first private', dm_post['message']
assert dm_post['override_username'] == 'worker-a', dm_post
assert dm_post['props']['agent_id'] == 'worker-a' and dm_post['props']['recipient_id'] == 'worker-b', dm_post
assert dm_post['props']['msg_id'] == dm['msg_id'] and dm['spool']['recipient_id'] == 'worker-b', dm
# Only the recipient reads the route; nobody addresses it by channel id.
out = ab('chat', 'read', '--inbox', agent_id='worker-b')
assert [p['id'] for p in out['posts']] == [dm['post']['id']], out
assert out['posts'][0]['props']['agent_id'] == 'worker-a' and out['channel_id'] == route, out
status, body = api('GET', f'/api/v1/conversations/reads?channel_id={route}', None, WA)
assert status == 403, (status, body)
status, body = api('POST', SEND, {'channel_id': route, 'body': 'sneak'}, WA)
assert status == 403, (status, body)
status, body = api('POST', SEND, {'to': 'ghost', 'body': 'nobody'}, WA)
assert status == 422, (status, body)
# A foreign channel holding a route name is never adopted.
foreign = rpc('IO.puts(Agentboard.Mattermost.AgentRoutes.channel_name("worker-c"))').strip()
with state['lock']:
    state['channels']['foreign-1'] = {'id': 'foreign-1', 'name': foreign, 'type': 'P', 'team_id': 'fixture-team',
                                      'creator_id': 'someone-else', 'display_name': 'x'}
ab('agent', 'register', agent_id='worker-c')
before = post_count()
status, body = api('POST', SEND, {'to': 'worker-c', 'body': 'collide'}, WA)
assert status == 503 and 'route_name_collision' in body['error']['message'], (status, body)
assert post_count() == before

# Dual-mode board DMs now deliver a body-free, attributed notice to the
# recipient's route; the legacy board inbox contract is unchanged.
private = ab('msg', 'send', '--to', 'worker-b', '--body', 'Secret board body')['message']
wait_rows = f"SELECT state||','||routing_revision FROM mattermost_outbox WHERE source_key='message:{private['id']}'"
for _ in range(60):
    if sql(wait_rows) == 'sent,2':
        break
    time.sleep(1)
assert sql(wait_rows) == 'sent,2', sql(wait_rows)
notice_id = sql(f"SELECT remote_post_id FROM mattermost_outbox WHERE source_key='message:{private['id']}'")
marker = sql(f"SELECT event_marker FROM mattermost_outbox WHERE source_key='message:{private['id']}'")
with state['lock']:
    notice = state['posts'][notice_id]
assert notice['channel_id'] == route and notice['user_id'] == 'shared-bot', notice
assert notice['message'].startswith('[worker-a · general]\n@worker-b private board message #%s from worker-a' % private['id']), notice['message']
assert 'Secret board body' not in notice['message'], notice['message']
assert notice['override_username'] == 'worker-a', notice
assert notice['props']['agent_id'] == 'worker-a' and notice['props']['msg_id'] == marker, notice['props']
assert notice['props']['agentboard_event_marker'] == marker and notice['props']['recipient_id'] == 'worker-b', notice['props']
assert private['id'] in [m['id'] for m in ab('msg', 'list', '--unread', agent_id='worker-b')['messages']]
assert sql(f"SELECT routing_revision||','||state||','||last_error FROM mattermost_outbox WHERE source_key='message:{parked['id']}'") == '1,pending,recipient_route_unavailable'
# Overrides off: header plus props still carry identity.
state['overrides'] = False
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 0)")
quiet = ab('msg', 'send', '--to', 'worker-b', '--body', 'Quiet override')['message']
wait_rows = f"SELECT state FROM mattermost_outbox WHERE source_key='message:{quiet['id']}'"
for _ in range(60):
    if sql(wait_rows) == 'sent':
        break
    time.sleep(1)
quiet_post = sql(f"SELECT remote_post_id FROM mattermost_outbox WHERE source_key='message:{quiet['id']}'")
with state['lock']:
    stored = state['posts'][quiet_post]
assert stored.get('override_username') is None and stored['message'].startswith('[worker-a · general]\n@worker-b'), stored
assert stored['props']['agent_id'] == 'worker-a', stored
state['overrides'] = True
rpc("Application.put_env(:agentboard, :mattermost_override_ttl_s, 3600)")
# Accepted notice whose response is lost: reconciled by marker, one post.
with state['lock']:
    state['post_modes'].append('accept_500')
before = post_count()
lost = ab('msg', 'send', '--to', 'worker-b', '--body', 'Lost notice')['message']
wait_rows = f"SELECT state FROM mattermost_outbox WHERE source_key='message:{lost['id']}'"
for _ in range(60):
    if sql(wait_rows) == 'sent':
        break
    time.sleep(1)
assert sql(wait_rows) == 'sent' and post_count() == before + 1, (sql(wait_rows), post_count(), before)
rpc('Application.put_env(:agentboard, :mattermost_private_routes_enabled, false); Application.put_env(:agentboard, :message_mode, "board")')
print('5.1 private routes: default-off parking, lost-create adoption, foreign-name refusal, owner-only inbox, attributed body-free dual notices with override on/off and lost-response reconciliation passed')

# Phase 2 elastic per-agent bots. The release boots with a fixture cloak
# key and provisioner token (BUILD env); the stub mimics the bot admin
# endpoints. Provisioning runs in Oban, so activation is polled.
# Re-enable provisioning held off for the deterministic Phase 1 above.
rpc('Application.put_env(:agentboard, :mattermost_provisioner_token, "fixture-provisioner-token")')
WBOT = {'X-Agentboard-Agent': 'worker-bot', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}


def wait_bot(headers, want_active, tries=45):
    for _ in range(tries):
        s, d = api('GET', '/api/v1/conversations/diagnostics', None, headers)
        assert s == 200, (s, d)
        if d['bot']['active'] == want_active:
            return d
        time.sleep(2)
    raise AssertionError(('bot never reached', want_active, d))


# Short-name mapping is deterministic and fits 22 chars.
out = rpc('Agentboard.Mattermost.ElasticBots.short_name("abc") |> IO.inspect()').strip()
assert out == '"ab-abc"', out
out = rpc('Agentboard.Mattermost.ElasticBots.short_name("codex-agent-b-worker") |> IO.inspect()').strip()
assert out.startswith('"ab-') and len(out) <= 24, out

# First register provisions exactly one bot; a racing second register adopts.
out = ab('agent', 'register', agent_id='worker-bot')
assert out['agent']['id'] == 'worker-bot', out
diag = wait_bot(WBOT, True)
assert diag['bot']['state'] == 'active' and diag['bot']['username'].startswith('ab-'), diag
out = ab('agent', 'register', agent_id='worker-bot')
with state['lock']:
    mine = [u for u, b in state['bots'].items() if b['display_name'] == 'worker-bot']
assert len(mine) == 1, mine
bot_uid = mine[0]
with state['lock']:
    assert state['bots'][bot_uid]['teams'] == ['fixture-team'], state['bots'][bot_uid]
    assert 'chan-1' in state['bots'][bot_uid]['channels'], state['bots'][bot_uid]

# Sends post as the bot with identical props/header shape.
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'bot hello',
                    'task_id': 'task-9', 'kind': 'status', 'retry_key': 'key-bot-1'}, WBOT)
assert status == 200 and body['duplicate'] is False, (status, body)
with state['lock']:
    bot_post = state['posts'][body['post']['id']]
assert bot_post['user_id'] == bot_uid, bot_post
assert bot_post['message'].startswith('[worker-bot · task-9]\nbot hello'), bot_post['message']
assert bot_post['props']['agent_id'] == 'worker-bot', bot_post['props']

# Tokens never surface in DB rows, API output, or CLI output.
row = sql("SELECT row_to_json(m)::text FROM mattermost_agent_bots m WHERE agent_id='worker-bot'")
assert 'tok-' not in row, row
assert 'tok-' not in json.dumps(diag), diag
out = ab('chat', 'read', '--channel', 'chan-1', '--since', body['post']['id'], agent_id='worker-bot')
assert 'tok-' not in json.dumps(out), out

# Revoked token falls back to the shared bot for that send, then re-provisions.
with state['lock']:
    old_tok = next(t for t, ok in state['bots'][bot_uid]['tokens'].items() if ok)
    state['bots'][bot_uid]['tokens'][old_tok] = False
status, body = api('POST', '/api/v1/conversations/send',
                   {'channel_id': 'chan-1', 'body': 'after revoke',
                    'task_id': 'task-9', 'kind': 'note', 'retry_key': 'key-bot-2'}, WBOT)
assert status == 200 and body['duplicate'] is False, (status, body)
with state['lock']:
    fb_post = state['posts'][body['post']['id']]
assert fb_post['user_id'] == 'shared-bot', fb_post
diag = wait_bot(WBOT, True)
with state['lock']:
    new_tok = next(t for t, ok in state['bots'][bot_uid]['tokens'].items() if ok)
assert new_tok != old_tok, (new_tok, old_tok)

# Retire disables plus revokes; re-register reactivates with a fresh token.
rpc('Agentboard.Mattermost.ElasticBots.retire("worker-bot")')
with state['lock']:
    assert state['bots'][bot_uid]['disabled'] is True, state['bots'][bot_uid]
    assert not any(state['bots'][bot_uid]['tokens'].values()), state['bots'][bot_uid]
    assert sql("SELECT state FROM mattermost_agent_bots WHERE agent_id='worker-bot'") == 'retired'
diag = wait_bot(WBOT, False)
assert diag['bot']['state'] == 'retired', diag
out = ab('agent', 'register', agent_id='worker-bot')
diag = wait_bot(WBOT, True)
with state['lock']:
    fresh_tok = next(t for t, ok in state['bots'][bot_uid]['tokens'].items() if ok)
assert fresh_tok != new_tok, (fresh_tok, new_tok)

# Collision-checked mapping: a colliding handle resolves deterministically elsewhere.
out = rpc('Agentboard.Mattermost.ElasticBots.unique_username("Worker Bot") |> IO.inspect()').strip()
assert out.startswith('"ab-') and out != '"ab-worker-bot"', out

# Mattermost down at register time: registration still succeeds, row waits pending.
rpc('Application.put_env(:agentboard, :mattermost_base_url, "http://127.0.0.1:9")')
WDOWN = {'X-Agentboard-Agent': 'worker-down', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
out = ab('agent', 'register', agent_id='worker-down')
assert out['agent']['id'] == 'worker-down', out
status, diag = api('GET', '/api/v1/conversations/diagnostics', None, WDOWN)
assert status == 200 and diag['bot']['active'] is False, (status, diag)
assert diag['bot']['state'] == 'pending', diag
rpc(f'Application.put_env(:agentboard, :mattermost_base_url, "http://127.0.0.1:{port}")')
print('Phase 2 elastic bots: lazy provision, short-name mapping, encrypted tokens, fallback, retire/reactivate passed')
