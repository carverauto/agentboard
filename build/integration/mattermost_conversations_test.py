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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = 'fixture-bot-token'

state = {
    'posts': {},
    'order': [],
    'received': [],
    'overrides': True,
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

    def _authed(self):
        return self.headers.get('Authorization') == f'Bearer {TOKEN}'

    def do_POST(self):
        if not self._authed():
            return self._json(401, {'message': 'invalid credentials'})
        length = int(self.headers.get('Content-Length', 0))
        payload = json.loads(self.rfile.read(length) or b'{}')
        parts = self.path.strip('/').split('/')
        # /api/v4/posts
        if parts == ['api', 'v4', 'posts']:
            pid = f"post-{len(state['order']) + 1}"
            post = {
                'id': pid,
                'channel_id': payload.get('channel_id'),
                'user_id': 'shared-bot',
                'message': payload.get('message'),
                'root_id': payload.get('root_id'),
                'props': payload.get('props', {}),
                'override_username': payload.get('override_username'),
                'override_icon_url': payload.get('override_icon_url'),
                'create_at': 1000 + len(state['order']),
            }
            with state['lock']:
                state['received'].append(dict(payload))
                if not state['overrides']:
                    post.pop('override_username', None)
                    post.pop('override_icon_url', None)
                state['posts'][pid] = post
                state['order'].append(pid)
            return self._json(201, post)
        return self._json(404, {'message': 'unknown fixture path'})

    def do_GET(self):
        if not self._authed():
            return self._json(401, {'message': 'invalid credentials'})
        parts = self.path.strip('/').split('?')[0].strip('/').split('/')
        # /api/v4/channels/<id>/posts?page=&per_page=
        if len(parts) == 5 and parts[:3] == ['api', 'v4', 'channels'] and parts[4] == 'posts':
            from urllib.parse import urlparse, parse_qs
            query = parse_qs(urlparse(self.path).query)
            page = int(query.get('page', ['0'])[0])
            per_page = int(query.get('per_page', ['60'])[0])
            with state['lock']:
                channel_posts = [p for p in (state['posts'][i] for i in state['order'])
                                 if p['channel_id'] == parts[3]]
            channel_posts.sort(key=lambda p: p['create_at'], reverse=True)
            window = channel_posts[page * per_page:(page + 1) * per_page]
            return self._json(200, {
                'order': [p['id'] for p in window],
                'posts': {p['id']: p for p in window},
            })
        if parts == ['api', 'v4', 'system', 'ping']:
            return self._json(200, {'status': 'ok'})
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
