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
