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
from html.parser import HTMLParser
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


def _strip_scripts(html):
    # Remove script elements with a real parser so variants like
    # `</script >` cannot slip through a filtering regexp.
    class Stripper(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=False)
            self.parts = []
            self.depth = 0
        def handle_starttag(self, tag, attrs):
            if tag.lower() == 'script':
                self.depth += 1
            elif self.depth == 0:
                self.parts.append(self.get_starttag_text())
        def handle_startendtag(self, tag, attrs):
            if tag.lower() != 'script' and self.depth == 0:
                self.parts.append(self.get_starttag_text())
        def handle_endtag(self, tag):
            if tag.lower() == 'script':
                self.depth = max(0, self.depth - 1)
            elif self.depth == 0:
                self.parts.append('</' + tag + '>')
        def handle_data(self, data):
            if self.depth == 0:
                self.parts.append(data)
        def handle_comment(self, data):
            if self.depth == 0:
                self.parts.append('<!--' + data + '-->')
        def handle_decl(self, decl):
            if self.depth == 0:
                self.parts.append('<!' + decl + '>')
    stripper = Stripper()
    stripper.feed(html)
    return ''.join(stripper.parts)


def export_page(path, filename, rendered=None):
    # Preserve real packaged SSR and its exact CSS for separate browser inspection.
    page = urllib.request.urlopen(URL + path, timeout=10).read().decode()
    stylesheet = re.search(r'<link rel="stylesheet"[^>]*href="([^"]+)"', page).group(1)
    css = urllib.request.urlopen(URL + stylesheet, timeout=10).read().decode()
    page = re.sub(r'<link rel="stylesheet"[^>]+>', lambda _: '<style>' + css + '</style>', page)
    page = _strip_scripts(page)
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


# Invalid JSON/root values must not prevent the packaged release runtime from loading.
loaded_policies = []
for raw in ('{malformed', '[]', 'null', json.dumps({'fixture/repo': {'tested_ref': 'head',
        'required': ['check:1:required'], 'accepted_conclusions': 'success'}})):
    env = dict(os.environ, AGENTBOARD_CI_POLICIES=raw)
    loaded = subprocess.run([os.environ['AGENTBOARD_BIN'], 'eval',
        'IO.puts("LOADED_POLICY:" <> Jason.encode!(Application.get_env(:agentboard, :ci_policies)))'],
        env=env, capture_output=True, text=True, timeout=30)
    assert loaded.returncode == 0, (raw, loaded.stdout, loaded.stderr)
    policies = json.loads(loaded.stdout.split('LOADED_POLICY:', 1)[1].splitlines()[0])
    assert isinstance(policies, dict), (raw, policies)
    loaded_policies.append(policies)
    if raw in ('{malformed', '[]', 'null'):
        assert policies == {}, (raw, policies)

for owner in ('ci-owner', 'ci-peer'):
    api('/agents/register', {'name': owner}, agent=owner)
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
api('/tasks', {'id': 'ci-source', 'title': 'Submitted work', 'repo': 'fixture/repo',
               'pr_url': 'https://github.com/fixture/repo/pull/101'})
pr = sql("SELECT id FROM delivery_pull_requests WHERE number='101'")


def reserve():
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='" + pr + "'")
    output = rpc('{:ok, [r]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(pr) + '); IO.puts("RESERVATION:" <> Jason.encode!(r))')
    return json.loads(output.split('RESERVATION:', 1)[1].strip())


def observe(state='failing', expected='ok', policy='unknown', reservation=None, attempts=None, tested_ref='head', draft=None, config_override=None):
    reservation = reservation or reserve()
    config = '%{"fixture/repo" => %{"tested_ref" => "head", "required" => ["check:1:required"]}}' if policy == 'verified' else '%{}'
    if config_override is not None:
        config = 'Jason.decode!(' + json.dumps(json.dumps(config_override)) + ')'
    check = dict(identity='check:1:required', latest=True, status='completed',
                 conclusion='failure' if state == 'failing' else 'success',
                 source_url='https://github.com/fixture/repo/actions/runs/1')
    payload = dict(policy='unknown', coverage='complete_head', tested_ref=tested_ref,
                   attempts=[check] if attempts is None else attempts)
    payload['draft'] = draft
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    expression = ('Application.put_env(:agentboard, :ci_policies, ' + config + '); '
                  'result = %{ci_state: ' + json.dumps('unknown' if state == 'passing' else state) +
                  ', lifecycle: "open", head_sha: ' + json.dumps(HEAD) + ', base_sha: ' + json.dumps(BASE) +
                  ', payload: Jason.decode!(Base.decode64!("' + encoded + '"))}; '
                  'reservation = %{id: ' + json.dumps(reservation['id']) +
                  ', attempt_id: ' + json.dumps(reservation['attempt_id']) +
                  ', generation: ' + str(reservation['generation']) + '}; '
                  'IO.puts(inspect(Agentboard.Delivery.Polling.commit_observation(reservation, result)))')
    output = rpc(expression)
    success = '{:ok,' in output
    if expected is not None:
        assert success == (expected == 'ok'), output
    return success


rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling); Application.put_env(:agentboard, :pr_observation_enabled, true)')
reservation = reserve()
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    results = list(pool.map(lambda _: observe(reservation=reservation, expected=None), range(4)))
assert results.count(True) == 1, results
assert sql('SELECT count(*) FROM delivery_ci_snapshots') == '1'
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
observe('passing', policy='verified', attempts=[])
assert sql('SELECT resolved_at IS NULL FROM delivery_obligations') == 't'
observe('passing', policy='verified', tested_ref='merge')
assert sql('SELECT resolved_at IS NULL FROM delivery_obligations') == 't'
# Feed the actual cold-loaded config through the canonical collector transaction.
for policies in loaded_policies:
    print('COLD_POLICY_COLLECTOR', policies, flush=True)
    observe('passing', config_override=policies)
    assert sql('SELECT ci_state FROM delivery_poll_states') == 'unknown', 'Cold-loaded malformed policy certified green'
    assert sql('SELECT count(*) FROM delivery_obligations WHERE resolved_at IS NULL') == '1'

# Malformed operator policy must retain the active episode and never certify green.
for accepted in ('success', None, ['success', 17], []):
    print('INVALID_POLICY_CASE', repr(accepted), flush=True)
    observe('passing', config_override={'fixture/repo': {
        'tested_ref': 'head', 'required': ['check:1:required'],
        'accepted_conclusions': accepted}})
    assert sql('SELECT ci_state FROM delivery_poll_states') == 'unknown', 'Invalid policy certified green'
    assert sql('SELECT count(*) FROM delivery_obligations WHERE resolved_at IS NULL') == '1', 'Invalid policy resolved accountability'
observe('passing', policy='verified')
assert sql('SELECT state FROM delivery_obligations') == 'resolved'
assert api('/tasks/' + repair)['task']['status'] == 'assigned', 'Recovery completed repair silently'
sql("CREATE FUNCTION reject_ci_source() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture source error'; END $$")
sql('CREATE TRIGGER reject_ci_source BEFORE INSERT ON cooperation_events FOR EACH ROW EXECUTE FUNCTION reject_ci_source()')
reservation = reserve()
snapshot_count = sql('SELECT count(*) FROM delivery_ci_snapshots')
projection_before = sql('SELECT to_jsonb(s) FROM delivery_poll_states s')
observe(expected='error', reservation=reservation)
assert sql('SELECT count(*) FROM delivery_ci_snapshots') == snapshot_count
assert sql('SELECT to_jsonb(s) FROM delivery_poll_states s') == projection_before
assert sql('SELECT count(*) FROM delivery_obligations') == '1'
assert sql("SELECT count(*) FROM tasks WHERE 'ci-repair'=ANY(labels)") == '1'
sql('DROP TRIGGER reject_ci_source ON cooperation_events')
observe(reservation=reservation)
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

# Captain-only responsibility retains accountability without crashing on a missing subscription.
print('MISSING_SUBSCRIPTION_TICK', flush=True)
sql("UPDATE delivery_obligations SET next_reminder_at=clock_timestamp()-interval '1 second' WHERE resolved_at IS NULL")
rpc('{:ok, _} = Agentboard.Delivery.Accountability.tick()')
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='ci_reminder'") == '0'
assert sql('SELECT escalated_at IS NOT NULL FROM delivery_obligations WHERE resolved_at IS NULL') == 't'

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
assert contains(view.initial, '1h ago') and not contains(view.initial, '3600 seconds ago')
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

# Relative-age display contract uses a fixed clock for exact boundaries; real roster above consumes it.
expression = 'now = ~U[2026-10-07 00:00:00Z]; values = Enum.map([0,1,59,89,90,201,947,3599,3600,86399,86400,172800,-60], fn n -> AgentboardWeb.RelativeTime.age(DateTime.to_iso8601(DateTime.add(now,-n)), now) end); IO.puts("AGES:" <> Jason.encode!(values ++ Enum.map([nil,"invalid",42], &AgentboardWeb.RelativeTime.age(&1, now))))'
ages = json.loads(rpc(expression).split('AGES:', 1)[1].strip())
assert ages == ['Just now','1s ago','59s ago','89s ago','1m ago','3m ago','15m ago','59m ago','1h ago','23h ago','1d ago','2d ago','Just now','Unknown age','Unknown age','Unknown age'], ages

# Review-card badges consume the same canonical CI projection as /prs, not their own provider reader.
api('/tasks', {'id': 'ci-review-card', 'title': 'Review ' + 'LongUnbrokenTitle' * 20,
               'repo': 'fixture/repo', 'pr_url': 'https://github.com/Fixture/REPO/pull/101'})
api('/tasks/ci-review-card/claim', {})
api('/tasks/ci-review-card/update', {'status': 'review'})
api('/tasks', {'id': 'ci-review-without-pr', 'title': 'Review without PR', 'repo': 'fixture/repo'})
api('/tasks/ci-review-without-pr/claim', {})
api('/tasks/ci-review-without-pr/update', {'status': 'review'})

def export_review(state, filename=None):
    view = LiveView(URL, '/?status=review')
    page = export_page('/?status=review', filename or 'board-ci-' + state + '.html', view.initial)
    view.close()
    assert 'CI ' + state in page, page
    cards = re.findall(r'<article[^>]*class="task-card"[^>]*>(.*?)</article>', page, re.S)
    without = next(card for card in cards if 'ci-review-without-pr' in card)
    assert 'review-ci' not in without
    return page

# Seven invented projections exercise real renderer output; recovery is proved above.
for state in ('failing', 'pending', 'unknown', 'passing'):
    sql("UPDATE delivery_poll_states SET ci_state='" + state + "',observed_at=clock_timestamp(),head_sha='" + HEAD + "',last_error=NULL WHERE id='" + pr + "'")
    export_page('/prs', 'prs-' + state + '.html')
    export_review(state)
sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp()-interval '1 hour' WHERE id='" + pr + "'")
export_page('/prs', 'prs-stale.html')
export_review('stale')
# Policy-unverified passing never becomes a green Review card.
sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp(),last_error='policy_unknown' WHERE id='" + pr + "'")
page = export_review('unknown')
assert 'CI passing' not in page

# Draft is read from the exact current head snapshot; stale metadata is labelled.
observe('pending', draft=True)
page = export_review('pending', 'board-draft-fresh.html')
assert '◇' in page and '> Draft</span>' in page
sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp()-interval '1 hour' WHERE id='" + pr + "'")
# Ageing the projection without the immutable snapshot cannot certify draft.
page = export_review('stale')
assert 'Draft' not in page
sql("UPDATE delivery_poll_states SET observed_at=s.observed_at FROM delivery_ci_snapshots s WHERE delivery_poll_states.snapshot_id=s.id")
sql("UPDATE delivery_poll_states SET last_error='unauthorized' WHERE id='" + pr + "'")
page = export_review('stale', 'board-draft-stale.html')
assert 'Draft (last observed)' in page
sql("UPDATE delivery_poll_states SET head_sha='" + BASE + "' WHERE id='" + pr + "'")
assert 'Draft' not in export_review('stale')
observe('pending', draft=False)
assert 'Draft' not in export_review('pending')


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

# Lost database after a verified-green card retains the card but removes its green claim.
sql("UPDATE delivery_poll_states SET ci_state='passing',observed_at=clock_timestamp(),last_error=NULL WHERE id='" + pr + "'")
view = LiveView(URL, '/?status=review')
assert contains(view.initial, 'CI passing')
import sys
prefix = [sys.executable, str(Path(os.environ['FIXTURE_DATA']).parent / 'as_user.py')] if os.geteuid() == 0 else []
subprocess.run(prefix + [os.environ['FIXTURE_CONTROL'], '-D', os.environ['FIXTURE_DATA'], '-m', 'immediate', 'stop'], check=True, capture_output=True)
changed = view.wait(lambda event: event[3] == 'diff' and contains(event[4], 'CI unavailable'), timeout=7)
assert changed and not contains(changed[4], 'CI passing'), view.events[-3:]
view.close()

print('Packaged failure episodes/provenance/recovery/handoff/rollback/dashboard contracts passed')
