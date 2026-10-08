"""Public packaged CLI + real pinned Treehouse; invented HTTP board state only."""
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

cli, treehouse, launcher = (Path(x).resolve() for x in sys.argv[1:])


def command(argv, cwd, env, ok=True):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env, text=True, capture_output=True, timeout=180)
    if ok and result.returncode:
        raise AssertionError(f"{argv[:5]}: {result.stdout}\n{result.stderr}")
    assert "invented-private-token" not in result.stdout + result.stderr
    return result


class Board(BaseHTTPRequestHandler):
    tasks = {}
    records = {}
    fail_record = set()
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def reply(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/api/v1/meta":
            return self.reply(200, {"api_version": 1, "schema_version": 22})
        task = path.rsplit("/", 1)[-1]
        with self.lock:
            body = self.records.get(task)
            record = self.tasks[task].copy()
        # Every task record is on page 2, so ignoring pagination loses authority.
        if "cursor=later" not in query:
            return self.reply(200, {"task": record, "events": [], "next_cursor": "later"})
        self.reply(200, {"task": record, "events": [{"body": body}] if body else [], "next_cursor": None})

    def do_POST(self):
        task = self.path.split("/")[-2]
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            if task in self.fail_record:
                self.fail_record.remove(task)
                return self.reply(500, {"error": {"code": "unavailable", "message": "invented record failure"}})
            self.records[task] = data["note"]
        self.reply(200, {"task": self.tasks[task]})


with tempfile.TemporaryDirectory(prefix="seat-attachment-") as temporary:
    base = Path(temporary)
    # Quoting is tested against actual shell evaluation, not a source substring.
    repo = base / "primary ' $(touch SHOULD_NOT_EXIST)"
    repo.mkdir()
    pool = base / "pool ' $(touch SHOULD_NOT_EXIST)"
    clean_env = {k: v for k, v in os.environ.items() if not k.startswith("AGENTBOARD_") and k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE")}
    clean_env.update(GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid", TREEHOUSE_NO_UPDATE_CHECK="1")
    command(["git", "init", "-q", "-b", "main"], repo, clean_env)
    (repo / "fixture").write_text("invented product repository without Agentboard scripts\n")
    (repo / "treehouse.toml").write_text("max_trees = 12\n")
    command(["git", "add", "."], repo, clean_env)
    command(["git", "commit", "-qm", "fixture"], repo, clean_env)
    original = command(["git", "rev-parse", "HEAD"], repo, clean_env).stdout
    binary_dir = base / "bin"
    binary_dir.mkdir()
    (binary_dir / "agentboard").symlink_to(cli)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Board)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(clean_env, PATH=str(binary_dir) + os.pathsep + clean_env["PATH"], AGENT_ID="codex-fixture-seat", AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture", AGENTBOARD_URL=f"http://127.0.0.1:{server.server_port}", AGENTBOARD_TOKEN="invented-private-token", AGENTBOARD_TREEHOUSE_BIN=str(treehouse), AGENTBOARD_COORDINATOR_ID="codex-fixture-captain")

    def task(name, **changes):
        Board.tasks[name] = dict(id=name, status="in_progress", assignee_id=env["AGENT_ID"], claim_expired=False, claim_expires_at="2099-01-01T00:00:00Z", **changes)

    def seat(mode, name, run_env=env, cwd=repo, ok=True):
        return command([cli, "seat", mode, name, "--repo", repo, "--root", pool, "--json"], cwd, run_env, ok)

    task("owned-task")
    with ThreadPoolExecutor(max_workers=2) as workers:
        responses = list(workers.map(lambda _: json.loads(seat("ensure", "owned-task").stdout), range(2)))
    assert responses[0] == responses[1], responses
    binding = responses[0]["binding"]
    worktree = Path(binding["worktree"])
    assert worktree != repo and worktree.is_relative_to(pool / ".treehouse")
    assert binding["source"] == str(repo) and binding["task_id"] == "owned-task"
    assert not (repo / ".agentboard-seat").exists()
    assert not (worktree / "scripts/launch-seat").exists(), "CLI must not require product-side scripts"
    state_path = worktree.parents[1] / "treehouse-state.json"
    state = json.loads(state_path.read_text())
    assert len([row for row in state["worktrees"] if row.get("leased")]) == 1
    (worktree / "fixture").write_text("uncommitted work must survive\n")
    assert json.loads(seat("ensure", "owned-task").stdout) == responses[0]
    assert (worktree / "fixture").read_text() == "uncommitted work must survive\n"
    exports = command([cli, "seat", "env", "owned-task", "--repo", repo, "--root", pool], repo, env).stdout
    assert "AGENTBOARD_TOKEN" not in exports and "TOKEN_FILE" not in exports
    script = base / "exports.sh"
    script.write_text(exports + 'agentboard seat check owned-task --json\n')
    checked = command(["bash", script], repo, env)
    assert json.loads(checked.stdout) == responses[0]
    assert not list(base.rglob("SHOULD_NOT_EXIST")), "shell substitution escaped its literal path"
    missing = seat("check", "owned-task", cwd=worktree, ok=False)
    assert missing.returncode and "AGENTBOARD_SEAT_WORKTREE" in missing.stderr
    wrong_cwd = seat("check", "owned-task", run_env=dict(env, **responses[0]["environment"]), ok=False)
    assert wrong_cwd.returncode and "primary" in wrong_cwd.stderr

    # Existing event evidence is authoritative even when a local registry exists.
    saved = Board.records["owned-task"]
    invalid = dict(binding, worktree=str(base / "missing"))
    Board.records["owned-task"] = "agentboard-seat " + json.dumps(invalid)
    refused = seat("ensure", "owned-task", ok=False)
    assert refused.returncode, "newest paginated event must not be ignored"
    Board.records["owned-task"] = saved

    stale_lease = dict(binding, lease_id="invented-stale-lease")
    Board.records["owned-task"] = "agentboard-seat " + json.dumps(stale_lease)
    assert seat("ensure", "owned-task", ok=False).returncode
    Board.records["owned-task"] = saved
    metadata = worktree / ".agentboard-seat/seat.json"
    retained_metadata = metadata.read_bytes()
    metadata.write_text(json.dumps(dict(binding, task_id="invented-other-task")))
    assert seat("ensure", "owned-task", ok=False).returncode
    assert metadata.read_text() == json.dumps(dict(binding, task_id="invented-other-task"))
    metadata.write_bytes(retained_metadata)
    metadata.chmod(0o644)
    assert seat("env", "owned-task", ok=False).returncode
    metadata.chmod(0o600)

    for name, changes in [("foreign-task", {"assignee_id": "codex-fixture-other"}), ("expired-task", {"claim_expired": True}), ("terminal-task", {"status": "done"})]:
        task(name)
        Board.tasks[name].update(changes)
        refused = seat("ensure", name, ok=False)
        assert refused.returncode and "live owned task claim" in refused.stderr
    task("empty-task")
    assert seat("env", "empty-task", ok=False).returncode
    assert len([row for row in json.loads(state_path.read_text())["worktrees"] if row.get("leased")]) == 1

    task("retry-task")
    Board.fail_record.add("retry-task")
    failed = seat("ensure", "retry-task", ok=False)
    assert failed.returncode and "preserved" in failed.stderr
    before_retry = json.loads(state_path.read_text())
    retried = json.loads(seat("ensure", "retry-task").stdout)
    assert len([row for row in before_retry["worktrees"] if row.get("leased")]) == 2
    assert before_retry["worktrees"] == json.loads(state_path.read_text())["worktrees"], "retry allocated or reset a worktree"

    task("interrupted-task")
    interrupted = base / "interrupted-treehouse"
    interrupted.write_text("#!/usr/bin/env python3\nimport subprocess,sys\nif sys.argv[1:]==['--version']: print('v3.1.2')\nelse:\n subprocess.run(" + repr(str(treehouse)) + " and [" + repr(str(treehouse)) + "]+sys.argv[1:],check=True)\n sys.exit(1)\n")
    interrupted.chmod(0o755)
    assert seat("ensure", "interrupted-task", run_env=dict(env, AGENTBOARD_TREEHOUSE_BIN=str(interrupted)), ok=False).returncode
    interrupted_state = json.loads(state_path.read_text())["worktrees"]
    refused_retry = seat("ensure", "interrupted-task", ok=False)
    assert refused_retry.returncode and "interrupted seat allocation" in refused_retry.stderr
    assert json.loads(state_path.read_text())["worktrees"] == interrupted_state

    # A record pointing at another task's real lease must preserve that task.
    task("conflict-task")
    Board.records["conflict-task"] = "agentboard-seat " + json.dumps(dict(binding, task_id="conflict-task"))
    conflict = seat("ensure", "conflict-task", ok=False)
    assert conflict.returncode and "another task" in conflict.stderr
    assert (worktree / "fixture").read_text() == "uncommitted work must survive\n"

    for name, target in [("primary-task", repo), ("legacy-task", base / "legacy")]:
        task(name)
        if name == "legacy-task":
            command(["git", "worktree", "add", "--detach", target], repo, env)
        Board.records[name] = "agentboard-seat " + json.dumps(dict(binding, task_id=name, worktree=str(target)))
        assert seat("ensure", name, ok=False).returncode
        assert not (target / ".agentboard-seat").exists()

    # Native repeat attach reuses the task binding; credentials are not rewritten.
    task("attach-task")
    brief = base / "brief.md"
    brief.write_text("Only the assigned invented fixture task.\n")
    recorder = base / "native.py"
    recorder.write_text("import json,os,pathlib,sys\npathlib.Path(sys.argv[1]).write_text(json.dumps({'cwd':os.getcwd(),'env':{k:os.environ[k] for k in ['AGENTBOARD_SEAT_WORKTREE','AGENTBOARD_SEAT_SOURCE','AGENTBOARD_SEAT_ROOT']},'brief':pathlib.Path(sys.argv[2]).read_text()}))\n")
    output = base / "native.json"
    argv = [sys.executable, launcher, "--repo", repo, "--root", pool, "--task", "attach-task", "--brief", brief, "--attach", "--", sys.executable, recorder, output, "{brief}"]
    command(argv, repo, env)
    first = json.loads(output.read_text())
    attached = Path(first["cwd"])
    credential_file = attached / ".agentboard-seat/agent.env"
    old_credentials = credential_file.read_bytes()
    command(argv, repo, env)
    assert json.loads(output.read_text()) == first
    assert credential_file.read_bytes() == old_credentials
    assert first["env"] == {"AGENTBOARD_SEAT_WORKTREE": str(attached), "AGENTBOARD_SEAT_SOURCE": str(repo), "AGENTBOARD_SEAT_ROOT": str(pool)}
    assert first["brief"].endswith(brief.read_text())
    reread = command(["bash", "-c", 'source "$1"; agentboard seat check attach-task --json', "fixture", credential_file], attached, env)
    assert json.loads(reread.stdout)["binding"]["worktree"] == str(attached)
    assert credential_file.stat().st_mode & 0o777 == 0o600
    brief.write_text("changed task brief must not overwrite retained work\n")
    assert command(argv, repo, env, ok=False).returncode
    assert credential_file.read_bytes() == old_credentials
    # Installed Markdown is intentional public output. This guards shipping the
    # procedure and sibling links; it does not claim that an LLM follows text.
    discovery = base / "skills"
    command([cli, "skills", "install", "--dir", discovery, "--json"], repo, dict(env, XDG_DATA_HOME=str(base / "data")))
    workflow = (discovery / "agentboard/SKILL.md").read_text()
    for invocation in ("agentboard seat ensure TASK", "agentboard seat env TASK", "agentboard seat check TASK"):
        assert invocation in workflow
    for name in ("agentboard-codex", "agentboard-muse", "agentboard-herdr"):
        variant = (discovery / name / "SKILL.md").read_text()
        assert "../agentboard/SKILL.md#recover-seat-environment-yourself" in variant
    assert command(["git", "status", "--porcelain"], repo, env).stdout == ""
    assert command(["git", "rev-parse", "HEAD"], repo, env).stdout == original
    server.shutdown()
    server.server_close()

print("packaged seat recovery: owned/paginated evidence, concurrent/retry/WIP preservation, shell/JSON secrecy, real isolation and repeat native attach passed")
