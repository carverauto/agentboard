"""Cold-start operator mode selection through the packaged API and CLI."""
import json
import os
import subprocess
import urllib.error
import urllib.request


def ab(*args, actor="mode-owner"):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture-model")
    result = subprocess.run([os.environ["AB_BINARY"], "--json", *args], env=env, capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return json.loads(result.stdout)


def sql(query):
    return subprocess.check_output([os.environ["FIXTURE_PSQL"], "-At", "-v", "ON_ERROR_STOP=1", "-c", query], text=True).strip()


with urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/api/v1/meta") as response:
    meta = json.load(response)
status = meta["message_transport"]
# Mattermost is not configured in this boot, so meta publishes no channel.
assert meta["coordination_channel"] is None, meta
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

# Measured inbound readiness replaces the static 5.3 blocker. Sole Mattermost
# stays refused; a client coverage report does not clear that blocker.
blockers = set(status["blockers"])
assert "mattermost_inbound_disabled" in blockers, blockers
assert "inbox_catch_up_unavailable_5_3" not in blockers, blockers
assert {
    "delivery_adapter_readiness_unverified",
    "coordinator_decision_path_unavailable_80",
    "legacy_unread_disposition_unverified_80",
} <= blockers, blockers


def rpc(expression):
    result = subprocess.run(
        [os.environ["AGENTBOARD_BIN"], "rpc", expression],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, (expression, result.stdout, result.stderr)
    return result.stdout.strip().splitlines()[-1]


def boot_flag(key):
    return rpc(f"IO.puts(Application.get_env(:agentboard, {key}) == true)")


# One boot parser: "true" and "1" enable a flag; other values stay off.
truthy = ("true", "1")
flags = {
    ":cooperation_enabled": "AGENTBOARD_COOPERATION_ENABLED",
    ":idle_continuation_enabled": "AGENTBOARD_IDLE_CONTINUATION_ENABLED",
    ":decision_cleanup_enabled": "AGENTBOARD_DECISION_CLEANUP_ENABLED",
    ":native_authority_enabled": "AGENTBOARD_NATIVE_AUTHORITY_ENABLED",
    ":branch_flow_enabled": "AGENTBOARD_BRANCH_FLOW_ENABLED",
    ":publication_recovery_enabled": "AGENTBOARD_PUBLICATION_RECOVERY_ENABLED",
    ":pr_observation_enabled": "AGENTBOARD_PR_OBSERVATION_ENABLED",
    ":pr_discovery_enabled": "AGENTBOARD_PR_DISCOVERY_ENABLED",
    ":mattermost_bridge_enabled": "AGENTBOARD_MATTERMOST_BRIDGE_ENABLED",
    ":mattermost_inbound_enabled": "AGENTBOARD_MATTERMOST_INBOUND_ENABLED",
    ":mattermost_private_routes_enabled": "AGENTBOARD_MATTERMOST_PRIVATE_ROUTES_ENABLED",
}
observed = {}
for key, env in flags.items():
    expect = "true" if os.environ.get(env, "false") in truthy else "false"
    got = boot_flag(key)
    assert got == expect, (key, os.environ.get(env), got)
    observed[env] = got
coop_on = os.environ.get("AGENTBOARD_COOPERATION_ENABLED", "false") in truthy
paused = rpc("case Oban.check_queue(queue: :cooperation) do %{paused: paused} -> IO.puts(paused) end")
assert paused == ("false" if coop_on else "true"), paused
print("boot-flags", json.dumps(observed), "cooperation_queue_paused", paused)

segments = rpc(
    "IO.puts(Enum.join(["
    "Agentboard.Mattermost.InboundHTTP.segment?(\"room-1\"),"
    "Agentboard.Mattermost.InboundHTTP.segment?(<<\"room-1\", 10>>),"
    "Agentboard.Mattermost.InboundHTTP.segment?(<<\"room\", 10, \"1\">>),"
    "Agentboard.Mattermost.InboundHTTP.segment?(\"\"),"
    "Agentboard.Mattermost.InboundHTTP.segment?(\"bad/id\"),"
    "Agentboard.Mattermost.InboundHTTP.segment?(String.duplicate(\"a\", 128)),"
    "Agentboard.Mattermost.InboundHTTP.segment?(String.duplicate(\"a\", 129))"
    "] |> Enum.map(&to_string/1), \",\"))"
)
assert segments == "true,false,false,false,false,true,false", segments
print("segment", segments)

bounds = rpc(
    "now = DateTime.utc_now(); "
    "IO.puts(Enum.join(["
    "Agentboard.Cooperation.Runtime.connector_stale?(%{reported_at: nil}, now),"
    "Agentboard.Cooperation.Runtime.connector_stale?(%{reported_at: DateTime.add(now, -90, :second)}, now),"
    "Agentboard.Cooperation.Runtime.connector_stale?(%{reported_at: DateTime.add(now, -91, :second)}, now),"
    "Agentboard.Cooperation.Runtime.safe_input_adapter?(\"pi-native-v1\"),"
    "Agentboard.Cooperation.Runtime.safe_input_adapter?(\"claude-hook-v1\"),"
    "Agentboard.Cooperation.Runtime.safe_input_adapter?(\"codex-app-server-v1\"),"
    "Agentboard.Cooperation.Runtime.safe_input_adapter?(\"manual\"),"
    "Agentboard.Cooperation.Runtime.safe_input_adapter?(\"herdr\")"
    "] |> Enum.map(&to_string/1), \",\"))"
)
assert bounds == "true,false,true,true,true,false,false,false", bounds
print("connector-bounds", bounds)

coverage_body = json.dumps({"last_post_id": "post-1", "last_version": 1, "caught_up": True}).encode()
coverage_request = urllib.request.Request(
    os.environ["AGENTBOARD_URL"] + "/api/v1/conversations/coverage/mode-owner/room-1",
    data=coverage_body,
    method="POST",
    headers={
        "Content-Type": "application/json",
        "x-agentboard-agent": "mode-owner",
        "x-agentboard-model": "fixture-model",
        "x-agentboard-harness": "codex",
    },
)
try:
    coverage_response = urllib.request.urlopen(coverage_request, timeout=10)
    coverage_status = coverage_response.status
    coverage_payload = json.load(coverage_response)
except urllib.error.HTTPError as error:
    coverage_status = error.code
    coverage_payload = error.read().decode()
assert coverage_status != 404, (coverage_status, coverage_payload)
with urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/api/v1/meta") as response:
    after = json.load(response)["message_transport"]
assert "mattermost_inbound_disabled" in after["blockers"], after
assert after["effective"] == status["effective"] and after["activation_refused"] == status["activation_refused"], after
print("coverage-report", coverage_status, "transport-unchanged")
