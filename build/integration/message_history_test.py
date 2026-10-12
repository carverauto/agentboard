"""Read-only board message history across message modes (OpenSpec 7.2).

Drives the packaged release through the API, the CLI, the dashboard NDJSON
download and the LiveView wire boundary: archive pagination and escaping,
export format/escaping, unchanged board/dual/refused-cutover sends, the
mattermost-mode legacy-send migration error, individually acknowledgeable
pending legacy DMs, primary navigation/task-thread links, and rollback to
board with no history, receipt or outbox loss.

This release's readiness gate always refuses sole-Mattermost activation, so the
cutover phase loads a fixture `Agentboard.MessageMode` that reports an accepted
`mattermost` mode into the running release, then reloads the packaged module
from disk for rollback. Everything downstream of the reported mode is the
packaged production code.
"""
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

from liveview_client import RenderedView

base = os.environ['AGENTBOARD_URL']
MATTERMOST = 'https://chat.example.test'
CHAT = 'agentboard chat send'


def run(*args, actor='history-sender'):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_HARNESS='codex', AGENTBOARD_MODEL='fixture-model')
    return subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                          capture_output=True, text=True, timeout=60)


def ab(*args, actor='history-sender'):
    result = run(*args, actor=actor)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


def export(*args):
    result = run('msg', 'export', *args)
    assert result.returncode == 0, (args, result.stderr)
    assert result.stdout == '' or result.stdout.endswith('\n'), result.stdout[-80:]
    # NDJSON splits on LF only; every record is exactly one line.
    return [json.loads(line) for line in result.stdout.split('\n')[:-1]], result.stdout


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query],
                                   text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def api(path, data=None, actor='history-sender'):
    headers = {'Content-Type': 'application/json', 'X-Agentboard-Agent': actor,
               'X-Agentboard-Model': 'fixture-model', 'X-Agentboard-Harness': 'codex'}
    request = urllib.request.Request(base + '/api/v1/' + path, headers=headers,
                                     data=json.dumps(data).encode() if data is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as response:
        return response.code, json.load(response)


def meta():
    return api('meta')[1]


def download(path):
    with urllib.request.urlopen(base + path, timeout=30) as response:
        return response.status, response.headers, response.read().decode()


class Anchors(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.links = []
        self.current = None
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        if tag == 'a':
            self.current = dict(attributes, text='')
            self.links.append(self.current)

    def handle_endtag(self, tag):
        if tag == 'a':
            self.current = None

    def handle_data(self, data):
        if self.current is not None:
            self.current['text'] += data


def nav():
    with urllib.request.urlopen(base + '/', timeout=15) as response:
        document = response.read().decode()
    section = document[document.index('<nav'):document.index('</nav>')]
    return {link['text'].strip(): link for link in Anchors(section).links}


def links(document):
    return {link['id']: link for link in Anchors(document).links if link.get('id')}


def view(path):
    page = RenderedView(base, path)
    document = page.document
    page.close()
    return document


def sends_work(body):
    message = ab('msg', 'send', '--to', 'history-peer', '--task', 'history-task', '--body', body)['message']
    assert message['body'] == body
    status, response = api('messages', {'to': 'history-peer', 'body': body + ' via API'})
    assert status == 200, response
    return [message['id'], response['message']['id']]


def ordered_ids():
    return [int(value) for value in sql('SELECT id FROM messages ORDER BY created_at, id').split('\n') if value]


# --- board mode (default) -------------------------------------------------
for agent in ('history-sender', 'history-peer', 'history-other'):
    ab('agent', 'register', actor=agent)
ab('task', 'create', '--id', 'history-task', '--title', 'Message history fixture')
ab('task', 'create', '--id', 'history-bulk', '--title', 'Paged history fixture')

status = meta()
assert status['message_transport']['effective'] == 'board', status
assert status['message_history']['export_supported'] and status['message_history']['legacy_sends'] == 'open', status

hostile = 'Line one\nline two "quoted" <script>alert("x")</script> & \\ back sep para\ttab é 🙂'
pending = ab('msg', 'send', '--to', 'history-peer', '--task', 'history-task', '--body', hostile)['message']
handled = ab('msg', 'send', '--to', 'history-peer', '--body', 'Already handled before cutover')['message']
ab('msg', 'read', str(handled['id']), actor='history-peer')
for n in range(3):
    ab('msg', 'send', '--task', 'history-task', '--body', f'Thread note {n}')
for n in range(105):
    code, response = api('messages', {'task': 'history-bulk', 'body': f'Bulk {n:03d}'})
    assert code == 200, response
sends_work('Board mode send')

# Export: complete, ordered, one escaped record per line, bounded pages.
records, raw = export('--page-size', '7')
assert [r['id'] for r in records] == ordered_ids(), 'export must cover all history in order'
assert raw.count('\n') == len(records)
assert ' ' not in raw and ' ' not in raw and '\\u2028' in raw and '\\u2029' in raw
exported = next(r for r in records if r['id'] == pending['id'])
assert exported['body'] == hostile and exported['read_at'] is None and exported['recipient_id'] == 'history-peer'
assert next(r for r in records if r['id'] == handled['id'])['read_at'], 'export keeps acknowledgement state'

bulk, _ = export('--task', 'history-bulk', '--page-size', '50')
assert [r['body'] for r in bulk] == [f'Bulk {n:03d}' for n in range(105)]
code, page = api('messages/export?task=history-bulk&limit=50')
assert code == 200 and len(page['messages']) == 50 and page['next_cursor'], page
walked = page['messages']
while page['next_cursor']:
    code, page = api('messages/export?' + urllib.parse.urlencode({'task': 'history-bulk', 'limit': '50', 'cursor': page['next_cursor']}))
    assert code == 200, page
    walked += page['messages']
assert walked == bulk
assert api('messages/export?unread=true')[0] == 422, 'export accepts only to/task/cursor/limit'
assert api('messages/export?task=history-bulk&limit=1001')[0] == 422
peer_only, _ = export('--to', 'history-peer')
assert {r['recipient_id'] for r in peer_only} == {'history-peer'}
# Exporting and viewing never acknowledge.
assert ab('msg', 'show', str(pending['id']))['message']['read_at'] is None

# Dashboard NDJSON download matches the CLI export.
code, headers, body = download('/messages/export?task=history-task')
assert code == 200 and headers['Content-Type'].startswith('application/x-ndjson'), headers
assert 'attachment' in headers['Content-Disposition'] and headers['X-Content-Type-Options'] == 'nosniff'
def same_export(body, records):
    downloaded = [json.loads(line) for line in body.split('\n')[:-1]]
    assert body.endswith('\n') and len(downloaded) == len(records), (len(downloaded), len(records), body[-200:])
    for left, right in zip(downloaded, records):
        assert left == right, (left, right)


same_export(body, export('--task', 'history-task')[0])
code, headers, body = download('/messages/export')
same_export(body, export()[0])

# Archive view: escaped bodies, export link, bounded pages with a next link.
assert nav()['Messages']['href'] == '/messages' and 'Message history' not in nav()
document = view('/messages?task=history-task')
assert '&lt;script&gt;alert(' in document and '<script>alert(' not in document
assert links(document)['message-export']['href'] == '/messages/export?task=history-task'
assert 'message-history-migrated' not in document
first = view('/messages?task=history-bulk')
assert first.count('class="message"') == 100 and 'Bulk 099' in first and 'Bulk 100' not in first
next_link = next(link for link in Anchors(first).links if link['text'] == 'Next messages')
second = view(next_link['href'])
assert second.count('class="message"') == 5 and 'Bulk 104' in second and 'Bulk 000' not in second
assert not any(link['text'] == 'Next messages' for link in Anchors(second).links)
task_view = view('/tasks/history-task')
assert links(task_view)['task-thread-export']['href'] == '/messages/export?task=history-task'
assert 'task-thread-migrated' not in task_view and '&lt;script&gt;alert(' in task_view

# --- dual mode and refused cutover keep legacy sends unchanged ------------
rpc('Application.put_env(:agentboard, :message_mode, "dual")')
assert meta()['message_transport']['effective'] == 'dual'
assert meta()['message_history']['legacy_sends'] == 'open'
sends_work('Dual mode send')
assert nav()['Messages']['href'] == '/messages'
rpc('Application.put_env(:agentboard, :message_mode, "mattermost")')
status = meta()
assert status['message_transport']['activation_refused'] and status['message_transport']['effective'] == 'board', status
assert status['message_history']['legacy_sends'] == 'open'
sends_work('Refused cutover send')
assert nav()['Messages']['href'] == '/messages' and 'Message history' not in nav()

# --- accepted mattermost mode (fixture readiness) --------------------------
rpc(f'Application.put_env(:agentboard, :mattermost_base_url, "{MATTERMOST}/")')
sql("INSERT INTO mattermost_task_threads(task_id, channel_id, root_post_id, state, routing_revision, created_at, updated_at) "
    "VALUES ('history-task', 'fixture-channel', 'rootpost123', 'rooted', 1, now(), now())")
rpc('''Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_string(~S"""
defmodule Agentboard.MessageMode do
  def status, do: %{requested: "mattermost", effective: "mattermost", activation_refused: false, cutover_ready: true, blockers: []}
  def dual?, do: false
  def report_activation, do: :ok
end
""")
:ok''')
history_before, _ = export()
messages_before = sql('SELECT count(*) FROM messages')
outbox_before = sql("SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') FROM mattermost_outbox")
assert outbox_before, 'dual mode captured notice intents that rollback must retain'
status = meta()
assert status['message_transport']['effective'] == 'mattermost' and status['message_history']['legacy_sends'] == 'migrated', status

for args in (('--to', 'history-peer', '--body', 'Refused DM'), ('--task', 'history-task', '--body', 'Refused thread note')):
    refused = run('msg', 'send', *args)
    assert refused.returncode == 4 and refused.stdout == '', (refused.returncode, refused.stdout, refused.stderr)
    error = json.loads(refused.stderr)['error']
    assert error['code'] == 'message_transport_migrated' and CHAT in error['message'], error
code, response = api('messages', {'to': 'history-peer', 'body': 'Refused API send'})
assert code == 409, response
assert response['error']['code'] == 'message_transport_migrated', response
assert response['error']['migration']['command'] == CHAT and response['error']['migration']['acknowledge_command'], response
assert sql('SELECT count(*) FROM messages') == messages_before, 'a refused send writes nothing'

# Pending legacy DMs stay individually readable and acknowledgeable.
assert pending['id'] in [m['id'] for m in ab('msg', 'list', '--unread', actor='history-peer')['messages']]
assert ab('msg', 'show', str(pending['id']), actor='history-peer')['message']['read_at'] is None
acknowledged = ab('msg', 'read', str(pending['id']), actor='history-peer')['message']
assert acknowledged['read_at'] and acknowledged['body'] == hostile
assert ab('msg', 'read', str(pending['id']), actor='history-peer')['message'] == acknowledged
assert run('msg', 'read', str(handled['id']), actor='history-other').returncode == 4, 'only the recipient acknowledges'
assert pending['id'] not in [m['id'] for m in ab('msg', 'list', '--unread', actor='history-peer')['messages']]
assert [r['id'] for r in export()[0]] == [r['id'] for r in history_before], 'history stays exportable'

# Primary navigation opens Mattermost; board history stays one click away.
links_now = nav()
assert links_now['Messages']['href'] == MATTERMOST and links_now['Messages']['target'] == '_blank', links_now['Messages']
assert links_now['Message history']['href'] == '/messages'
document = view('/messages')
assert 'id="message-history-migrated"' in document and f'href="{MATTERMOST}"' in document
assert 'href="/messages/export"' in document
task_view = view('/tasks/history-task')
assert links(task_view)['task-thread-mattermost']['href'] == MATTERMOST + '/_redirect/pl/rootpost123'
assert 'id="task-thread-migrated"' in task_view and '&lt;script&gt;alert(' in task_view
unmapped = view('/tasks/history-bulk')
assert 'No Mattermost thread is mapped yet' in unmapped and links(unmapped)['task-thread-mattermost']['href'] == MATTERMOST
assert view('/messages?task=history-bulk').count('class="message"') == 100

# --- rollback to board ------------------------------------------------------
rpc(':code.purge(Agentboard.MessageMode); {:module, Agentboard.MessageMode} = :code.load_file(Agentboard.MessageMode); :ok')
rpc('Application.put_env(:agentboard, :message_mode, "board")')
status = meta()
assert status['message_transport']['effective'] == 'board' and status['message_history']['legacy_sends'] == 'open', status
assert nav()['Messages']['href'] == '/messages' and 'Message history' not in nav()
assert 'task-thread-migrated' not in view('/tasks/history-task')
resumed = sends_work('Board resumes after rollback')
after, _ = export()
assert [r['id'] for r in after] == [r['id'] for r in history_before] + resumed
for before_record, after_record in zip(history_before, after):
    if before_record['id'] == pending['id']:
        assert all(after_record[key] == value for key, value in acknowledged.items()), (after_record, acknowledged)
    else:
        assert after_record == before_record, (before_record, after_record)
assert sql("SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') FROM mattermost_outbox") == outbox_before, \
    'rollback neither deletes nor replays retained intents'
assert sql("SELECT root_post_id FROM mattermost_task_threads WHERE task_id='history-task'") == 'rootpost123'
print('Board history stays readable, exportable and acknowledgeable across board, dual, mattermost and rollback')
