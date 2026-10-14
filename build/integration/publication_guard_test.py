"""Real Git pushes from a private gate worktree with invented provider replies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

guard, launcher, wrapper, treehouse = [Path(p).resolve() for p in sys.argv[1:]]


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
    (source / 'conflict.txt').write_text('base\n')
    run(['git', 'add', '.'], source)
    run(['git', 'commit', '-m', 'Invented public fixture'], source)
    for bare in (gate, target):
        run(['git', 'init', '--bare', bare], source)
    run(['git', 'remote', 'add', 'origin', target], source)
    run(['git', 'remote', 'add', 'no-mistakes', gate], source)
    run(['git', 'push', 'origin', 'HEAD:refs/heads/staging'], source)
    run(['git', '--git-dir', target, 'symbolic-ref', 'HEAD', 'refs/heads/staging'], source)
    run(['git', '--git-dir', gate, 'config', 'url.' + str(target) + '.insteadOf',
         'https://github.com/fixture/project.git'], source)
    run(['git', 'push', 'no-mistakes', 'HEAD:refs/heads/input'], source)
    # Publication requires a real durable Treehouse lease, not merely a linked
    # Git worktree. Exercise the same pinned acquisition as production seats.
    pool = root / 'pool'
    acquisition_env = dict(os.environ, TREEHOUSE_NO_UPDATE_CHECK='1')
    seat = Path(run([treehouse, 'get', '--lease', '--lease-holder', 'codex-fixture', '--root', pool], source, acquisition_env).stdout.strip())
    run(['git', 'switch', '-c', 'feat/replay', 'main'], seat)
    run(['git', '--git-dir', gate, 'worktree', 'add', '--detach', private, 'input'], source)
    post = gate / 'hooks/post-receive'
    original_post = b'#!/bin/sh\nexit 0\n'
    post.write_bytes(original_post)
    post.chmod(0o755)
    state = root / 'provider.json'
    data = dict(task=dict(id='guard-fixture', status='review', assignee_id='codex-fixture',
                         claim_expired=False, claim_expires_at='2099-01-01T00:00:00Z',
                         held_by_decision=False, revision=1,
                         pr_url='https://github.com/fixture/project/pull/1'),
                pr=dict(state='OPEN', url='https://github.com/fixture/project/pull/1'), merged=[],
                repo=dict(defaultBranchRef=dict(name='staging')))
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
if name=='agentboard' and sys.argv[1:]==['decision','request','--help']:
    print('decision request fixture help')
elif name=='agentboard' and sys.argv[1:]==['doctor','--json']:
    print(json.dumps({'compatible':True,'cli_capabilities':{'decision_intake':1},'required_decision_intake_version':1,'schema_version':29}))
else:
    print(json.dumps({'task':d['task']} if name=='agentboard' else d['repo'] if 'repo' in sys.argv else d['pr'] if 'view' in sys.argv else d['merged']))
'''
    for name in ('agentboard', 'gh'):
        (tools / name).write_text(script)
        (tools / name).chmod(0o755)
    env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'],
               FIXTURE_PROVIDER=str(state), AGENT_ID='codex-fixture',
               AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex',
               AGENTBOARD_SEAT_SOURCE=str(source), AGENTBOARD_SEAT_WORKTREE=str(seat),
               AGENTBOARD_SEAT_ROOT=str(pool),
               AGENTBOARD_PUBLICATION_REPO='fixture/project', AGENTBOARD_URL='https://fixture.invalid')
    def push(head='HEAD', extra=()):
        return run(['git', 'push', target, str(head)+':refs/heads/feat/replay', *extra], private, env, ok=False)
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

    # Fresh-base admission owns the exact pre-push SHA, even when a different,
    # clean commit is checked out. The actual provider default is staging.
    data['task'].update(status='review', pr_url=None)
    data['merged'] = []
    save()
    base = run(['git', 'rev-parse', 'HEAD'], private).stdout.strip()
    (private / 'conflict.txt').write_text('feature\n')
    run(['git', '-c', 'user.name=Invented seat', '-c', 'user.email=fixture@example.invalid',
         'commit', '-am', 'Invented conflicting head'], private)
    conflicting = run(['git', 'rev-parse', 'HEAD'], private).stdout.strip()
    run(['git', 'checkout', '--detach', base], private)
    upstream = root / 'upstream'
    run(['git', 'clone', target, upstream], source)
    (upstream / 'conflict.txt').write_text('upstream\n')
    run(['git', '-c', 'user.name=Invented upstream', '-c', 'user.email=fixture@example.invalid',
         'commit', '-am', 'Invented default-tip advance'], upstream)
    run(['git', 'push', 'origin', 'staging'], upstream)
    result = push(conflicting, (base+':refs/heads/unbound-evidence',))
    assert result.returncode != 0 and 'conflict' in result.stderr.lower() and absent(), \
        ('Conflicting exact SHA was published against advanced staging', result.stdout, result.stderr)
    assert run(['git', '--git-dir', target, 'show-ref', '--verify', 'refs/heads/unbound-evidence'],
               source, ok=False).returncode != 0, 'Rejected multi-ref push sent another ref'
    # A behind head can still merge cleanly; warn without claiming a rebase.
    result = push(base)
    assert result.returncode == 0 and 'behind' in result.stderr.lower(), result.stderr
    remove()
    current = run(['git', 'rev-parse', 'HEAD'], upstream).stdout.strip()
    result = push(current)
    assert result.returncode == 0 and 'behind' not in result.stderr.lower(), result.stderr
    remove()
    (gate / 'shallow').write_text(base+'\n')
    result = push(base)
    assert result.returncode != 0 and 'unavailable' in result.stderr and absent(), result.stderr
    (gate / 'shallow').unlink()
    data['task']['held_by_decision'] = True
    save()
    result = push(base)
    assert result.returncode != 0 and 'decision' in result.stderr and absent(), result.stderr
    result = run(['git', 'push', target, base+':refs/heads/unbound-evidence'], private, env, ok=False)
    assert result.returncode == 0, 'Unrelated evidence ref was subjected to a task-bound publication check'
    run(['git', '--git-dir', target, 'update-ref', '-d', 'refs/heads/unbound-evidence'], source)
    data['task']['held_by_decision'] = False
    save()
    # Unknown/default fetch failure must refuse and redact provider stderr.
    run(['git', '--git-dir', gate, 'config', 'url.' + str(target) + '.insteadOf',
         'https://unused.invalid/'], source)
    run(['git', '--git-dir', gate, 'config', 'url.' + str(root / 'missing-secret-path') + '.insteadOf',
         'https://github.com/fixture/project.git'], source)
    result = push(base)
    assert result.returncode != 0 and absent() and 'missing-secret-path' not in result.stderr, result.stderr
    # A seat on another repository (no agentboard scripts in it) drives the
    # helpers from the agentboard checkout; each resolves its siblings there,
    # never from the target repository (GH264).
    agentboard = root / 'agentboard' / 'scripts'
    agentboard.mkdir(parents=True)
    for original, name in ((launcher, 'launch-seat'), (guard, 'publication-guard'), (wrapper, 'publish-seat')):
        shutil.copy2(original, agentboard / name)
        (agentboard / name).chmod(0o755)
    external, external_gate, external_pool = root / 'external', root / 'external-gate.git', root / 'external-pool'
    external.mkdir()
    run(['git', 'init', '-b', 'main'], external)
    run(['git', 'config', 'user.name', 'Invented seat'], external)
    run(['git', 'config', 'user.email', 'fixture@example.invalid'], external)
    (external / 'README').write_text('no agentboard scripts here\n')
    run(['git', 'add', '.'], external)
    run(['git', 'commit', '-m', 'Invented external fixture'], external)
    run(['git', 'init', '--bare', external_gate], external)
    run(['git', 'remote', 'add', 'origin', target], external)
    run(['git', 'remote', 'add', 'no-mistakes', external_gate], external)
    external_seat = Path(run([treehouse, 'get', '--lease', '--lease-holder', 'codex-fixture', '--root', external_pool],
                             external, acquisition_env).stdout.strip())
    run(['git', 'switch', '-c', 'feat/external', 'main'], external_seat)
    assert not (external_seat / 'scripts').exists()
    (tools / 'no-mistakes').write_text('#!/bin/sh\necho "fixture no-mistakes $*"\n')
    (tools / 'no-mistakes').chmod(0o755)
    external_env = dict(env, AGENTBOARD_SEAT_SOURCE=str(external), AGENTBOARD_SEAT_WORKTREE=str(external_seat),
                        AGENTBOARD_SEAT_ROOT=str(external_pool))
    result = run([agentboard / 'publication-guard', 'check', 'guard-fixture'], external_seat, external_env, ok=False)
    assert result.returncode == 0 and 'verified' in result.stdout, ('external-repo guard check', result.stdout, result.stderr)
    result = run([agentboard / 'publish-seat', 'guard-fixture', '--', 'run'], external_seat, external_env, ok=False)
    assert result.returncode == 0 and 'fixture no-mistakes axi run' in result.stdout, \
        ('external-repo publish-seat', result.stdout, result.stderr)
    assert (external_gate / 'hooks' / 'pre-push').exists(), 'external-repo guard was not bound to its native gate'
    print('Real native-gate pushes: ownership/history guards, exact-head conflict refusal, staging default advance, behind-clean warning, unknown refusal and external-repo helpers passed')
