"""Outbound lifecycle bridge acceptance: real board activity to a thread.

A stub Mattermost speaks the three REST calls the bridge uses; every other
proof runs against the packaged release and TLS PostgreSQL. All channel IDs
are invented. The stub records real post/thread/marker IDs; bare curl posts
never substitute for the bridge path.
"""
import concurrent.futures
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHANNEL = 'fixture-board-channel'
TOKEN = 'fixture-bot-token'

state = {
    'posts': {},
    'order': [],
    'received': [],
    'modes': [],
    'hide_history': False,
    'counter': 0,
    'lock': threading.Lock(),
}


class Stub(BaseHTTPRequestHandler):
    server_version = 'FixtureMattermost/1'

    def log_message(self, *args):
        pass

    def _json(self, status, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == f'/api/v4/channels/{CHANNEL}':
            return self._json(200, {'id': CHANNEL, 'name': 'board'})
        if self.path.startswith(f'/api/v4/channels/{CHANNEL}/posts'):
            with state['lock']:
                if state['hide_history']:
                    posts, order = {}, []
                else:
                    posts = {pid: dict(post) for pid, post in state['posts'].items()}
                    order = list(state['order'])
            return self._json(200, {'posts': posts, 'order': order})
        return self._json(404, {'message': 'unknown fixture path'})

    def do_POST(self):
        if self.path != '/api/v4/posts':
            return self._json(404, {'message': 'unknown fixture path'})
        length = int(self.headers.get('Content-Length', 0))
        payload = json.loads(self.rfile.read(length) or b'{}')
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            return self._json(401, {'message': 'invalid credentials'})
        with state['lock']:
            mode = state['modes'].pop(0) if state['modes'] else 'ok'
        if mode == 'hang':
            # Stored remotely, response never arrives: the client must time
            # out and reconcile instead of blindly posting again.
            with state['lock']:
                state['counter'] += 1
                pid = f'post-{state["counter"]}'
                state['posts'][pid] = {
                    'id': pid, 'channel_id': payload.get('channel_id'),
                    'root_id': payload.get('root_id', ''),
                    'message': payload.get('message'),
                    'props': payload.get('props', {}),
                }
                state['order'].append(pid)
                state['received'].append(dict(payload))
            time.sleep(30)
            return
        if mode == 'http429':
            return self._json(429, {'message': 'slow down'}, {'Retry-After': '2'})
        if mode == 'http401':
            return self._json(401, {'message': 'invalid credentials'})
        with state['lock']:
            state['counter'] += 1
            pid = f'post-{state["counter"]}'
            state['posts'][pid] = {
                'id': pid, 'channel_id': payload.get('channel_id'),
                'root_id': payload.get('root_id', ''),
                'message': payload.get('message'),
                'props': payload.get('props', {}),
            }
            state['order'].append(pid)
            state['received'].append(dict(payload))
            post = dict(state['posts'][pid])
        return self._json(201, post)


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


def wait_for(query, expected, seconds=60):
    deadline = time.monotonic() + seconds
    actual = None
    while time.monotonic() < deadline:
        actual = sql(query)
        if actual == expected:
            return
        time.sleep(.2)
    jobs = sql("SELECT json_agg(json_build_object('worker',worker,'state',state,'args',args)) FROM oban_jobs WHERE queue LIKE 'mattermost%'")
    raise AssertionError((query, expected, actual, jobs))


def route_claimed(expected):
    out = rpc('input = Ash.ActionInput.for_action(Agentboard.Mattermost.Router, :route_pending, %{}, actor: %{role: :system}); IO.inspect(Ash.run_action(input))')
    assert f'claimed: {expected}' in out, (expected, out)


cli_env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
cli_env.update(AGENT_ID='bridge-owner', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args, success=True):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=cli_env,
                            capture_output=True, text=True, timeout=25)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)
    assert result.returncode != 0, (args, result.stdout)


router = 'Agentboard.Mattermost.RoutePending'
sender = 'Agentboard.Mattermost.SendWorker'

# The stub address is known only after boot, so push it (and the board link
# base) through runtime config like an operator would at enablement.
rpc(f'Application.put_env(:agentboard, :mattermost_base_url, "http://127.0.0.1:{port}")')
rpc(f'Application.put_env(:agentboard, :public_board_url, "{os.environ["AGENTBOARD_URL"]}")')

# Default-off fence: with the bridge disabled, board writes commit and capture
# nothing, so enabling later cannot dump history into chat.
rpc(':ok = Oban.pause_queue(queue: :mattermost_router); :ok = Oban.pause_queue(queue: :mattermost_sender)')
rpc('Application.put_env(:agentboard, :mattermost_bridge_enabled, false)')
ab('agent', 'register')
ab('task', 'create', '--id', 'quiet-task', '--title', 'Silent while disabled')
assert sql("SELECT count(*) FROM mattermost_outbox") == '0'
assert sql("SELECT count(*) FROM mattermost_task_threads") == '0'

# A queue insert failure rolls the board mutation back with it.
rpc('Application.put_env(:agentboard, :mattermost_bridge_enabled, true)')
sql("CREATE FUNCTION reject_bridge_job_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.worker='%s' THEN RAISE EXCEPTION 'Synthetic bridge scheduling failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_bridge_job_fixture BEFORE INSERT ON oban_jobs FOR EACH ROW EXECUTE FUNCTION reject_bridge_job_fixture()" % sender)
ab('task', 'create', '--id', 'rollback-task', '--title', 'Queue failure', success=False)
assert sql("SELECT count(*) FROM tasks WHERE id='rollback-task'") == '0'
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='rollback-task'") == '0'
sql('DROP TRIGGER reject_bridge_job_fixture ON oban_jobs; DROP FUNCTION reject_bridge_job_fixture()')

ab('task', 'create', '--id', 'bridge-task', '--title', 'Lifecycle to thread')
wait_for("SELECT state FROM mattermost_outbox WHERE task_id='bridge-task'", 'claimed')
assert sql("SELECT state FROM mattermost_task_threads WHERE task_id='bridge-task'") == 'pending'
# Capture is idempotent per task event: the outbox key survives replays.
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='bridge-task'") == '1'

# A lost send notification with a stale claim is recovered by state, and two
# routers racing claim one page once; one root post follows.
sql("DELETE FROM oban_jobs WHERE worker='%s'" % sender)
sql("UPDATE mattermost_outbox SET updated_at=clock_timestamp()-interval '10 minutes' WHERE task_id='bridge-task'")
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    outcomes = list(pool.map(lambda _: rpc(
        'input = Ash.ActionInput.for_action(Agentboard.Mattermost.Router, :route_pending, %{}, actor: %{role: :system}); IO.inspect(Ash.run_action(input))'), range(2)))
assert sum('claimed: 1' in outcome for outcome in outcomes) == 1, outcomes
assert sum('claimed: 0' in outcome for outcome in outcomes) == 1, outcomes
rpc(':ok = Oban.resume_queue(queue: :mattermost_sender)')
wait_for("SELECT state FROM mattermost_outbox WHERE task_id='bridge-task'", 'sent')
wait_for("SELECT state FROM mattermost_task_threads WHERE task_id='bridge-task'", 'rooted')
root = sql("SELECT root_post_id FROM mattermost_task_threads WHERE task_id='bridge-task'")
remote = sql("SELECT remote_post_id||','||remote_root_id FROM mattermost_outbox WHERE task_id='bridge-task'")
assert remote == f'{root},{root}', (remote, root)
with state['lock']:
    assert len(state['received']) == 1, state['received']
    first = state['received'][0]
assert first['channel_id'] == CHANNEL, first
assert 'bridge-task' in first['message'] and 'bridge-owner' in first['message'], first
assert 'board: ' in first['message'] and '/tasks/bridge-task' in first['message'], first

# A lower-ID late commit stays discoverable by pending state, not cursors.
sql("INSERT INTO mattermost_outbox(id,source,source_key,task_id,event_id,destination,routing_revision,state,next_eligible_at,event_marker,payload,created_at,updated_at) VALUES (gen_random_uuid(),'board_task_event','task_event:1','bridge-task',1,'mattermost:board_thread:bridge-task',1,'pending',clock_timestamp()-interval '1 minute','agentboard:bridge-task:1:late','{\"action\":\"update\",\"actor\":\"bridge-owner\",\"model\":\"fixture-model\",\"harness\":\"codex\"}',clock_timestamp(),clock_timestamp())")
route_claimed(1)
wait_for("SELECT state FROM mattermost_outbox WHERE source_key='task_event:1'", 'sent')
with state['lock']:
    assert len(state['received']) == 2, state['received']
    reply = state['received'][1]
assert reply.get('root_id') == root, reply

# Accepted-post/lost-response: the hung post is adopted, never duplicated.
with state['lock']:
    state['modes'].append('hang')
    before = len(state['received'])
ab('task', 'claim', 'bridge-task')
claim_key = sql("SELECT source_key FROM mattermost_outbox WHERE task_id='bridge-task' ORDER BY created_at DESC LIMIT 1")
wait_for(f"SELECT state FROM mattermost_outbox WHERE source_key='{claim_key}'", 'sent', 90)
with state['lock']:
    assert len(state['received']) == before + 1, state['received']

# Unresolvable history parks visible uncertainty instead of replaying.
rpc(':ok = Oban.pause_queue(queue: :mattermost_sender)')
with state['lock']:
    state['modes'].append('hang')
    state['hide_history'] = True
ab('task', 'update', 'bridge-task', '--status', 'blocked', '--body', 'waiting on fixture')
uncertain_key = sql("SELECT source_key FROM mattermost_outbox WHERE task_id='bridge-task' ORDER BY created_at DESC LIMIT 1")
sql(f"UPDATE mattermost_outbox SET attempts=8 WHERE source_key='{uncertain_key}'")
rpc(':ok = Oban.resume_queue(queue: :mattermost_sender)')
wait_for(f"SELECT state FROM mattermost_outbox WHERE source_key='{uncertain_key}'", 'uncertain', 90)
assert sql(f"SELECT uncertain_reason FROM mattermost_outbox WHERE source_key='{uncertain_key}'") == 'accepted_post_unconfirmed'
assert sql("SELECT state FROM mattermost_task_threads WHERE task_id='bridge-task'") == 'uncertain'
with state['lock']:
    state['hide_history'] = False

# Duplicate roots are flagged, not hidden: a corrupted mapping keeps the
# first root and reports the collision.
sql("UPDATE mattermost_task_threads SET root_post_id='foreign-root',state='pending',uncertain_reason=NULL WHERE task_id='bridge-task'")
with state['lock']:
    state['modes'].append('hang')
ab('task', 'update', 'bridge-task', '--status', 'review')
wait_for("SELECT count(*) FROM mattermost_outbox WHERE task_id='bridge-task' AND state='sent' AND remote_post_id LIKE 'post-%'", '4', 90)
assert sql("SELECT uncertain_reason FROM mattermost_task_threads WHERE task_id='bridge-task'") == 'duplicate_root'

# Auth failure parks without retry storms; 429 honors Retry-After then sends.
with state['lock']:
    state['modes'].append('http401')
ab('task', 'create', '--id', 'auth-task', '--title', 'Bad token')
wait_for("SELECT state FROM mattermost_outbox WHERE task_id='auth-task'", 'failed', 90)
assert 'unauthorized' in sql("SELECT last_error FROM mattermost_outbox WHERE task_id='auth-task'")
with state['lock']:
    state['modes'].append('http429')
ab('task', 'create', '--id', 'retry-task', '--title', 'Slow down')
wait_for("SELECT last_error FROM mattermost_outbox WHERE task_id='retry-task'", 'rate_limited', 90)
time.sleep(5)
route_claimed(1)
wait_for("SELECT state FROM mattermost_outbox WHERE task_id='retry-task'", 'sent', 90)

# Bridge outage never blocks board writes.
server.shutdown()
ab('task', 'create', '--id', 'offline-task', '--title', 'Board survives outage')
wait_for("SELECT last_error FROM mattermost_outbox WHERE task_id='offline-task'", 'timeout', 90)
wait_for("SELECT state FROM mattermost_outbox WHERE task_id='offline-task'", 'pending', 90)
print('Outbound bridge: cutoff, rollback, single root, late commit, lost-response adoption, uncertainty, duplicate roots, auth, 429 and outage isolation passed')
