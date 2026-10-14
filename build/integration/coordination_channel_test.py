"""The configured seat coordination channel through the packaged API and CLI."""
import json
import os
import subprocess
import tempfile
import urllib.request

CHANNEL = os.environ["AGENTBOARD_COORDINATION_CHANNEL_ID"]
AB = os.environ["AB_BINARY"]


def ab(*args, actor="coord-seat", check=True):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture-model")
    result = subprocess.run([AB, "--json", *args], env=env, capture_output=True, text=True, timeout=25)
    if check and result.returncode != 0:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result


def mm_log():
    path = os.environ["MM_RECORD"]
    rows = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    rows.append(json.loads(line))
    return rows


with urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/api/v1/meta") as response:
    meta = json.load(response)
assert meta["coordination_channel"] == {"id": CHANNEL}, meta

ab("agent", "register")
read = ab("chat", "read", "--coordination", "--limit", "50")
read_body = json.loads(read.stdout)
assert read_body["channel_id"] == CHANNEL, read_body
assert read_body["posts"] == []
reads = [row for row in mm_log() if row["method"] == "GET" and row["path"].startswith("/api/v4/channels/%s/posts" % CHANNEL)]
assert reads, mm_log()
print("meta and chat read --coordination use", CHANNEL)

sent = ab("chat", "send", "--coordination", "--body", "claimed ship-it", "--task", "ship-it", "--kind", "status", "--retry-key", "claim-ship-it")
receipt = json.loads(sent.stdout)
assert receipt["duplicate"] is False, receipt
assert receipt["post"]["channel_id"] == CHANNEL, receipt
again = ab("chat", "send", "--coordination", "--body", "claimed ship-it", "--task", "ship-it", "--kind", "status", "--retry-key", "claim-ship-it")
again_body = json.loads(again.stdout)
assert again_body["duplicate"] is True, again_body
posts = [row for row in mm_log() if row["method"] == "POST" and row["path"] == "/api/v4/posts"]
assert len(posts) == 1 and posts[0]["body"]["channel_id"] == CHANNEL, posts
print("chat send --coordination posts once to", CHANNEL, "and a repeat adopts it")

before = len(mm_log())
for args in (
    ["chat", "read", "--coordination", "--channel", "other-channel"],
    ["chat", "read", "--coordination", "--inbox"],
    ["chat", "send", "--coordination", "--to", "coord-peer", "--body", "x"],
    ["chat", "send", "--coordination", "--channel", "other-channel", "--body", "x"],
):
    rejected = ab(*args, check=False)
    assert rejected.returncode != 0, args
assert len(mm_log()) == before, mm_log()[before:]
print("coordination is exclusive with --channel, --inbox and --to")


def boot(extra=None, drop=()):
    env = dict(os.environ)
    for key in drop:
        env.pop(key, None)
    env.update(extra or {})
    env["PHX_SERVER"] = "false"
    result = subprocess.run(
        [os.environ["AGENTBOARD_BIN"], "eval", "IO.puts(inspect(Application.get_env(:agentboard, :coordination_channel_id)))"],
        env=env, capture_output=True, text=True, timeout=90,
    )
    return result.returncode, result.stdout, result.stderr


def refused(extra=None, drop=()):
    code, out, err = boot(extra, drop)
    text = out + err
    assert code != 0 and "AGENTBOARD_COORDINATION_CHANNEL_ID" in text, (code, out, err)


def accepted(expect, extra=None, drop=()):
    code, out, err = boot(extra, drop)
    lines = [line.strip() for line in out.splitlines()]
    assert code == 0 and expect in lines, (expect, code, out, err)


# Mattermost configured means a base URL or the outbound bridge. Either one
# without a channel, or with a malformed channel, refuses to boot. A blank
# URL and a disabled bridge are not that configuration, so the channel stays
# unset and meta can publish null. A configured server keeps the channel id.
refused(extra={"AGENTBOARD_MATTERMOST_BASE_URL": "https://chat.example.test"}, drop=("AGENTBOARD_COORDINATION_CHANNEL_ID",))
refused(extra={"AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "1"}, drop=("AGENTBOARD_COORDINATION_CHANNEL_ID",))
refused(extra={"AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "true", "AGENTBOARD_COORDINATION_CHANNEL_ID": "  "})
refused(extra={"AGENTBOARD_MATTERMOST_BASE_URL": "https://chat.example.test", "AGENTBOARD_COORDINATION_CHANNEL_ID": "not-a-channel"})
refused(extra={"AGENTBOARD_COORDINATION_CHANNEL_ID": "not-a-channel"})
accepted("nil", extra={"AGENTBOARD_MATTERMOST_BASE_URL": "   ", "AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "false"}, drop=("AGENTBOARD_COORDINATION_CHANNEL_ID", "AGENTBOARD_MATTERMOST_BOT_TOKEN"))
accepted(f'"{CHANNEL}"', extra={"AGENTBOARD_MATTERMOST_BASE_URL": "https://chat.example.test", "AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "true"})
print("boot refuses Mattermost without a coordination channel and keeps one when configured")

# Disposable Herdr: the real CLI discovers this pane and emits the nudge.
root = tempfile.mkdtemp(prefix="coord-seat-")
herdr = os.path.join(root, "herdr")
with open(herdr, "w", encoding="utf-8") as fh:
    fh.write("""#!/usr/bin/env python3
import json, sys
agent = {"pane_id":"w1:p1","workspace_id":"w1","name":"coord-seat","agent":"codex","agent_status":"idle","state_change_seq":3,"agent_session":{"value":"sess-1"}}
cmd = sys.argv[1:3]
if cmd == ["agent", "list"]:
    print(json.dumps({"result": {"agents": [agent]}}))
elif cmd == ["agent", "get"]:
    print(json.dumps({"result": {"agent": agent}}))
elif cmd == ["agent", "read"]:
    print("ready")
else:
    sys.stderr.write("unexpected %s\\n" % sys.argv[1:])
    sys.exit(2)
""")
os.chmod(herdr, 0o700)
os.environ["AGENTBOARD_HERDR_BIN"] = herdr

ab("agent", "register", actor="coord-peer")
ab("msg", "send", "--to", "coord-seat", "--body", "found a bug in the claim path", actor="coord-peer")
seat_cfg = os.path.join(root, "seat.json")
with open(seat_cfg, "w", encoding="utf-8") as fh:
    json.dump({"version": 1, "state_file": os.path.join(root, "state.json"), "kill_switch": os.path.join(root, "off")}, fh)
os.chmod(seat_cfg, 0o600)
nudge = ab("seat", "nudge", "--config", seat_cfg)
nudge_body = json.loads(nudge.stdout)
prompts = [d.get("prompt") or "" for d in nudge_body.get("decisions") or []]
assert any("agentboard chat read --coordination" in prompt and "agentboard context feed" in prompt for prompt in prompts), nudge_body
print("seat nudge dry-run tells the idle seat to read the coordination channel")

launcher = os.path.join(root, "launch-seat")
with open(launcher, "w", encoding="utf-8") as fh:
    fh.write("#!/bin/sh\nexit 0\n")
os.chmod(launcher, 0o700)
repo = os.path.join(root, "repo")
pool = os.path.join(root, "pool")
os.mkdir(repo)
os.mkdir(pool)
allow = os.path.join(root, "harnesses.json")
with open(allow, "w", encoding="utf-8") as fh:
    json.dump({
        "version": 1,
        "launcher": launcher,
        "repo": repo,
        "root": pool,
        "brief_dir": os.path.join(root, "briefs"),
        "harnesses": {"codex": {"model": "fixture-model", "argv": ["codex", "{brief_text}"]}},
    }, fh)
os.chmod(allow, 0o600)
spawn = ab("seat", "spawn", "--dry-run", "--agent", "spawn-seat", "--harness", "codex", "--task", "ship-it", "--config", allow)
plan = json.loads(spawn.stdout)
brief = plan.get("brief_text") or ""
for phrase in (
    "agentboard chat read --coordination",
    "agentboard context feed",
    "agentboard context search",
    "agentboard chat send --coordination",
    "agentboard context publish",
    "--root-id",
    "agentboard decision request TASK",
):
    assert phrase in brief, (phrase, brief)
assert plan.get("dry_run") is True
print("seat spawn dry-run brief includes the coordination check-in")
