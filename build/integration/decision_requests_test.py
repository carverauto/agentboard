"""Decision ownership, atomic delivery and replay fences at the packaged HTTP/CLI/PG boundary.
Invented actors only. Existing board/runtime fixtures own general lease and receipt behavior;
this fixture owns their decision integration and new public wire contract."""
import http.cookiejar
import concurrent.futures
import json
import os
import re
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from liveview_client import LiveView, Page, contains

URL = os.environ["AGENTBOARD_URL"]
CAPTAIN = "fixture-decision-capability-0123456789"
TOKEN = Path(os.environ["TEST_TMPDIR"]) / "decision-captain.token"
TOKEN.write_text(CAPTAIN + "\n")
TOKEN.chmod(0o600)
BASE = dict(os.environ, AGENT_ID="decision-seat", AGENTBOARD_MODEL="fixture",
            AGENTBOARD_HARNESS="codex", AGENTBOARD_CAPTAIN_TOKEN_FILE=str(TOKEN))

def sql(query):
    return subprocess.check_output([os.environ["FIXTURE_PSQL"], "-At", "-v",
                                    "ON_ERROR_STOP=1", "-c", query], text=True).strip()

def rpc(expression):
    p = subprocess.run([os.environ["AGENTBOARD_BIN"], "rpc", expression],
                       capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)

def api(path, data=None, actor="decision-seat", captain=False, status=200, token=None):
    headers = {"x-agentboard-agent": actor, "x-agentboard-model": "fixture",
               "x-agentboard-harness": "captain" if actor == "captain" else "codex", "x-agentboard-worker-protocol": "1", "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if captain:
        headers["Authorization"] = "Bearer " + CAPTAIN
        headers["x-agentboard-captain-token"] = CAPTAIN
    req = urllib.request.Request(URL + "/api/v1/" + path, headers=headers,
                                 data=json.dumps(data).encode() if data is not None else None)
    try:
        result = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as e:
        result = e
    body = json.load(result)
    assert result.status == status, (path, result.status, body)
    return body

def ab(*args, actor="decision-seat", code=0):
    p = subprocess.run([os.environ["AB_BINARY"], "--json", *args],
                       env=dict(BASE, AGENT_ID=actor), capture_output=True, text=True, timeout=20)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    assert CAPTAIN not in p.stdout + p.stderr
    return json.loads(p.stderr if code else p.stdout)

def create_task(id, owner="decision-seat"):
    api("tasks", {"id": id, "title": "Decision fixture", "repo": "fixture/decisions"})
    api("tasks/" + id + "/claim", {}, actor=owner)

def request(task="decision-task", gate="run/gate", question="  Exact question?\n", findings="<script>verbatim</script>\nF1 critical file.ex:7 authority ask-user\n"):
    return {"task": task, "kind": "ask_user_gate", "gate": gate,
            "question": question, "findings": findings, "options": ["Approve", "Revise"]}

def counts(id):
    return sql("SELECT json_build_array((SELECT count(*) FROM messages WHERE task_id='" + id +
               "'),(SELECT count(*) FROM task_events WHERE task_id='" + id +
               "'),(SELECT count(*) FROM decision_wakes WHERE task_id='" + id + "'))")

rpc('Application.put_env(:agentboard,:captain_token,' + json.dumps(CAPTAIN) + ')')
rpc('Application.put_env(:agentboard,:coordinator_id,"decision-coordinator")')
for actor in ["decision-seat", "decision-other", "decision-coordinator", "captain", "decision-worker"]:
    api("agents/register", {"name": actor}, actor=actor)
assert api("meta")["schema_version"] >= 20
create_task("decision-task")
before = api("tasks/decision-task")
api("decisions", request(), actor="decision-other", status=409)
assert api("tasks/decision-task") == before
payload = request()
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    requested = list(pool.map(lambda _: api("decisions", payload), range(2)))
rid = requested[0]["decision"]["id"]
assert requested[1]["decision"]["id"] == rid
assert requested[0]["decision"]["question"] == payload["question"]
assert requested[0]["decision"]["findings"] == payload["findings"]
assert sql("SELECT count(*) FROM decision_requests WHERE task_id='decision-task'") == "1"
assert sql("SELECT count(*) FROM task_events WHERE task_id='decision-task' AND kind='decision_requested'") == "1"
assert api("tasks/decision-task")["task"]["status"] == "blocked"
api("decisions", dict(payload, question="Changed"), status=409)
api("decisions", dict(payload, question="x"*8193), status=422)
api("decisions", dict(payload, decision_admin=True), status=422)
api("decisions/not-a-uuid", status=422)
api("decisions/" + rid + "/recommend", {"body": "Suggested"}, actor="decision-coordinator", status=403)
api("decisions/" + rid + "/answer", {"answer": "Yes"}, actor="decision-coordinator", status=403)
api("decisions/" + rid + "/answer", {"answer": "Yes", "decision_admin": True}, actor="decision-coordinator", captain=True, status=422)
api("decisions/" + rid + "/answer", {"answer": "Yes"}, actor="decision-other", captain=True, status=403)
recommend = ab("decision", "recommend", rid, "--body", "Proceed with captain approval", actor="decision-coordinator")
assert recommend["decision"]["recommended_by"] == "decision-coordinator"

# Expiry and heartbeat staleness do not grant another seat recovery rights.
sql("UPDATE tasks SET claimed_at=clock_timestamp()-interval '2 seconds',claim_expires_at=clock_timestamp()-interval '1 second' WHERE id='decision-task'")
held = ab("task", "show", "decision-task")["task"]
assert held["claim_expired"] and held["held_by_decision"] and held["requester_stale"]
api("tasks/decision-task/reclaim", {}, actor="decision-other", status=409)
api("tasks/decision-task/release", {"expired": True}, actor="decision-other", status=409)
api("tasks/decision-task/handoff", {"to": "decision-other", "note": "transfer"}, status=409)
api("tasks/decision-task/update", {"status": "cancelled"}, status=409)

# Failed wake insertion rolls back the answer, inbox and timeline together.
sql("CREATE FUNCTION reject_decision_wake() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture wake failure'; END $$")
sql("CREATE TRIGGER reject_decision_wake BEFORE INSERT ON decision_wakes FOR EACH ROW EXECUTE FUNCTION reject_decision_wake()")
prior_counts = counts("decision-task")
api("decisions/" + rid + "/answer", {"answer": "Approved\nKeep verbatim"}, actor="decision-coordinator", captain=True, status=503)
assert api("decisions/" + rid)["decision"]["status"] == "open"
assert counts("decision-task") == prior_counts
sql("DROP TRIGGER reject_decision_wake ON decision_wakes")

rpc('Application.put_env(:agentboard,:message_mode,"dual")')
mm_before = sql("SELECT count(*) FROM mattermost_outbox")
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    answers = list(pool.map(lambda _: api("decisions/" + rid + "/answer",
                         {"answer": "Approved\nKeep verbatim"}, actor="decision-coordinator", captain=True), range(2)))
assert answers[0] == answers[1]
answered = answers[0]
assert sql("SELECT count(*) FROM mattermost_outbox") == mm_before
assert answered["decision"]["on_behalf_of"] == "captain"
assert answered["wake"]["route"] == "seat_watcher"
assert answered["wake"]["source_key"] == "decision:" + rid + ":answer"
assert sql("SELECT count(*) FROM decision_wakes WHERE request_id='" + rid + "'") == "1"
assert sql("SELECT count(*) FROM task_events WHERE task_id='decision-task' AND kind='decision_answered'") == "1"
inbox = ab("msg", "list", "--to", "decision-seat", "--task", "decision-task", "--unread")["messages"]
assert len(inbox) == 1 and inbox[0]["id"] == answered["decision"]["message_id"]
assert payload["question"] in inbox[0]["body"] and answered["decision"]["answer"] in inbox[0]["body"]
api("decisions/" + rid + "/answer", {"answer": "Changed"}, actor="decision-coordinator", captain=True, status=409)
# A durable reserve grants physical dispatch only once, even for the same key.
wid = answered["wake"]["id"]
api("decisions/wakes/" + wid + "/reserve", {"key": "watcher-1"}, actor="decision-coordinator", status=403)
first = ab("decision", "wake", "reserve", wid, "--key", "watcher-1", actor="decision-coordinator")
assert first["dispatch_allowed"]
retry = ab("decision", "wake", "reserve", wid, "--key", "watcher-1", actor="decision-coordinator")
assert not retry["dispatch_allowed"]
api("decisions/wakes/" + wid + "/accept", {"key": "foreign"}, actor="decision-coordinator", captain=True, status=409)
accepted = ab("decision", "wake", "accept", wid, "--key", "watcher-1", actor="decision-coordinator")
assert accepted["wake"]["status"] == "accepted"
assert not ab("decision", "wake", "reserve", wid, "--key", "watcher-1", actor="decision-coordinator")["dispatch_allowed"]


api("decisions/" + rid + "/ack", {}, actor="decision-other", status=403)
api("decisions/" + rid + "/withdraw", {"reason": "steal"}, actor="decision-other", status=403)
api("decisions/" + rid + "/ack", {}, status=409)
api("tasks/decision-task/renew", {})
assert ab("decision", "ack", rid)["decision"]["status"] == "applied"
assert not api("tasks/decision-task")["task"]["held_by_decision"]
assert ab("decision", "ack", rid)["decision"]["status"] == "applied"

# Recovery supersedes all outstanding requests, never implicitly transfers work.
create_task("recovery-task")
r1 = api("decisions", request("recovery-task", "gate-1"))["decision"]["id"]
r2 = api("decisions", request("recovery-task", "gate-2"))["decision"]["id"]
a2 = api("decisions/" + r2 + "/answer", {"answer": "wait"}, actor="decision-coordinator", captain=True)
w2 = a2["wake"]["id"]
ab("decision", "wake", "reserve", w2, "--key", "uncertain-1", actor="decision-coordinator")
ab("decision", "wake", "uncertain", w2, "--key", "uncertain-1", "--reason", "Connection lost", actor="decision-coordinator")
sql("UPDATE tasks SET claimed_at=clock_timestamp()-interval '2 seconds',claim_expires_at=clock_timestamp()-interval '1 second' WHERE id='recovery-task'")
api("decisions/" + r1 + "/supersede", {"reason": "Explicit captain recovery"}, actor="decision-coordinator", status=403)
ab("decision", "supersede", r1, "--reason", "Explicit captain recovery", actor="decision-coordinator")
records = ab("decision", "list", "--task", "recovery-task")["decisions"]
assert len(records) == 2 and all(r["status"] == "superseded" and r["closed_by"] == "decision-coordinator" for r in records)
assert ab("decision", "wake", "list", "--task", "recovery-task")["wakes"][0]["status"] == "uncertain"
assert api("tasks/recovery-task")["task"]["assignee_id"] == "decision-seat"
assert api("tasks/recovery-task/reclaim", {}, actor="decision-other")["task"]["assignee_id"] == "decision-other"

create_task("withdraw-task")
wr = api("decisions", request("withdraw-task"))["decision"]["id"]
assert ab("decision", "withdraw", wr, "--reason", "Gate withdrawn")["decision"]["status"] == "withdrawn"
assert not api("tasks/withdraw-task")["task"]["held_by_decision"]
create_task("self-task", owner="decision-coordinator")
self_id = api("decisions", request("self-task"), actor="decision-coordinator")["decision"]["id"]
api("decisions/" + self_id + "/answer", {"answer": "self"}, actor="decision-coordinator", captain=True, status=403)

# Stable equal-time ordering and filter-bound cursors.
create_task("page-task")
ids = [api("decisions", request("page-task", "gate-" + str(i)))["decision"]["id"] for i in range(3)]
sql("UPDATE decision_requests SET created_at='2026-01-01T00:00:00Z' WHERE task_id='page-task'")
page = api("decisions?task=page-task&limit=1")
walk = []
while True:
    walk += [r["id"] for r in page["decisions"]]
    cursor = page["next_cursor"]
    if not cursor:
        break
    api("decisions?task=withdraw-task&limit=1&cursor=" + urllib.parse.quote(cursor), status=422)
    api("decisions/wakes?task=page-task&limit=1&cursor=" + urllib.parse.quote(cursor), status=422)
    page = api("decisions?task=page-task&limit=1&cursor=" + urllib.parse.quote(cursor))
assert walk == sorted(ids)

# Actual connected rendering escapes findings, guards spoofed forms and exposes waits.
view = LiveView(URL, "/")
Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"],"board-connected.json").write_text(json.dumps(view.initial))
assert contains(view.initial, "Waiting on captain")
assert contains(view.initial, "&lt;script&gt;verbatim&lt;/script&gt;")
assert contains(view.initial, "requester_stale")
view.send(["1","decision-spoof",view.topic,"event",{"type":"form","event":"decision_answer","value":urllib.parse.urlencode({"decision_id":ids[0],"answer":"spoofed"})}])
response = view.wait(lambda e: e[3] == "phx_reply" and e[1] == "decision-spoof")
assert contains(response, "Unlock captain controls")
assert api("decisions/" + ids[0])["decision"]["status"] == "open"
view.close()
api("tasks/page-task/link", {"pr_url": "https://github.com/fixture/decisions/pull/700"})
prs = LiveView(URL, "/prs")
Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"],"prs-connected.json").write_text(json.dumps(prs.initial))
assert contains(prs.initial, "Waiting on captain") and contains(prs.initial, "requester_stale")
prs.close()
agents = ab("agent", "list", "--waiting", "true")["agents"]
assert any(a["id"] == "decision-seat" and a["waiting_on_captain"] for a in agents)
assert all(a["waiting_on_captain"] for a in agents)
assert sql("SELECT count(*) FROM decision_requests_versions WHERE provenance->>'agent'='decision-coordinator'") != "0"
assert sql("SELECT count(*) FROM decision_wakes_versions") != "0"
print("Decision request/list/answer/inbox/frozen-wake/ack/recovery/auth/pagination packaged proof passed")


# Enrolled healthy capability chooses exactly one named generic worker route.
rpc('Application.put_env(:agentboard,:cooperation_enabled,true)')
provision = {"worker_id":"decision-worker","host_id":"fixture-host","repos":["fixture/decisions"],"model":"fixture","harness":"codex","idempotency_key":"decision-provision"}
host = api("workers/provision",provision,actor="captain",captain=True)["host_token"]
capabilities = {name:{"supported":name in ("turn_start","receipt","recovery"),"reason":"Invented adapter fixture"} for name in ("idle_wake","turn_start","tool_return","receipt","recovery")}
api("workers/decision-worker/bind", {"idempotency_key":"decision-bind","expected_epoch":0,"host_id":"fixture-host","session_id":"fixture-session","pane_id":"fixture-pane","adapter":"manual","adapter_version":"1","capabilities":capabilities},token=host)
api("workers/decision-worker/report", {"binding_epoch":1,"connector_state":"healthy","adapter_state":"ready","reason":"Fixture proof","capabilities":capabilities},token=host)
create_task("worker-decision-task",owner="decision-worker")
worker_id = api("decisions",request("worker-decision-task"),actor="decision-worker")["decision"]["id"]
worker_answer = api("decisions/"+worker_id+"/answer",{"answer":"Proceed"},actor="decision-coordinator",captain=True)
assert worker_answer["wake"]["route"] == "worker"
assert worker_answer["wake"]["worker_id"] == "decision-worker"
pending = api("workers/decision-worker/pending",token=host)
assert sql("SELECT audience::text FROM cooperation_events WHERE source_key='decision:"+worker_id+":answer'") == "{decision-worker}"
assert sql("SELECT count(*) FROM cooperation_deliveries WHERE worker_id='decision-worker' AND event_id=(SELECT id FROM cooperation_events WHERE source_key='decision:"+worker_id+":answer')") == "1"
assert sql("SELECT kind FROM cooperation_events WHERE source_key='decision:"+worker_id+":answer'") == "decision_answered"
api("decisions/wakes/"+worker_answer["wake"]["id"]+"/reserve",{"key":"must-not-fallback"},actor="decision-coordinator",captain=True,status=409)
# Default-off after enrollment still freezes fallback; later enablement adds no event.
rpc('Application.put_env(:agentboard,:cooperation_enabled,false)')
create_task("disabled-decision-task",owner="decision-worker")
disabled_id = api("decisions",request("disabled-decision-task"),actor="decision-worker")["decision"]["id"]
disabled = api("decisions/"+disabled_id+"/answer",{"answer":"Proceed"},actor="decision-coordinator",captain=True)
assert disabled["wake"]["route"] == "seat_watcher"
rpc('Application.put_env(:agentboard,:cooperation_enabled,true)')
assert api("decisions/"+disabled_id+"/answer",{"answer":"Proceed"},actor="decision-coordinator",captain=True) == disabled
assert sql("SELECT count(*) FROM cooperation_events WHERE source_key='decision:"+disabled_id+":answer'") == "0"

# Execute the fallback consumer against the real CLI/API. Fake native submitter
# asserts the emitted JSON frame contract; it never implements board behavior.
consumer = Path(os.environ["TEST_SRCDIR"])/os.environ["TEST_WORKSPACE"]/"scripts/decision-wake-consumer.py"
submitter = Path(os.environ["TEST_TMPDIR"])/"decision-submit.py"
frames = Path(os.environ["TEST_TMPDIR"])/"decision-frames.ndjson"
submitter.write_text("import json,sys\nfrom pathlib import Path\nframe=json.load(sys.stdin)\nassert frame['source_key']=='decision:'+frame['decision_id']+':answer'\nassert frame['answered_at'] and frame['requester_id']=='decision-seat'\nwith Path(sys.argv[1]).open('a') as f:f.write(json.dumps(frame)+'\\n')\nsys.exit(int(sys.argv[2]))\n")
create_task("consumer-task")
findings_file = Path(os.environ["TEST_TMPDIR"])/"verbatim-findings.txt"
findings_file.write_text("  F1 café\ncritical file.ex:7 authority ask-user\n")
cr = ab("decision","request","--task","consumer-task","--gate","consumer-gate","--question","Exact?","--findings-file",str(findings_file))["decision"]
assert cr["findings"] == findings_file.read_text()
canswer = api("decisions/"+cr["id"]+"/answer",{"answer":"Approved"},actor="decision-coordinator",captain=True)
def consume(exit_code=0,execute=True):
    command = ["python3",str(consumer),"--owner","decision-seat","--task","consumer-task","--agentboard",os.environ["AB_BINARY"]]
    if execute: command += ["--execute","--","python3",str(submitter),str(frames),str(exit_code)]
    result=subprocess.run(command,env=dict(BASE,AGENT_ID="decision-coordinator"),capture_output=True,text=True,timeout=30)
    assert result.returncode == 0,(result.stdout,result.stderr)
    return result.stdout
assert '"dry_run": true' in consume(execute=False) and not frames.exists()
consume()
assert len(frames.read_text().splitlines()) == 1
consume()
assert len(frames.read_text().splitlines()) == 1
cr2 = api("decisions",request("consumer-task","uncertain-gate"))["decision"]
api("decisions/"+cr2["id"]+"/answer",{"answer":"Approved"},actor="decision-coordinator",captain=True)
assert '"uncertain"' in consume(exit_code=1)
assert len(frames.read_text().splitlines()) == 2
consume()
assert len(frames.read_text().splitlines()) == 2
assert any(w["status"] == "uncertain" for w in ab("decision","wake","list","--task","consumer-task")["wakes"])
print("Worker/default-off/frozen-route/no-MM and executable fallback disposition proof passed")

# Availability and simultaneous watchers fence the actual reservation write.
create_task("reservation-task")
race_id=api("decisions",request("reservation-task"))["decision"]["id"]
race_wake=api("decisions/"+race_id+"/answer",{"answer":"Proceed"},actor="decision-coordinator",captain=True)["wake"]["id"]
api("availability",{"agent_id":"decision-seat","state":"out_of_service","reason":"Fixture maintenance"},actor="captain",captain=True)
api("decisions/wakes/"+race_wake+"/reserve",{"key":"unavailable"},actor="decision-coordinator",captain=True,status=409)
assert ab("decision","wake","list","--task","reservation-task")["wakes"][0]["status"] == "pending"
api("availability",{"agent_id":"decision-seat","state":"active","reason":"Fixture restoration"},actor="captain",captain=True)
def reserve_racer(key):
    result=subprocess.run([os.environ["AB_BINARY"],"--json","decision","wake","reserve",race_wake,"--key",key],env=dict(BASE,AGENT_ID="decision-coordinator"),capture_output=True,text=True,timeout=20)
    assert result.returncode in (0,4),(result.stdout,result.stderr)
    return result.returncode,json.loads(result.stdout if result.returncode == 0 else result.stderr)
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    racers=list(pool.map(reserve_racer,["watcher-a","watcher-b"]))
assert sum(code == 0 and body.get("dispatch_allowed") is True for code,body in racers) == 1
assert sum(code == 4 for code,_ in racers) == 1
print("Availability and concurrent fallback reservation proof passed")

create_task("skip-task")
skip1 = api("decisions", request("skip-task", "skip-gate-1"))["decision"]["id"]
skip2 = api("decisions", request("skip-task", "skip-gate-2"))["decision"]["id"]
skip_wake1 = api("decisions/" + skip1 + "/answer", {"answer": "Proceed"}, actor="decision-coordinator", captain=True)["wake"]["id"]
skip_wake2 = api("decisions/" + skip2 + "/answer", {"answer": "Proceed"}, actor="decision-coordinator", captain=True)["wake"]["id"]
skip_frames = Path(os.environ["TEST_TMPDIR"]) / "decision-skip-frames.ndjson"
assert not skip_frames.exists()
api("availability", {"agent_id": "decision-seat", "state": "out_of_service", "reason": "Fixture skip proof"}, actor="captain", captain=True)
skip_cmd = ["python3", str(consumer), "--owner", "decision-seat", "--task", "skip-task", "--agentboard", os.environ["AB_BINARY"],
            "--execute", "--", "python3", str(submitter), str(skip_frames), "0"]
denied = subprocess.run(skip_cmd, env=dict(BASE, AGENT_ID="decision-coordinator"), capture_output=True, text=True, timeout=30)
assert denied.returncode == 0, (denied.stdout, denied.stderr)
assert skip_wake1 in denied.stdout and skip_wake2 in denied.stdout
assert denied.stdout.count('"skipped"') == 2 and '"accepted"' not in denied.stdout
assert not skip_frames.exists()
wakes = {w["id"]: w for w in ab("decision", "wake", "list", "--task", "skip-task")["wakes"]}
assert wakes[skip_wake1]["status"] == "pending" and wakes[skip_wake2]["status"] == "pending"
api("availability", {"agent_id": "decision-seat", "state": "active", "reason": "Fixture skip restoration"}, actor="captain", captain=True)
restored = subprocess.run(skip_cmd, env=dict(BASE, AGENT_ID="decision-coordinator"), capture_output=True, text=True, timeout=30)
assert restored.returncode == 0, (restored.stdout, restored.stderr)
assert restored.stdout.count('"accepted"') == 2
lines = skip_frames.read_text().splitlines()
assert len(lines) == 2 and {json.loads(line)["wake_id"] for line in lines} == {skip_wake1, skip_wake2}
wakes = {w["id"]: w for w in ab("decision", "wake", "list", "--task", "skip-task")["wakes"]}
assert wakes[skip_wake1]["status"] == "accepted" and wakes[skip_wake2]["status"] == "accepted"
print("Denied first wake skips without suppressing the later eligible wake proof passed")

# Retain actual packaged server HTML/CSS for isolated browser visual review.
# This is supplemental product evidence, not a hand-authored UI or test seam.
out=Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"])
for label,path in [("board","/tasks/page-task"),("prs","/prs")]:
    document=urllib.request.urlopen(URL+path,timeout=15).read().decode()
    styles=re.findall(r'<link[^>]+href="([^" ]+\.css[^" ]*)"[^>]*>',document)
    for style in styles:
        css=urllib.request.urlopen(urllib.parse.urljoin(URL,style),timeout=15).read().decode()
        document=document.replace('href="'+style+'"','href="data:text/css;base64,'+__import__('base64').b64encode(css.encode()).decode()+'"')
    document=re.sub(r'<script\b[^>]*>.*?</script>', '', document, flags=re.S)
    document=re.sub(r'\s(?:data-phx-session|data-phx-static)="[^" ]*"', '', document)
    (out/(label+"-decision-preview.html")).write_text(document)

# Use the real protected browser session and LiveView form actions: attribution
# alone is insufficient, and the fixed captain identity owns both audited writes.
create_task("captain-ui-task")
ui_id=api("decisions",request("captain-ui-task"))["decision"]["id"]
jar=http.cookiejar.CookieJar()
browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
settings=Page();settings.feed(browser.open(URL+"/settings",timeout=10).read().decode())
assert settings.csrf
unlock=urllib.request.Request(URL+"/settings/unlock",data=urllib.parse.urlencode({"token":CAPTAIN,"_csrf_token":settings.csrf}).encode(),headers={"Content-Type":"application/x-www-form-urlencoded","Origin":URL})
assert browser.open(unlock,timeout=10).status == 200
cookie='; '.join(c.name+'='+c.value for c in jar)
captain_view=LiveView(URL,"/tasks/captain-ui-task",cookie)
assert contains(captain_view.initial,"Answer decision") and contains(captain_view.initial,"Supersede all outstanding")
Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"],"captain-connected.json").write_text(json.dumps(captain_view.initial))
captain_view.send(["1","captain-answer",captain_view.topic,"event",{"type":"form","event":"decision_answer","value":urllib.parse.urlencode({"decision_id":ui_id,"answer":"Browser captain approved"})}])
assert captain_view.wait(lambda e:e[3] == "phx_reply" and e[1] == "captain-answer")
ui_answer=api("decisions/"+ui_id)["decision"]
assert ui_answer["status"] == "answered" and ui_answer["answered_by"] == "captain" and ui_answer["on_behalf_of"] == "captain"
api("decisions",request("captain-ui-task","second-ui-gate"))
captain_view.send(["1","captain-recovery",captain_view.topic,"event",{"type":"form","event":"decision_supersede","value":urllib.parse.urlencode({"decision_id":ui_id,"reason":"Browser captain recovery"})}])
assert captain_view.wait(lambda e:e[3] == "phx_reply" and e[1] == "captain-recovery")
ui_records=ab("decision","list","--task","captain-ui-task")["decisions"]
assert len(ui_records) == 2 and all(r["status"] == "superseded" and r["closed_by"] == "captain" and r["close_reason"] == "Browser captain recovery" for r in ui_records)
assert api("tasks/captain-ui-task")["task"]["assignee_id"] == "decision-seat"
captain_view.close()
print("Protected captain browser answer and all-request recovery form proof passed")
