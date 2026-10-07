"""Worker identity and coverage acceptance: enrollment, verification,
revocation, renames, foreign-sender rejection and explicit catch-up state.

A stub Mattermost serves user/member reads; all proof runs against the
packaged release and TLS PostgreSQL. Worker sends stay headless through
worker-held tokens; the server maps and verifies, never proxies bodies.
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TEAM = 'fixture-team-id'
TOKEN = 'fixture-bot-token'
CAPTAIN = 'fixture-captain-token-0123456789abcdef'

state = {
    'users': {'mm-user-a': {'id': 'mm-user-a', 'username': 'worker-a'}},
    'members': {('fixture-team-id', 'mm-user-a'): True},
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

    def do_GET(self):
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            return self._json(401, {'message': 'invalid credentials'})
        parts = self.path.strip('/').split('/')
        # /api/v4/users/<id>
        if len(parts) == 4 and parts[:3] == ['api', 'v4', 'users']:
            with state['lock']:
                user = state['users'].get(parts[3])
            if user:
                return self._json(200, user)
            return self._json(404, {'message': 'user not found'})
        # /api/v4/teams/<team>/members/<user>
        if len(parts) == 6 and parts[:3] == ['api', 'v4', 'teams'] and parts[4] == 'members':
            with state['lock']:
                member = state['members'].get((parts[3], parts[5]), False)
            if member:
                return self._json(200, {'team_id': parts[3], 'user_id': parts[5]})
            return self._json(404, {'message': 'not a member'})
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
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def wait_for(query, expected, seconds=60):
    deadline = time.monotonic() + seconds
    actual = None
    while time.monotonic() < deadline:
        actual = sql(query)
        if actual == expected:
            return
        time.sleep(.2)
    raise AssertionError((query, expected, actual))


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


AGENT = {'X-Agentboard-Agent': 'conv-probe', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
WA = {'X-Agentboard-Agent': 'worker-a', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
WB = {'X-Agentboard-Agent': 'worker-b', 'X-Agentboard-Model': 'fixture', 'X-Agentboard-Harness': 'codex'}
CAPTAIN_H = {'Authorization': f'Bearer {CAPTAIN}'}

rpc(f'Application.put_env(:agentboard, :mattermost_base_url, "http://127.0.0.1:{port}")')
rpc(f'Application.put_env(:agentboard, :mattermost_team_id, "{TEAM}")')
rpc(':ok = Oban.pause_queue(queue: :mattermost_verify)')

# Enrollment is provisioning: no captain token, no identity.
status, _ = api('POST', '/api/v1/conversations/identities',
                {'agent_id': 'worker-a', 'mm_user_id': 'mm-user-a'}, AGENT)
assert status == 422, status
status, body = api('POST', '/api/v1/conversations/identities',
                   {'agent_id': 'worker-a', 'mm_user_id': 'mm-user-a',
                    'mm_username': 'worker-a', 'credential_ref': 'worker-a-token'},
                   {**AGENT, **CAPTAIN_H})
assert status == 200, (status, body)
assert sql("SELECT status FROM conversation_identities WHERE agent_id='worker-a'") == 'enrolled'
# No credential value is ever stored: the reference names protected storage.
assert sql("SELECT credential_ref FROM conversation_identities WHERE agent_id='worker-a'") == 'worker-a-token'
assert 'fixture' not in sql("SELECT row_to_json(c)::text FROM conversation_identities c")

# Membership verification runs asynchronously and records proof.
rpc(':ok = Oban.resume_queue(queue: :mattermost_verify)')
wait_for('SELECT membership_verified_at IS NOT NULL FROM conversation_identities WHERE agent_id=\'worker-a\'', 't')
assert sql("SELECT last_error FROM conversation_identities WHERE agent_id='worker-a'") == ''

# One Mattermost user maps to exactly one worker.
status, _ = api('POST', '/api/v1/conversations/identities',
                {'agent_id': 'worker-b', 'mm_user_id': 'mm-user-a'}, {**AGENT, **CAPTAIN_H})
assert status == 409, status

# A renamed handle keeps the stable user ID; attribution follows the ID.
with state['lock']:
    state['users']['mm-user-a'] = {'id': 'mm-user-a', 'username': 'worker-a-renamed'}
out = rpc('{:ok, result} = Agentboard.Mattermost.Conversations.verify("worker-a"); IO.inspect(result)')
assert "'renamed' => true" in out or '"renamed"=>true' in out.replace(' ', ''), out
assert sql("SELECT mm_username FROM conversation_identities WHERE agent_id='worker-a'") == 'worker-a-renamed'

# Membership loss suspends; it never deletes the mapping.
with state['lock']:
    del state['members'][(TEAM, 'mm-user-a')]
rpc('{:ok, _} = Agentboard.Mattermost.Conversations.verify("worker-a")')
wait_for("SELECT status FROM conversation_identities WHERE agent_id='worker-a'", 'suspended')
assert sql("SELECT last_error FROM conversation_identities WHERE agent_id='worker-a'") == 'team_membership_lost'

# A suspended worker authorizes nothing, including its own coverage.
status, _ = api('POST', '/api/v1/conversations/coverage/worker-a/fixture-channel',
                {'last_post_id': 'post-1', 'last_version': 1}, WA)
assert status == 503, status

# Unknown workers are rejected before any write.
status, _ = api('POST', '/api/v1/conversations/coverage/ghost/fixture-channel',
                {'last_post_id': 'post-1', 'last_version': 1},
                {'X-Agentboard-Agent': 'ghost', 'X-Agentboard-Model': 'f', 'X-Agentboard-Harness': 'c'})
assert status == 503, status

# Restore membership, re-enroll a second worker, and prove peer parity:
# two mapped workers, distinct stable IDs, explicit coverage each.
with state['lock']:
    state['members'][(TEAM, 'mm-user-a')] = True
    state['users']['mm-user-b'] = {'id': 'mm-user-b', 'username': 'worker-b'}
    state['members'][(TEAM, 'mm-user-b')] = True
rpc('{:ok, _} = Agentboard.Mattermost.Conversations.verify("worker-a")')
status, _ = api('POST', '/api/v1/conversations/identities',
                {'agent_id': 'worker-b', 'mm_user_id': 'mm-user-b',
                 'mm_username': 'worker-b', 'credential_ref': 'worker-b-token'},
                {**AGENT, **CAPTAIN_H})
assert status == 200, status
wait_for("SELECT membership_verified_at IS NOT NULL FROM conversation_identities WHERE agent_id='worker-b'", 't')

# Foreign senders cannot report another worker's coverage.
status, _ = api('POST', '/api/v1/conversations/coverage/worker-b/fixture-channel',
                {'last_post_id': 'post-9', 'last_version': 1}, AGENT)
assert status == 422, status

# Exact post/version receipts with explicit incomplete state.
status, body = api('POST', '/api/v1/conversations/coverage/worker-a/fixture-channel',
                   {'last_post_id': 'post-10', 'last_version': 3,
                    'caught_up': False, 'incomplete_reason': 'page_race_gap'}, WA)
assert status == 200, (status, body)
assert body['caught_up'] is False and body['incomplete_reason'] == 'page_race_gap', body
status, body = api('GET', '/api/v1/conversations/coverage/worker-a/fixture-channel', None, WA)
assert status == 200 and body['last_post_id'] == 'post-10' and body['last_version'] == 3, (status, body)
# Equal-time edit at a higher version advances without inventing posts.
status, body = api('POST', '/api/v1/conversations/coverage/worker-a/fixture-channel',
                   {'last_post_id': 'post-10', 'last_version': 4, 'caught_up': True}, WA)
assert status == 200 and body['caught_up'] is True and body['incomplete_reason'] is None, (status, body)

# Explicit revocation ends attribution; history remains readable.
status, _ = api('POST', '/api/v1/conversations/identities/worker-b/revoke',
                {'reason': 'role_changed'}, {**AGENT, **CAPTAIN_H})
assert status == 200, status
wait_for("SELECT status FROM conversation_identities WHERE agent_id='worker-b'", 'revoked')
status, _ = api('POST', '/api/v1/conversations/coverage/worker-b/fixture-channel',
                {'last_post_id': 'post-11', 'last_version': 1}, WB)
assert status == 503, status
status, body = api('GET', '/api/v1/conversations/coverage/worker-a/fixture-channel', None, WA)
assert status == 200, (status, body)
print('Worker identities: provisioning gate, verification, rename, suspension, revocation, attribution and explicit coverage passed')
