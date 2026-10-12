"""Bounded idle/no-findings continuation through the packaged release, real API and PostgreSQL.

Reminders are ordinary cooperation deliveries: these checks reserve and
acknowledge them through the worker protocol and inspect only durable state.
"""
import concurrent.futures
import json
import os
import subprocess
import urllib.error
import urllib.request
from liveview_client import LiveView, contains

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-captain-capability-32-characters'
WORKER = 'idle-worker'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    p = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout


def api(path, body=None, agent=WORKER, status=200, captain=False, token=None):
    headers = {'x-agentboard-agent': agent, 'x-agentboard-model': 'fixture-model',
               'x-agentboard-harness': 'codex', 'x-agentboard-worker-protocol': '1'}
    if captain:
        headers['x-agentboard-captain-token'] = CAPTAIN
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(URL + '/api/v1' + path, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    data = json.load(response)
    assert response.status == status, (response.status, path, data)
    return data


def tick():
    out = rpc('{:ok, r} = Agentboard.Cooperation.IdleContinuation.tick(); IO.puts("TICK:" <> Jason.encode!(r))')
    return json.loads(out.split('TICK:', 1)[1].splitlines()[0])


def due():
    sql("UPDATE cooperation_continuations SET next_eligible_at=clock_timestamp()-interval '1 second'")


def report(adapter='ready'):
    api('/workers/' + WORKER + '/state', {'binding_epoch': 1, 'connector_state': 'healthy',
        'adapter_state': adapter, 'reason': None}, token=host)


def reminders():
    return int(sql("SELECT count(*) FROM cooperation_events WHERE kind='idle_continuation'"))


def summaries():
    return sql("SELECT summary FROM cooperation_events WHERE kind='idle_continuation' ORDER BY created_at,id").splitlines()


def row(column):
    return sql('SELECT ' + column + " FROM cooperation_continuations WHERE id='" + WORKER + "'")


def state():
    return api('/workers/' + WORKER + '/continuation', token=receipt)['continuation']


def dispose(disposition, reason, key, status=200):
    return api('/workers/' + WORKER + '/continuation',
               {'disposition': disposition, 'reason': reason, 'idempotency_key': key},
               token=receipt, status=status)


drains = 0


def drain():
    """Reserve and explicitly handle every pending delivery, as a worker would."""
    global drains
    kinds = []
    while True:
        drains += 1
        batch = api('/workers/' + WORKER + '/reserve', {'binding_epoch': 1, 'idempotency_key': 'drain-%d' % drains}, token=host)['batch']
        if batch is None:
            return kinds
        kinds += [item['kind'] for item in json.loads(batch['payload'])['items']]
        fence = {key: batch[key] for key in ('attempt_id', 'binding_epoch', 'dispatch_generation', 'payload_hash')}
        api('/workers/' + WORKER + '/receipts', dict(fence, idempotency_key='handled-%d' % drains,
            kind='handled', delivery_ids=batch['delivery_ids']), token=receipt)


def tick_and_expect(count):
    report()
    due()
    tick()
    assert reminders() == count, (reminders(), count, state())


def agents_page():
    view = LiveView(URL, '/agents')
    html = view.initial
    view.close()
    return html


# Enrolled, bound, healthy, idle worker with one claimed in-scope responsibility.
api('/agents/register', {'name': 'Idle worker'})
api('/agents/register', {'name': 'Idle captain'}, agent='idle-captain')
rpc('Application.put_env(:agentboard, :captain_token, "' + CAPTAIN + '")')
rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
host = api('/workers/provision', {'worker_id': WORKER, 'host_id': 'fixture-host', 'repos': ['fixture/repo'],
           'model': 'fixture-model', 'harness': 'codex', 'idempotency_key': 'idle-provision'}, captain=True)['host_token']
capabilities = {name: {'supported': True, 'reason': 'Manual fixture'}
                for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
receipt = api('/workers/' + WORKER + '/bind', {'idempotency_key': 'idle-bind', 'expected_epoch': 0, 'host_id': 'fixture-host',
              'session_id': 'fixture-session', 'pane_id': 'fixture-pane', 'adapter': 'manual', 'adapter_version': '1',
              'capabilities': capabilities}, token=host)['receipt_token']
api('/tasks', {'id': 'idle-task', 'title': 'Idle continuation fixture', 'repo': 'fixture/repo'}, agent='idle-captain')
api('/tasks/idle-task/claim', {})
api('/agents/' + WORKER + '/heartbeat', {'status': 'idle'})
report()

# Default off: cooperation alone schedules nothing and dispositions are refused.
assert tick() == {'continuation': 'disabled'}
assert sql('SELECT count(*) FROM cooperation_continuations') == '0' and reminders() == 0
off = state()
assert off['enabled'] is False and 'idle_continuation_disabled' in off['reason_codes'] and off['state'] is None
dispose('no_new_finding', 'Nothing new', 'disabled-key', status=409)

# First observation adopts history as the baseline; the ten-minute delay applies.
rpc('Application.put_env(:agentboard, :idle_continuation_enabled, true)')
tick()
assert reminders() == 0 and row('progress_at IS NULL') == 't'
assert row("next_eligible_at>clock_timestamp()+interval '9 minutes'") == 't'
first = state()
assert first['enabled'] and not first['eligible'] and 'idle_delay' in first['reason_codes']
assert first['limits']['delay_seconds'] == 600 and first['limits']['reminders_before_cooldown'] == 2

# The real cooperation scheduler issues one recipient-pinned ordinary reminder.
report()
due()
scheduled = json.loads(rpc('{:ok, r} = Ash.run_action(Ash.ActionInput.for_action(Agentboard.Cooperation.Scheduler, :reconcile, %{}, actor: %{role: :system, id: "cooperation"})); IO.puts("RUN:" <> Jason.encode!(r))').split('RUN:', 1)[1].splitlines()[0])
# The minute cron may race this explicit run; durable state is authoritative.
assert 'continuation_checked' in scheduled and 'checked' in scheduled, scheduled
assert reminders() == 1
assert sql("SELECT audience::text||','||priority||','||task_id FROM cooperation_events WHERE kind='idle_continuation'") == '{idle-worker},2,idle-task'
assert 'No publication is required' in summaries()[0] and 'without a shared finding' not in summaries()[0]

# At most one outstanding reminder per binding, including duplicate sweeps.
report()
due()
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    list(pool.map(lambda _: tick(), range(2)))
assert reminders() == 1 and 'reminder_outstanding' in state()['reason_codes']

# Delivery uses the existing frozen batch and exact receipt path; no automatic ack.
pending = api('/workers/' + WORKER + '/pending', token=receipt)['deliveries']
assert [d['state'] for d in pending if d['kind'] == 'idle_continuation'] == ['pending']
assert 'idle_continuation' in drain()
assert sql("SELECT d.state FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.kind='idle_continuation'") == 'handled'

# Repeated turns without recorded progress stop at the bound and escalate visibly.
tick_and_expect(2)
drain()
tick_and_expect(2)
assert row("cooldown_reason||','||(escalated_at IS NOT NULL)||','||round(extract(epoch FROM cooldown_until-escalated_at))") == 'repeated_no_progress,true,3600'
cooled = state()
assert 'repeated_no_progress_cooldown' in cooled['reason_codes'] and cooled['escalated'] and cooled['cooldown_active']
tick_and_expect(2)
assert contains(agents_page(), 'Idle continuation escalated')

# Substantive progress lifts the cooldown and escalation; with no Context finding
# the next reminder invites a finding or explicit no-new-finding disposition, once.
api('/tasks/idle-task/update', {'note': 'Reproduced the failing case locally'})
drain()
report()
due()
tick()
assert reminders() == 2 and row("finding_due||','||(cooldown_until IS NULL)||','||(escalated_at IS NULL)") == 'true,true,true'
assert not state()['escalated']
tick_and_expect(3)
assert 'without a shared finding' in summaries()[2] and 'Do not invent findings' in summaries()[2]
drain()
tick_and_expect(4)
assert 'No publication is required' in summaries()[3]
assert sum('without a shared finding' in s for s in summaries()) == 1
drain()

# Explicit no-new-finding: idempotent, validated, and suppresses until new progress.
recorded = dispose('no_new_finding', 'Turn only reconciled CI; nothing new for peers', 'nnf-1')
assert recorded['idempotent'] is False and recorded['continuation']['no_new_finding_active']
assert dispose('no_new_finding', 'Turn only reconciled CI; nothing new for peers', 'nnf-1')['idempotent'] is True
dispose('no_new_finding', 'Different reason', 'nnf-1', status=409)
for bad in ({'disposition': 'no_new_finding', 'idempotency_key': 'k'},
            {'disposition': 'fabricated_finding', 'reason': 'x', 'idempotency_key': 'k'},
            {'disposition': 'no_new_finding', 'reason': ' ', 'idempotency_key': 'k'},
            {'disposition': 'no_new_finding', 'reason': 'x' * 513, 'idempotency_key': 'k'},
            {'disposition': 'no_new_finding', 'reason': 'x', 'idempotency_key': 'k', 'context': 'forced'}):
    api('/workers/' + WORKER + '/continuation', bad, token=receipt, status=422)
assert sql("SELECT count(*) FROM context_entries WHERE source_agent_id='" + WORKER + "'") == '0'
tick_and_expect(4)
assert row('cooldown_reason IS NULL') == 't' and 'no_new_finding' in state()['reason_codes']
assert contains(agents_page(), 'no new finding recorded')

# A published Context finding is progress; the next reminder does not ask for one.
api('/context', {'entry_key': 'idle-finding', 'repo': 'fixture/repo', 'kind': 'FACT',
                 'summary': 'Idle fixture finding', 'task_id': 'idle-task'})
report()
due()
tick()
assert reminders() == 4 and row('finding_due') == 'f' and not state()['no_new_finding_active']
tick_and_expect(5)
assert 'No publication is required' in summaries()[4]
assert sum('without a shared finding' in s for s in summaries()) == 1
drain()

# Outages enter bounded doubling cooldowns with a visible reason, capped at four hours.
dispose('provider_outage', 'Provider returned 529 overloaded', 'outage-1')
assert row("cooldown_reason||','||round(extract(epoch FROM cooldown_until-disposition_at))") == 'provider_outage,900'
tick_and_expect(5)
assert 'provider_outage_cooldown' in state()['reason_codes']
dispose('model_outage', 'Model endpoint unavailable', 'outage-2')
assert row("cooldown_reason||','||round(extract(epoch FROM cooldown_until-disposition_at))") == 'model_outage,1800'
sql("UPDATE cooperation_continuations SET outages=10")
dispose('quota_exhausted', 'Provider quota exhausted until reset', 'outage-3')
assert row("cooldown_reason||','||round(extract(epoch FROM cooldown_until-disposition_at))") == 'quota_exhausted,14400'
tick_and_expect(5)
assert contains(agents_page(), 'Idle continuation cooldown (quota_exhausted)')
api('/tasks/idle-task/update', {'note': 'Provider recovered; resumed the reproduction'})
drain()
report()
due()
tick()
assert row('cooldown_until IS NULL AND outages=0') == 't' and not state()['cooldown_active']

# Durable pause suppresses every sweep without consuming the due state.
api('/workers/' + WORKER + '/pause', {'binding_epoch': 1}, token=host)
tick_and_expect(5)
api('/workers/' + WORKER + '/resume', {'binding_epoch': 1}, token=host)

# Approval-blocked adapter and outstanding captain decision suppress continuation.
report('blocked')
due()
tick()
assert reminders() == 5 and 'approval_blocked' in state()['reason_codes']
decision = api('/decisions', {'task': 'idle-task', 'kind': 'scope', 'question': 'Proceed with idle fixture?',
                              'options': ['Proceed']})['decision']
tick_and_expect(5)
assert 'captain_decision_pending' in state()['reason_codes']
api('/decisions/' + decision['id'] + '/withdraw', {'reason': 'Fixture decision withdrawn'})
if sql("SELECT status FROM tasks WHERE id='idle-task'") != 'in_progress':
    api('/tasks/idle-task/update', {'status': 'in_progress'})
drain()

# Quota exhaustion recorded through captain availability suppresses continuation.
api('/availability', {'agent_id': WORKER, 'state': 'out_of_service', 'reason': 'Provider quota exhausted until reset'}, token=CAPTAIN)
tick_and_expect(5)
assert 'agent_unavailable' in state()['reason_codes']
api('/availability', {'agent_id': WORKER, 'state': 'active', 'reason': 'Quota reset'}, token=CAPTAIN)

# A busy turn restarts the idle delay instead of prompting into active work.
api('/agents/' + WORKER + '/heartbeat', {'status': 'busy'})
tick_and_expect(5)
assert 'agent_not_idle' in state()['reason_codes'] and row("next_eligible_at>clock_timestamp()+interval '9 minutes'") == 't'
api('/agents/' + WORKER + '/heartbeat', {'status': 'idle'})

# Adapter failure: a recent not-submitted attempt cools continuation down.
tick_and_expect(6)
batch = api('/workers/' + WORKER + '/reserve', {'binding_epoch': 1, 'idempotency_key': 'refused'}, token=host)['batch']
api('/workers/' + WORKER + '/attempts/' + batch['attempt_id'] + '/result',
    {'binding_epoch': 1, 'dispatch_generation': batch['dispatch_generation'], 'payload_hash': batch['payload_hash'],
     'status': 'not_submitted', 'reason': 'Fixture adapter refused input'}, token=host)
drain()
tick_and_expect(6)
assert 'adapter_failure_cooldown' in state()['reason_codes']
sql("UPDATE cooperation_attempts SET updated_at=clock_timestamp()-interval '20 minutes' WHERE worker_id='" + WORKER + "' AND status='not_submitted'")
tick_and_expect(7)
drain()

# No unresolved responsibility: completed work never produces a reminder.
api('/tasks/idle-task/update', {'status': 'done', 'note': 'Fixture complete'})
drain()
report()
due()
tick()
tick_and_expect(7)
assert 'no_unresolved_responsibilities' in state()['reason_codes']

# Switching the feature off stops sweeps and dashboard notes without losing evidence.
api('/tasks', {'id': 'idle-task-2', 'title': 'Second responsibility', 'repo': 'fixture/repo'}, agent='idle-captain')
api('/tasks/idle-task-2/claim', {})
rpc('Application.put_env(:agentboard, :idle_continuation_enabled, false)')
report()
due()
assert tick() == {'continuation': 'disabled'} and reminders() == 7
rpc('Application.put_env(:agentboard, :idle_continuation_enabled, true)')
rpc('Application.put_env(:agentboard, :cooperation_enabled, false)')
assert tick() == {'continuation': 'disabled'} and reminders() == 7
assert sql("SELECT count(*) FROM cooperation_events WHERE kind='idle_continuation' AND NOT (audience=ARRAY['" + WORKER + "'])") == '0'
print('Idle continuation: default-off, bounded one-outstanding reminders, explicit dispositions and cooldown suppression passed')
