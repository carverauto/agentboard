"""Durable PR submission through CLI/API and the public discovery domain.

Protects identity/attribution independently of mutable task ownership, real
transaction rollback, terminal-task discovery, concurrent replay and scoped
locks. Existing board tests own lifecycle/transport contracts; this target
uses the same packaged-release/TLS-PG fixture without a test-only API seam.
"""
import concurrent.futures
import json
import os
import subprocess
import time

cli_env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
cli_env.update(AGENT_ID='alpha', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args, actor='alpha', model='fixture-model', code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args],
                            env=dict(cli_env, AGENT_ID=actor, AGENTBOARD_MODEL=model), capture_output=True,
                            text=True, timeout=20)
    assert result.returncode == code, (args, result.stdout, result.stderr)
    return json.loads(result.stderr if code else result.stdout)


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def discover(cursor=None, limit=2):
    # Real domain seam used by the subsequent scheduler, in the running release.
    cursor_expr = 'nil' if cursor is None else json.dumps(cursor)
    expression = (f'{{:ok, page}} = Agentboard.Delivery.discover({cursor_expr}, {limit}); '
                  'IO.puts("INVENTORY_RESULT=" <> Jason.encode!(page))')
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(next(line.split('=', 1)[1] for line in result.stdout.splitlines()
                           if line.startswith('INVENTORY_RESULT=')))


def link(task, number, owner='CarverAuto', repo='AgentBoard', actor='alpha'):
    return ab('task', 'link', task, '--pr',
              f'https://github.com/{owner}/{repo}/pull/{number}', actor=actor)['task']


for actor in ['alpha', 'beta']:
    ab('agent', 'register', actor=actor)
first = ab('task', 'create', '--id', 'submission', '--title', 'First submitter',
           '--pr', 'https://github.com/CarverAuto/AgentBoard/pull/42')['task']
assert sql("SELECT owner||'/'||repo||'/'||number FROM delivery_pull_requests") == 'carverauto/agentboard/42'
assert sql("SELECT submitted_by_id||','||attribution FROM delivery_task_links") == 'alpha,submission'
# Model attribution is captured at link time, never fetched from the agent later.
ab('agent', 'register', '--name', 'Changed name', actor='alpha', model='changed-model')
assert sql("SELECT model FROM delivery_task_links") == 'fixture-model'
ab('task', 'claim', first['id'])
ab('task', 'handoff', first['id'], '--to', 'beta', '--body', 'Different owner')
ab('task', 'claim', first['id'], actor='beta')
link(first['id'], 42, owner='carverauto', repo='agentboard', actor='beta')
assert sql("SELECT submitted_by_id FROM delivery_task_links WHERE task_id='submission'") == 'alpha'
assert sql('SELECT count(*) FROM delivery_pull_requests_versions') == '1'
assert sql('SELECT count(*) FROM delivery_task_links') == '1'
# Clearing/replacing a task's current URL retains the old durable obligation.
ab('task', 'link', first['id'], '--pr', '', actor='beta')
link(first['id'], 43, actor='beta')
assert sql("SELECT count(*) FROM delivery_task_links WHERE task_id='submission'") == '2'

# Multiple task links/case aliases race to one canonical PR record.
def create_alias(i):
    actor = 'alpha' if i % 2 else 'beta'
    return ab('task', 'create', '--id', f'alias-{i}', '--title', 'Alias fixture',
              '--pr', f'https://github.com/{"CarverAuto" if i % 2 else "carverauto"}/agentboard/pull/42', actor=actor)
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    list(pool.map(create_alias, range(4)))
assert sql('SELECT count(*) FROM delivery_pull_requests') == '2'
assert sql("SELECT count(*) FROM delivery_task_links WHERE pull_request_id=(SELECT id FROM delivery_pull_requests WHERE number='42')") == '5'
assert sql("SELECT count(*) FROM delivery_pull_requests_versions WHERE version_source_id=(SELECT id FROM delivery_pull_requests WHERE number='42')") == '1'

# A failed inventory audit must roll back task/version/timeline and PR/link writes.
ab('task', 'create', '--id', 'rollback', '--title', 'Atomic submission')
before = ab('task', 'show', 'rollback')
counts = sql("SELECT (SELECT count(*) FROM tasks_versions)||','||(SELECT count(*) FROM board_action_events)||','||(SELECT count(*) FROM delivery_pull_requests_versions)")
sql("CREATE FUNCTION reject_inventory_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource='Elixir.Agentboard.Delivery.TaskLink' THEN RAISE EXCEPTION 'Synthetic inventory audit failure'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER reject_inventory_fixture BEFORE INSERT ON board_action_events FOR EACH ROW EXECUTE FUNCTION reject_inventory_fixture()')
link_result = ab('task', 'link', 'rollback', '--pr', 'https://github.com/carverauto/agentboard/pull/99', code=1)
assert link_result['error']['code'] == 'server_error'
assert ab('task', 'show', 'rollback') == before
assert sql("SELECT (SELECT count(*) FROM tasks_versions)||','||(SELECT count(*) FROM board_action_events)||','||(SELECT count(*) FROM delivery_pull_requests_versions)") == counts
assert sql("SELECT count(*) FROM delivery_pull_requests WHERE number='99'") == '0'
sql('DROP TRIGGER reject_inventory_fixture ON board_action_events; DROP FUNCTION reject_inventory_fixture()')
link('rollback', 99)
for invalid_url in ['https://github.com/carverauto/agentboard/pull/99\n', 'https://github.com/' + 'x' * 2048 + '/agentboard/pull/99']:
    ab('task', 'link', 'rollback', '--pr', invalid_url, code=2)

# Invented pre-cutoff history includes terminal work and unknown attribution.
# Status events copy the URL but must not be mistaken for its submission.
for task, status in [('legacy-done', 'done'), ('legacy-cancelled', 'cancelled'), ('legacy-unknown', 'done')]:
    sql(f"INSERT INTO tasks(id,title,status,assignee_id,pr_url) VALUES ('{task}','Legacy fixture','{status}','beta','https://github.com/CARVERAUTO/AGENTBOARD/pull/77')")
    if task != 'legacy-unknown':
        intro = json.dumps({'before': None, 'after': {'pr_url': 'https://github.com/CARVERAUTO/AGENTBOARD/pull/77'}})
        unchanged = json.dumps({'before': {'pr_url': 'https://github.com/CARVERAUTO/AGENTBOARD/pull/77'}, 'after': {'pr_url': 'https://github.com/CARVERAUTO/AGENTBOARD/pull/77'}})
        sql(f"INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision,data) VALUES ('{task}','alpha','legacy-model','codex','create',1,'{intro}'),('{task}','beta','later-model','codex','update',2,'{unchanged}')")
# A pre-cutoff link repeated by another agent must use the earlier submission
# even before a reconciliation sweep has created its durable link.
sql("INSERT INTO tasks(id,title,pr_url) VALUES ('legacy-active','Active legacy','https://github.com/CARVERAUTO/AGENTBOARD/pull/77')")
intro = json.dumps({'before': None, 'after': {'pr_url': 'https://github.com/CARVERAUTO/AGENTBOARD/pull/77'}})
sql(f"INSERT INTO task_events(task_id,actor_id,model,harness,kind,new_revision,data) VALUES ('legacy-active','alpha','legacy-model','codex','create',1,'{intro}')")
link('legacy-active', 77, actor='beta')
assert sql("SELECT submitted_by_id||','||attribution FROM delivery_task_links WHERE task_id='legacy-active'") == 'alpha,timeline'
sql("INSERT INTO task_archives(id,archived_at,revision,changed_by) VALUES ('legacy-done',clock_timestamp(),1,'fixture-captain')")
legacy_before = sql("SELECT md5(string_agg(row_to_json(t)::text,'|' ORDER BY id)) FROM tasks t WHERE id LIKE 'legacy-%'")
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    list(pool.map(lambda _: discover(), range(2)))
cursor = None
scanned = 0
while True:
    page = discover(cursor)
    scanned += page['scanned']
    cursor = page['next_cursor']
    if cursor is None:
        break
assert scanned == int(sql('SELECT count(*) FROM tasks WHERE pr_url IS NOT NULL'))
assert sql("SELECT count(*) FROM delivery_pull_requests WHERE number='77'") == '1'
assert sql("SELECT count(*) FROM delivery_task_links WHERE task_id LIKE 'legacy-%'") == '4'
assert sql("SELECT submitted_by_id||','||model||','||attribution FROM delivery_task_links WHERE task_id='legacy-done'") == 'alpha,legacy-model,timeline'
assert sql("SELECT submitted_by_id IS NULL AND source_event_id IS NULL AND linked_at IS NULL AND attribution='unknown' FROM delivery_task_links WHERE task_id='legacy-unknown'") == 't'
assert sql("SELECT md5(string_agg(row_to_json(t)::text,'|' ORDER BY id)) FROM tasks t WHERE id LIKE 'legacy-%'") == legacy_before
counts = sql("SELECT (SELECT count(*) FROM delivery_task_links)||','||(SELECT count(*) FROM delivery_pull_requests_versions)||','||(SELECT count(*) FROM board_action_events WHERE resource LIKE 'Elixir.Agentboard.Delivery.%')")
discover(None, 100)
assert sql("SELECT (SELECT count(*) FROM delivery_task_links)||','||(SELECT count(*) FROM delivery_pull_requests_versions)||','||(SELECT count(*) FROM board_action_events WHERE resource LIKE 'Elixir.Agentboard.Delivery.%')") == counts

# An unrelated PR can commit while another canonical identity lock is held.
lock_env = dict(os.environ, PGAPPNAME='inventory-lock-fixture')
# Pause the real submission at a database trigger while its task/PR/audit
# transaction is live. The unrelated caller uses the same agent and resource.
key = 7001042
sql("CREATE FUNCTION hold_inventory_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.number='101' THEN PERFORM pg_advisory_xact_lock(7001042); END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER hold_inventory_fixture BEFORE INSERT ON delivery_pull_requests FOR EACH ROW EXECUTE FUNCTION hold_inventory_fixture()')
locker = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1',
                           '-c', f'BEGIN; SELECT pg_advisory_xact_lock({key}); SELECT pg_sleep(4); COMMIT;'],
                          env=lock_env, stdout=subprocess.PIPE, text=True)
for _ in range(100):
    if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='inventory-lock-fixture' AND wait_event='PgSleep'") == '1':
        break
    time.sleep(.01)
else:
    raise AssertionError('Canonical PR lock not acquired')
ab('task', 'create', '--id', 'lock-waiter', '--title', 'Held identity')
with concurrent.futures.ThreadPoolExecutor(1) as pool:
    waiting = pool.submit(link, 'lock-waiter', 101)
    time.sleep(.1)
    started = time.monotonic()
    ab('task', 'create', '--id', 'unrelated', '--title', 'Independent PR', '--pr',
       'https://github.com/carverauto/agentboard/pull/100')
    assert time.monotonic() - started < 2 and not waiting.done()
    waiting.result()
assert locker.wait(timeout=10) == 0
sql('DROP TRIGGER hold_inventory_fixture ON delivery_pull_requests; DROP FUNCTION hold_inventory_fixture()')

for table in ['delivery_task_links', 'delivery_pull_requests', 'delivery_pull_requests_versions']:
    for statement in [f'UPDATE {table} SET id=id', f'DELETE FROM {table}', f'TRUNCATE {table} CASCADE']:
        result = subprocess.run([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', statement], capture_output=True, text=True)
        assert result.returncode != 0 and 'Task history is append-only' in result.stderr, (table, statement, result.stderr)
print('Canonical PR inventory, durable submitting agents, terminal discovery/replay, atomic rollback and unrelated-PR lock isolation passed')
