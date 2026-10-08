"""Real Git pushes from a private gate worktree with invented provider replies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

guard, launcher, wrapper = [Path(p).resolve() for p in sys.argv[1:]]


def run(argv, cwd, env=None, ok=True):
    p = subprocess.run([str(x) for x in argv], cwd=cwd, env=env,
                       capture_output=True, text=True, timeout=60)
    if ok:
        assert p.returncode == 0, (argv, p.stdout, p.stderr)
    return p


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    source, gate, target, seat, private = [root / p for p in ('source', 'gate.git', 'target.git', 'seat', 'private')]
    source.mkdir()
    run(['git', 'init', '-b', 'main'], source)
    run(['git', 'config', 'user.name', 'Invented seat'], source)
    run(['git', 'config', 'user.email', 'fixture@example.invalid'], source)
    (source / 'scripts').mkdir()
    for original, name in ((launcher, 'launch-seat'), (guard, 'publication-guard'), (wrapper, 'publish-seat')):
        shutil.copy2(original, source / 'scripts' / name)
        (source / 'scripts' / name).chmod(0o755)
    (source / '.gitignore').write_text('.agentboard-seat/\n')
    run(['git', 'add', '.'], source)
    run(['git', 'commit', '-m', 'Invented public fixture'], source)
    for bare in (gate, target):
        run(['git', 'init', '--bare', bare], source)
    run(['git', 'remote', 'add', 'origin', target], source)
    run(['git', 'remote', 'add', 'no-mistakes', gate], source)
    run(['git', 'push', 'no-mistakes', 'HEAD:refs/heads/input'], source)
    run(['git', 'worktree', 'add', '-b', 'feat/replay', seat, 'main'], source)
    run(['git', '--git-dir', gate, 'worktree', 'add', '--detach', private, 'input'], source)
    post = gate / 'hooks/post-receive'
    original_post = b'#!/bin/sh\nexit 0\n'
    post.write_bytes(original_post)
    post.chmod(0o755)
    state = root / 'provider.json'
    data = dict(task=dict(id='guard-fixture', status='review', assignee_id='codex-fixture',
                         claim_expired=False, claim_expires_at='2099-01-01T00:00:00Z',
                         pr_url='https://github.com/fixture/project/pull/1'),
                pr=dict(state='OPEN', url='https://github.com/fixture/project/pull/1'), merged=[])
    def save():
        state.write_text(json.dumps(data))
    save()
    tools = root / 'tools'
    tools.mkdir()
    script = '''#!/usr/bin/env python3
import json,os,sys
d=json.load(open(os.environ['FIXTURE_PROVIDER']))
if d.get('error'): print('invented-secret-must-not-leak',file=sys.stderr); sys.exit(1)
name=os.path.basename(sys.argv[0])
print(json.dumps({'task':d['task']} if name=='agentboard' else d['pr'] if 'view' in sys.argv else d['merged']))
'''
    for name in ('agentboard', 'gh'):
        (tools / name).write_text(script)
        (tools / name).chmod(0o755)
    env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'],
               FIXTURE_PROVIDER=str(state), AGENT_ID='codex-fixture',
               AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex',
               AGENTBOARD_SEAT_SOURCE=str(source), AGENTBOARD_SEAT_WORKTREE=str(seat),
               AGENTBOARD_PUBLICATION_REPO='fixture/project', AGENTBOARD_URL='https://fixture.invalid')
    def push():
        return run(['git', 'push', target, 'HEAD:refs/heads/feat/replay'], private, env, ok=False)
    def remove():
        run(['git', '--git-dir', target, 'update-ref', '-d', 'refs/heads/feat/replay'], source)
    def absent():
        return run(['git', '--git-dir', target, 'show-ref', '--verify', 'refs/heads/feat/replay'], source, ok=False).returncode != 0
    # The same actual push succeeds before the guard; refusal is not a broken
    # remote, missing commit, simulator, or credential problem.
    assert push().returncode == 0
    remove()
    run([guard, 'install', 'guard-fixture'], seat, env)
    assert post.read_bytes() == original_post, 'Native post-receive contract changed'
    assert push().returncode == 0, 'Still-open control must remain publishable'
    remove()
    for reason, changes in (
        ('terminal', dict(status='done')),
        ('merged', dict(status='review')),
    ):
        data['task'].update(changes)
        data['pr']['state'] = 'MERGED' if reason == 'merged' else 'OPEN'
        save()
        result = push()
        assert result.returncode != 0 and reason in result.stderr and absent(), result.stderr
    data['task']['pr_url'] = None
    data['merged'] = [dict(url='https://github.com/fixture/project/pull/1', headRefName='feat/replay',
                           headRepository=dict(name='project'), headRepositoryOwner=dict(login='fixture'))]
    save()
    result = push()
    assert result.returncode != 0 and 'already merged' in result.stderr and absent(), result.stderr
    # Forks with the same branch spelling are independent; provider failure is
    # unknown evidence, never permission to recreate a branch.
    data['merged'][0]['headRepositoryOwner']['login'] = 'another-fork'
    save()
    assert push().returncode == 0
    remove()
    data['error'] = True
    save()
    result = push()
    assert result.returncode != 0 and absent()
    assert 'invented-secret-must-not-leak' not in result.stderr
    data.pop('error')
    data['task']['status'] = 'done'
    save()
    result = run([seat / 'scripts/publish-seat', 'guard-fixture', '--', 'run'], seat, env, ok=False)
    assert result.returncode != 0 and 'terminal' in result.stderr, result.stderr
    # Isolation remains a mandatory outer-driver boundary, independent of state.
    result = run([guard, 'install', 'guard-fixture'], source, env, ok=False)
    assert result.returncode != 0 and 'explicitly leased' in result.stderr, result.stderr
    print('Private-gate real push refusal, no branch recreation, same-fork/open controls, fail-closed provider state and preserved native hooks passed')
