"""Real scheduled jobs, rollback catch-up and shared provider admission.

Poll exclusivity belongs to delivery_polling_test. This fixture owns the
asynchronous path: no task/current-pointer/green filter may end scheduling.
All records are invented, executed on the packaged release and TLS PostgreSQL.
"""
import concurrent.futures
import hashlib
import json
import os
import subprocess
import time


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def wait_for(query, expected, seconds=45):
    deadline = time.monotonic() + seconds
    actual = None
    while time.monotonic() < deadline:
        actual = sql(query)
        if actual == expected:
            return
        time.sleep(.15)
    jobs = sql("SELECT json_agg(json_build_object('state',state,'args',args,'errors',errors)) FROM oban_jobs WHERE queue IN ('delivery_scheduler','delivery_polling')")
    raise AssertionError((query, expected, actual, jobs))


cli_env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
cli_env.update(AGENT_ID='schedule-owner', AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex')


def ab(*args, success=True):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=cli_env,
                            capture_output=True, text=True, timeout=25)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)
    assert result.returncode != 0, (args, result.stdout)


worker = 'Agentboard.Delivery.PollWorker'
scheduler = 'Agentboard.Delivery.ScheduleDue'
active = "('available','scheduled','executing','retryable')"
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
ab('agent', 'register')
ab('task', 'create', '--id', 'terminal-pr', '--title', 'Terminal archived PR', '--pr', 'https://github.com/fixture/repo/pull/501')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}'", '1')
ab('task', 'claim', 'terminal-pr')
ab('task', 'update', 'terminal-pr', '--status', 'done')
sql("INSERT INTO task_archives(id,archived_at,revision,changed_by) VALUES ('terminal-pr',clock_timestamp(),1,'fixture-captain')")
# An existing passing projection must not suppress a later poll. The fixture
# supplies evidence; no scheduler action is allowed to manufacture it.
sql("UPDATE delivery_poll_states SET ci_state='passing',head_sha='fixture-head',observed_at=clock_timestamp()")
source_before = sql("SELECT jsonb_build_object('task',(SELECT row_to_json(t) FROM tasks t WHERE id='terminal-pr'),'pr',(SELECT row_to_json(t) FROM delivery_pull_requests t),'links',(SELECT json_agg(t) FROM delivery_task_links t),'events',(SELECT json_agg(t) FROM task_events t))")
# Simulate schema-7 rollback writers whose task PR URLs are already cleared:
# only all-canonical anti-join reconciliation can find this inventory.
sql("INSERT INTO delivery_pull_requests(id,owner,repo,number,url,created_at) SELECT md5('legacy'||n)||md5('legacy'||n),'fixture','legacy',n::text,'https://github.com/fixture/legacy/pull/'||n,clock_timestamp() FROM generate_series(1,125) n")
# Real configured cron enqueues the disabled-by-operator scheduler; not DSL grep.
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{scheduler}' AND state='available'", 't', 75)
# Drive the public Ash action with paused queues to measure a bounded page.
rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.Observation, :schedule_due, %{}, actor: %{role: :system}); {:ok, %{enrolled: 100}} = Ash.run_action(input)')
assert sql('SELECT count(*) FROM delivery_poll_states') == '101'
rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.Observation, :schedule_due, %{}, actor: %{role: :system}); {:ok, %{enrolled: 25}} = Ash.run_action(input)')
assert sql('SELECT count(*) FROM delivery_poll_states') == '126'
assert sql(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN {active}") == '126'
# Restart actual Oban supervision, losing process state but preserving jobs.
rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban)')
wait_for('SELECT count(*) FROM delivery_poll_states WHERE generation>0', '126')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN {active}", '0')
assert sql("SELECT ci_state||','||head_sha||','||last_error FROM delivery_poll_states s JOIN delivery_pull_requests pr USING(id) WHERE pr.number='501'") in ['passing,fixture-head,unauthorized']
assert sql("SELECT count(*) FROM delivery_poll_states WHERE ci_state='unknown' AND head_sha IS NULL AND observed_at IS NULL") == '125'
assert sql("SELECT jsonb_build_object('task',(SELECT row_to_json(t) FROM tasks t WHERE id='terminal-pr'),'pr',(SELECT row_to_json(t) FROM delivery_pull_requests t WHERE number='501' AND repo='repo'),'links',(SELECT json_agg(t) FROM delivery_task_links t),'events',(SELECT json_agg(t) FROM task_events t))") == source_before
# Already green still-open PRs keep recurring. Make due using the actual clock
# without waiting a whole poll interval; no fake scheduler/budget implementation.
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour'; UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='501' AND repo='repo')")
first_generation = int(sql("SELECT generation FROM delivery_poll_states s JOIN delivery_pull_requests p USING(id) WHERE p.number='501' AND p.repo='repo'"))
rpc('AshOban.schedule(Agentboard.Delivery.Observation, :schedule_due)')
rpc(':ok = Oban.resume_queue(queue: :delivery_scheduler); :ok = Oban.resume_queue(queue: :delivery_polling)')
wait_for(f"SELECT generation>{first_generation} FROM delivery_poll_states s JOIN delivery_pull_requests p USING(id) WHERE p.number='501' AND p.repo='repo'", 't')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN {active}", '0')
rpc(':ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
# Global budgets survive restart and competing callers share a single last slot.
sql("UPDATE delivery_provider_budgets SET remaining=1,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    outcomes = list(pool.map(lambda _: rpc('{:ok, result} = Agentboard.Delivery.ProviderAdmission.acquire("github"); IO.puts("ADMISSION=" <> Jason.encode!(result))'), range(2)))
assert sum('"allowed":true' in outcome for outcome in outcomes) == 1, outcomes
assert sum('"allowed":false' in outcome for outcome in outcomes) == 1, outcomes
assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == '0'
rpc('{:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.acquire("buildbuddy")')
assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='buildbuddy'") == '29'
assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == '0'
# Allocation is database state, not a restarted process's quota counter.
rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban)')
assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == '0'
rpc('{:ok, %{allowed: false}} = Agentboard.Delivery.ProviderAdmission.acquire("github"); :ok = Oban.pause_queue(queue: :delivery_scheduler); :ok = Oban.pause_queue(queue: :delivery_polling)')
sql("UPDATE delivery_provider_budgets SET reset_at=clock_timestamp()-interval '1 second' WHERE id='github'")
rpc('{:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.acquire("github")')
assert sql("SELECT remaining||','||(reset_at>=clock_timestamp()+interval '59 seconds') FROM delivery_provider_budgets WHERE id='github'") == '59,true'
# Provider deadline/backoff does not reset with job or supervisor restart.
sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour' WHERE id=(SELECT id FROM delivery_pull_requests WHERE number='501' AND repo='repo')")
counts = sql("SELECT count(*) FROM delivery_poll_states_versions")
before = sql("SELECT row_to_json(s) FROM delivery_poll_states s JOIN delivery_pull_requests p USING(id) WHERE p.number='501' AND p.repo='repo'")
rpc('id = Agentboard.Repo.statement!("SELECT id FROM delivery_pull_requests WHERE number=$1 AND repo=$2", ["501", "repo"]).rows |> hd() |> hd(); Agentboard.Delivery.Scheduling.enqueue(id)')
rpc(':ok = Oban.resume_queue(queue: :delivery_polling)')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN {active}", '0')
assert sql("SELECT row_to_json(s) FROM delivery_poll_states s JOIN delivery_pull_requests p USING(id) WHERE p.number='501' AND p.repo='repo'") == before
assert sql('SELECT count(*) FROM delivery_poll_states_versions') == counts
# Runtime disable fences already queued jobs even with an unpaused queue.
rpc('Application.put_env(:agentboard, :pr_observation_enabled, false)')
before = sql('SELECT json_agg(s ORDER BY id) FROM delivery_poll_states s')
budget_before = sql('SELECT json_agg(b ORDER BY id) FROM delivery_provider_budgets b')
rpc('AshOban.schedule(Agentboard.Delivery.Observation, :schedule_due); Agentboard.Delivery.Scheduling.enqueue(Agentboard.Repo.statement!("SELECT id FROM delivery_pull_requests LIMIT 1", []).rows |> hd() |> hd()); :ok = Oban.resume_queue(queue: :delivery_scheduler)')
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{worker}' AND state='scheduled'", 't')
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{scheduler}' AND state='scheduled'", 't')
assert sql('SELECT json_agg(s ORDER BY id) FROM delivery_poll_states s') == before
assert sql('SELECT json_agg(b ORDER BY id) FROM delivery_provider_budgets b') == budget_before
ab('task', 'create', '--id', 'board-independent', '--title', 'Board remains writable')
# Enabled immediate scheduling is transactionally tied to the PR submission:
# a queue insert failure must not leave the task, PR or poll enrollment behind.
rpc('Application.put_env(:agentboard, :pr_observation_enabled, true); :ok = Oban.pause_queue(queue: :delivery_polling); :ok = Oban.pause_queue(queue: :delivery_scheduler)')
url = 'https://github.com/fixture/repo/pull/999'
ident = hashlib.sha256(url.encode()).hexdigest()
sql(f"CREATE FUNCTION reject_poll_job_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.worker='{worker}' AND NEW.args->>'id'='{ident}' THEN RAISE EXCEPTION 'Synthetic scheduling failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_poll_job_fixture BEFORE INSERT ON oban_jobs FOR EACH ROW EXECUTE FUNCTION reject_poll_job_fixture()")
ab('task', 'create', '--id', 'queue-rollback', '--title', 'Queue failure', '--pr', url, success=False)
assert sql("SELECT count(*) FROM tasks WHERE id='queue-rollback'") == '0'
assert sql(f"SELECT count(*) FROM delivery_pull_requests WHERE id='{ident}'") == '0'
assert sql(f"SELECT count(*) FROM delivery_poll_states WHERE id='{ident}'") == '0'
sql('DROP TRIGGER reject_poll_job_fixture ON oban_jobs; DROP FUNCTION reject_poll_job_fixture()')
for args in json.loads(sql(f"SELECT json_agg(args) FROM oban_jobs WHERE worker='{worker}'")):
    assert set(args) == {'id'}, args
print('Independent cron and immediate scheduling, bounded all-canonical recovery, restart, recurring green/archived PRs, shared admission, backoff, disabled queued work and submission rollback passed')
