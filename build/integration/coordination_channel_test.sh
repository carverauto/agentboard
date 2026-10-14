#!/usr/bin/env bash
# Starts a disposable loopback Mattermost before the release boots, so chat
# read/send --coordination can be observed at the channel the CLI resolved.
set -euo pipefail
export MM_RECORD="${TEST_TMPDIR}/mm-requests.jsonl"
export MM_PORT_FILE="${TEST_TMPDIR}/mm.port"
: >"$MM_RECORD"
python3 - <<'PY' &
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

record = os.environ["MM_RECORD"]
posts = {}
order = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _save(self, body):
        with open(record, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")

    def _json(self, status, payload):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._save(None)
        if "/posts" in self.path:
            self._json(200, {"order": list(order), "posts": posts})
            return
        self._json(200, {})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        body = json.loads(raw) if raw else None
        self._save(body)
        if self.path.split("?", 1)[0] == "/api/v4/posts" and isinstance(body, dict):
            post_id = "post-%d" % (len(order) + 1)
            post = {
                "id": post_id,
                "channel_id": body.get("channel_id"),
                "message": body.get("message"),
                "props": body.get("props") or {},
                "create_at": len(order) + 1,
            }
            posts[post_id] = post
            order.insert(0, post_id)
            self._json(201, post)
            return
        self._json(201, {"id": "ignored"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["MM_PORT_FILE"], "w", encoding="utf-8") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY
mm_pid=$!
cleanup_mm() { kill "$mm_pid" 2>/dev/null || true; wait "$mm_pid" 2>/dev/null || true; }
trap cleanup_mm EXIT
for _ in $(seq 1 50); do
  if [[ -s "$MM_PORT_FILE" ]]; then break; fi
  sleep 0.05
done
[[ -s "$MM_PORT_FILE" ]]
mm_port="$(cat "$MM_PORT_FILE")"
export AGENTBOARD_MATTERMOST_BASE_URL="http://127.0.0.1:${mm_port}"
export AGENTBOARD_MATTERMOST_BOT_TOKEN="fixture-coordination-token"
export AGENTBOARD_API_TEST_SCRIPT=coordination_channel_test.py
exec bash "$TEST_SRCDIR/$TEST_WORKSPACE/build/integration/board_api_test.sh" "$@"
