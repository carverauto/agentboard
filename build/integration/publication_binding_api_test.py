"""Durable exact branch/card attribution at the public API boundary."""
import concurrent.futures
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
env.update(AGENT_ID='codex-binding-alpha', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args, actor='codex-binding-alpha', code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args],
        env=dict(env, AGENT_ID=actor), text=True, capture_output=True, timeout=15)
    assert result.returncode == code, (args, result.stdout, result.stderr)
    return json.loads(result.stderr)['error'] if code else json.loads(result.stdout)


def bind(task, branch='feat/bound', actor='codex-binding-alpha', **extra):
    payload = dict(task=task, repo='fixture/project', head_repo='fixture/project', branch=branch)
    payload.update(extra)
    request = urllib.request.Request(os.environ['AGENTBOARD_URL']+'/api/v1/publications/bind',
        data=json.dumps(payload).encode(), headers={'Content-Type':'application/json',
        'X-Agentboard-Agent':actor,'X-Agentboard-Model':'fixture-model','X-Agentboard-Harness':'codex'})
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read()
        return response.status, json.loads(data) if response.headers.get('Content-Type','').startswith('application/json') else None


for actor in ('codex-binding-alpha', 'codex-binding-beta'):
    ab('agent','register','--name','Invented binding seat',actor=actor)
for task in ('binding-one','binding-two'):
    ab('task','create','--id',task,'--title','Invented binding card','--repo','fixture/project')
    ab('task','claim',task)

before = ab('task','show','binding-one')
first = ab('publication','bind','binding-one','--repo','fixture/project','--branch','feat/bound')
row = first['binding']
assert row['task_id'] == 'binding-one' and row['branch'] == 'feat/bound' and row['generation'] == 1
assert row['bound_by_id'] == 'codex-binding-alpha' and row['repo'] == row['head_repo'] == 'fixture/project'
assert first['idempotent'] is False
assert bind('binding-one') == (200, dict(binding=row, idempotent=True))
assert ab('task','show','binding-one') == before, 'Binding changed source ownership, lease or timeline'

# Exact branch identity cannot be silently rebound to another card, even when
# the caller owns both. Concurrent registrations elect only one durable owner.
assert bind('binding-two')[0] == 409
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    results = list(pool.map(lambda task: bind(task, 'feat/contended'), ('binding-one','binding-two')))
assert sorted(code for code, _ in results) == [200,409], results
assert bind('binding-one', actor='codex-binding-beta')[0] == 409
assert bind('binding-one', repo='fixture/other')[0] == 409
for branch in ('','refs/heads/feature','feat/../bad','feat//bad','feat/@{bad','feat/secret\nvalue'):
    assert bind('binding-one', branch)[0] == 422, branch

ab('task','release','binding-one')
assert bind('binding-one')[0] == 409, 'Retained attribution authorized a released claim'
ab('task','claim','binding-one',actor='codex-binding-beta')
assert bind('binding-one',actor='codex-binding-beta')[0] == 200, 'New live owner could not reuse same-card attribution'
assert bind('binding-one')[0] == 409, 'Previous owner retained publication permission'

ab('task','create','--id','binding-expired','--title','Expiring publication','--repo','fixture/project')
ab('--ttl','200ms','task','claim','binding-expired')
time.sleep(0.3)
assert bind('binding-expired','feat/expired')[0] == 409

with tempfile.NamedTemporaryFile(mode='w') as findings:
    findings.write('Invented decision fixture'); findings.flush()
    ab('decision','request','--task','binding-two','--kind','other','--gate','binding-fixture',
       '--question','Invented held publication question','--findings-file',findings.name)
assert bind('binding-two','feat/held')[0] == 409

def sql(statement):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1',
                                    '-c',statement],text=True).strip()

assert sql('SELECT count(*) FROM delivery_publication_bindings') == '2'
assert sql('SELECT count(*) FROM delivery_publication_bindings_versions') == '2'
assert sql("SELECT count(*) FROM board_action_events WHERE resource='Elixir.Agentboard.Delivery.PublicationBinding'") == '2'
assert json.loads(sql('SELECT provenance FROM delivery_publication_bindings_versions LIMIT 1')) == \
    dict(agent='codex-binding-alpha',model='fixture-model',harness='codex',operation_version=1)

# Attribution/history must be part of the same commit. An audit failure cannot
# leave an unreviewable binding that later authorizes another publication.
sql("CREATE FUNCTION reject_binding_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Delivery.PublicationBinding' THEN RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Invented audit refusal'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER fixture_binding_audit_guard BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_binding_audit()')
assert bind('binding-one','feat/audit-failure',actor='codex-binding-beta')[0] == 409
assert sql('SELECT count(*) FROM delivery_publication_bindings') == '2'
assert sql('SELECT count(*) FROM delivery_publication_bindings_versions') == '2'

print('Durable same-card branch attribution, live-owner fencing, idempotency and concurrent uniqueness passed')
