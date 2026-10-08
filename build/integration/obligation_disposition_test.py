"""Terminal obligation owner contract through packaged callbacks, API and AshOban."""
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.request
import urllib.error
URL = os.environ['AGENTBOARD_URL']
HEAD = 'a' * 40
BASE = 'b' * 40
def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=45)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def api(path, body=None, status=200, captain=False):
    headers = {'x-agentboard-agent': 'merge-owner', 'x-agentboard-model': 'fixture-model',
               'x-agentboard-harness': 'codex', 'Content-Type': 'application/json', 'x-agentboard-worker-protocol': '1'}
    if captain:
        headers['x-agentboard-captain-token'] = 'fixture-captain-capability-32-characters'
    req = urllib.request.Request(URL + '/api/v1' + path, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        response = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    data = json.load(response)
    assert response.status == status, (path, response.status, data)
    return data


def task(id, number=None, status='review', url=None):
    body = dict(id=id, title=id, repo='fixture/merge')
    if number is not None:
        body['pr_url'] = url or f'https://github.com/fixture/merge/pull/{number}'
    api('/tasks', body)
    if status not in ('open', 'assigned'):
        api('/tasks/' + id + '/claim', {})
        if status != 'in_progress':
            api('/tasks/' + id + '/update', dict(status=status, note='Invented fixture status'))
    elif status == 'assigned':
        api('/tasks/' + id + '/assign', dict(to='merge-owner'))


def observe(number, lifecycle='merged', failing=False, passing=False):
    ident = sql(f"SELECT id FROM delivery_pull_requests WHERE number='{number}' AND repo='merge'")
    # Repeated invented observations explicitly reenable the fixture row;
    # production terminal retirement remains the collector's responsibility.
    sql(f"UPDATE delivery_poll_states SET enabled=true,next_poll_at=clock_timestamp()-interval '1 second' WHERE id='{ident}'")
    policy = ('Application.put_env(:agentboard, :ci_policies, %{"fixture/merge" => %{"tested_ref" => "head", "required" => ["check:1:required"]}}); ') if passing else ''
    payload = '%{"coverage" => "complete_head", "tested_ref" => "head", "attempts" => []}'
    if passing:
        payload = '%{"coverage" => "complete_head", "tested_ref" => "head", "attempts" => [%{"identity" => "check:1:required", "latest" => true, "status" => "completed", "conclusion" => "success"}]}'
    expr = (policy + '{:ok, [r]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(ident) + '); '
            'result = %{lifecycle: ' + json.dumps(lifecycle) + ', head_sha: "' + HEAD +
            '", base_sha: "' + BASE + '", ci_state: ' + json.dumps('failing' if failing else 'unknown') +
            ', payload: ' + payload + '}; '
            '{:ok, projection} = Agentboard.Delivery.Polling.commit_observation(r, result); '
            'IO.puts("OBSERVATION:" <> Jason.encode!(projection))')
    return json.loads(rpc(expr).split('OBSERVATION:', 1)[1].strip())



rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
api('/agents/register', {'name': 'Terminal fixture owner'})
rpc('Application.put_env(:agentboard, :captain_token, "fixture-captain-capability-32-characters")')
api('/workers/provision', {'worker_id': 'merge-owner', 'host_id': 'fixture-host', 'repos': ['fixture/merge'], 'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'terminal-provision'}, captain=True)

for lifecycle, number in [('merged', 701), ('closed', 702)]:
    task('terminal-' + lifecycle, number, status='in_progress')
    observe(number, lifecycle='open', failing=True)
    oid, repair = sql(f"SELECT o.id||','||repair_task_id FROM delivery_obligations o JOIN delivery_pull_requests p ON p.id=o.pull_request_id WHERE p.number='{number}'").split(',')
    # Route a real captured failure to prove suppression of an existing delivery.
    rpc('{:ok, _} = Agentboard.Board.Operations.transaction(fn -> Agentboard.Cooperation.Runtime.route() end)')
    assert sql(f"SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.task_id='{repair}' AND d.state='pending'") == '1'
    rpc('{:ok, _} = Agentboard.Board.Operations.transaction(fn -> for kind <- ["ci_reminder", "ci_digest"] do Agentboard.Cooperation.Runtime.capture(%{source_key: "fixture:" <> kind <> ":' + repair + '", kind: kind, repo: "fixture/merge", task_id: "' + repair + '", summary: "Invented queued notice", source_url: "https://github.com/fixture/merge/pull/701", priority: 1}, recipient: "merge-owner") end; Agentboard.Cooperation.Runtime.route() end)')
    sql(f"UPDATE cooperation_deliveries d SET state=CASE WHEN e.kind='ci_failure' THEN 'handled' WHEN e.kind='ci_reminder' THEN 'received' ELSE 'pending' END FROM cooperation_events e WHERE d.event_id=e.id AND e.task_id='{repair}'")
    observe(number, lifecycle=lifecycle)
    assert sql(f"SELECT resolved_at IS NOT NULL FROM delivery_obligations WHERE id='{oid}'") == 't', 'Terminal PR left obligation unresolved: ' + lifecycle
    assert sql(f"SELECT resolution_reason FROM delivery_obligations WHERE id='{oid}'") == lifecycle
    assert sql(f"SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.task_id='{repair}' AND d.state IN ('pending','received')") == '0'
    assert sql(f"SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.task_id='{repair}' AND d.state='handled'") == '1'
    assert api('/tasks/' + repair)['task']['status'] == 'assigned', 'Lifecycle silently completed repair'
    assert sql(f"SELECT ci_state FROM delivery_poll_states WHERE id=(SELECT pull_request_id FROM delivery_obligations WHERE id='{oid}')") != 'passing'

def obligation(number):
    return json.loads(sql(f"SELECT row_to_json(o) FROM delivery_obligations o JOIN delivery_pull_requests p ON p.id=o.pull_request_id WHERE p.number='{number}' ORDER BY episode DESC LIMIT 1"))


def reconcile(after=None):
    args = '%{}' if after is None else '%{after_id: ' + json.dumps(after) + '}'
    output = rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.ObligationDisposition, :reconcile, ' + args + ', actor: %{role: :system}); IO.puts("PAGE:" <> Jason.encode!(Ash.run_action!(input)))')
    return json.loads(output.split('PAGE:', 1)[1].strip())


# A closed PR can reopen and create a new failure episode.
observe(702, lifecycle='open', failing=True)
assert obligation(702)['episode'] == 2 and obligation(702)['resolved_at'] is None

for disposition, number in [('done', 703), ('cancelled', 704)]:
    task('repair-' + disposition, number, status='in_progress')
    observe(number, lifecycle='open', failing=True)
    o = obligation(number)
    api('/tasks/' + o['repair_task_id'] + '/claim', {})
    api('/tasks/' + o['repair_task_id'] + '/update', {'status': disposition, 'note': 'Explicit fixture disposition'})
    assert obligation(number)['resolution_reason'] == 'repair_' + disposition
    observe(number, lifecycle='open', failing=True)
    assert obligation(number)['episode'] == 1, 'Identical dismissed failure resurrected'
    HEAD = 'c' * 40
    observe(number, lifecycle='open', failing=True)
    assert obligation(number)['episode'] == 2 and obligation(number)['resolved_at'] is None
    HEAD = 'a' * 40

# A verified passing rerun after explicit disposition restores monitoring even
# on the SAME head. Unknown evidence must not have that effect.
task('same-head-recovery', 709, status='in_progress')
observe(709, lifecycle='open', failing=True)
o = obligation(709)
api('/tasks/' + o['repair_task_id'] + '/claim', {})
api('/tasks/' + o['repair_task_id'] + '/update', {'status': 'cancelled', 'note': 'Explicit disposition'})
observe(709, lifecycle='open')
observe(709, lifecycle='open', failing=True)
assert obligation(709)['episode'] == 1
observe(709, lifecycle='open', passing=True)
assert sql("SELECT ci_state FROM delivery_poll_states WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='709')") == 'passing'
observe(709, lifecycle='open', failing=True)
assert obligation(709)['episode'] == 2 and obligation(709)['resolved_at'] is None

task('disposition-close-reopen', 710, status='in_progress')
observe(710, lifecycle='open', failing=True)
o = obligation(710)
api('/tasks/' + o['repair_task_id'] + '/claim', {})
api('/tasks/' + o['repair_task_id'] + '/update', {'status': 'cancelled', 'note': 'Explicit disposition'})
assert obligation(710)['resolution_reason'] == 'repair_cancelled'
observe(710, lifecycle='closed')
assert obligation(710)['resolution_reason'] == 'repair_cancelled', 'Fenced closed observation rewrote retained disposition'
observe(710, lifecycle='open', failing=True)
assert obligation(710)['episode'] == 2 and obligation(710)['resolved_at'] is None, 'Retained closed lifecycle did not end same-head suppression'

task('source-done', 705, status='in_progress')
observe(705, lifecycle='open', failing=True)
api('/tasks/source-done/update', {'status': 'done', 'note': 'Source disposition'})
assert obligation(705)['resolved_at'] is None

# An audit failure rolls back BOTH owner task transition and resolution/suppression.
o = obligation(705)
api('/tasks/' + o['repair_task_id'] + '/claim', {})
sql("CREATE FUNCTION reject_resolution() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Delivery.Obligation' THEN RAISE EXCEPTION 'Invented obligation audit failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_resolution BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_resolution()")
api('/tasks/' + o['repair_task_id'] + '/update', {'status': 'cancelled', 'note': 'Fail atomically'}, status=503)
assert api('/tasks/' + o['repair_task_id'])['task']['status'] == 'in_progress'
assert obligation(705)['resolved_at'] is None
sql('DROP TRIGGER reject_resolution ON board_action_events; DROP FUNCTION reject_resolution()')

# Invented pre-upgrade records: missed terminal task and retained terminal snapshot.
# Never import live data or mutate production via SQL.
task('historic-done', 706, status='in_progress')
observe(706, lifecycle='open', failing=True)
o = obligation(706)
sql(f"UPDATE tasks SET status='done',claimed_at=NULL,claim_expires_at=NULL WHERE id='{o['repair_task_id']}'")
task('historic-merge', 707, status='in_progress')
projection = observe(707, lifecycle='open', failing=True)
o = obligation(707)
sql(f"WITH retained AS (INSERT INTO delivery_ci_snapshots SELECT gen_random_uuid(),pull_request_id,generation+1,observed_at,head_sha,base_sha,'merged',ci_state,payload FROM delivery_ci_snapshots WHERE id='{projection['snapshot_id']}' RETURNING *) UPDATE delivery_poll_states p SET lifecycle='merged',enabled=false,snapshot_id=s.id,generation=s.generation FROM retained s WHERE p.id=s.pull_request_id")
task('mismatched-proof', 708, status='in_progress')
observe(708, lifecycle='open', failing=True)
sql("UPDATE delivery_poll_states SET lifecycle='merged' WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='708')")
rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)')
rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.ObligationDisposition, :reconcile, %{}, actor: %{role: :system}); {:error, _} = Ash.run_action(input)')
assert obligation(706)['resolved_at'] is None
rpc('Application.put_env(:agentboard, :pr_observation_enabled, true)')
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    pages = list(pool.map(lambda _: reconcile(), range(2)))
assert sum(p['completed'] for p in pages) == 2, pages
assert obligation(706)['resolution_reason'] == 'repair_done'
assert obligation(707)['resolution_reason'] == 'merged'
assert obligation(707)['resolution_snapshot_id'] is not None
assert obligation(705)['resolved_at'] is None
assert obligation(708)['resolved_at'] is None, 'Projection without matching immutable proof resolved'
assert reconcile()['completed'] == 0
rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.ObligationDisposition, :reconcile, %{}, actor: %{role: :agent}); {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)')
# Page through more than 100 invented unresolved obligations, then execute the
# persisted continuation through the configured AshOban worker, not a test seam.
sql("INSERT INTO tasks(id,title,status) SELECT 'historical-bulk-'||n,'Retained terminal repair '||n,'done' FROM generate_series(1,105) n; INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) SELECT md5('bulk-'||n)||md5('bulk-'||n),'fixture','merge',(1000+n)::text,'https://github.com/fixture/merge/pull/'||(1000+n),clock_timestamp() FROM generate_series(1,105) n; INSERT INTO delivery_obligations(id,pull_request_id,episode,repair_task_id,responsible_id,state,head_sha,evidence_urls,last_progress_at,next_reminder_at,reminder_generation,window_at,reminders,created_at) SELECT gen_random_uuid(),md5('bulk-'||n)||md5('bulk-'||n),1,'historical-bulk-'||n,'merge-owner','unresolved',repeat('a',40),'{}',clock_timestamp(),clock_timestamp()+interval '1 hour',0,clock_timestamp(),0,clock_timestamp() FROM generate_series(1,105) n")
page = reconcile()
assert page['scanned'] == 100 and page['next_cursor'], page
assert sql("SELECT count(*)>0 FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileTerminalObligations' AND args->'action_arguments'->>'after_id'='" + page['next_cursor'] + "'") == 't'
rpc(':ok = Oban.resume_queue(queue: :delivery_scheduler)')
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    left = sql("SELECT count(*) FROM delivery_obligations WHERE repair_task_id LIKE 'historical-bulk-%' AND resolved_at IS NULL")
    if left == '0': break
    time.sleep(.2)
assert left == '0', left
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler)')
assert sql("SELECT count(*) FROM delivery_obligations WHERE repair_task_id LIKE 'historical-bulk-%' AND resolution_reason='repair_done'") == '105'
print('TERMINAL_OBLIGATIONS_OK', flush=True)
