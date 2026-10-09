"""Actual-default watch invalidates non-default-target PRs through packaged HTTPS/Ash/PG.

Owns default-tip identity and stale-observation fencing; the older pr_conflicts
suite owns actual-target-only paging and conflict deliveries. No fixture mints
an order, custody receipt or publication grant.
"""
import concurrent.futures
import http.server
import json
import os
import subprocess
import threading
import urllib.parse
from provider_fixture import tls_provider

HEAD, BASE, DEFAULT, MOVED = (c * 40 for c in 'abcd')
default_tip = DEFAULT
slow = False
entered, release = threading.Event(), threading.Event()
reads = {}
branch_reads = {}
requests = []


def sql(query):
    return subprocess.check_output([os.environ['FIXTURE_PSQL'], '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], text=True).strip()


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression], text=True, capture_output=True, timeout=45)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def ab(*args):
    env = {k:v for k,v in os.environ.items() if not k.startswith(('PG','DATABASE_'))}
    env.update(AGENT_ID='codex-default-watch',AGENTBOARD_HARNESS='codex',AGENTBOARD_MODEL='fixture-model')
    result = subprocess.run([os.environ['AB_BINARY'],'--json',*args], env=env, text=True, capture_output=True, timeout=25)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


def reset_budget():
    sql("UPDATE delivery_provider_budgets SET remaining=60,blocked_until=NULL,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")


def poll(pr):
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour'")
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+pr+"'")
    reset_budget()
    return rpc('IO.puts(inspect(Agentboard.Delivery.Scheduling.poll('+json.dumps(pr)+')))')


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_): pass

    def do_GET(self):
        assert self.headers.get('Authorization') == 'Bearer invented-default-watch-token'
        path=urllib.parse.urlparse(self.path).path
        requests.append(path)
        other=path.startswith('/repos/fixture/other/') or path=='/repos/fixture/other'
        repo='fixture/other' if other else 'fixture/watch'
        if path in ('/repos/fixture/watch','/repos/fixture/other'):
            body=dict(full_name=repo,default_branch='trunk' if other else 'staging')
        elif '/branches/' in path:
            ref=path.rsplit('/',1)[1]
            body=dict(name=ref,commit=dict(sha='7'*40 if other and ref=='trunk' else default_tip if ref=='staging' else BASE))
            branch_reads[ref]=branch_reads.get(ref,0)+1
            if slow and ref=='release' and branch_reads[ref]%2==0:
                entered.set(); assert release.wait(15)
        elif '/pulls/' in path:
            number=int(path.rsplit('/',1)[1]);reads[number]=reads.get(number,0)+1
            body=dict(number=number,state='open',merged=False,draft=False,
                head=dict(sha=HEAD,ref='feat/fixture-'+str(number),repo=dict(full_name=repo)),
                base=dict(sha=BASE,ref='release'),mergeable=True,mergeable_state='clean')
        elif path.endswith('/check-suites'):
            body=dict(total_count=0,check_suites=[])
        elif path.endswith('/statuses'):
            body=[]
        else: raise AssertionError(path)
        encoded=json.dumps(body).encode();self.send_response(200)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(encoded)))
        self.end_headers();self.wfile.write(encoded)


rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling); Application.put_env(:agentboard, :cooperation_enabled, false); Application.put_env(:agentboard, :conflict_routing_mode, "dry_run")')
ab('agent','register','--name','Invented default watch seat')
prs=[]
for number in (101,102):
    task='default-watch-'+str(number)
    ab('task','create','--id',task,'--title','Non-default-target fixture','--repo','fixture/watch')
    ab('task','claim',task)
    ab('task','link',task,'--pr','https://github.com/fixture/watch/pull/'+str(number))
    prs.append(sql("SELECT id FROM delivery_pull_requests WHERE number='"+str(number)+"'"))
source_before=sql('SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t')
with tls_provider(Provider) as (api_url,ca,_):
    rpc('Application.put_env(:agentboard, :github, [api_url: '+json.dumps(api_url)+', token: "invented-default-watch-token", ca_file: '+json.dumps(ca)+'])')
    for pr in prs:
        result=poll(pr)
        assert 'observed' in result, (result, requests)
    watches=json.loads(sql('SELECT jsonb_object_agg(ref,id) FROM delivery_base_watches'))
    assert set(watches)=={'staging','release'}, 'Actual repository default was not enrolled independently of target base'
    payload=json.loads(sql('SELECT payload FROM delivery_ci_snapshots ORDER BY observed_at LIMIT 1'))
    assert (payload['default_ref'],payload['default_tip_sha'],payload['base_ref'],payload['evaluation_base_sha']) == ('staging',DEFAULT,'release',BASE)
    assert '/repos/fixture/watch/branches/main' not in requests
    assert sql('SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM tasks t') == source_before
    assert sql('SELECT count(*) FROM delivery_conflict_orders') == '0'
    assert sql('SELECT count(*) FROM delivery_publication_grants') == '0'
    assert sql('SELECT count(*) FROM messages') == '0'

    # A second registered repository shares the actual target name, but its
    # independent default/watch generation must remain outside this fanout.
    ab('task','create','--id','other-default-watch','--title','Invented other repository','--repo','fixture/other')
    ab('task','claim','other-default-watch')
    ab('task','link','other-default-watch','--pr','https://github.com/fixture/other/pull/103')
    other_pr=sql("SELECT id FROM delivery_pull_requests WHERE owner='fixture' AND repo='other'")
    assert 'observed' in poll(other_pr)
    other_before=sql("SELECT to_jsonb(s) FROM delivery_poll_states s WHERE id='"+other_pr+"'")

    # Current target stays unchanged while actual default advances: all linked
    # open PR reservations must be invalidated, not only staging-target PRs.
    default_tip=MOVED;reset_budget()
    watch=watches['staging']
    sql("UPDATE delivery_base_watches SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+watch+"'")
    assert 'changed: true' in rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.check('+json.dumps(watch)+')))')
    assert 'invalidated: 2' in rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.invalidate(%{id: '+json.dumps(watch)+', revision: 1, cursor: ""})))')
    assert sql("SELECT count(*) FROM delivery_poll_states WHERE last_error='default_changed' AND next_poll_at<=clock_timestamp() AND expected_base_sha='"+BASE+"'") == '2'
    assert sql("SELECT to_jsonb(s) FROM delivery_poll_states s WHERE id='"+other_pr+"'")==other_before, 'Default fanout crossed the registered repository boundary'

    # Restart recovery can replay a committed page. The same default revision
    # must not replace reservations already invalidated for that tip.
    invalidated=sql('SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_poll_states s')
    rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.invalidate(%{id: '+json.dumps(watch)+', revision: 1, cursor: ""})))')
    assert sql('SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM delivery_poll_states s') == invalidated, 'Replay of one default-tip page replaced already-invalidated reservations'

    # A default watch advance during provider I/O fences an old clean response.
    before=sql('SELECT count(*) FROM delivery_ci_snapshots')
    slow=True;reads[101]=0;branch_reads.clear()
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        pending=pool.submit(poll,prs[0]);assert entered.wait(15)
        default_tip='e'*40;reset_budget()
        sql("UPDATE delivery_base_watches SET next_poll_at=clock_timestamp()-interval '1 second' WHERE id='"+watch+"'")
        rpc('IO.puts(inspect(Agentboard.Delivery.BaseMonitor.check('+json.dumps(watch)+')))')
        release.set();outcome=pending.result()
    assert 'base_changed' in outcome, outcome
    assert sql('SELECT count(*) FROM delivery_ci_snapshots') == before, 'Stale default-tip response appended clean evidence'
    slow=False
    rpc('Application.put_env(:agentboard, :conflict_routing_mode, "disabled")')
    requests.clear();assert 'observed' in poll(prs[0])
    assert '/repos/fixture/watch' not in requests, 'Disabled conflict mode kept collecting repository default identity'

print('Actual staging default and release evaluation base stayed distinct; default advance invalidated all linked PRs; stale response fenced; default-off provider behavior preserved')
