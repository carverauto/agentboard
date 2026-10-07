"""Persisted AshOban inventory pages, retry and worker restart recovery.

The inventory target owns canonical identity and attribution. This target owns
real asynchronous delivery and catch-up across the 100-task page boundary.
All fixtures are invented; there is no test-only application API.
"""
import json
import os
import subprocess
import time


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v',
                                    'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def wait_for(query, expected, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        actual = sql(query)
        if actual == expected:
            return
        time.sleep(.1)
    jobs = sql("SELECT json_agg(json_build_object('state',state,'attempt',attempt,'args',args,'errors',errors)) FROM oban_jobs WHERE worker='Agentboard.Delivery.ReconcileLinks'")
    queue = rpc('IO.inspect(Oban.check_queue(queue: :delivery_discovery))')
    raise AssertionError((query, expected, actual, jobs, queue))


worker = 'Agentboard.Delivery.ReconcileLinks'
rpc(':ok = Oban.pause_queue(queue: :delivery_discovery)')
sql("INSERT INTO tasks(id,title,status,pr_url) SELECT 'catchup-'||lpad(n::text,3,'0'),'Legacy catch-up',CASE WHEN n%2=0 THEN 'done' ELSE 'cancelled' END,'https://github.com/fixture/repo/pull/10' FROM generate_series(1,125) n")
sql("INSERT INTO task_archives(id,archived_at,revision,changed_by) VALUES ('catchup-002',clock_timestamp(),1,'fixture-captain')")
before = sql("SELECT md5(string_agg(row_to_json(t)::text,'|' ORDER BY id)) FROM tasks t")
# Exercise the configured Cron consumer, not an assertion over its DSL text.
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{worker}' AND state='available'", 't', 70)
assert sql('SELECT count(*) FROM delivery_task_links') == '0'
# Queued work survives an actual Oban supervisor restart. The configured queue
# resumes; the API/Repo are independent children and remain available.
rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); {:ok, _} = Supervisor.restart_child(Agentboard.Supervisor, Oban)')
wait_for('SELECT count(*) FROM delivery_task_links', '125')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN ('available','executing','scheduled','retryable')", '0')
assert sql("SELECT count(*) FROM delivery_pull_requests WHERE owner='fixture' AND repo='repo' AND number='10'") == '1'
assert sql(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{worker}' AND state='completed' AND args->'action_arguments'->>'after_id' IS NOT NULL") == 't', 'Continuation cursor was not durably delivered'
assert sql("SELECT count(*) FROM delivery_task_links WHERE attribution='unknown' AND submitted_by_id IS NULL AND source_event_id IS NULL AND linked_at IS NULL") == '125'
assert sql('SELECT count(*) FROM task_events') == '0'
assert sql("SELECT md5(string_agg(row_to_json(t)::text,'|' ORDER BY id)) FROM tasks t") == before
# A page error must enter the real retry path, not complete with missing work.
sql("INSERT INTO tasks(id,title,status,pr_url) VALUES ('z-retry','Retry fixture','done','https://github.com/fixture/repo/pull/11')")
sql("CREATE FUNCTION reject_discovery_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.task_id='z-retry' THEN RAISE EXCEPTION 'Synthetic catch-up failure'; END IF; RETURN NEW; END $$")
sql('CREATE TRIGGER reject_discovery_fixture BEFORE INSERT ON delivery_task_links FOR EACH ROW EXECUTE FUNCTION reject_discovery_fixture()')
rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{worker}' AND state='retryable'", 't')
assert sql("SELECT count(*) FROM delivery_task_links WHERE task_id='z-retry'") == '0'
assert sql("SELECT count(*) FROM delivery_pull_requests WHERE number='11'") == '0', 'Failed page left a partial PR'
sql('DROP TRIGGER reject_discovery_fixture ON delivery_task_links; DROP FUNCTION reject_discovery_fixture()')
# Operator retry is a real Oban interface, not a shortened test-only backoff.
rpc('import Ecto.Query; ids = Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "retryable", select: j.id); Enum.each(ids, &Oban.retry_job/1)')
wait_for("SELECT count(*) FROM delivery_task_links WHERE task_id='z-retry'", '1')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN ('available','executing','scheduled','retryable')", '0')
# A complete second sweep changes neither attribution nor append-only audits.
counts = sql("SELECT (SELECT count(*) FROM delivery_task_links)||','||(SELECT count(*) FROM delivery_pull_requests_versions)||','||(SELECT count(*) FROM board_action_events)")
rpc('AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links)')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN ('available','executing','scheduled','retryable')", '0')
assert sql("SELECT (SELECT count(*) FROM delivery_task_links)||','||(SELECT count(*) FROM delivery_pull_requests_versions)||','||(SELECT count(*) FROM board_action_events)") == counts
# The runtime disable switch fences already-queued jobs even if their queue
# is still running. It retains the work as snoozed rather than completing it.
rpc('Application.put_env(:agentboard, :pr_discovery_enabled, false); job = AshOban.schedule(Agentboard.Delivery.Discovery, :reconcile_links); IO.puts("DISABLED_JOB=" <> Integer.to_string(job.id))')
wait_for(f"SELECT count(*)>0 FROM oban_jobs WHERE worker='{worker}' AND state='scheduled'", 't')
assert sql("SELECT (SELECT count(*) FROM delivery_task_links)||','||(SELECT count(*) FROM delivery_pull_requests_versions)||','||(SELECT count(*) FROM board_action_events)") == counts
rpc('Application.put_env(:agentboard, :pr_discovery_enabled, true); import Ecto.Query; ids = Agentboard.Repo.all(from j in Oban.Job, where: j.worker == "Agentboard.Delivery.ReconcileLinks" and j.state == "scheduled", select: j.id); Enum.each(ids, &Oban.retry_job/1)')
wait_for(f"SELECT count(*) FROM oban_jobs WHERE worker='{worker}' AND state IN ('available','executing','scheduled','retryable')", '0')
# Pages contain cursors only, never provider keys, source text or HTML.
for args in json.loads(sql(f"SELECT json_agg(args) FROM oban_jobs WHERE worker='{worker}'")):
    assert set(args) <= {'action_arguments'}
    assert set(args.get('action_arguments', {})) <= {'after_id'}
print('Cron catch-up, durable keyset pages, worker restart, failed-page retry and replay without duplicate audits passed')
