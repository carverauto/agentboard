"""Packaged AshOban merge policy, audited board transaction and real LiveView rereads.

The collector suite owns HTTPS metadata truth; this suite commits invented
observations through its fenced public callback, then exercises actual jobs.
No live board data or provider credentials are used.
"""
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from liveview_client import LiveView, contains

URL = os.environ['AGENTBOARD_URL']
HEAD = 'a' * 40
BASE = 'b' * 40
ACTOR = '%{"agent" => "merge-owner", "model" => "fixture-model", "harness" => "codex"}'
WORKER = 'Agentboard.Delivery.ReconcileMergedReviews'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                   'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                       capture_output=True, text=True, timeout=45)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def api(path, body=None):
    headers = {'x-agentboard-agent': 'merge-owner', 'x-agentboard-model': 'fixture-model',
               'x-agentboard-harness': 'codex', 'Content-Type': 'application/json'}
    req = urllib.request.Request(URL + '/api/v1' + path, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


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


def observe(number, lifecycle='merged', failing=False):
    ident = sql(f"SELECT id FROM delivery_pull_requests WHERE number='{number}' AND repo='merge'")
    # Repeated invented observations explicitly reenable the fixture row;
    # production terminal retirement remains the collector's responsibility.
    sql(f"UPDATE delivery_poll_states SET enabled=true,next_poll_at=clock_timestamp()-interval '1 second' WHERE id='{ident}'")
    expr = ('{:ok, [r]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(ident) + '); '
            'result = %{lifecycle: ' + json.dumps(lifecycle) + ', head_sha: "' + HEAD +
            '", base_sha: "' + BASE + '", ci_state: ' + json.dumps('failing' if failing else 'unknown') +
            ', payload: %{"coverage" => "complete_head", "tested_ref" => "head", "attempts" => []}}; '
            '{:ok, projection} = Agentboard.Delivery.Polling.commit_observation(r, result); '
            'IO.puts("OBSERVATION:" <> Jason.encode!(projection))')
    return json.loads(rpc(expr).split('OBSERVATION:', 1)[1].strip())


def reconcile(after=None):
    args = '%{}' if after is None else '%{after_id: ' + json.dumps(after) + '}'
    out = rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.MergeDisposition, :reconcile, ' +
              args + ', actor: %{role: :system}); '
              'result = case Ash.run_action(input) do {:ok, page} -> page; '
              '{:error, _} -> %{error: true} end; IO.puts("MERGES:" <> Jason.encode!(result))')
    return json.loads(out.split('MERGES:', 1)[1].strip())


def wait(query, expected, seconds=75):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        got = sql(query)
        if got == expected:
            return
        time.sleep(.2)
    raise AssertionError((query, expected, got,
                          sql(f"SELECT json_agg(json_build_object('state',state,'errors',errors)) FROM oban_jobs WHERE worker='{WORKER}'")))


rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
api('/agents/register', {'name': 'Merge fixture owner'})
task('merge-unknown', 101)
projection = observe(101)
view = LiveView(URL, '/?status=review')
assert contains(view.initial, 'merge-unknown')
# No LLM or direct watcher invocation: the actual configured minute cron owns
# this disposition. On pre-fix main this exact card remains in Review.
rpc(':ok = Oban.resume_queue(queue: :delivery_scheduler)')
wait("SELECT status FROM tasks WHERE id='merge-unknown'", 'done')
assert view.wait(lambda frame: frame[3] == 'diff', timeout=7)
view.close()
page = urllib.request.urlopen(URL + '/?status=review', timeout=15).read().decode()
assert 'merge-unknown' not in page
output = Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'])
output.mkdir(exist_ok=True)
(output / 'review-after-merge.html').write_text(page)
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler)')
assert sql(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{WORKER}' AND state='completed'") == 't'
t = api('/tasks/merge-unknown')['task']
assert (t['status'], t['assignee_id'], t['claimed_at'], t['claim_expires_at']) == ('done', 'merge-owner', None, None)
assert t['revision'] == 4
message = json.loads(sql("SELECT row_to_json(m) FROM messages m WHERE task_id='merge-unknown' AND sender_id='ci-accountability'"))
assert (message['recipient_id'], message['model'], message['harness'], message['read_at']) == ('merge-owner', 'system', 'ash', None)
assert 'Review completed' in message['body'] and 'CI qualification is unchanged' in message['body']
assert sql("SELECT ci_state FROM delivery_poll_states WHERE id='" + projection['id'] + "'") == 'unknown'
event = json.loads(sql("SELECT row_to_json(e) FROM task_events e WHERE task_id='merge-unknown' ORDER BY id DESC LIMIT 1"))
assert (event['actor_id'], event['harness'], event['model'], event['kind']) == ('ci-accountability', 'ash', 'system', 'update')
assert event['data']['before']['status'] == 'review' and event['data']['after']['status'] == 'done'
evidence = event['data']['merge_evidence']
assert evidence['policy'] == 'merged_review_v1' and evidence['snapshot_id'] == projection['snapshot_id']
assert evidence['head_sha'] == HEAD and evidence['base_sha'] == BASE and evidence['ci_state'] == 'unknown'
assert sql("SELECT count(*) FROM tasks_versions WHERE version_source_id='merge-unknown' AND version_action_name='complete_merged_pr'") == '1'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Board.Resources.Task' AND record_id='merge-unknown' AND action='complete_merged_pr'") == '1'

# Permission and runtime-off fences apply to action execution, even for queued jobs.
rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.MergeDisposition, :reconcile, %{}, actor: %{role: :agent}); {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)')
task('merge-disabled', 102)
observe(102)
rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)')
assert reconcile() == {'error': True}
assert api('/tasks/merge-disabled')['task']['status'] == 'review'
rpc('AshOban.schedule(Agentboard.Delivery.MergeDisposition, :reconcile_merges); :ok = Oban.resume_queue(queue: :delivery_scheduler)')
wait(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{WORKER}' AND state='scheduled'", 't', 20)
assert api('/tasks/merge-disabled')['task']['status'] == 'review'
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); Application.put_env(:agentboard, :pr_observation_enabled, true)')

# Merge remains lifecycle evidence after downtime, even with expired ownership
# and old/failing CI. It neither resolves an obligation nor auto-acks its repair.
historical = observe(102)
# Append a historical fixture rather than mutating immutable evidence.
sql("WITH historical AS (INSERT INTO delivery_ci_snapshots SELECT gen_random_uuid(), pull_request_id, generation+1, clock_timestamp()-interval '1 day', head_sha, base_sha, lifecycle, ci_state, payload FROM delivery_ci_snapshots WHERE id='" + historical['snapshot_id'] + "' RETURNING *) UPDATE delivery_poll_states p SET snapshot_id=h.id,generation=h.generation,observed_at=h.observed_at FROM historical h WHERE p.id=h.pull_request_id")
sql("UPDATE tasks SET claimed_at=clock_timestamp()-interval '3 hours',claim_expires_at=clock_timestamp()-interval '1 hour' WHERE id='merge-disabled'")
assert reconcile()['completed'] == 1
assert api('/tasks/merge-disabled')['task']['status'] == 'done'
task('merge-failing', 103)
observe(103, failing=True)
repair = sql("SELECT repair_task_id FROM delivery_obligations WHERE pull_request_id=(SELECT id FROM delivery_pull_requests WHERE number='103')")
api('/tasks/' + repair + '/claim', {})
api('/tasks/' + repair + '/update', {'status': 'review'})
assert reconcile()['completed'] == 1
assert api('/tasks/merge-failing')['task']['status'] == 'done'
assert api('/tasks/' + repair)['task']['status'] == 'review'
assert sql("SELECT state||','||(resolved_at IS NULL) FROM delivery_obligations WHERE repair_task_id='" + repair + "'") == 'unresolved,true'
assert sql("SELECT ci_state FROM delivery_poll_states WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='103')") == 'failing'

# Only Review, only its CURRENT canonical PR, only the current merged snapshot.
for i, state in enumerate(('open', 'assigned', 'in_progress', 'blocked', 'done', 'cancelled'), 201):
    task('merge-state-' + state, i, state)
    observe(i)
task('merge-no-pr')
task('merge-closed', 210)
observe(210, lifecycle='closed')
task('merge-unobserved', 211)
task('merge-relinked', 212)
observe(212)
api('/tasks/merge-relinked/link', {'pr_url': 'https://github.com/fixture/merge/pull/213'})
task('merge-cleared', 214)
observe(214)
api('/tasks/merge-cleared/link', {'pr_url': None})
task('merge-superseded', 215)
observe(215)
observe(215, lifecycle='open')
task('merge-mismatch', 216)
observe(216)
sql("UPDATE delivery_poll_states SET head_sha='" + BASE + "' WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='216')")
before = sql("SELECT json_agg(t ORDER BY id) FROM tasks t WHERE id LIKE 'merge-%' AND status!='done'")
assert reconcile()['completed'] == 0
assert sql("SELECT json_agg(t ORDER BY id) FROM tasks t WHERE id LIKE 'merge-%' AND status!='done'") == before

# Relinking to a merged PR does not discard an older unfinished submission.
task('merge-multi', 217)
observe(217, lifecycle='open')
api('/tasks/merge-multi/link', {'pr_url': 'https://github.com/fixture/merge/pull/218'})
observe(218)
assert reconcile()['completed'] == 0
assert api('/tasks/merge-multi')['task']['status'] == 'review'
observe(217, lifecycle='closed')
assert reconcile()['completed'] == 0
observe(217)
# Terminal pruning/manual disable cannot make retained merge proof disappear.
sql("UPDATE delivery_poll_states SET enabled=false WHERE id IN (SELECT pull_request_id FROM delivery_task_links WHERE task_id='merge-multi')")
assert reconcile()['completed'] == 1
assert api('/tasks/merge-multi')['task']['status'] == 'done'
proof = json.loads(sql("SELECT data->'merge_evidence' FROM task_events WHERE task_id='merge-multi' AND data ? 'merge_evidence'"))
assert len(proof['submissions']) == 2
assert {p['pull_request_id'] for p in proof['submissions']} == set(sql("SELECT pull_request_id FROM delivery_task_links WHERE task_id='merge-multi'").splitlines())

# Independent replicas replay/race the policy: one action/version/event only.
task('merge-race', 301, url='https://github.com/FiXtUrE/MERGE/pull/301')
observe(301)
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    pages = list(pool.map(lambda _: reconcile(), range(2)))
assert sum(p['completed'] for p in pages) == 1
assert reconcile()['completed'] == 0
assert sql("SELECT count(*) FROM tasks_versions WHERE version_source_id='merge-race' AND version_action_name='complete_merged_pr'") == '1'
assert sql("SELECT count(*) FROM messages WHERE task_id='merge-race' AND sender_id='ci-accountability'") == '1'

# The existing board transaction must include Ash audit + event + notification
# capture. A capture/audit failure keeps the source task and its lease intact.
task('merge-rollback', 302)
observe(302)
before = api('/tasks/merge-rollback')['task']
sql("CREATE FUNCTION reject_merge_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Board.Resources.Task' AND NEW.action='complete_merged_pr' THEN RAISE EXCEPTION 'Invented merge audit failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_merge_fixture BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_merge_fixture()")
assert reconcile() == {'error': True}
assert api('/tasks/merge-rollback')['task'] == before
assert sql("SELECT count(*) FROM task_events WHERE task_id='merge-rollback' AND data ? 'merge_evidence'") == '0'
assert sql("SELECT count(*) FROM tasks_versions WHERE version_source_id='merge-rollback' AND version_action_name='complete_merged_pr'") == '0'
sql('DROP TRIGGER reject_merge_fixture ON board_action_events; DROP FUNCTION reject_merge_fixture()')
# A notification failure after task/audit/timeline capture also rolls them back.
sql("CREATE FUNCTION reject_merge_message() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.sender_id='ci-accountability' AND NEW.task_id='merge-rollback' THEN RAISE EXCEPTION 'Invented owner message failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_merge_message BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION reject_merge_message()")
assert reconcile() == {'error': True}
assert api('/tasks/merge-rollback')['task'] == before
assert sql("SELECT count(*) FROM task_events WHERE task_id='merge-rollback' AND data ? 'merge_evidence'") == '0'
assert sql("SELECT count(*) FROM tasks_versions WHERE version_source_id='merge-rollback' AND version_action_name='complete_merged_pr'") == '0'
assert sql("SELECT count(*) FROM messages WHERE task_id='merge-rollback' AND sender_id='ci-accountability'") == '0'
sql('DROP TRIGGER reject_merge_message ON messages; DROP FUNCTION reject_merge_message()')
rpc('Application.put_env(:agentboard, :mattermost_bridge_enabled, true); Application.put_env(:agentboard, :cooperation_enabled, true)')
assert reconcile()['completed'] == 1
assert sql("SELECT count(*) FROM messages WHERE task_id='merge-rollback' AND sender_id='ci-accountability'") == '1'
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='merge-rollback'") == '1'
assert sql("SELECT count(*) FROM cooperation_events c JOIN task_events e ON c.source_key='task:'||e.id WHERE e.task_id='merge-rollback' AND e.data ? 'merge_evidence' AND c.kind='task_update'") == '1'
assert reconcile()['completed'] == 0
assert sql("SELECT count(*) FROM mattermost_outbox WHERE task_id='merge-rollback'") == '1'
rpc('Application.put_env(:agentboard, :mattermost_bridge_enabled, false); Application.put_env(:agentboard, :cooperation_enabled, false)')

# Keyset continuation and real persisted jobs clear >100 records without an
# in-memory cursor or starvation behind ineligible Review rows.
for start in range(1, 106, 20):
    end = min(start + 19, 105)
    rpc('for n <- ' + str(start) + '..' + str(end) + ' do '
        'id = "page-" <> String.pad_leading(Integer.to_string(n), 3, "0"); '
        '{:ok, _} = Agentboard.Board.Operations.mutate(id, "create", ' + ACTOR + ', %{"id" => id, "title" => id, "pr_url" => "https://github.com/fixture/merge/pull/301"}); '
        '{:ok, _} = Agentboard.Board.Operations.mutate(id, "claim", ' + ACTOR + ', %{}); '
        '{:ok, _} = Agentboard.Board.Operations.mutate(id, "update", ' + ACTOR + ', %{"status" => "review"}) end')
page = reconcile('page-')
assert page == {'scanned': 100, 'completed': 100, 'next_cursor': 'page-100'}, page
assert sql("SELECT count(*) FROM tasks WHERE id LIKE 'page-%' AND status='review'") == '5'
assert sql(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{WORKER}' AND args->'action_arguments'->>'after_id'='page-100'") == 't'
rpc(':ok = Oban.resume_queue(queue: :delivery_scheduler)')
wait("SELECT count(*) FROM tasks WHERE id LIKE 'page-%' AND status='review'", '0', 30)
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler)')
assert sql("SELECT count(*) FROM tasks_versions WHERE version_action_name='complete_merged_pr' AND version_source_id LIKE 'page-%'") == '105'

print('Real AshOban merged Review disposition, current-link/evidence fences, lifecycle-only policy, audit rollback, notification capture, replica replay, paging and LiveView rereads passed')
