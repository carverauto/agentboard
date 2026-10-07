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
import urllib.request
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


def ab(*args, success=True, actor="bridge-owner"):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=dict(cli_env, AGENT_ID=actor),
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

# Default board mode retains message/read contracts without message intents,
# independently of an enabled lifecycle bridge.
def mode_status():
    with urllib.request.urlopen(os.environ['AGENTBOARD_URL'] + '/api/v1/meta') as response:
        return json.load(response)['message_transport']

assert mode_status()['requested'] == 'board'
assert mode_status()['effective'] == 'board'
ab('agent', 'register', actor='bridge-peer')
board_dm = ab('msg', 'send', '--to', 'bridge-peer', '--body', 'Board-only private fixture')['message']
assert sql("SELECT count(*) FROM mattermost_outbox WHERE source='board_message'") == '0'
assert board_dm['id'] in [m['id'] for m in ab('msg', 'list', '--unread', actor='bridge-peer')['messages']]
ab('msg', 'read', str(board_dm['id']), success=False)
read = ab('msg', 'read', str(board_dm['id']), actor='bridge-peer')['message']
assert read['read_at'] and read['read_model'] == 'fixture-model'

# Selecting dual is independent of the jobs fence. Even with jobs disabled,
# every send has a durable intent and handoff remains explicitly assigned.
rpc('Application.put_env(:agentboard, :message_mode, "dual"); Application.put_env(:agentboard, :mattermost_bridge_enabled, false); :ok = Oban.pause_queue(queue: :mattermost_sender)')
assert mode_status()['effective'] == 'dual'
ab('task', 'create', '--id', 'dual-thread', '--title', 'Dual comments')
ab('task', 'create', '--id', 'dual-handoff', '--title', 'Dual ownership')
ab('task', 'claim', 'dual-handoff')
public = ab('msg', 'send', '--task', 'dual-thread', '--body', 'Public dual comment')['message']
private = ab('msg', 'send', '--to', 'bridge-peer', '--body', 'Never echo this private body')['message']
scoped = ab('msg', 'send', '--to', 'bridge-peer', '--task', 'dual-thread', '--body', 'Private task context')['message']
for message in (public, private, scoped):
    assert sql(f"SELECT count(*) FROM mattermost_outbox WHERE source='board_message' AND source_key='message:{message['id']}' AND state='pending'") == '1'
for message in (private, scoped):
    assert sql(f"SELECT destination||','||last_error FROM mattermost_outbox WHERE source_key='message:{message['id']}'") == 'mattermost:agent_inbox:bridge-peer,recipient_route_unavailable'
assert sql("SELECT count(*) FROM mattermost_task_threads WHERE task_id='dual-thread'") == '1'

handoff = ab('task', 'handoff', 'dual-handoff', '--to', 'bridge-peer', '--body', 'One handoff notice')
assert handoff['task']['status'] == 'assigned' and handoff['task']['claim_expires_at'] is None
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='dual-handoff' AND payload->>'action'='handoff' AND state='pending'") == '1'
assert sql(f"SELECT count(*) FROM mattermost_outbox WHERE source_key='message:{handoff['message_id']}'") == '0'
assert handoff['message_id'] in [m['id'] for m in ab('msg', 'list', '--unread', actor='bridge-peer')['messages']]
assert sql("SELECT count(*) FROM oban_jobs WHERE worker='%s' AND args->>'id' IN (SELECT id::text FROM mattermost_outbox WHERE task_id IN ('dual-thread','dual-handoff'))" % sender) == '0'
# A disabled queued action cannot send; recipient still claims explicitly.
route_claimed_out = rpc('input = Ash.ActionInput.for_action(Agentboard.Mattermost.Router, :route_pending, %{}, actor: %{role: :system}); IO.inspect(Ash.run_action(input))')
assert 'Snooze' in route_claimed_out, route_claimed_out
disabled_id = sql(f"SELECT id FROM mattermost_outbox WHERE source_key='message:{public['id']}'")
disabled_send = rpc(f'input = Ash.ActionInput.for_action(Agentboard.Mattermost.Router, :send_intent, %{{id: "{disabled_id}"}}, actor: %{{role: :system}}); IO.inspect(Ash.run_action(input))')
assert 'Snooze' in disabled_send, disabled_send
claimed = ab('task', 'claim', 'dual-handoff', actor='bridge-peer')['task']
assert claimed['status'] == 'in_progress' and claimed['claim_expires_at']

# Outbox insertion failure rolls back a send and every part of a handoff.
ab('task', 'create', '--id', 'dual-rollback', '--title', 'No partial assignment')
ab('task', 'claim', 'dual-rollback')
before_task = ab('task', 'show', 'dual-rollback')['task']
before_events = sql("SELECT count(*) FROM task_events WHERE task_id='dual-rollback'")
before_messages = sql("SELECT count(*) FROM messages")
sql("CREATE FUNCTION reject_dual_outbox_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Synthetic dual capture failure'; END $$; CREATE TRIGGER reject_dual_outbox_fixture BEFORE INSERT ON mattermost_outbox FOR EACH ROW EXECUTE FUNCTION reject_dual_outbox_fixture()")
ab('msg', 'send', '--to', 'bridge-peer', '--body', 'Rollback direct message', success=False)
ab('task', 'handoff', 'dual-rollback', '--to', 'bridge-peer', '--body', 'Rollback ownership', success=False)
assert ab('task', 'show', 'dual-rollback')['task'] == before_task
assert sql("SELECT count(*) FROM task_events WHERE task_id='dual-rollback'") == before_events
assert sql("SELECT count(*) FROM messages") == before_messages
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='dual-rollback'") == '0'
sql('DROP TRIGGER reject_dual_outbox_fixture ON mattermost_outbox; DROP FUNCTION reject_dual_outbox_fixture()')
# Failure in the internal board message also rolls back the already-captured
# event notice; commit order must not produce a partial notification.
sql("CREATE FUNCTION reject_dual_message_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.body='Rollback internal message' THEN RAISE EXCEPTION 'Synthetic internal message failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_dual_message_fixture BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION reject_dual_message_fixture()")
ab('task', 'handoff', 'dual-rollback', '--to', 'bridge-peer', '--body', 'Rollback internal message', success=False)
assert ab('task', 'show', 'dual-rollback')['task'] == before_task
assert sql("SELECT count(*) FROM task_events WHERE task_id='dual-rollback'") == before_events
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='dual-rollback'") == '0'
sql('DROP TRIGGER reject_dual_message_fixture ON messages; DROP FUNCTION reject_dual_message_fixture()')

# Re-enabling dispatch recovers pending public routes. Scoped/private intents
# remain pending, without fallback to the service bot's public channel.
with state['lock']:
    posts_before_dual = len(state['received'])
rpc('Application.put_env(:agentboard, :mattermost_bridge_enabled, true); :ok = Oban.resume_queue(queue: :mattermost_sender)')
route_claimed(2)
wait_for("SELECT count(*) FROM mattermost_outbox WHERE task_id IN ('dual-thread','dual-handoff') AND state='sent'", '2')
with state['lock']:
    dual_posts = list(state['received'][posts_before_dual:])
assert len(dual_posts) == 2, dual_posts
assert any('Public dual comment' in post['message'] for post in dual_posts), dual_posts
assert any('handoff' in post['message'] and 'bridge-peer' in post['message'] and 'explicit claim required' in post['message'] for post in dual_posts), dual_posts
assert all('Never echo' not in post['message'] and 'Private task context' not in post['message'] for post in dual_posts)
route_claimed(0)
assert sql("SELECT count(*) FROM mattermost_outbox WHERE destination='mattermost:agent_inbox:bridge-peer' AND state='pending'") == '2'
# Acknowledgement is still explicit and does not generate a chat echo.
private_read = ab('msg', 'read', str(private['id']), actor='bridge-peer')['message']
assert private_read['read_at']
assert ab('msg', 'read', str(private['id']), actor='bridge-peer')['message'] == private_read

# A working service bot is insufficient for sole-Mattermost activation. The
# actual operator configuration refuses both missing capabilities and #80,
# retaining board writes and actionable legacy unread messages.
rpc('Application.put_env(:agentboard, :message_mode, "mattermost")')
status = mode_status()
assert status['activation_refused'] and not status['cutover_ready'] and status['effective'] == 'board', status
assert {'peer_identities_unavailable_5_1', 'headless_send_read_unavailable_5_2', 'inbox_catch_up_unavailable_5_3', 'coordinator_decision_path_unavailable_80', 'legacy_unread_disposition_unverified_80', 'delivery_adapter_readiness_unverified'} <= set(status['blockers']), status
fallback = ab('msg', 'send', '--to', 'bridge-peer', '--body', 'Refused cutover preserves inbox')['message']
assert fallback['id'] in [m['id'] for m in ab('msg', 'list', '--unread', actor='bridge-peer')['messages']]
assert sql(f"SELECT count(*) FROM mattermost_outbox WHERE source_key='message:{fallback['id']}'") == '0'
rpc('Application.put_env(:agentboard, :message_mode, "invalid")')
assert 'invalid_message_mode' in mode_status()['blockers']
assert mode_status()['effective'] == 'board'
rpc('Application.put_env(:agentboard, :message_mode, "dual")')

# Bridge outage never blocks board writes or a dual handoff.
server.shutdown()
rpc(':ok = Oban.pause_queue(queue: :mattermost_sender)')
ab('task', 'create', '--id', 'offline-task', '--title', 'Board survives outage')
ab('task', 'claim', 'offline-task')
offline = ab('task', 'handoff', 'offline-task', '--to', 'bridge-peer', '--body', 'Handoff while chat is offline')
assert offline['task']['status'] == 'assigned' and offline['task']['claim_expires_at'] is None
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='offline-task' AND payload->>'action'='handoff'") == '1'
assert offline['message_id'] in [m['id'] for m in ab('msg', 'list', '--unread', actor='bridge-peer')['messages']]
rpc(':ok = Oban.resume_queue(queue: :mattermost_sender)')
wait_for("SELECT count(*) FROM mattermost_outbox WHERE task_id='offline-task' AND state='pending' AND last_error='timeout'", '3', 90)
assert ab('task', 'claim', 'offline-task', actor='bridge-peer')['task']['status'] == 'in_progress'
print('Bridge and message modes: board compatibility, dual atomic send/handoff, private route fence, disabled-job recovery, explicit claim, rollback and refused cutover incl. #80 passed')
