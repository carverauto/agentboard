"""Real callback/API/PG accountability invariants. Collector suite owns HTTP normalization."""
import base64
import concurrent.futures
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
import re
from liveview_client import LiveView, contains

URL = os.environ['AGENTBOARD_URL']
HEAD = 'a' * 40
BASE = 'b' * 40


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def api(path, body=None, agent='ci-owner', status=200, method=None, captain=False, token=None):
    headers = {'x-agentboard-agent': agent, 'x-agentboard-model': 'fixture-model', 'x-agentboard-harness': 'codex'}
    if captain:
        headers['x-agentboard-captain-token'] = 'fixture-captain-capability-32-characters'
    if token:
        headers['Authorization'] = 'Bearer ' + token
    headers['x-agentboard-worker-protocol'] = '1'
    if body is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(URL + '/api/v1' + path, headers=headers, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    data = json.load(response)
    assert response.status == status, (response.status, path, data)
    return data


def export_page(path, filename, rendered=None):
    # Preserve real packaged SSR and its exact CSS for separate browser inspection.
    page = urllib.request.urlopen(URL + path, timeout=10).read().decode()
    stylesheet = re.search(r'<link rel="stylesheet"[^>]*href="([^"]+)"', page).group(1)
    css = urllib.request.urlopen(URL + stylesheet, timeout=10).read().decode()
    page = re.sub(r'<link rel="stylesheet"[^>]+>', lambda _: '<style>' + css + '</style>', page)
    page = re.sub(r'<script[^>]+></script>', '', page)
    if rendered is not None:
        # Convert the actual full websocket render with the pinned Phoenix consumer.
        encoded = base64.b64encode(json.dumps(rendered).encode()).decode()
        expression = 'normalize = fn walk, node ->\n  cond do\n    is_map(node) -> Map.new(node, fn {key, value} ->\n      mapped = case Integer.parse(key) do\n        {number, ""} -> number\n        _ -> String.to_existing_atom(key)\n      end\n      {mapped, walk.(walk, value)}\n    end)\n    is_list(node) -> Enum.map(node, &walk.(walk, &1))\n    true -> node\n  end\nend;\ndiff = Base.decode64!("' + encoded + '") |> Jason.decode!();\nhtml = Phoenix.LiveView.Diff.to_iodata(normalize.(normalize, diff)) |> IO.iodata_to_binary();\nIO.puts("FRAME_HTML:" <> Base.encode64(html))'
        decoded = base64.b64decode(rpc(expression).split('FRAME_HTML:', 1)[1].strip()).decode()
        page = re.sub(r'<main\b[^>]*>.*?</main>', lambda _: decoded, page, count=1, flags=re.S)
    output = Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'])
    output.mkdir(exist_ok=True)
    (output / filename).write_text(page)
    return page


for owner in ('ci-owner', 'ci-peer'):
    api('/agents/register', {'name': owner}, agent=owner)
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
api('/tasks', {'id': 'ci-source', 'title': 'Submitted work', 'repo': 'fixture/repo',
               'pr_url': 'https://github.com/fixture/repo/pull/101'})
pr = sql("SELECT id FROM delivery_pull_requests WHERE number='101'")


def observe(state='failing', expected='ok', policy='unknown'):
    expression = ('result = %{ci_state: ' + json.dumps(state) + ', head_sha: ' + json.dumps(HEAD) +
                  ', base_sha: ' + json.dumps(BASE) + ', payload: %{"policy" => ' + json.dumps(policy) + ', "attempts" => [%{latest: true, source_url: "https://github.com/fixture/repo/actions/runs/1"}]}}; '
                  'r = Agentboard.Board.Operations.transaction(fn -> Agentboard.Delivery.Accountability.observe(%{pull_request_id: ' + json.dumps(pr) + '}, result, Agentboard.Board.Operations.now()); true end); IO.puts(inspect(r))')
    output = rpc(expression)
    assert ('{:ok, true}' in output) == (expected == 'ok'), output


with concurrent.futures.ThreadPoolExecutor(4) as pool:
    list(pool.map(lambda _: observe(), range(4)))
assert sql('SELECT count(*) FROM delivery_obligations') == '1'
assert sql("SELECT responsible_id FROM delivery_obligations") == 'ci-owner'
assert sql("SELECT count(*) FROM tasks WHERE 'ci-repair'=ANY(labels)") == '1'
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_failure'") == '1'
repair = sql('SELECT repair_task_id FROM delivery_obligations')
api('/tasks/ci-source/claim', {})
api('/tasks/ci-source/update', {'status': 'done', 'note': 'Original source done'})
api('/tasks', {'id': 'ci-other', 'title': 'Another issue', 'repo': 'fixture/repo'})
api('/tasks/ci-other/claim', {})
api('/agents/ci-owner/heartbeat', {'status': 'busy', 'task': 'ci-other'})
observe()
assert sql('SELECT responsible_id FROM delivery_obligations') == 'ci-owner'
assert api('/tasks/ci-source')['task']['status'] == 'done'

# Atomic episode/task/source rollback on a new episode after qualifying recovery.
observe('passing', policy='unknown')
assert sql('SELECT resolved_at IS NULL FROM delivery_obligations') == 't'
observe('passing', policy='verified')
assert sql('SELECT state FROM delivery_obligations') == 'resolved'
assert api('/tasks/' + repair)['task']['status'] == 'assigned', 'Recovery completed repair silently'
sql("CREATE FUNCTION reject_ci_source() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture source error'; END $$")
sql('CREATE TRIGGER reject_ci_source BEFORE INSERT ON cooperation_events FOR EACH ROW EXECUTE FUNCTION reject_ci_source()')
observe(expected='error')
assert sql('SELECT count(*) FROM delivery_obligations') == '1'
assert sql("SELECT count(*) FROM tasks WHERE 'ci-repair'=ANY(labels)") == '1'
sql('DROP TRIGGER reject_ci_source ON cooperation_events')
observe()
assert sql('SELECT max(episode) FROM delivery_obligations') == '2'
repair2 = sql('SELECT repair_task_id FROM delivery_obligations WHERE resolved_at IS NULL')
api('/tasks/' + repair2 + '/claim', {})
api('/tasks/' + repair2 + '/handoff', {'to': 'ci-peer', 'note': 'Explicit responsibility handoff'})
assert sql('SELECT responsible_id FROM delivery_obligations WHERE resolved_at IS NULL') == 'ci-peer'
api('/tasks/' + repair2 + '/claim', {}, agent='ci-peer')
api('/tasks/' + repair2 + '/update', {'note': 'Investigated actual failed test'}, agent='ci-peer')
assert sql("SELECT next_reminder_at>clock_timestamp()+interval '14 minutes' FROM delivery_obligations WHERE resolved_at IS NULL") == 't'
api('/tasks/' + repair2 + '/update', {'status': 'blocked', 'note': 'Requires provider permission'}, agent='ci-peer')
assert sql('SELECT blocker FROM delivery_obligations WHERE resolved_at IS NULL') == 'Requires provider permission'

# Unknown and conflicting immutable provenance goes to captain, never current_task.
api('/tasks', {'id': 'ci-conflict', 'title': 'Other submitter', 'repo': 'fixture/repo',
               'pr_url': 'https://github.com/fixture/repo/pull/101'}, agent='ci-peer')
observe('passing', policy='verified')
observe()
assert sql('SELECT responsible_id IS NULL FROM delivery_obligations WHERE resolved_at IS NULL') == 't'

# Explicit policy is required; unrelated green or missing expected checks cannot resolve.
expr = '''pr = %{owner: "fixture", repo: "repo"};
result = %{ci_state: "unknown", payload: %{"coverage" => "complete_head", "tested_ref" => "head", "attempts" => [%{identity: "check:1:required", latest: true, status: "completed", conclusion: "success"}]}};
Application.put_env(:agentboard, :ci_policies, %{});
"unknown" = Agentboard.Delivery.Policy.classify(pr, result).ci_state;
Application.put_env(:agentboard, :ci_policies, %{"fixture/repo" => %{"tested_ref" => "head", "required" => ["check:1:required"]}});
"passing" = Agentboard.Delivery.Policy.classify(pr, result).ci_state;
"unknown" = Agentboard.Delivery.Policy.classify(pr, %{result | payload: Map.put(result.payload, "attempts", [])}).ci_state;
"failing" = Agentboard.Delivery.Policy.classify(pr, %{result | ci_state: "failing"}).ci_state; IO.puts("POLICY_OK")'''
assert 'POLICY_OK' in rpc(expr)

# Real scheduler decisions, rolling bounds and duplicate-job fences across pods.
rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
host = api('/workers/provision', {'worker_id': 'ci-peer', 'host_id': 'fixture-host', 'repos': ['fixture/repo'], 'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'reminder-provision'}, captain=True)['host_token']
oid = sql('SELECT id FROM delivery_obligations WHERE resolved_at IS NULL')
api('/obligations/' + oid + '/responsibility', {'to': 'ci-peer', 'expected_responsible_id': None, 'reason': 'Captain resolved conflicting provenance', 'idempotency_key': 'captain-owner'}, captain=True)
assert api('/workers/ci-peer/obligations', token=host)['obligations'][0]['id'] == oid
sql("UPDATE cooperation_subscriptions SET repos=ARRAY['foreign/repo'] WHERE id='ci-peer'")
assert api('/workers/ci-peer/obligations', token=host)['obligations'] == []
sql("UPDATE cooperation_subscriptions SET repos=ARRAY['fixture/repo'] WHERE id='ci-peer'")
capabilities = {name: {'supported': name in ('receipt', 'recovery'), 'reason': 'Manual fixture'}
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
bound = api('/workers/ci-peer/bind', {'idempotency_key': 'reminder-bind', 'expected_epoch': 0,
            'host_id': 'fixture-host', 'session_id': 'fixture-session', 'pane_id': 'fixture-pane',
            'adapter': 'manual', 'adapter_version': '1', 'capabilities': capabilities}, token=host)
batch = api('/workers/ci-peer/reserve', {'binding_epoch': 1, 'idempotency_key': 'reminder-reserve'}, token=host)['batch']
before = sql("SELECT last_progress_at||','||next_reminder_at FROM delivery_obligations WHERE id='" + oid + "'")
receipt = {key: batch[key] for key in ('attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash')}
api('/workers/ci-peer/receipts', dict(receipt, idempotency_key='notification-handled',
    kind='handled', delivery_ids=batch['delivery_ids']), token=bound['receipt_token'])
assert sql("SELECT last_progress_at||','||next_reminder_at FROM delivery_obligations WHERE id='" + oid + "'") == before
sql("UPDATE delivery_poll_states SET ci_state='failing',observed_at=clock_timestamp(),head_sha='" + HEAD + "' WHERE id='" + pr + "'")
sql("UPDATE delivery_obligations SET next_reminder_at=clock_timestamp()-interval '1 second' WHERE id='" + oid + "'")
rpc('Application.put_env(:agentboard, :cooperation_enabled, false)')
rpc('{:ok, _} = Agentboard.Delivery.Accountability.tick()')
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder'") == '0'
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
for n in range(6):
    sql("UPDATE delivery_obligations SET next_reminder_at=clock_timestamp()-interval '1 second' WHERE id='" + oid + "'")
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        list(pool.map(lambda _: rpc('{:ok, _} = Agentboard.Delivery.Accountability.tick()'), range(2)))
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder'") == '4'
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_digest'") == '1'
assert sql("SELECT escalated_at IS NOT NULL FROM delivery_obligations WHERE id='" + oid + "'") == 't'
# Blocker and pause retain accountability without new agent reminder intents.
sql("UPDATE delivery_obligations SET blocker='Explicit fixture blocker',next_reminder_at=clock_timestamp()-interval '1 second' WHERE id='" + oid + "'")
rpc('{:ok, _} = Agentboard.Delivery.Accountability.tick()')
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder'") == '4'
api('/workers/ci-peer/pause', {'binding_epoch': 1}, token=host)
sql("UPDATE delivery_obligations SET blocker=NULL,next_reminder_at=clock_timestamp()-interval '1 second' WHERE id='" + oid + "'")
rpc('{:ok, _} = Agentboard.Delivery.Accountability.tick()')
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder'") == '4'

# Connector reports, heartbeat and task leases remain independent health dimensions.
api('/workers/ci-peer/report', {'binding_epoch': 1, 'connector_state': 'healthy',
    'adapter_state': 'ready', 'reason': None}, token=host)
repair3 = sql("SELECT repair_task_id FROM delivery_obligations WHERE id='" + oid + "'")
api('/tasks/' + repair3 + '/claim', {}, agent='ci-peer')
sql("UPDATE agents SET last_heartbeat=clock_timestamp()-interval '1 hour' WHERE id='ci-peer'")
view = LiveView(URL, '/tasks/' + repair3)
assert contains(view.initial, 'healthy') and contains(view.initial, 'Lease expires')
export_page('/tasks/' + repair3, 'task-health.html', view.initial)
view.close()
view = LiveView(URL, '/agents')
assert contains(view.initial, 'Stale') and contains(view.initial, 'healthy')
export_page('/agents', 'agents-health.html', view.initial)
view.close()
sql("UPDATE cooperation_bindings SET reported_at=clock_timestamp()-interval '2 minutes' WHERE id='ci-peer'")
api('/workers/ci-peer/resume', {'binding_epoch': 1}, token=host)
assert 'connector_stale' in api('/workers/ci-peer/state', token=host)['degraded_reasons']
api('/workers/ci-peer/pause', {'binding_epoch': 1}, token=host)

# Dashboard dead render is domain-backed and escapes source text.
sql("UPDATE delivery_obligations SET next_reminder_at=clock_timestamp()-interval '1 second' WHERE id='" + oid + "'")
html = urllib.request.urlopen(URL + '/prs', timeout=10).read().decode()
assert 'ci-peer' in html and 'episode 3' in html and 'Reminder overdue' in html
html = urllib.request.urlopen(URL + '/prs/' + urllib.parse.quote(pr, safe=''), timeout=10).read().decode()
assert 'Immutable submission sources' in html and 'ci-source' in html
assert 'Reminder overdue' in html and 'Captain escalation' in html and 'Progress' in html
# The actual connected LiveView follows durable rereads after missed notifications.
view = LiveView(URL, '/prs')
assert contains(view.initial, 'Captain escalation')
sql("UPDATE delivery_poll_states SET ci_state='unknown',last_error='unauthorized' WHERE id='" + pr + "'")
assert view.wait(lambda event: event[3] == 'diff' and contains(event[4], 'stale'), timeout=7)
view.close()

# Seven invented projections exercise real renderer output; recovery is proved above.
for state in ('failing', 'pending', 'unknown', 'passing'):
    sql("UPDATE delivery_poll_states SET ci_state='" + state + "',observed_at=clock_timestamp(),head_sha='" + HEAD + "',last_error=NULL WHERE id='" + pr + "'")
    export_page('/prs', 'prs-' + state + '.html')
sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp()-interval '1 hour' WHERE id='" + pr + "'")
export_page('/prs', 'prs-stale.html')

api('/workers/ci-peer/resume', {'binding_epoch': 1}, token=host)
batch = api('/workers/ci-peer/reserve', {'binding_epoch': 1, 'idempotency_key': 'dashboard-uncertain'}, token=host)['batch']
fences = {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}
api('/workers/ci-peer/attempts/' + batch['attempt_id'] + '/result',
    dict(fences, status='uncertain', reason='Fixture lost native transport response'), token=host)
page = export_page('/prs', 'prs-uncertain.html')
assert 'Submission uncertain' in page and 'connector healthy / stale' in page
rpc('Application.put_env(:agentboard, :cooperation_enabled, false)')
page = export_page('/prs', 'prs-disabled.html')
assert 'Disabled' in page and 'Submission uncertain' in page

print('Packaged failure episodes/provenance/recovery/handoff/rollback/dashboard contracts passed')
