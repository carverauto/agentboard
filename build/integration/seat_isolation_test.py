"""Exercise the public launch/check boundary with the real pinned Treehouse."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

launcher, treehouse = map(lambda x: Path(x).resolve(), sys.argv[1:])


def command(argv, cwd, env=None, ok=True):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env, text=True, capture_output=True, timeout=120)
    if ok and result.returncode:
        raise AssertionError(f"{argv}: {result.stdout}\n{result.stderr}")
    return result


with tempfile.TemporaryDirectory(prefix="seat-isolation-") as tmp:
    root = Path(tmp)
    repo = root / "primary"
    repo.mkdir()
    command(["git", "init", "-b", "main"], repo)
    command(["git", "config", "user.name", "Fixture Seat"], repo)
    command(["git", "config", "user.email", "fixture@example.invalid"], repo)
    (repo / "treehouse.toml").write_text(f'root = "{root / "pool"}"\nmax_trees = 8\n')
    (repo / ".gitignore").write_text('.agentboard-seat/\n')
    command(["git", "add", "."], repo)
    command(["git", "commit", "-m", "invented repository"], repo)
    original = command(["git", "rev-parse", "HEAD"], repo).stdout.strip()
    task = root / "task.md"
    task.write_text("Implement only the assigned fixture change. Preserve literal $ and ` markers.\n")
    recorder = root / "native.py"
    recorder.write_text('''import json, os, pathlib, sys
brief=pathlib.Path(sys.argv[2]).read_text() if sys.argv[3]=='file' else sys.argv[2]
pathlib.Path(sys.argv[1]).write_text(json.dumps({'cwd':os.getcwd(),'expected':os.environ['AGENTBOARD_SEAT_WORKTREE'],'source':os.environ['AGENTBOARD_SEAT_SOURCE'],'brief':brief}))
''')
    env = dict(os.environ, AGENT_ID="codex-fixture-seat", AGENTBOARD_HARNESS="codex", AGENTBOARD_MODEL="fixture-model", AGENTBOARD_TREEHOUSE_BIN=str(treehouse))
    seats = []
    for form in ("text", "file"):
        output = root / f"{form}.json"
        result = command([sys.executable, launcher, "--repo", repo, "--brief", task, "--", sys.executable, recorder, output, "{brief_text}" if form == "text" else "{brief}", form], repo, env)
        data = json.loads(output.read_text())
        seat = Path(data["cwd"])
        seats.append(seat)
        assert seat != repo and seat == Path(data["expected"])
        assert data["source"] == str(repo)
        assert data["brief"].endswith(task.read_text()) and "STOP" in data["brief"]
        assert "AGENTBOARD_SEAT_WORKTREE" in data["brief"]
        assert (seat / ".agentboard-seat/brief.md").stat().st_mode & 0o777 == 0o600
        assert (seat / ".agentboard-seat").stat().st_mode & 0o777 == 0o700
        assert command(["git", "status", "--porcelain"], repo).stdout == ""
        assert command(["git", "rev-parse", "HEAD"], repo).stdout.strip() == original
        check_env = dict(env, AGENTBOARD_SEAT_WORKTREE=str(seat))
        command([sys.executable, launcher, "--repo", repo, "--check"], seat, check_env)
    assert seats[0] != seats[1], "persistent leases must survive process exit"
    status = command([treehouse, "status"], repo).stdout
    assert status.count("codex-fixture-seat") >= 2, status

    foreign = root / "foreign"
    foreign.mkdir()
    command(["git", "init", "-b", "main"], foreign)
    command(["git", "config", "user.name", "Fixture Seat"], foreign)
    command(["git", "config", "user.email", "fixture@example.invalid"], foreign)
    (foreign / "fixture").write_text("unrelated\n")
    command(["git", "add", "."], foreign)
    command(["git", "commit", "-m", "unrelated"], foreign)
    foreign_link = root / "foreign-link"
    command(["git", "worktree", "add", "--detach", foreign_link], foreign)
    primary_link = root / "primary-alias"
    primary_link.symlink_to(repo, target_is_directory=True)
    subdir = seats[0] / "subdir"
    subdir.mkdir()
    check_env = dict(env, AGENTBOARD_SEAT_WORKTREE=str(seats[0]))
    for source, cwd, expected_reason in (
        (repo, repo, "primary"),
        (repo, primary_link, "primary"),
        (seats[0], repo, "primary"),
        (repo, subdir, "root"),
        (repo, foreign_link, "another repository"),
        (repo, seats[1], "expected seat"),
    ):
        result = command([sys.executable, launcher, "--repo", source, "--check"], cwd, check_env, ok=False)
        assert result.returncode == 2 and "STOP" in result.stderr and expected_reason in result.stderr, result.stderr

    linked_gitdir = command(["git", "rev-parse", "--absolute-git-dir"], seats[0]).stdout.strip()
    tainted = dict(env, AGENTBOARD_SEAT_WORKTREE=str(repo), GIT_DIR=linked_gitdir, GIT_WORK_TREE=".")
    result = command([sys.executable, launcher, "--repo", seats[0], "--check"], repo, tainted, ok=False)
    assert result.returncode == 2 and "STOP" in result.stderr and "GIT_DIR" in result.stderr, result.stderr
    assert not (repo / ".agentboard-seat").exists()

    stale = root / "stale-sibling"
    command(["git", "worktree", "add", "--detach", stale], repo)
    command(["rm", "-rf", stale], repo)
    assert str(stale) in command(["git", "worktree", "list", "--porcelain"], repo).stdout
    command([sys.executable, launcher, "--repo", repo, "--check"], seats[0], dict(env, AGENTBOARD_SEAT_WORKTREE=str(seats[0])))

    # Malformed acquisition must stop before metadata or the native process writes.
    fake = root / "bad-treehouse"
    fake.write_text(f'#!/bin/sh\nif [ "$1" = --version ]; then echo v2.0.1; else echo "{repo}"; fi\n')
    fake.chmod(0o755)
    output = root / "must-not-exist.json"
    bad_env = dict(env, AGENTBOARD_TREEHOUSE_BIN=str(fake))
    argv = [sys.executable, launcher, "--repo", repo, "--brief", task, "--", sys.executable, recorder, output, "{brief_text}", "text"]
    result = command(argv, repo, bad_env, ok=False)
    assert result.returncode == 2 and "primary" in result.stderr, result.stderr
    assert not output.exists() and not (repo / ".agentboard-seat").exists()
    # A recycled seat directory left group/world-readable must be locked back down.
    reused = seats[0] / ".agentboard-seat"
    (reused / "brief.md").unlink()
    os.chmod(reused, 0o755)
    reuse_treehouse = root / "reuse-treehouse"
    reuse_treehouse.write_text(f'#!/bin/sh\nif [ "$1" = --version ]; then echo v2.0.1; else echo "{seats[0]}"; fi\n')
    reuse_treehouse.chmod(0o755)
    reuse_output = root / "reuse.json"
    reuse_env = dict(env, AGENTBOARD_TREEHOUSE_BIN=str(reuse_treehouse))
    command([sys.executable, launcher, "--repo", repo, "--brief", task, "--", sys.executable, recorder, reuse_output, "{brief}", "file"], repo, reuse_env)
    assert reused.stat().st_mode & 0o777 == 0o700
    assert (reused / "brief.md").stat().st_mode & 0o777 == 0o600
    fake.write_text('#!/bin/sh\necho v3.1.2\n')
    result = command(argv, repo, bad_env, ok=False)
    assert result.returncode == 2 and "expected Treehouse 2.0.1" in result.stderr
    assert not output.exists()
    missing_env = dict(env)
    del missing_env["AGENT_ID"]
    result = command(argv, repo, missing_env, ok=False)
    assert result.returncode == 2 and "AGENT_ID" in result.stderr
    assert not output.exists()
print("real pinned Treehouse acquisition, retained leases, native brief/cwd and STOP cases passed")
