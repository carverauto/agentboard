"""Deterministic fleet backlog refill (issue #170) at packaged HTTP, CLI, RPC and PostgreSQL boundaries.

The release boots with AGENTBOARD_REFILL_ENABLED unset, so the refill queue is
paused and the minute schedule is absent. The fixture then enables refill in
this isolated server only and drives passes through the public run entry point,
so every pass is deterministic. The last section resumes the queue to prove a
task done event wakes a refill job through Oban.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ['AGENTBOARD_URL']
CAPTAIN = 'fixture-fleet-refill-captain-0123456789'
TOKEN = Path(os.environ['TEST_TMPDIR']) / 'refill-captain.token'
TOKEN.write_text(CAPTAIN + '\n')
TOKEN.chmod(0o600)
MISSING = object()
FLEET = 'refill'
REPO = 'fixture/refill'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (expression, result.stdout, result.stderr)
    return result.stdout.strip()


def api(path, data=MISSING, *, captain=False, actor='refill-captain', harness='codex',
        status=200, method=None):
    headers = {'X-Agentboard-Agent': actor, 'X-Agentboard-Model': 'fixture-model',
               'X-Agentboard-Harness': harness, 'Content-Type': 'application/json'}
    if captain:
        headers['Authorization'] = 'Bearer ' + CAPTAIN
    request = urllib.request.Request(URL + '/api/v1/' + path, headers=headers,
                                     data=None if data is MISSING else json.dumps(data).encode(),
                                     method=method)
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    body = json.load(response)
    assert CAPTAIN not in json.dumps(body), 'Captain capability leaked'
    assert response.status == status, (path, response.status, status, body)
    return body


def cli(*args, code=0):
    env = dict(os.environ, AGENTBOARD_CAPTAIN_TOKEN_FILE=str(TOKEN), AGENT_ID='',
               AGENTBOARD_MODEL='', AGENTBOARD_HARNESS='')
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert CAPTAIN not in result.stdout + result.stderr, 'Capability leaked'
    return json.loads(result.stderr if code else result.stdout)


def run_pass():
    output = rpc('IO.puts("REFILL_RESULT=" <> Jason.encode!(elem(Agentboard.FleetRefill.run_all(), 1)))')
    line = [l for l in output.splitlines() if l.startswith('REFILL_RESULT=')][-1]
    return json.loads(line.split('=', 1)[1])


def register(agent, kind='seat'):
    api('agents/register', {'name': agent, 'kind': kind}, actor=agent)
    api('agents/' + agent + '/heartbeat', {'status': 'idle'}, actor=agent)


def scope(agent, allowed_labels=()):
    return api('agents/' + agent + '/scope', {'allowed_repos': [REPO], 'required_labels': [],
               'allowed_labels': list(allowed_labels), 'revision': 0},
               method='PUT', captain=True)['scope']


def card(id, priority, labels=()):
    api('tasks', {'id': id, 'title': 'Refill ' + id, 'repo': REPO, 'priority': priority,
                  'labels': list(labels)})


def task(id):
    return api('tasks/' + id)['task']


def board():
    return sql("SELECT jsonb_build_object("
               "'tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),"
               "'events',(SELECT count(*) FROM task_events),"
               "'messages',(SELECT count(*) FROM messages),"
               "'assignments',(SELECT count(*) FROM fleet_refill_assignments))")


def orders(task_id):
    return sql("SELECT coalesce(jsonb_agg(jsonb_build_array(sender_id,recipient_id) ORDER BY id),'[]') "
               "FROM messages WHERE kind='task_order' AND task_id='" + task_id + "'")


def pairs(result):
    return [(p['task_id'], p['agent_id']) for p in result['fleets'][FLEET]['pairs']]


def status():
    return api('fleets/' + FLEET + '/refill', captain=True)['refill']


def loadout():
    return api('fleets/' + FLEET + '/loadout', captain=True)['loadout']


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard, :queue_limit, 2)')
assert api('meta')['schema_version'] == api('meta')['required_schema_version'] == 47
assert sql("SELECT kind||':'||model||':'||harness FROM agents WHERE id='fleet-refill'") == 'system:system:ash'

api('agents/register', {'name': 'refill-captain'}, actor='refill-captain')
for seat in ['seat-a', 'seat-b', 'seat-sec']:
    register(seat)
scope('seat-a')
scope('seat-b')
scope('seat-sec', ['security'])

# Activation is captain-only, validated, and needs a saved loadout.
api('fleets/' + FLEET + '/activate', {'mode': 'dry_run'}, status=403)
api('fleets/' + FLEET + '/activate', {'mode': 'dry_run'}, captain=True, status=409)
seats = [{'seat_id': s, 'agent_id': s, 'harness': 'codex', 'desired_host_id': 'host-a',
          'desired_model': 'model', 'desired_effort': 'effort', 'scope_revision': 1}
         for s in ['seat-a', 'seat-b', 'seat-sec']]
api('fleets/' + FLEET + '/loadout', {'revision': 0, 'idempotency_key': 'refill-1', 'seats': seats},
    method='PUT', captain=True)
dormant = loadout()
assert dormant['enabled'] is False and dormant['activation_state'] == 'not_activatable', dormant
for bad in [{'mode': 'on'}, {'mode': 'live', 'claim_deadline_seconds': 59},
            {'mode': 'live', 'claim_deadline_seconds': 86401}, {'mode': 'live', 'enabled': True}, {}]:
    api('fleets/' + FLEET + '/activate', bad, captain=True, status=422)
api('fleets/' + FLEET + '/deactivate', {'mode': 'live'}, captain=True, status=422)
api('fleets/Bad/activate', {'mode': 'live'}, captain=True, status=422)
assert sql('SELECT count(*) FROM fleet_activations') == '0'
# Deactivating a never-activated fleet writes nothing.
assert api('fleets/' + FLEET + '/deactivate', {}, captain=True)['changed'] is False
assert sql('SELECT count(*) FROM fleet_activations') == '0'

card('card-old', 2)
card('card-mid', 1)
card('card-new', 1)

# Default off: the queue is paused, an activation is only recorded, and a pass
# writes nothing at all.
assert 'REFILL_PAUSED=true' in rpc('IO.puts("REFILL_PAUSED=#{Oban.check_queue(queue: :fleet_refill).paused}")')
activated = cli('fleet', 'activate', FLEET, '--mode', 'dry-run', '--claim-deadline', '1m')
assert activated['changed'] is True and activated['activation']['mode'] == 'dry_run'
assert activated['activation']['claim_deadline_seconds'] == 60
assert activated['activation']['refill_enabled'] is False
assert cli('fleet', 'activate', FLEET, '--mode', 'dry-run')['changed'] is False
assert loadout()['activation_state'] == 'dry_run' and loadout()['enabled'] is False
before = board()
assert run_pass() == {'enabled': False}
assert board() == before and sql('SELECT count(*) FROM fleet_refill_passes') == '0'

rpc('Application.put_env(:agentboard, :refill_enabled, true)')

# Dry run: two eligible general seats, three cards. One card per seat per pass;
# lower priority number first, then creation time; the third card waits. The
# security-only seat takes nothing unlabelled. The board is unchanged.
result = run_pass()
assert pairs(result) == [('card-mid', 'seat-a'), ('card-new', 'seat-b')], result
assert board() == before
digest = status()
assert digest['refill_enabled'] is True and digest['last_pass']['mode'] == 'dry_run'
assert [(p['task_id'], p['agent_id']) for p in digest['last_pass']['pairs']] == pairs(result)
assert digest['pending'] == [] and digest['misses'] == []
assert cli('fleet', 'refill', 'status', FLEET)['refill']['last_pass'] == digest['last_pass']

# Security-labelled card goes only to the seat whose scope carries the label,
# even though it outranks every other card.
card('card-sec', 0, ['security'])
before = board()
assert pairs(run_pass()) == [('card-sec', 'seat-sec'), ('card-mid', 'seat-a'), ('card-new', 'seat-b')]
assert board() == before

# Waiting on the captain and reserved seats receive nothing.
api('tasks', {'id': 'waiting-card', 'title': 'Waiting fixture', 'repo': 'fixture/other'})
api('agents/seat-b/scope', {'allowed_repos': [REPO, 'fixture/other'], 'required_labels': [],
    'allowed_labels': [], 'revision': 1}, method='PUT', captain=True)
api('tasks/waiting-card/claim', {}, actor='seat-b')
decision = api('decisions', {'task': 'waiting-card', 'kind': 'scope', 'question': 'Refill fixture?',
                             'options': ['Proceed']}, actor='seat-b')['decision']
before = board()
assert pairs(run_pass()) == [('card-sec', 'seat-sec'), ('card-mid', 'seat-a')]
reserved = api('availability', {'agent_id': 'seat-a', 'state': 'reserved', 'reason': 'Fixture'},
               captain=True)['policy']
assert pairs(run_pass()) == [('card-sec', 'seat-sec')]
assert board() == before
api('availability', {'agent_id': 'seat-a', 'state': 'active', 'revision': reserved['revision']}, captain=True)
api('decisions/' + decision['id'] + '/withdraw', {'reason': 'Fixture done'}, actor='seat-b')
api('tasks/waiting-card/update', {'status': 'cancelled'}, actor='seat-b')
assert pairs(run_pass()) == [('card-sec', 'seat-sec'), ('card-mid', 'seat-a'), ('card-new', 'seat-b')]
assert sql('SELECT count(*) FROM fleet_refill_assignments') == '0'

# Live, queue limit 1. A failure after the first committed assignment (here a
# rejected assignment row for every other card) rolls back only those cards.
rpc('Application.put_env(:agentboard, :queue_limit, 1)')
# Omitting --claim-deadline keeps the recorded value; set a long one and
# backdate deadlines explicitly so slow fixtures cannot expire them early.
assert cli('fleet', 'activate', FLEET, '--mode', 'live')['activation']['claim_deadline_seconds'] == 60
assert cli('fleet', 'activate', FLEET, '--mode', 'live', '--claim-deadline', '1h')['activation']['claim_deadline_seconds'] == 3600
assert loadout()['activation_state'] == 'live' and loadout()['enabled'] is True
sql("CREATE FUNCTION refill_crash() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN "
    "IF NEW.task_id <> 'card-sec' THEN RAISE EXCEPTION 'injected crash'; END IF; RETURN NEW; END $$; "
    "CREATE TRIGGER refill_crash BEFORE INSERT ON fleet_refill_assignments FOR EACH ROW EXECUTE FUNCTION refill_crash()")
crashed = run_pass()
assert pairs(crashed) == [('card-sec', 'seat-sec')], crashed
assert task('card-sec')['status'] == 'assigned' and task('card-sec')['assigner_id'] == 'fleet-refill'
assert json.loads(orders('card-sec')) == [['fleet-refill', 'seat-sec']]
for id in ['card-mid', 'card-new', 'card-old']:
    assert task(id)['status'] == 'open' and task(id)['assignee_id'] is None
    assert orders(id) == '[]'
sql('DROP TRIGGER refill_crash ON fleet_refill_assignments; DROP FUNCTION refill_crash()')
replayed = run_pass()
assert pairs(replayed) == [('card-mid', 'seat-a'), ('card-new', 'seat-b')], replayed
assert json.loads(orders('card-sec')) == [['fleet-refill', 'seat-sec']]
for id, seat in [('card-mid', 'seat-a'), ('card-new', 'seat-b')]:
    assigned = task(id)
    assert assigned['status'] == 'assigned' and assigned['assignee_id'] == seat
    assert assigned['assigner_id'] == 'fleet-refill' and assigned['assignment_authorized'] is False
    assert json.loads(orders(id)) == [['fleet-refill', seat]]
    assert sql("SELECT count(*) FROM task_events WHERE task_id='" + id + "' AND kind='assign' AND actor_id='fleet-refill'") == '1'
body = sql("SELECT body FROM messages WHERE kind='task_order' AND task_id='card-mid'")
assert 'agentboard task claim card-mid' in body and 'returns to the backlog' in body, body
assert task('card-old')['status'] == 'open'
# Further passes converge: no new assignment, order or event.
before = board()
assert pairs(run_pass()) == []
assert board() == before
assert sorted((p['task_id'], p['agent_id']) for p in status()['pending']) == [
    ('card-mid', 'seat-a'), ('card-new', 'seat-b'), ('card-sec', 'seat-sec')]

# Claim deadline: seat-a claims; the others miss. Returns are attributed task
# release events and the cards are eligible on the next pass.
api('tasks/card-mid/claim', {}, actor='seat-a')
sql("UPDATE fleet_refill_assignments SET deadline_at=clock_timestamp()-interval '1 second'")
returned = run_pass()['fleets'][FLEET]
assert returned['returned'] == 2 and returned['pairs'] == [], returned
for id, seat in [('card-new', 'seat-b'), ('card-sec', 'seat-sec')]:
    assert task(id)['status'] == 'open' and task(id)['assignee_id'] is None
    event = json.loads(sql("SELECT jsonb_build_object('actor',actor_id,'body',body) FROM task_events "
                           "WHERE task_id='" + id + "' ORDER BY id DESC LIMIT 1")
                       .replace('\n', ' '))
    assert event['actor'] == 'fleet-refill' and 'claim deadline' in event['body'] and seat in event['body'], event
assert sql("SELECT state FROM fleet_refill_assignments WHERE task_id='card-mid'") == 'claimed'
assert task('card-mid')['status'] == 'in_progress'
assert pairs(run_pass()) == [('card-sec', 'seat-sec'), ('card-new', 'seat-b')]
sql("UPDATE fleet_refill_assignments SET deadline_at=clock_timestamp()-interval '1 second' "
    "WHERE task_id='card-new' AND state='assigned'")
assert run_pass()['fleets'][FLEET]['returned'] == 1
misses = {m['agent_id']: m for m in status()['misses']}
assert misses['seat-b']['count'] == 2 and misses['seat-b']['attention'] is True, misses
assert misses['seat-sec']['count'] == 1 and misses['seat-sec']['attention'] is False, misses

# Deactivation stops new assignments and returns; it releases no claim and
# leaves pending assignments in place, even past their deadline.
assert cli('fleet', 'deactivate', FLEET)['activation']['mode'] == 'inactive'
assert loadout()['activation_state'] == 'not_activatable' and loadout()['enabled'] is False
sql("UPDATE fleet_refill_assignments SET deadline_at=clock_timestamp()-interval '1 second' WHERE state='assigned'")
before = board()
assert FLEET not in run_pass()['fleets']
assert board() == before
assert task('card-mid')['status'] == 'in_progress' and task('card-mid')['assignee_id'] == 'seat-a'
assert task('card-sec')['status'] == 'assigned' and task('card-sec')['assignee_id'] == 'seat-sec'
assert status()['activation']['mode'] == 'inactive' and len(status()['pending']) == 1
history = sql("SELECT string_agg(version_action_name, ',' ORDER BY version_inserted_at) FROM fleet_activations_versions")
assert history == 'activate,change,change,change', history

# A done event wakes refill through Oban: seat-a finishes its card and gets the
# waiting card without any explicit pass.
sql("UPDATE fleet_refill_assignments SET deadline_at=clock_timestamp()+interval '1 hour' WHERE state='assigned'")
cli('fleet', 'activate', FLEET, '--mode', 'live', '--claim-deadline', '1h')
rpc('import Ecto.Query; Oban.cancel_all_jobs(from j in Oban.Job, where: j.queue == "fleet_refill")')
rpc('Oban.resume_queue(queue: :fleet_refill)')
time.sleep(2)
assert task('card-old')['status'] == 'open' and task('card-new')['status'] == 'open'
api('tasks/card-mid/update', {'status': 'done'}, actor='seat-a')
deadline = time.monotonic() + 30
while task('card-old')['status'] != 'assigned' or task('card-new')['status'] != 'assigned':
    assert time.monotonic() < deadline, 'done event did not wake refill'
    time.sleep(0.2)
assert {task('card-old')['assignee_id'], task('card-new')['assignee_id']} == {'seat-a', 'seat-b'}
for id in ['card-old', 'card-new']:
    assert json.loads(orders(id))[-1] == ['fleet-refill', task(id)['assignee_id']]
assert len(json.loads(orders('card-old'))) == 1
print('Fleet refill: deterministic order, eligibility, security labels, idempotent orders, '
      'claim deadline, dry run, deactivation and event wake verified.')
