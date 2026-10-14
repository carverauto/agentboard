"""Mattermost `/board` slash command through the packaged release and PostgreSQL.

Posts urlencoded forms exactly as Mattermost sends slash commands and checks:
unavailable while intake is off, unconfigured and bad tokens, unmapped,
retired and reserved filers refused with nothing created, help and syntax
errors, filing with and without an issue under the mapped filer identity,
trigger_id replay, status visibility, scope refusal and the thread-free
response shape. Every identity, token and repository is invented.
"""
import hashlib
import json
import os
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-slash-captain-capability-0123456789'
TOKEN = 'fixture-slash-token-abcdefghijklmnop'
BOARD = 'https://board.example.test'
FILER_USER = 'a' * 26
RETIRED_USER = 'b' * 26
CAPTAIN_USER = 'c' * 26
UNMAPPED_USER = 'd' * 26


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1',
                                    '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)


def counts():
    return sql("SELECT (SELECT count(*) FROM tasks)||','||(SELECT count(*) FROM intake_requests)||','||"
               "(SELECT count(*) FROM intake_items)")


def register(agent, harness):
    headers = {'X-Agentboard-Agent': agent, 'X-Agentboard-Model': 'fixture-model',
               'X-Agentboard-Harness': harness, 'Content-Type': 'application/json'}
    request = urllib.request.Request(URL + '/api/v1/agents/register', headers=headers,
                                     data=json.dumps({'name': agent, 'kind': 'human'}).encode())
    urllib.request.urlopen(request, timeout=30).read()


def slash(text, *, user=FILER_USER, token=TOKEN, trigger='trigger-1', status=200):
    form = {'channel_id': 'channel0000000000000000000', 'team_id': 'team00000000000000000000000',
            'user_id': user, 'user_name': 'fixture-user', 'command': '/board', 'text': text}
    if token is not None:
        form['token'] = token
    if trigger is not None:
        form['trigger_id'] = trigger
    body = urllib.parse.urlencode(form).encode()
    request = urllib.request.Request(URL + '/api/v1/hooks/mattermost/board', data=body,
                                     headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    payload = json.load(response)
    assert TOKEN not in json.dumps(payload) and CAPTAIN not in json.dumps(payload), 'credential leaked'
    assert response.status == status, (text, response.status, status, payload)
    assert response.headers['cache-control'] == 'no-store'
    return payload


def ephemeral(text, **kwargs):
    reply = slash(text, **kwargs)
    assert reply['response_type'] == 'ephemeral', reply
    return reply['text']


def captain_file(key, item):
    request = urllib.request.Request(URL + '/api/v1/intake', data=json.dumps(
        {'request_key': key, 'items': [item]}).encode(), headers={
        'Authorization': 'Bearer ' + CAPTAIN, 'Content-Type': 'application/json',
        'X-Agentboard-Agent': 'captain', 'X-Agentboard-Model': 'human', 'X-Agentboard-Harness': 'captain'})
    return json.load(urllib.request.urlopen(request, timeout=30))['intake']


# Off by default: unavailable before any token check, nothing created.
before = counts()
assert slash('help', status=404)['error']['code'] == 'intake_disabled'
assert counts() == before

rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard, :intake_enabled, true)')
rpc('Application.put_env(:agentboard, :intake_repositories, ["acme/widgets"])')
rpc('Application.put_env(:agentboard, :public_board_url, ' + json.dumps(BOARD + '/') + ')')
rpc('Application.put_env(:agentboard, :rate_limits, Keyword.put(Application.fetch_env!(:agentboard, :rate_limits), :intake, 1000))')

# No configured token: the command is unavailable.
assert slash('help', status=503)['error']['code'] == 'unconfigured'

# The token file is re-read per request; wrong and missing tokens fail closed.
token_file = tempfile.NamedTemporaryFile('w', delete=False, suffix='.token')
token_file.write(TOKEN + '\n')
token_file.close()
rpc('Application.put_env(:agentboard, :mattermost_slash_token_file, ' + json.dumps(token_file.name) + ')')
assert slash('help', token='wrong-token-wrong-token-wrong-to', status=401)['error']['code'] == 'unauthorized'
assert slash('help', token=None, status=401)['error']['code'] == 'unauthorized'

register('slash-filer', 'mattermost')
register('slash-retired', 'mattermost')
sql("UPDATE agents SET retired_at=now(), retired_by='captain' WHERE id='slash-retired'")
rpc('Application.put_env(:agentboard, :mattermost_slash_filers, %{' + ', '.join(
    f'"{user}" => "{agent}"' for user, agent in [
        (FILER_USER, 'slash-filer'), (RETIRED_USER, 'slash-retired'), (CAPTAIN_USER, 'captain')]) + '})')

# Refusals create nothing.
before = counts()
assert 'not on the board' in ephemeral('file acme/widgets "Nope"', user=UNMAPPED_USER)
assert 'not a live, ordinary agent' in ephemeral('file acme/widgets "Nope"', user=RETIRED_USER)
assert 'not a live, ordinary agent' in ephemeral('file acme/widgets "Nope"', user=CAPTAIN_USER)
assert 'Usage' in ephemeral('help')
assert 'Usage' in ephemeral('')
assert 'Unbalanced quotes' in ephemeral('file acme/widgets "Never closed')
assert 'Unrecognized command' in ephemeral('file acme/widgets')
assert 'Unrecognized file options' in ephemeral('file acme/widgets "Title" --priority high')
assert 'Unrecognized file options' in ephemeral('file acme/widgets "Title" --bogus')
assert 'trigger ID' in ephemeral('file acme/widgets "No trigger"', trigger=None)
assert 'Intake refused (forbidden)' in ephemeral('file other/repo "Out of scope"')
assert counts() == before

# A card-only filing under the mapped filer, linked to the public board.
reply = slash('file acme/widgets “Fix the login redirect” --no-issue --priority 1 '
              '--label bug --label Auth', trigger='trigger-card')
assert reply['response_type'] == 'in_channel' and set(reply) == {'response_type', 'text'}, reply
text = reply['text']
assert text.startswith('Filed by `slash-filer` in `acme/widgets`: **Fix the login redirect**'), text
assert 'GitHub issue: not requested.' in text
key = 'mattermost-' + hashlib.sha256(b'trigger-card').hexdigest()
request_id, task_id = sql("SELECT r.id||'|'||i.task_id FROM intake_requests r JOIN intake_items i "
                          f"ON i.request_id=r.id WHERE r.request_key='{key}' AND r.filer_id='slash-filer'").split('|')
assert f'[`{task_id}`]({BOARD}/tasks/{task_id})' in text and f'`{request_id}`' in text
assert sql(f"SELECT priority||'|'||array_to_string(labels, ',')||'|'||repo FROM tasks WHERE id='{task_id}'") == \
    '1|Auth,bug|acme/widgets'
assert sql(f"SELECT issue_state FROM intake_items WHERE task_id='{task_id}'") == 'none'

# Mattermost redelivering the same invocation replays it.
before = counts()
again = slash('file acme/widgets “Fix the login redirect” --no-issue --priority 1 '
              '--label bug --label Auth', trigger='trigger-card')
assert again['text'].startswith('Already filed by `slash-filer`') and f'`{request_id}`' in again['text']
assert counts() == before

# Default filing asks for an issue; the outbox stays parked, so it is pending.
issue_reply = slash('file acme/widgets "Add retries" --body "Steps \\"quoted\\" here"', trigger='trigger-issue')
assert 'GitHub issue: pending; `/board status ' in issue_reply['text'], issue_reply
issue_task = sql("SELECT i.task_id FROM intake_items i JOIN intake_requests r ON i.request_id=r.id "
                 "WHERE r.request_key='mattermost-" + hashlib.sha256(b'trigger-issue').hexdigest() + "'")
assert sql(f"SELECT description FROM tasks WHERE id='{issue_task}'") == 'Steps "quoted" here'
assert sql(f"SELECT issue_state FROM intake_items WHERE task_id='{issue_task}'") == 'pending'

# Status shows the filer's own request; another filer's request stays hidden.
status = ephemeral('status ' + request_id)
assert status.startswith(f'Intake request `{request_id}` by `slash-filer`:') and task_id in status
assert '(open): no issue' in status, status
captain_request = captain_file('captain-slash-1', {'repository': 'acme/widgets', 'title': 'Captain card',
                                                   'issue': False})
assert 'Status refused (not_found)' in ephemeral('status ' + captain_request['id'])
# Now registered, the captain identity is still refused as a reserved filer.
assert sql("SELECT count(*) FROM agents WHERE id='captain'") == '1'
assert 'not a live, ordinary agent' in ephemeral('status ' + captain_request['id'], user=CAPTAIN_USER)
assert 'Status refused (not_found)' in ephemeral('status not-a-uuid')

# The slash token is its own boundary: the command works without any board
# credential in enforce and observe modes, and a bad token still fails.
for mode in ('enforce', 'observe'):
    rpc('Application.put_env(:agentboard, :agent_auth_mode, "' + mode + '")')
    assert 'Usage' in ephemeral('help')
    assert slash('help', token='wrong-token-wrong-token-wrong-to', status=401)['error']['code'] == 'unauthorized'
    moded = slash('file acme/widgets "Filed in ' + mode + '" --no-issue', trigger='trigger-' + mode)
    assert moded['text'].startswith('Filed by `slash-filer`'), moded
rpc('Application.put_env(:agentboard, :agent_auth_mode, "off")')

# Turning intake off makes the command unavailable again.
rpc('Application.put_env(:agentboard, :intake_enabled, false)')
before = counts()
assert slash('file acme/widgets "Off"', trigger='trigger-off', status=404)['error']['code'] == 'intake_disabled'
assert counts() == before
os.unlink(token_file.name)
print('board slash: ok')
