"""Owns whole-poll admission/fairness at packaged Phoenix -> real TLS -> PG.
Invented eight-PR, thirteen-suite workload; no mocked admission/scheduler.
The collector sibling owns paging/revision fences and hostile transport.
"""
import concurrent.futures
import email.utils
import http.server
import json
import os
import subprocess
import threading
import urllib.parse
import urllib.request
from provider_fixture import tls_provider

HEAD = "a" * 40
BASE = "b" * 40
NOW = "2026-10-01T00:00:00Z"
requests = []
conditional = []
versions = {}
pending = False
hold = threading.Event()
entered = threading.Event()
slow = False
use_etag = True
provider_token = "invented-fairness-token"

def sql(query):
    return subprocess.check_output([os.environ["FIXTURE_PSQL"], "-At", "-v",
        "ON_ERROR_STOP=1", "-c", query], text=True).strip()

def rpc(expression):
    p = subprocess.run([os.environ["AGENTBOARD_BIN"], "rpc", expression],
        capture_output=True, text=True, timeout=110)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout

def ab(*args):
    env = {k:v for k,v in os.environ.items() if not k.startswith(("DATABASE_", "PG"))}
    env.update(AGENT_ID="fairness-owner", AGENTBOARD_MODEL="fixture", AGENTBOARD_HARNESS="codex")
    p = subprocess.run([os.environ["AB_BINARY"], "--json", *args], env=env,
        capture_output=True, text=True, timeout=25)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return json.loads(p.stdout)

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        assert self.headers["Authorization"] == "Bearer " + provider_token
        path = urllib.parse.urlparse(self.path).path
        requests.append(self.path)
        version = versions.get(path, 0)
        etag = '"fixture-' + str(version) + '"'
        modified = email.utils.formatdate(1760000000 + version * 60, usegmt=True)
        validator = etag if use_etag else modified
        supplied = self.headers.get("If-None-Match" if use_etag else "If-Modified-Since")
        conditional.append((path, supplied))
        if slow and "/pulls/" in path:
            entered.set()
            assert hold.wait(10)
        if supplied == validator:
            self.send_response(304)
            self.send_header("ETag" if use_etag else "Last-Modified", validator)
            self.end_headers()
            return
        if "/pulls/" in path:
            n = int(path.rsplit("/", 1)[1])
            body = dict(number=n, head=dict(sha=HEAD, ref="fixture"),
                base=dict(sha=BASE, ref="main"), state="open", merged=False,
                draft=False, mergeable=True, mergeable_state="clean")
        elif path.endswith("/check-suites"):
            body = dict(total_count=13, check_suites=[dict(id=i, head_sha=HEAD) for i in range(1,14)])
        elif path.endswith("/check-runs"):
            i = int(path.split("/")[-2])
            body = dict(total_count=1, check_runs=[dict(id=i, name="suite-" + str(i),
                head_sha=HEAD, app=dict(id=1), status="queued" if pending else "completed",
                conclusion=None if pending else "success", started_at=None,
                completed_at=None if pending else NOW)])
        elif path.endswith("/statuses"): body = []
        elif "/branches/" in path:
            body = dict(name="main", commit=dict(sha=BASE))
        else: raise AssertionError(path)
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("ETag" if use_etag else "Last-Modified", validator)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

with tls_provider(Provider) as (url, ca, server):
    rpc(':ok = Oban.stop_queue(queue: :delivery_scheduler); :ok = Oban.stop_queue(queue: :delivery_polling)')
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(url) +
        ', ca_file: ' + json.dumps(ca) + ', token: "invented-fairness-token"])')
    ab("agent", "register")
    for n in range(1,9):
        ab("task", "create", "--id", "fairness-" + str(n), "--title", "Invented poll workload",
            "--pr", "https://github.com/fixture/fairness/pull/" + str(n))
    ids = json.loads(sql("SELECT json_agg(id ORDER BY number::int) FROM delivery_pull_requests"))
    def due(ident):
        sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second',attempt_id=NULL,lease_expires_at=NULL WHERE id='" + ident + "'")
    def poll(ident):
        return rpc('IO.puts("RESULT=" <> inspect(Agentboard.Delivery.Scheduling.poll(' + json.dumps(ident) + ')))')
    # Regression: one poll cannot begin on credit insufficient to complete it.
    # Keep other rows not due to isolate admission from fairness.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour'")
    due(ids[0])
    sql("UPDATE delivery_provider_budgets SET remaining=16,reset_at=clock_timestamp()+interval '60 seconds',blocked_until=NULL WHERE id='github'")
    start = len(requests)
    out = poll(ids[0])
    assert len(requests) == start, ("partial poll wasted requests", out, requests[start:])
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "16"
    # Reverse dispatch cannot take credit from an older eligible observation.
    sql("UPDATE delivery_provider_budgets SET capacity=500,remaining=500,reset_at=clock_timestamp()-interval '1 second',blocked_until=NULL WHERE id='github'")
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second',attempt_id=NULL,lease_expires_at=NULL")
    start = len(requests)
    out = poll(ids[-1])
    assert "fairness_deferred" in out and len(requests) == start, out
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "500"

    # Advance only persisted eligibility/window deadlines, not implementation
    # clocks or mocked admission. Eight cold PRs must all observe within four
    # minute windows at the unchanged60 cap, even with synchronized demand.
    first_seen = {}
    for window in range(4):
        sql("UPDATE delivery_provider_budgets SET reset_at=clock_timestamp()-interval '1 second',blocked_until=NULL WHERE id='github'")
        sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()-interval '1 second',attempt_id=NULL,lease_expires_at=NULL")
        before = len(requests)
        for ident in ids:
            out = poll(ident)
            assert "rate_limited" not in out, (window, ident, out)
            if "observed" in out: first_seen.setdefault(ident, window + 1)
        assert len(requests) - before <= 60, (window, requests[before:])
        assert sql("SELECT count(*) FROM delivery_poll_credits") == "0"
    assert len(first_seen) == 8 and max(first_seen.values()) <= 4, first_seen
    assert sql("SELECT count(*) FROM delivery_poll_states WHERE observed_at IS NOT NULL") == "8"

    # Already observed rows retain their own cache across separate RPC workers.
    # Correctly authorized304s reuse complete representations/paging metadata,
    # produce a new real observation and consume zero net local credit.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour'")
    due(ids[0])
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds',blocked_until=NULL WHERE id='github'")
    before = len(requests)
    snapshot = int(sql("SELECT count(*) FROM delivery_ci_snapshots"))
    assert "observed" in poll(ids[0])
    assert len(requests) - before == 17
    assert all(v is not None for _,v in conditional[before:]), conditional[before:]
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "60"
    assert int(sql("SELECT count(*) FROM delivery_ci_snapshots")) == snapshot + 1
    assert sql("SELECT next_poll_at-observed_at=interval '120 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    due(ids[0]); assert "observed" in poll(ids[0])
    assert sql("SELECT next_poll_at-observed_at=interval '300 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    # Conditional suite-list304 must not hide a changed check run.
    pending = True
    versions["/repos/fixture/fairness/check-suites/1/check-runs"] = 1
    due(ids[0])
    assert "pending" in poll(ids[0])
    assert sql("SELECT unchanged_polls=0 AND next_poll_at-observed_at=interval '60 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "59"
    pending = False
    versions["/repos/fixture/fairness/check-suites/1/check-runs"] = 2
    due(ids[0])
    assert "observed" in poll(ids[0])
    assert sql("SELECT unchanged_polls=0 FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    due(ids[0]); assert "observed" in poll(ids[0])
    assert sql("SELECT next_poll_at-observed_at=interval '120 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    due(ids[0]); assert "observed" in poll(ids[0])
    assert sql("SELECT next_poll_at-observed_at=interval '300 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    # New explicit link resets stable backoff and makes the row eligible.
    ab("task", "create", "--id", "fairness-manual", "--title", "Explicit refresh",
       "--pr", "https://github.com/fixture/fairness/pull/1")
    assert sql("SELECT unchanged_polls=0 AND next_poll_at<=clock_timestamp() FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"

    # Two concurrent collectors cannot half-spend the same last whole-poll
    # allocation. Ordinary board writes are possible while actual TLS is held.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour',github_cache='{}'")
    due(ids[0]); due(ids[1])
    sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp()-interval '1 hour' WHERE id='" + ids[0] + "'")
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    slow = True
    before = len(requests)
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        f = pool.submit(poll, ids[0])
        assert entered.wait(10)
        deferred = poll(ids[1])
        assert "budget_deferred" in deferred, deferred
        assert len(requests) == before + 1
        ab("task", "create", "--id", "fairness-independent", "--title", "Write during TLS")
        hold.set()
        assert "observed" in f.result(timeout=30)
    slow = False
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "43"
    assert sql("SELECT count(*) FROM delivery_poll_credits") == "0"
    html = urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/prs").read().decode()
    assert "GitHub budget" in html and "Poll deferred" in html
    # The read surface contains no raw cache, validator or provider token.
    projection = rpc('IO.puts(Jason.encode!(elem(Agentboard.Delivery.Reads.list(), 1)))')
    assert "github_cache" not in projection and "invented-fairness-token" not in projection
    assert "fixture-0" not in projection
    audit = sql("SELECT json_agg(e) FROM board_action_events e")
    # AshEvents records the empty create default in changed_attributes;
    # private representations/validators must never enter an event.
    assert "invented-fairness-token" not in audit and "fixture-" not in audit
    for event in json.loads(audit):
        for field in ("data", "changed_attributes"):
            assert event.get(field, {}).get("github_cache") in (None, {}), event

    # Crash recovery refunds unused durable credit exactly once in its own
    # window. The provider-spend interface is the production request boundary.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour',attempt_id=NULL,lease_expires_at=NULL")
    due(ids[0])
    sql("UPDATE delivery_poll_states SET github_cache='{}' WHERE id='" + ids[0] + "'")
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    rpc('{:ok, [r]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(ids[0]) + '); {:ok, %{allowed: true, credit: c}} = Agentboard.Delivery.ProviderAdmission.reserve_poll(r,32); {:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.spend(c)')
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "28"
    sql("UPDATE delivery_poll_credits SET expires_at=clock_timestamp()-interval '1 second'")
    due(ids[0])
    assert "observed" in poll(ids[0])
    # 1 already charged before crash plus17 cold requests:60-18=42.
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "42"
    assert sql("SELECT count(*) FROM delivery_poll_credits") == "0"
    # A still-active reservation spanning a minute remains charged in the
    # refilled window. Ordinary workflow requests share that same budget;
    # old credit must not give a second invisible allowance after reset.
    due(ids[0])
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    rpc('{:ok, [r]} = Agentboard.Delivery.Polling.reserve_pr(' + json.dumps(ids[0]) + '); {:ok, %{allowed: true, credit: c}} = Agentboard.Delivery.ProviderAdmission.reserve_poll(r,32); {:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.spend(c)')
    sql("UPDATE delivery_provider_budgets SET reset_at=clock_timestamp()-interval '1 second' WHERE id='github'")
    rpc('{:ok, %{allowed: true}} = Agentboard.Delivery.ProviderAdmission.acquire("github")')
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "28", "active credit vanished at minute reset"
    # A delayed304 from the old minute cannot mint new-window credit.
    rpc('c = Ash.read!(Agentboard.Delivery.PollCredit) |> hd(); {:ok, :ok} = Agentboard.Delivery.ProviderAdmission.not_modified(c.id, DateTime.add(c.window_end,-60)); {:ok, :ok} = Agentboard.Delivery.ProviderAdmission.release(c.id); {:ok, :ok} = Agentboard.Delivery.ProviderAdmission.release(c.id)')
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "59"
    assert sql("SELECT count(*) FROM delivery_poll_credits") == "0"
    # A provider head change invalidates stable backoff and stale route cache.
    sql("UPDATE delivery_poll_states SET next_poll_at=clock_timestamp()+interval '1 hour'")
    due(ids[0]); assert "observed" in poll(ids[0])
    assert sql("SELECT next_poll_at-observed_at=interval '300 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    due(ids[0])
    HEAD = "c" * 40
    for path in {path for path,_ in conditional}: versions[path] = versions.get(path,0) + 1
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    assert "observed" in poll(ids[0])
    assert sql("SELECT head_sha='" + HEAD + "' AND unchanged_polls=0 AND next_poll_at-observed_at=interval '60 seconds' FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"
    assert sql("SELECT position('" + "a"*40 + "' in github_cache::text)=0 FROM delivery_poll_states WHERE id='" + ids[0] + "'") == "t"

    # Last-Modified fallback follows the real HTTPS boundary too; rotation of
    # the operator credential must discard those cached representations.
    use_etag = False
    sql("UPDATE delivery_poll_states SET github_cache='{}' WHERE id='" + ids[0] + "'")
    sql("UPDATE delivery_provider_budgets SET remaining=60,reset_at=clock_timestamp()+interval '60 seconds' WHERE id='github'")
    due(ids[0]); assert "observed" in poll(ids[0])
    before = len(requests)
    due(ids[0]); assert "observed" in poll(ids[0])
    assert len(requests)-before == 17 and all(v for _,v in conditional[before:])
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "43"
    provider_token = "invented-rotated-fairness-token"
    rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(url) + ', ca_file: ' + json.dumps(ca) + ', token: ' + json.dumps(provider_token) + '])')
    before = len(requests)
    due(ids[0]); assert "observed" in poll(ids[0])
    assert len(requests)-before == 17 and all(v is None for _,v in conditional[before:])
    assert sql("SELECT remaining FROM delivery_provider_budgets WHERE id='github'") == "26"
print("Whole-poll zero spend,8x13 bounded fairness,conditional credit/cache isolation,backoff reset,concurrent admission,crash refund and minute rollover passed.")
