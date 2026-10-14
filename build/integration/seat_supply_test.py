"""Seat supply (schema 47) at packaged HTTP, CLI, RPC and PostgreSQL boundaries.

The release boots with AGENTBOARD_SEAT_SUPPLY_ENABLED unset, so the seat-supply
queue is paused and the minute schedule is absent. The fixture enables supply in
this isolated server only and drives passes through the public run entry point.
The host daemon runs as `agentboard host fleet serve --once` against stateful
fake herdr and treehouse binaries, so no tab or worktree is real.
"""
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ['AGENTBOARD_URL']
TMP = Path(os.environ['TEST_TMPDIR'])
CAPTAIN = 'fixture-seat-supply-captain-0123456789'
TOKEN = TMP / 'supply-captain.token'
TOKEN.write_text(CAPTAIN + '\n')
TOKEN.chmod(0o600)
MISSING = object()
FLEET = 'supply'
REPO = 'fixture/supply'


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (expression, result.stdout, result.stderr)
    return result.stdout.strip()


def api(path, data=MISSING, *, captain=False, bearer=None, actor='supply-captain',
        status=200, method=None):
    headers = {'X-Agentboard-Agent': actor, 'X-Agentboard-Model': 'fixture-model',
               'X-Agentboard-Harness': 'codex', 'Content-Type': 'application/json'}
    if captain:
        bearer = CAPTAIN
    if bearer:
        headers['Authorization'] = 'Bearer ' + bearer
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


def cli(*args, code=0, env=None):
    base = dict(os.environ, AGENTBOARD_CAPTAIN_TOKEN_FILE=str(TOKEN), AGENT_ID='',
                AGENTBOARD_MODEL='', AGENTBOARD_HARNESS='')
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env={**base, **(env or {})},
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert CAPTAIN not in result.stdout + result.stderr, 'Capability leaked'
    return result


def run_pass():
    output = rpc('IO.puts("SUPPLY_RESULT=" <> Jason.encode!(elem(Agentboard.SeatSupply.run_all(), 1)))')
    line = [l for l in output.splitlines() if l.startswith('SUPPLY_RESULT=')][-1]
    return json.loads(line.split('=', 1)[1])


def intents(where='true'):
    return json.loads(sql("SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'seat',seat_id,'state',state,"
                          "'pane',pane_id,'lease',lease_path,'reason',reason) ORDER BY created_at,seat_id),'[]') "
                          "FROM fleet_launch_intents WHERE " + where))


def outstanding():
    return [(i['seat'], i['state']) for i in intents("closed_at IS NULL")]


def board():
    return sql("SELECT jsonb_build_object('tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t),"
               "'events',(SELECT count(*) FROM task_events),'messages',(SELECT count(*) FROM messages))")


def stale_seats():
    sql("UPDATE agents SET last_heartbeat=clock_timestamp()-interval '1 day' WHERE kind='seat'")


rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
assert api('meta')['schema_version'] == api('meta')['required_schema_version'] == 48

api('agents/register', {'name': 'supply-captain'}, actor='supply-captain')
for seat in ['seat-a', 'seat-b']:
    api('agents/register', {'name': seat, 'kind': 'seat'}, actor=seat)
    api('agents/' + seat + '/scope', {'allowed_repos': [REPO], 'required_labels': [], 'allowed_labels': [],
                                      'revision': 0}, method='PUT', captain=True)
seats = [{'seat_id': s, 'agent_id': s, 'harness': 'codex', 'desired_host_id': 'host-a',
          'desired_model': 'model', 'desired_effort': 'effort', 'scope_revision': 1}
         for s in ['seat-a', 'seat-b']]
api('fleets/' + FLEET + '/loadout', {'revision': 0, 'idempotency_key': 'supply-1', 'seats': seats},
    method='PUT', captain=True)
for card in ['card-1', 'card-2', 'card-3']:
    api('tasks', {'id': card, 'title': 'Supply ' + card, 'repo': REPO, 'priority': 1})
stale_seats()

# Seat counts are captain settings on the activation; they default to 0 and
# are validated.
first = json.loads(cli('fleet', 'activate', FLEET, '--mode', 'live').stdout)['activation']
assert first['requested_seats'] == 0 and first['max_seats'] == 0, first
for bad in [{'mode': 'live', 'requested_seats': 33}, {'mode': 'live', 'max_seats': -1},
            {'mode': 'live', 'max_seats': '2'}]:
    api('fleets/' + FLEET + '/activate', bad, captain=True, status=422)

# Default off: the queue is paused and a pass writes nothing, even for a live
# fleet with seats requested and backlog above its live seats.
assert 'SUPPLY_PAUSED=true' in rpc('IO.puts("SUPPLY_PAUSED=#{Oban.check_queue(queue: :seat_supply).paused}")')
cli('fleet', 'activate', FLEET, '--mode', 'live', '--requested-seats', '2', '--max-seats', '2')
assert run_pass() == {'enabled': False}
assert intents() == []
rpc('Application.put_env(:agentboard, :seat_supply_enabled, true)')

# Requested seats unset: wanted is 0 and nothing is written.
cli('fleet', 'activate', FLEET, '--mode', 'live', '--requested-seats', '0')
assert run_pass()['fleets'][FLEET]['wanted_seats'] == 0 and intents() == []

# Dry run records one would-launch intent per missing seat, writes no board
# state, never repeats an intent, and lists none to a host.
cli('fleet', 'activate', FLEET, '--mode', 'dry-run', '--requested-seats', '2')
before = board()
dry = run_pass()['fleets'][FLEET]
assert dry['would_launch'] == ['seat-a', 'seat-b'] and dry['live_seats'] == 0, dry
assert run_pass()['fleets'][FLEET]['would_launch'] == ['seat-a', 'seat-b']
assert outstanding() == [('seat-a', 'dry_run'), ('seat-b', 'dry_run')]
assert board() == before

# Host enrollment is captain-only; the token is returned once and only its
# hash is stored. The launch cap defaults to what the captain sets.
api('fleet-hosts/host-a', {'launch_cap': 0}, method='PUT', status=403)
api('fleet-hosts/host-a', {'launch_cap': 33}, method='PUT', captain=True, status=422)
host_token_file = TMP / 'host-a.token'
enrolled = json.loads(cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '0',
                          '--token-file', str(host_token_file)).stdout)
host_token = host_token_file.read_text().strip()
assert 'token' not in enrolled and enrolled['host']['launch_cap'] == 0, enrolled
assert oct(host_token_file.stat().st_mode & 0o777) == '0o600'
assert host_token not in sql('SELECT token_hash FROM fleet_hosts')
listed = api('fleet-hosts/host-a/launch-intents', bearer=host_token)
assert listed['intents'] == [] and listed['host']['launch_cap'] == 0, listed
api('fleet-hosts/host-a/launch-intents', bearer='wrong-token-0123456789abcdefghijklmno', status=401)
api('fleet-hosts/host-a/launch-intents', status=401)
# A dry-run intent is not reservable even if a host guesses its id.
dry_id = intents("state='dry_run'")[0]['id']
api('fleet-hosts/host-a/launch-intents/' + dry_id + '/reserve', {}, bearer=host_token, status=409)

# Live: dry-run intents are superseded and one pending intent per missing seat
# is written; repeated passes add none while they are outstanding.
cli('fleet', 'activate', FLEET, '--mode', 'live')
live = run_pass()['fleets'][FLEET]
assert live['written'] == ['seat-a', 'seat-b'] and live['wanted_seats'] == 2, live
assert run_pass()['fleets'][FLEET]['written'] == []
assert outstanding() == [('seat-a', 'pending'), ('seat-b', 'pending')]
assert [i['state'] for i in intents("state='superseded'")] == ['superseded', 'superseded']
pending = {i['seat_id']: i for i in api('fleet-hosts/host-a/launch-intents', bearer=host_token)['intents']}
assert set(pending) == {'seat-a', 'seat-b'} and all('argv' not in i for i in pending.values())
seat_a = pending['seat-a']['id']

# The cap holds reservations: 0 reserves nothing; at 1 the second waits.
api('fleet-hosts/host-a/launch-intents/' + seat_a + '/reserve', {}, bearer=host_token, status=409)
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '1')
reserved = api('fleet-hosts/host-a/launch-intents/' + seat_a + '/reserve', {}, bearer=host_token)['intent']
assert reserved['state'] == 'reserved'
assert api('fleet-hosts/host-a/launch-intents/' + seat_a + '/reserve', {}, bearer=host_token)['intent']['state'] == 'reserved'
api('fleet-hosts/host-a/launch-intents/' + pending['seat-b']['id'] + '/reserve', {}, bearer=host_token, status=409)

# Reports follow the state machine; launched needs a pane, others a reason.
report = 'fleet-hosts/host-a/launch-intents/' + seat_a + '/report'
for bad in [{'state': 'launched'}, {'state': 'failed'}, {'state': 'launched', 'pane_id': 'p', 'argv': ['sh']},
            {'state': 'pending', 'reason': 'x'}]:
    api(report, bad, bearer=host_token, status=422)
api(report, {'state': 'closed', 'reason': 'not launched yet'}, bearer=host_token, status=409)
uncertain = {'state': 'uncertain', 'reason': 'pane started; no lease yet', 'pane_id': 'manual:p1'}
assert api(report, uncertain, bearer=host_token)['intent']['state'] == 'uncertain'
assert api(report, uncertain, bearer=host_token)['intent']['state'] == 'uncertain'
api(report, {'state': 'failed', 'reason': 'too late'}, bearer=host_token, status=409)
launched = api(report, {'state': 'launched', 'pane_id': 'manual:p1', 'lease_path': '/pool/1'}, bearer=host_token)['intent']
assert launched['state'] == 'launched' and launched['lease_path'] == '/pool/1' and launched['launched_at']
# Another host's token cannot see or touch this host's intents.
other = TMP / 'host-b.token'
cli('fleet', 'host', 'set', 'host-b', '--launch-cap', '1', '--token-file', str(other))
api('fleet-hosts/host-b/launch-intents/' + seat_a + '/report', {'state': 'closed', 'reason': 'x'},
    bearer=other.read_text().strip(), status=404)
api('fleet-hosts/host-a/launch-intents', bearer=other.read_text().strip(), status=401)

# A loadout change fences the still-pending seat-b intent; the next pass
# writes its successor at the new revision.
loadout = api('fleets/' + FLEET + '/loadout', captain=True)['loadout']
api('fleets/' + FLEET + '/loadout', {'revision': loadout['revision'], 'idempotency_key': 'supply-2',
    'seats': seats}, method='PUT', captain=True)
api('fleet-hosts/host-a/launch-intents/' + pending['seat-b']['id'] + '/reserve', {}, bearer=host_token, status=409)
assert intents("seat_id='seat-b' AND state='superseded'")
run_pass()
assert outstanding() == [('seat-a', 'launched'), ('seat-b', 'pending')]

# The host daemon: stateful fake herdr and treehouse. `pane run` stands for
# launch-seat taking a Treehouse lease held by the seat's agent ID.
state = TMP / 'fake-host.json'
state.write_text(json.dumps({'workspaces': [], 'tabs': [], 'panes': [], 'leases': [], 'runs': []}))
fake = TMP / 'bin'
fake.mkdir()
(fake / 'herdr').write_text('''#!/usr/bin/env python3
import json, sys
path = %r
s = json.load(open(path))
a = sys.argv[1:]
def opt(name):
    return a[a.index(name) + 1]
def out(result):
    json.dump(s, open(path, 'w')); print(json.dumps({'result': result})); sys.exit(0)
cmd = a[0] + ' ' + a[1]
if cmd == 'agent list': out({'agents': []})
if cmd == 'workspace list': out({'workspaces': s['workspaces']})
if cmd == 'workspace create':
    w = {'workspace_id': 'w%%d' %% (len(s['workspaces']) + 1), 'label': opt('--label')}
    s['workspaces'].append(w); out({'workspace': w})
if cmd == 'tab list': out({'tabs': [t for t in s['tabs'] if t['workspace_id'] == opt('--workspace')]})
if cmd == 'tab create':
    n = len(s['tabs']) + 1
    env = dict(e.split('=', 1) for e in a[a.index('--env') + 1::2] if '=' in e)
    t = {'tab_id': 't%%d' %% n, 'label': opt('--label'), 'workspace_id': opt('--workspace'), 'agent': env.get('AGENT_ID')}
    s['tabs'].append(t); s['panes'].append({'pane_id': 'p%%d' %% n, 'tab_id': t['tab_id'], 'workspace_id': t['workspace_id']})
    out({'tab': t, 'root_pane': {'pane_id': 'p%%d' %% n}})
if cmd == 'pane list': out({'panes': [p for p in s['panes'] if p['workspace_id'] == opt('--workspace')]})
if cmd == 'pane run':
    tab = [p['tab_id'] for p in s['panes'] if p['pane_id'] == a[2]][0]
    agent = [t['agent'] for t in s['tabs'] if t['tab_id'] == tab][0]
    s['runs'].append(a[3]); s['leases'].append({'path': '/pool/.treehouse/%%d/repo' %% len(s['runs']), 'lease_holder': agent, 'status': 'leased'})
    out({})
print('unexpected herdr ' + ' '.join(a), file=sys.stderr); sys.exit(2)
''' % str(state))
(fake / 'treehouse').write_text('''#!/usr/bin/env python3
import json, sys
if sys.argv[1:] == ['--version']: print('v3.1.2'); sys.exit(0)
if sys.argv[1] == 'status': print(json.dumps(json.load(open(%r))['leases'])); sys.exit(0)
sys.exit(2)
''' % str(state))
for tool in ['herdr', 'treehouse']:
    (fake / tool).chmod(0o755)
launcher = TMP / 'launch-seat'
launcher.write_text('#!/bin/sh\nexit 0\n')
launcher.chmod(0o755)
for directory in ['repo', 'pool']:
    (TMP / directory).mkdir()
harnesses = TMP / 'harnesses.json'
harnesses.write_text(json.dumps({'version': 1, 'launcher': str(launcher), 'repo': str(TMP / 'repo'),
                                 'root': str(TMP / 'pool'), 'brief_dir': str(TMP / 'briefs'),
                                 'harnesses': {'codex': {'model': 'gpt-5.5', 'argv': ['codex', '{brief}']}}}))
harnesses.chmod(0o600)


def serve(journal=None):
    result = cli('host', 'fleet', 'serve', '--host-id', 'host-a', '--token-file', str(host_token_file),
                 '--harnesses', str(harnesses), '--journal', str(journal or (TMP / 'journal.json')), '--once',
                 '--lease-wait', '1s', env={'AGENTBOARD_HERDR_BIN': str(fake / 'herdr'),
                                            'AGENTBOARD_TREEHOUSE_BIN': str(fake / 'treehouse')})
    assert host_token not in result.stdout + result.stderr, 'Host token leaked'
    return json.loads(result.stdout)


# One pass: seat-a's manual pane is not on this host, so it is reported closed;
# seat-b is reserved and launched in a new tab with the lease it took.
actions = serve()['actions']
assert [(a['agent'], a['action']) for a in actions] == [('seat-a', 'closed'), ('seat-b', 'reserved'),
                                                       ('seat-b', 'launched')], actions
fake_state = json.loads(state.read_text())
assert [(t['label'], t['agent']) for t in fake_state['tabs']] == [('seat-b', 'seat-b')]
command = fake_state['runs'][0]
assert ' --repo ' in command and ' --brief ' in command and command.endswith(" -- codex '{brief}'"), command
seat_b = intents("seat_id='seat-b' AND closed_at IS NULL")[0]
assert seat_b['state'] == 'launched' and seat_b['pane'] == 'p1' and seat_b['lease'] == '/pool/.treehouse/1/repo', seat_b
assert intents("seat_id='seat-a' AND state='closed'")
# A second pass opens nothing new: the launched pane is still there.
assert serve()['actions'] == []
assert len(json.loads(state.read_text())['tabs']) == 1

# Reap closing the pane (here: removing it) makes the daemon report it gone,
# and the server closes the intent. Reap itself writes nothing to the board.
fake_state = json.loads(state.read_text())
fake_state['panes'] = []
state.write_text(json.dumps(fake_state))
assert [(a['agent'], a['action']) for a in serve()['actions']] == [('seat-b', 'closed')]
assert outstanding() == []

# A launched seat whose identity was live and then went stale is closed by the
# server pass; a seat that never registered is not.
run_pass()
assert sorted(outstanding()) == [('seat-a', 'pending'), ('seat-b', 'pending')]
for intent in api('fleet-hosts/host-a/launch-intents', bearer=host_token)['intents']:
    sql("UPDATE fleet_launch_intents SET state='launched',reserved_at=clock_timestamp(),launched_at=clock_timestamp(),"
        "pane_id='p' WHERE id='" + intent['id'] + "'")
run_pass()
assert sorted(outstanding()) == [('seat-a', 'launched'), ('seat-b', 'launched')]
sql("UPDATE agents SET last_heartbeat=clock_timestamp()-interval '1 day' WHERE id='seat-a'")
sql("UPDATE fleet_launch_intents SET launched_at=clock_timestamp()-interval '2 days' WHERE seat_id='seat-a' AND state='launched'")
run_pass()
assert intents("seat_id='seat-a' AND state='closed' AND reason LIKE '%identity%'")

# Captain abandon frees a stuck seat; deactivation stops new intents and
# leaves open ones in place.
seat_b_open = intents("seat_id='seat-b' AND closed_at IS NULL")[0]['id']
cli('fleet', 'supply', 'abandon', FLEET, seat_b_open, '--reason', 'pane closed by hand')
assert intents("id='" + seat_b_open + "'")[0]['state'] == 'abandoned'
cli('fleet', 'supply', 'abandon', FLEET, seat_b_open, '--reason', 'again', code=4)
cli('fleet', 'deactivate', FLEET)
before_intents = intents()
assert FLEET not in run_pass()['fleets']
assert intents() == before_intents
status = json.loads(cli('fleet', 'supply', 'status', FLEET).stdout)['supply']
assert status['seat_supply_enabled'] is True and status['demand'] is None
assert status['activation']['requested_seats'] == 2 and status['activation']['max_seats'] == 2
assert [h['host_id'] for h in status['hosts']] == ['host-a'] and status['hosts'][0]['enrolled'] is True
assert 'token_hash' not in json.dumps(status)

# Host tokens stay the only credential on these routes in every auth mode.
for mode in ('observe', 'enforce'):
    rpc('Application.put_env(:agentboard, :agent_auth_mode, ' + json.dumps(mode) + ')')
    listed = api('fleet-hosts/host-a/launch-intents', bearer=host_token)
    assert listed['host']['host_id'] == 'host-a' and 'token_hash' not in json.dumps(listed), listed
    assert all('argv' not in intent for intent in listed['intents']), listed
    api('fleet-hosts/host-a/launch-intents', bearer='wrong-token-0123456789abcdefghijklmno', status=401)
    api('fleet-hosts/host-a/launch-intents', bearer=CAPTAIN, status=401)
    api('fleet-hosts/host-a/launch-intents', status=401)
rpc('Application.put_env(:agentboard, :agent_auth_mode, "off")')


def age(intent_id, column, interval):
    sql("UPDATE fleet_launch_intents SET " + column + "=clock_timestamp()-interval '" + interval
        + "' WHERE id='" + intent_id + "'")


def open_ids(seat):
    return intents("seat_id='" + seat + "' AND closed_at IS NULL")


# Pending intents expire after 10 minutes and a successor is written. A
# reserved intent the same age keeps the seat, and so does an uncertain one.
cli('fleet', 'activate', FLEET, '--mode', 'live', '--requested-seats', '2', '--max-seats', '2')
stale_seats()
run_pass()
pending_ids = {i['seat']: i['id'] for i in intents("state='pending'")}
assert set(pending_ids) == {'seat-a', 'seat-b'}, pending_ids
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '1')
api('fleet-hosts/host-a/launch-intents/' + pending_ids['seat-a'] + '/reserve', {}, bearer=host_token)
for seat in ('seat-a', 'seat-b'):
    age(pending_ids[seat], 'created_at', '11 minutes')
run_pass()
still_a = open_ids('seat-a')
assert len(still_a) == 1 and still_a[0]['id'] == pending_ids['seat-a'] and still_a[0]['state'] == 'reserved', still_a
expired_b = intents("seat_id='seat-b' AND state='expired'")
assert expired_b and '600' in (expired_b[-1]['reason'] or ''), expired_b
reborn_b = open_ids('seat-b')
assert len(reborn_b) == 1 and reborn_b[0]['state'] == 'pending' and reborn_b[0]['id'] != pending_ids['seat-b'], reborn_b
api('fleet-hosts/host-a/launch-intents/' + pending_ids['seat-a'] + '/report',
    {'state': 'uncertain', 'reason': 'pane may exist', 'pane_id': 'manual:old'}, bearer=host_token)
age(pending_ids['seat-a'], 'created_at', '11 minutes')
run_pass()
still_uncertain = open_ids('seat-a')
assert len(still_uncertain) == 1 and still_uncertain[0]['id'] == pending_ids['seat-a'] and still_uncertain[0]['state'] == 'uncertain', still_uncertain

# A failed launch occupies the cooldown: 14 minutes is still too soon for a
# successor, 16 minutes lets the next pass write one.
cli('fleet', 'supply', 'abandon', FLEET, pending_ids['seat-a'], '--reason', 'free the cap')
api('fleet-hosts/host-a/launch-intents/' + reborn_b[0]['id'] + '/reserve', {}, bearer=host_token)
api('fleet-hosts/host-a/launch-intents/' + reborn_b[0]['id'] + '/report',
    {'state': 'failed', 'reason': 'harness refused'}, bearer=host_token)
run_pass()
assert open_ids('seat-b') == [], open_ids('seat-b')
age(reborn_b[0]['id'], 'closed_at', '14 minutes')
run_pass()
assert open_ids('seat-b') == [], 'successor written inside the 15 minute cooldown'
age(reborn_b[0]['id'], 'closed_at', '16 minutes')
run_pass()
cooled = open_ids('seat-b')
assert len(cooled) == 1 and cooled[0]['state'] == 'pending', cooled

# The daemon relaunches the same reserved intent only when the journal shows
# pane creation never started. A spawning entry with no pane stays uncertain.
for row in intents("closed_at IS NULL"):
    if row['state'] != 'pending':
        cli('fleet', 'supply', 'abandon', FLEET, row['id'], '--reason', 'clear before journal check')
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '0')
# Drop leftover occupying intents so the pass can write fresh pending ones.
for row in list(intents("closed_at IS NULL")):
    cli('fleet', 'supply', 'abandon', FLEET, row['id'], '--reason', 'clear before journal check')
stale_seats()
run_pass()
fresh = {i['seat']: i['id'] for i in intents("state='pending'")}
assert set(fresh) == {'seat-a', 'seat-b'}, fresh
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '1')
api('fleet-hosts/host-a/launch-intents/' + fresh['seat-a'] + '/reserve', {}, bearer=host_token)
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '0')
state.write_text(json.dumps({'workspaces': [], 'tabs': [], 'panes': [], 'leases': [], 'runs': []}))
relaunch_journal = TMP / 'journal-relaunch.json'
relaunch_journal.write_text(json.dumps({'intents': {fresh['seat-a']: {'agent': 'seat-a', 'step': 'reserving',
                                                                       'updated_at': '2026-10-13T00:00:00Z'}}}))
relaunch = serve(relaunch_journal)
assert [(a['agent'], a['action']) for a in relaunch['actions']] == [('seat-a', 'launched')], relaunch
assert [t['label'] for t in json.loads(state.read_text())['tabs']] == ['seat-a']
assert open_ids('seat-b')[0]['state'] == 'pending'
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '1')
api('fleet-hosts/host-a/launch-intents/' + fresh['seat-b'] + '/reserve', {}, bearer=host_token)
cli('fleet', 'host', 'set', 'host-a', '--launch-cap', '0')
tabs_before = len(json.loads(state.read_text())['tabs'])
stuck_journal = TMP / 'journal-spawning.json'
stuck_journal.write_text(json.dumps({'intents': {fresh['seat-b']: {'agent': 'seat-b', 'step': 'spawning',
                                                                    'updated_at': '2026-10-13T00:00:00Z'}}}))
stuck = serve(stuck_journal)
assert [(a['agent'], a['action']) for a in stuck['actions'] if a['agent'] == 'seat-b'] == [('seat-b', 'uncertain')], stuck
assert len(json.loads(state.read_text())['tabs']) == tabs_before
again = serve(stuck_journal)
assert [(a['agent'], a['action']) for a in again['actions'] if a['agent'] == 'seat-b'] == [('seat-b', 'kept')], again
assert len(json.loads(state.read_text())['tabs']) == tabs_before
assert open_ids('seat-b')[0]['id'] == fresh['seat-b'] and open_ids('seat-b')[0]['state'] == 'uncertain'

print('Seat supply: default off, dry run, captain seat counts and host enrollment, cap, fencing, '
      'report state machine, host daemon launch with fake Herdr/Treehouse, pane-gone and stale '
      'identity close, expiry, cooldown, journal relaunch, auth modes, abandon and deactivation verified.')
