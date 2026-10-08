"""Decision ownership, atomic delivery and replay fences at the packaged HTTP/CLI/PG boundary.
Invented actors only. Existing board/runtime fixtures own general lease and receipt behavior;
this fixture owns their decision integration and new public wire contract."""
import http.cookiejar
import concurrent.futures
from html.parser import HTMLParser
import json
import os
import re
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from liveview_client import LiveView, Page, contains, RenderedView

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

def create_task(id, owner="decision-seat", repo="fixture/decisions"):
    api("tasks", {"id": id, "title": "Decision fixture", "repo": repo})
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
# Universal intake protects the public CLI contract: positional task, optional
# non-gate evidence, and server-authoritative Unicode/whitespace retry identity.
create_task("universal-task")
u = ab("decision", "request", "universal-task", "--kind", "scope",
       "--question", "  Café\u00a0release?  ", "--option", "Proceed")["decision"]
assert u["question"] == "  Café\u00a0release?  " and u["findings"] == ""
retry = api("decisions", {"task":"universal-task","kind":"scope",
            "question":"Cafe\u0301 \nrelease?","options":["Proceed"]})["decision"]
assert retry["id"] == u["id"] and retry["question"] == u["question"]
api("decisions", {"task":"universal-task","kind":"scope",
    "question":"Café release?","options":["Changed"]}, status=409)
assert sql("SELECT count(*) FROM task_events WHERE task_id='universal-task' AND kind='decision_requested'") == "1"

# Retained terminal retries do not reopen; an intentional re-ask has a stable
# retry key and still produces one event under concurrent transport retries.
api("decisions/" + u["id"] + "/answer", {"answer":"Proceed"}, actor="decision-coordinator", captain=True)
waiting = ab("decision","waiting","--task","universal-task")
assert waiting["total"] == 0 and waiting["answered_total"] == 1
ab("decision","ack",u["id"])
assert ab("decision","request","universal-task","--kind","scope","--question","Café release?","--option","Proceed")["decision"]["id"] == u["id"]
assert not api("tasks/universal-task")["task"]["held_by_decision"]
new_payload={"task":"universal-task","kind":"scope","question":"Café release?","options":["Proceed"],"new":True,"request_key":"fixture-reask-1"}
with concurrent.futures.ThreadPoolExecutor(2) as pool:
    rerequests=list(pool.map(lambda _: api("decisions",new_payload),range(2)))
assert rerequests[0]["decision"]["id"] == rerequests[1]["decision"]["id"] != u["id"]
api("decisions",dict(new_payload,request_key="another-generation"),status=409)
ab("decision","request","universal-task","--task","other-task","--question","Mismatch",code=2)
ab("decision","request","universal-task","--kind","ask_user_gate","--question","Missing evidence",code=2)
api("decisions",{"task":"universal-task","kind":"ask_user_gate","gate":"missing-file","question":"Missing"},status=422)
for kind in ("approval","merge","policy","credential","scope","blocked_decision","other"):
    create_task("kind-"+kind.replace("_","-"))
    assert ab("decision","request","kind-"+kind.replace("_","-"),"--kind",kind,"--question","Capability question")["decision"]["kind"] == kind

# Read-only informal recovery: latest owner source, quoted/negated markers,
# explicit authority, revision/source CAS and retained terminal suppression.
create_task("unfiled-task")
api("tasks/unfiled-task/update",{"status":"blocked","note":"CAPTAIN DECISION: approve invented scope <script>raw</script>"})
informal=ab("decision","waiting","--task","unfiled-task")
assert informal["total"] == 1 and informal["answered_total"] == 0
source=informal["decisions"][0]
assert source["status"] == "unfiled" and not source["held_by_decision"]
assert not api("tasks/unfiled-task")["task"]["held_by_decision"]
promotion={"task":"unfiled-task","source_type":source["source_type"],"source_id":source["source_id"],"revision":source["revision"],"kind":"scope","question":"Approve invented scope?","options":["Proceed"]}
api("decisions/promote",promotion,actor="decision-other",status=403)
api("tasks/unfiled-task/update",{"note":"Waiting on captain: revised invented scope"})
api("decisions/promote",promotion,actor="decision-coordinator",captain=True,status=409)
source=ab("decision","waiting","--task","unfiled-task")["decisions"][0]
promoted=ab("decision","promote","unfiled-task","--source-type",source["source_type"],"--source-id",source["source_id"],"--revision",str(source["revision"]),"--kind","scope","--question","Approve revised scope?","--option","Proceed",actor="decision-coordinator")["decision"]
assert promoted["requester_id"] == "decision-seat" and promoted["promoted_by"] == "decision-coordinator"
assert promoted["findings"] == "Waiting on captain: revised invented scope"
p_retry=dict(promotion,source_type=source["source_type"],source_id=source["source_id"],revision=source["revision"],question="Approve revised scope?")
assert api("decisions/promote",p_retry,actor="decision-coordinator",captain=True)["decision"]["id"] == promoted["id"]
ab("decision","supersede",promoted["id"],"--reason","Source resolved",actor="decision-coordinator")
assert ab("decision","waiting","--task","unfiled-task")["total"] == 0
api("tasks/unfiled-task/update",{"note":"CAPTAIN DECISION: a new source"})
assert ab("decision","waiting","--task","unfiled-task")["total"] == 1
api("tasks/unfiled-task/update",{"note":"No captain decision needed; continuing"})
assert ab("decision","waiting","--task","unfiled-task")["total"] == 0
api("tasks/unfiled-task/update",{"note":"> CAPTAIN DECISION: quoted old ask"})
assert ab("decision","waiting","--task","unfiled-task")["total"] == 0
ab("msg","send","--to","decision-coordinator","--task","unfiled-task","--body","waiting on captain: newest owner message")
assert ab("decision","waiting","--task","unfiled-task")["decisions"][0]["source_type"] == "message"
api("tasks/unfiled-task/update",{"note":"Non-captain progress removes informal ask"})
assert ab("decision","waiting","--task","unfiled-task")["total"] == 0
api("tasks/unfiled-task/update",{"note":"CAPTAIN DECISION: terminal ask"})
api("tasks/unfiled-task/update",{"status":"cancelled","note":"Cancelled"})
assert ab("decision","waiting","--task","unfiled-task")["total"] == 0

# Exact32-row total remains independent of20-row paging and task/status views.
create_task("lane-task",repo="fixture/lane")
lane_ids=[api("decisions",{"task":"lane-task","question":"Lane question "+str(i)})["decision"]["id"] for i in range(32)]
sql("UPDATE decision_requests SET created_at='2026-01-02T00:00:00Z' WHERE task_id='lane-task'")
lane=api("decisions/waiting?task=lane-task&limit=20")
assert lane["total"] == 32 and len(lane["decisions"]) == 20 and lane["next_cursor"]
api("decisions/waiting?task=unfiled-task&cursor="+urllib.parse.quote(lane["next_cursor"]),status=422)
tail=api("decisions/waiting?task=lane-task&limit=20&cursor="+urllib.parse.quote(lane["next_cursor"]))
assert tail["total"] == 32 and len(tail["decisions"]) == 12 and not tail["next_cursor"]
assert [r["id"] for r in lane["decisions"]+tail["decisions"]] == sorted(lane_ids)
lane_view=LiveView(URL,"/?repo=fixture%2Fdecisions&status=review")
assert contains(lane_view.initial,"captain-waiting-count") and contains(lane_view.initial,"data-count")
lane_view.close()
task_lane=LiveView(URL,"/tasks/lane-task")
Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"],"waiting-lane-connected.json").write_text(json.dumps(task_lane.initial))
assert contains(task_lane.initial,"32") and contains(task_lane.initial,"Next waiting decisions")
task_lane.close()

create_task("mixed-lane-task",repo="fixture/lane")
api("tasks/mixed-lane-task/update",{"status":"blocked","note":"CAPTAIN DECISION: mixed source"})
mixed=api("decisions/waiting?repo=fixture%2Flane&limit=20")
assert mixed["total"] == 33 and len(mixed["decisions"]) == 20
mixed_tail=api("decisions/waiting?repo=fixture%2Flane&limit=20&cursor="+urllib.parse.quote(mixed["next_cursor"]))
assert mixed_tail["total"] == 33 and len(mixed_tail["decisions"]) == 13
assert mixed_tail["decisions"][-1]["status"] == "unfiled"
board_lane=RenderedView(URL,"/?repo=fixture%2Flane&status=review")
# Decode the actual connected wire result through the pinned Phoenix consumer.
lane_html=board_lane.document
assert lane_html.index('id="captain-waiting"') < lane_html.index('class="board-columns"')
assert 'data-count="33"' in lane_html and "33" in lane_html
styles_page=urllib.request.urlopen(URL+"/",timeout=15).read().decode()
styles=[]
for css_path in re.findall(r'<link[^>]+href="([^" ]+\.css[^" ]*)"',styles_page):
    styles.append(urllib.request.urlopen(urllib.parse.urljoin(URL,css_path),timeout=15).read().decode())
Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"],"waiting-lane-preview.html").write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Agentboard waiting lane — remote fixture</title><style>'+''.join(styles)+'</style><body>'+lane_html+'</body></html>')
sql("ALTER TABLE decision_requests RENAME COLUMN source_type TO fixture_missing_source")
try:
    assert api("decisions/waiting?task=lane-task",status=503)["error"]["code"] == "unavailable"
    unavailable=board_lane.live.wait(lambda e:e[3]=="diff" and contains(e,"count and freshness are unknown"),timeout=8)
    assert unavailable
    board_lane.diffs.extend(event[4] for event in board_lane.live.events if event[3]=="diff")
    board_lane.live.events.clear()
    retained=board_lane.render()
    assert 'data-count="?"' in retained and "Lane question" in retained
finally:
    sql("ALTER TABLE decision_requests RENAME COLUMN fixture_missing_source TO source_type")
    board_lane.close()

create_task("promotion-ownership")
api("tasks/promotion-ownership/update",{"status":"blocked","note":"CAPTAIN DECISION: owner question"})
owned_source=ab("decision","waiting","--task","promotion-ownership")["decisions"][0]
api("tasks/promotion-ownership/handoff",{"to":"decision-other","note":"Explicit handoff"})
lost={"task":"promotion-ownership","source_type":owned_source["source_type"],"source_id":owned_source["source_id"],"revision":owned_source["revision"],"kind":"scope","question":"Owner question"}
api("decisions/promote",lost,actor="decision-coordinator",captain=True,status=409)
assert api("tasks/promotion-ownership")["task"]["assignee_id"] == "decision-other"
assert sql("SELECT count(*) FROM decision_requests WHERE task_id='promotion-ownership'") == "0"

# Connected board Promote keeps the selected non-default kind/options: the same
# reducer the CLI promote path proves, driven through the real LiveView form.
create_task("board-promote-task")
api("tasks/board-promote-task/update",{"status":"blocked","note":"CAPTAIN DECISION: board scope ask"})
board_source=ab("decision","waiting","--task","board-promote-task")["decisions"][0]
assert board_source["status"] == "unfiled"
# Current revision with no qualifying source refuses with conflict, never a crash.
create_task("board-promote-nonsource")
current_revision=api("tasks/board-promote-nonsource")["task"]["revision"]
api("decisions/promote",{"task":"board-promote-nonsource","source_type":"message","source_id":"00000000-0000-4000-8000-000000000000","revision":current_revision,"kind":"scope","question":"No qualifying source"},actor="decision-coordinator",captain=True,status=409)
assert sql("SELECT count(*) FROM decision_requests WHERE task_id='board-promote-nonsource'") == "0"
# An observer browser session cannot promote through the board form.
observer_view=LiveView(URL,"/tasks/board-promote-task")
observer_view.send(["1","observer-promote",observer_view.topic,"event",{"type":"form","event":"decision_promote","value":urllib.parse.urlencode({"task":"board-promote-task","source_type":board_source["source_type"],"source_id":board_source["source_id"],"revision":str(board_source["revision"]),"question":"Board promote scope question?","kind":"scope","options":"Proceed\nDefer"})}])
observer_reply=observer_view.wait(lambda e:e[3] == "phx_reply" and e[1] == "observer-promote")
assert observer_reply and contains(observer_reply,"Unlock captain controls before promotion")
assert sql("SELECT count(*) FROM decision_requests WHERE task_id='board-promote-task'") == "0"
observer_view.close()
board_jar=http.cookiejar.CookieJar()
board_browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(board_jar))
board_settings=Page();board_settings.feed(board_browser.open(URL+"/settings",timeout=10).read().decode())
board_unlock=urllib.request.Request(URL+"/settings/unlock",data=urllib.parse.urlencode({"token":CAPTAIN,"_csrf_token":board_settings.csrf}).encode(),headers={"Content-Type":"application/x-www-form-urlencoded","Origin":URL})
assert board_browser.open(board_unlock,timeout=10).status == 200
board_cookie='; '.join(c.name+'='+c.value for c in board_jar)
board_view=LiveView(URL,"/tasks/board-promote-task",board_cookie)
board_view.send(["1","board-promote",board_view.topic,"event",{"type":"form","event":"decision_promote","value":urllib.parse.urlencode({"task":"board-promote-task","source_type":board_source["source_type"],"source_id":board_source["source_id"],"revision":str(board_source["revision"]),"question":"Board promote scope question?","kind":"scope","options":"Proceed\nDefer"})}])
assert board_view.wait(lambda e:e[3] == "phx_reply" and e[1] == "board-promote")
board_view.close()
board_promoted=ab("decision","list","--task","board-promote-task")["decisions"][0]
assert board_promoted["kind"] == "scope" and board_promoted["options"] == ["Proceed","Defer"]
assert board_promoted["question"] == "Board promote scope question?"
assert board_promoted["findings"] == "CAPTAIN DECISION: board scope ask"
assert board_promoted["requester_id"] == "decision-seat" and board_promoted["promoted_by"] == "captain"
assert board_promoted["source_type"] == board_source["source_type"] and board_promoted["source_id"] == board_source["source_id"]
print("Board LiveView promote preserves selected kind/options with provenance proof passed")

# Default-off cleanup and explicit TTL retirement retain audit and emit no
# answer/inbox/wake. Expiry payload changes conflict instead of mutating history.
create_task("expiry-task")
expiry=ab("decision","request","expiry-task","--kind","policy","--question","Expiry fixture","--expires-in","60")["decision"]
api("decisions",{"task":"expiry-task","kind":"policy","question":"Expiry fixture","expires_in":120},status=409)
sql("UPDATE decision_requests SET expires_at=clock_timestamp()-interval '1 second' WHERE task_id='expiry-task'")
rpc('Agentboard.Decisions.cleanup()')
assert api("decisions/"+expiry["id"])["decision"]["status"] == "open"
prior=counts("expiry-task")
rpc('Application.put_env(:agentboard,:decision_cleanup_enabled,true); {:ok,_}=Agentboard.Decisions.cleanup()')
expired=api("decisions/"+expiry["id"])["decision"]
assert expired["status"] == "superseded" and expired["close_reason"] == "expired: explicit non-gate TTL"
assert expired["answer"] is None
assert json.loads(counts("expiry-task"))[0:1]+json.loads(counts("expiry-task"))[2:] == json.loads(prior)[0:1]+json.loads(prior)[2:]
create_task("merge-expiry-task")
merge_url="https://github.com/fixture/decisions/pull/729"
api("tasks/merge-expiry-task/link",{"pr_url":merge_url})
merge=ab("decision","request","merge-expiry-task","--kind","merge","--question","Review this PR?")["decision"]
assert merge["bound_pr"] == merge_url
pr_id=sql("SELECT id FROM delivery_pull_requests WHERE url='"+merge_url+"'")
sql("UPDATE delivery_poll_states SET lifecycle='merged',observed_at=clock_timestamp()-interval '1 hour' WHERE id='"+pr_id+"'")
rpc('Agentboard.Decisions.cleanup()')
assert api("decisions/"+merge["id"])["decision"]["status"] == "open"
sql("UPDATE delivery_poll_states SET observed_at=clock_timestamp() WHERE id='"+pr_id+"'")
api("tasks/merge-expiry-task/link",{"pr_url":"https://github.com/fixture/decisions/pull/730"})
rpc('Agentboard.Decisions.cleanup()')
assert api("decisions/"+merge["id"])["decision"]["status"] == "open"
api("tasks/merge-expiry-task/link",{"pr_url":merge_url})
prior=counts("merge-expiry-task")
rpc('Agentboard.Decisions.cleanup()')
closed=api("decisions/"+merge["id"])["decision"]
assert closed["status"] == "superseded" and closed["close_reason"] == "bound PR terminal: merged"
assert json.loads(counts("merge-expiry-task"))[0] == json.loads(prior)[0] and closed["answer"] is None
assert sql("SELECT count(*) FROM decision_wakes WHERE task_id='merge-expiry-task'") == "0"
# Scheduling isolation: one poisoned cleanup candidate neither stalls delivery
# scheduling nor starves a healthy peer retirement. A trigger fails updates to
# the poison row through the real public cleanup and schedule_due actions.
create_task("cleanup-healthy-task")
create_task("cleanup-poison-task")
healthy=ab("decision","request","cleanup-healthy-task","--kind","policy","--question","Healthy TTL fixture","--expires-in","60")["decision"]
poison=ab("decision","request","cleanup-poison-task","--kind","policy","--question","Poison TTL fixture","--expires-in","60")["decision"]
sql("UPDATE decision_requests SET expires_at=clock_timestamp()-interval '1 second' WHERE task_id IN ('cleanup-healthy-task','cleanup-poison-task')")
sql("CREATE FUNCTION poison_decision_cleanup() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.task_id='cleanup-poison-task' THEN RAISE EXCEPTION 'fixture cleanup poison'; END IF; RETURN NEW; END $$")
sql("CREATE TRIGGER poison_decision_cleanup BEFORE UPDATE ON decision_requests FOR EACH ROW EXECUTE FUNCTION poison_decision_cleanup()")
rpc('Application.put_env(:agentboard,:decision_cleanup_enabled,true)')
rpc('Application.put_env(:agentboard,:pr_observation_enabled,true)')
try:
    rpc('{:ok,_}=Agentboard.Decisions.cleanup()')
    assert api("decisions/"+healthy["id"])["decision"]["status"] == "superseded"
    assert api("decisions/"+poison["id"])["decision"]["status"] == "open"
    rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.Observation, :schedule_due, %{}, actor: %{role: :system}); {:ok, %{enrolled: _}} = Ash.run_action(input)')
    assert api("decisions/"+healthy["id"])["decision"]["status"] == "superseded"
    assert api("decisions/"+poison["id"])["decision"]["status"] == "open"
    sql("ALTER TABLE decision_requests RENAME TO decision_requests_fixture_hidden")
    try:
        rpc('input = Ash.ActionInput.for_action(Agentboard.Delivery.Observation, :schedule_due, %{}, actor: %{role: :system}); {:ok, %{enrolled: _}} = Ash.run_action(input)')
    finally:
        sql("ALTER TABLE decision_requests_fixture_hidden RENAME TO decision_requests")
finally:
    sql("DROP TRIGGER poison_decision_cleanup ON decision_requests")
    sql("DROP FUNCTION poison_decision_cleanup()")
    rpc('Application.put_env(:agentboard,:pr_observation_enabled,false)')
print("Poisoned cleanup candidate cannot stall scheduling or starve peer retirement proof passed")
rpc('Application.put_env(:agentboard,:decision_cleanup_enabled,false)')
print("Universal requests, retained retries, re-ask, derived intake, promotion, paging and default-off TTL proof passed")

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
class _ScriptStripper(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.parts=[]
        self.depth=0
    def handle_starttag(self,tag,attrs):
        if tag.lower() == "script":
            self.depth+=1
        elif self.depth == 0:
            self.parts.append(self.get_starttag_text())
    def handle_endtag(self,tag):
        if tag.lower() == "script":
            self.depth=max(0,self.depth-1)
        elif self.depth == 0:
            self.parts.append("</%s>" % tag)
    def handle_startendtag(self,tag,attrs):
        if tag.lower() != "script" and self.depth == 0:
            self.parts.append(self.get_starttag_text())
    def handle_data(self,data):
        if self.depth == 0:
            self.parts.append(data)
    def handle_comment(self,data):
        if self.depth == 0:
            self.parts.append("<!--%s-->" % data)
    def handle_decl(self,decl):
        if self.depth == 0:
            self.parts.append("<!%s>" % decl)
    def handle_pi(self,data):
        if self.depth == 0:
            self.parts.append("<?%s>" % data)
    def handle_entityref(self,name):
        if self.depth == 0:
            self.parts.append("&%s;" % name)
    def handle_charref(self,name):
        if self.depth == 0:
            self.parts.append("&#%s;" % name)

def _strip_scripts(document):
    stripper=_ScriptStripper()
    stripper.feed(document)
    stripper.close()
    return "".join(stripper.parts)

out=Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"])
for label,path in [("board","/tasks/page-task"),("prs","/prs")]:
    document=urllib.request.urlopen(URL+path,timeout=15).read().decode()
    styles=re.findall(r'<link[^>]+href="([^" ]+\.css[^" ]*)"[^>]*>',document)
    for style in styles:
        css=urllib.request.urlopen(urllib.parse.urljoin(URL,style),timeout=15).read().decode()
        document=document.replace('href="'+style+'"','href="data:text/css;base64,'+__import__('base64').b64encode(css.encode()).decode()+'"')
    document=_strip_scripts(document)
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
