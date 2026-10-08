"""Cold-start operator mode selection through the packaged API and CLI."""
import json
import os
import subprocess
import urllib.request


def ab(*args, actor="mode-owner"):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture-model")
    result = subprocess.run([os.environ["AB_BINARY"], "--json", *args], env=env, capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


def sql(query):
    return subprocess.check_output([os.environ["FIXTURE_PSQL"], "-At", "-v", "ON_ERROR_STOP=1", "-c", query], text=True).strip()


with urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/api/v1/meta") as response:
    status = json.load(response)["message_transport"]
requested = os.environ["AGENTBOARD_MESSAGE_MODE"]
assert status["requested"] == requested
assert not status["cutover_ready"]
if requested == "dual":
    assert status["effective"] == "dual" and not status["activation_refused"], status
else:
    assert status["effective"] == "board" and status["activation_refused"], status
    assert "coordinator_decision_path_unavailable_80" in status["blockers"], status
    assert "bridge_disabled" in status["blockers"], status

ab("agent", "register")
ab("agent", "register", actor="mode-peer")
message = ab("msg", "send", "--to", "mode-peer", "--body", "Cold-start inbox fixture")["message"]
assert message["id"] in [m["id"] for m in ab("msg", "list", "--unread", actor="mode-peer")["messages"]]
assert sql("SELECT count(*) FROM mattermost_outbox") == ("1" if requested == "dual" else "0")
read = ab("msg", "read", str(message["id"]), actor="mode-peer")["message"]
assert read["read_at"]
assert ab("msg", "read", str(message["id"]), actor="mode-peer")["message"] == read
print("Cold-start", requested, "retains an actionable board inbox with the correct capture policy")
