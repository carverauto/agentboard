"""Packaged collector -> board inbox/worker handoff contract, invented fixtures only.

This owns zero-worker routing/deduplication; ci_accountability owns episode
creation and worker receipt behavior. No implementation/source assertions.
"""
import base64
import json
import os
import subprocess
import urllib.request

URL = os.environ['AGENTBOARD_URL']

def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
        'ON_ERROR_STOP=1', '-c', query], text=True).strip()

def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
        capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout

def api(path, body=None, agent='inbox-owner', captain=False, token=None):
    headers = {'x-agentboard-agent': agent, 'x-agentboard-model': 'fixture-model',
        'x-agentboard-harness': 'codex', 'x-agentboard-worker-protocol': '1'}
    if captain:
        headers['x-agentboard-captain-token'] = 'fixture-captain-capability-32-characters'
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = 'application/json'
    with urllib.request.urlopen(urllib.request.Request(URL + '/api/v1' + path,
            headers=headers, data=None if body is None else json.dumps(body).encode()),
            timeout=15) as response:
        return json.load(response)

def source(number, owner='inbox-owner'):
    api('/tasks', {'id': 'inbox-source-' + str(number), 'title': 'Inbox fixture',
        'repo': 'fixture/repo', 'pr_url': 'https://github.com/fixture/repo/pull/' + str(number)}, agent=owner)
    return sql("SELECT id FROM delivery_pull_requests WHERE number='" + str(number) + "'")

def observe(pr, failing=True, dirty=False, lifecycle='open'):
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + pr + "'")
    r = json.loads(rpc('{:ok,[r]}=Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(pr) + '); IO.puts("R:"<>Jason.encode!(r))').split('R:', 1)[1])
    payload = dict(policy='unknown', coverage='complete_head', tested_ref='head',
        attempts=[dict(identity='check:1:required', latest=True, status='completed',
            conclusion='failure' if failing else 'success', source_url='https://github.com/fixture/repo/actions/runs/1')],
        mergeable=not dirty, mergeable_state='dirty' if dirty else 'clean')
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    expression = ('result=%{ci_state: ' + json.dumps('failing' if failing else 'pending') +
        ',lifecycle: ' + json.dumps(lifecycle) + ',head_sha: "' + 'a'*40 + '",base_sha: "' + 'b'*40 +
        '",payload: Jason.decode!(Base.decode64!("' + encoded + '"))}; r=%{id: ' + json.dumps(r['id']) +
        ',attempt_id: ' + json.dumps(r['attempt_id']) + ',generation: ' + str(r['generation']) +
        '}; IO.puts(inspect(Agentboard.Delivery.Polling.commit_observation(r,result)))')
    assert '{:ok,' in rpc(expression)

failures = []
for owner in ('inbox-owner', 'inbox-coordinator'):
    api('/agents/register', {'name': owner}, agent=owner)
rpc(':ok=Oban.pause_queue(queue: :delivery_scheduler); :ok=Oban.pause_queue(queue: :delivery_polling); Application.put_env(:agentboard,:pr_observation_enabled,true); Application.put_env(:agentboard,:coordinator_id,"inbox-coordinator"); Application.put_env(:agentboard,:cooperation_enabled,true)')
pr = source(401)
observe(pr)
repair = sql("SELECT repair_task_id FROM delivery_obligations WHERE pull_request_id='" + pr + "'")
messages = api('/messages?unread=true', agent='inbox-owner')['messages']
owned = [m for m in messages if m['task_id'] == repair]
if len(owned) != 1:
    failures.append(('first-delivery not exactly-once to responsible', owned))
observe(pr)
if sql("SELECT count(*) FROM messages WHERE task_id='" + repair + "'") != '1':
    failures.append(('repair-task inbox count != 1 after replay', sql("SELECT count(*) FROM messages WHERE task_id='" + repair + "'")))
sql("UPDATE delivery_obligations SET next_reminder_at=clock_timestamp()-interval '1 second' WHERE repair_task_id='" + repair + "'")
rpc('{:ok, %{checked: n}} = Agentboard.Delivery.Accountability.tick(); if n < 1, do: raise("tick checked nothing")')
gen = sql("SELECT reminder_generation FROM delivery_obligations WHERE repair_task_id='" + repair + "'")
if int(gen) < 1:
    failures.append(('reminder never fired', gen))
coord = api('/messages?unread=true', agent='inbox-coordinator')['messages']
digest = [m for m in coord if m['task_id'] == repair]
if len(digest) != 1:
    failures.append(('escalated digest missing from coordinator inbox',
        {'digest': digest, 'gen': gen,
         'all_messages': sql("SELECT recipient_id || '/' || coalesce(task_id,'-') FROM messages ORDER BY id"),
         'digest_events': sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_digest'")}))
detail = api('/prs/' + pr, agent='inbox-owner')
modes = {(d['task_id'], d['kind']): d['mode'] for d in detail.get('follow_up_delivery', [])}
if modes.get((repair, 'ci_failure')) != 'inbox_fallback':
    failures.append(('prs detail missing inbox_fallback mode', modes))
rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
before = sql("SELECT count(*) FROM messages WHERE task_id='" + repair + "'")
api('/workers/provision', {'worker_id': 'inbox-owner', 'host_id': 'sunset-host', 'idempotency_key': 'sunset-key-1', 'repos': ['fixture/repo'], 'model': 'fixture-model', 'harness': 'codex'}, agent='inbox-owner', captain=True)
if sql("SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id = d.event_id WHERE e.task_id='" + repair + "'") != '1':
    failures.append(('bootstrap did not adopt inbox-delivered occurrence exactly once', repair))
if sql("SELECT count(*) FROM messages WHERE task_id='" + repair + "'") != before:
    failures.append(('bootstrap sent second message', (before, repair)))
pr2 = source(402)
observe(pr2)
repair2 = sql("SELECT repair_task_id FROM delivery_obligations WHERE pull_request_id='" + pr2 + "'")
if sql("SELECT count(*) FROM messages WHERE task_id='" + repair2 + "'") != '0':
    failures.append(('worker-owned event gained fallback message', repair2))
rpc('Agentboard.Cooperation.Runtime.route()')
if sql("SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id = d.event_id WHERE e.task_id='" + repair2 + "'") == '0':
    failures.append(('worker delivery missing for new event', repair2))
detail2 = api('/prs/' + pr2, agent='inbox-owner')
modes2 = {(d['task_id'], d['kind']): d['mode'] for d in detail2.get('follow_up_delivery', [])}
if modes2.get((repair2, 'ci_failure')) != 'worker':
    failures.append(('prs detail missing worker mode', modes2))
assert not failures, failures
print('Zero-worker CI failure/replay/reminder/enrollment-sunset inbox proof passed', flush=True)
