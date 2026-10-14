"""The configured seat coordination channel through the packaged API and CLI."""
import json
import os
import subprocess
import urllib.request

CHANNEL = os.environ["AGENTBOARD_COORDINATION_CHANNEL_ID"]

with urllib.request.urlopen(os.environ["AGENTBOARD_URL"] + "/api/v1/meta") as response:
    meta = json.load(response)
assert meta["coordination_channel"] == {"id": CHANNEL}, meta

# The CLI resolves --coordination from meta and reads that channel. Without a
# Mattermost bridge the read itself is refused, but never for want of a channel.
env = dict(os.environ, AGENT_ID="coord-seat", AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture-model")
subprocess.run([os.environ["AB_BINARY"], "--json", "agent", "register"], env=env, check=True, capture_output=True, timeout=25)
read = subprocess.run([os.environ["AB_BINARY"], "--json", "chat", "read", "--coordination"], env=env, capture_output=True, text=True, timeout=25)
assert "coordination_channel_unset" not in read.stderr and "AGENTBOARD_COORDINATION_CHANNEL_ID" not in read.stderr, (read.stdout, read.stderr)
print("meta publishes the coordination channel and the CLI resolves it:", CHANNEL)


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
accepted("nil", extra={"AGENTBOARD_MATTERMOST_BASE_URL": "   ", "AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "false"}, drop=("AGENTBOARD_COORDINATION_CHANNEL_ID",))
accepted(f'"{CHANNEL}"', extra={"AGENTBOARD_MATTERMOST_BASE_URL": "https://chat.example.test", "AGENTBOARD_MATTERMOST_BRIDGE_ENABLED": "true"})
print("boot refuses Mattermost without a coordination channel and keeps one when configured")
