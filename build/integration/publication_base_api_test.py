"""Native pre-push evidence through the real packaged CLI/Phoenix API.

The provider and Git repositories are invented. Task state and attributed
events are produced by the release, never by the provider fixture.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile


env = {k: v for k, v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
env.update(AGENT_ID='codex-fixture-publisher', AGENTBOARD_MODEL='fixture-model',
           AGENTBOARD_HARNESS='codex')
binary = os.environ['AB_BINARY']
task_id = 'publication-base-fixture'


def run(argv, cwd=None, code=0):
    result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env,
                            text=True, capture_output=True, timeout=60)
    if code is not None:
        assert result.returncode == code, (argv, result.stdout, result.stderr)
    return result


def ab(*args):
    return json.loads(run([binary, '--json', *args]).stdout)


def evidence():
    return [e for e in ab('task', 'show', task_id)['events']
            if (e['body'] or '').startswith('publication-base:')]


ab('agent', 'register', '--name', 'Invented publisher')
ab('task', 'create', '--id', task_id, '--title', 'Publication base fixture', '--repo', 'fixture/project')
ab('task', 'claim', task_id)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    repo, target, upstream, tools, hooks = [root / p for p in ('repo', 'target.git', 'upstream', 'tools', 'hooks')]
    repo.mkdir(); tools.mkdir(); hooks.mkdir()
    run(['git', 'init', '-b', 'staging'], repo)
    run(['git', 'config', 'user.name', 'Invented publisher'], repo)
    run(['git', 'config', 'user.email', 'fixture@example.invalid'], repo)
    (repo / 'content').write_text('base\n')
    run(['git', 'add', '.'], repo)
    run(['git', 'commit', '-m', 'Invented base'], repo)
    base = run(['git', 'rev-parse', 'HEAD'], repo).stdout.strip()
    run(['git', 'init', '--bare', target], repo)
    run(['git', '--git-dir', target, 'symbolic-ref', 'HEAD', 'refs/heads/staging'], repo)
    run(['git', 'push', target, 'staging'], repo)
    run(['git', 'clone', target, upstream], repo)
    run(['git', 'config', 'user.name', 'Invented upstream'], upstream)
    run(['git', 'config', 'user.email', 'fixture@example.invalid'], upstream)
    (upstream / 'content').write_text('upstream\n')
    run(['git', 'commit', '-am', 'Invented default advance'], upstream)
    run(['git', 'push', 'origin', 'staging'], upstream)
    tip = run(['git', 'rev-parse', 'HEAD'], upstream).stdout.strip()
    run(['git', 'config', 'url.' + str(target) + '.insteadOf', 'https://github.com/fixture/project.git'], repo)
    (tools / 'agentboard').symlink_to(binary)
    provider = tools / 'gh'
    provider.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
if 'repo' in sys.argv:
    if os.environ.get('FIXTURE_REVISION_RACE') == 'true':
        subprocess.run([os.environ['AB_BINARY'],'--json','task','update',
                        'publication-base-fixture','--body','concurrent owner progress'],
                       stdout=subprocess.DEVNULL,check=True)
    print(json.dumps({'defaultBranchRef':{'name':'staging'}}))
else:
    print('[]')
''')
    provider.chmod(0o755)
    env['PATH'] = str(tools)+os.pathsep+env['PATH']
    guard = Path(os.environ['TEST_SRCDIR']) / os.environ['TEST_WORKSPACE'] / 'scripts/publication-guard'
    registry = root / 'bindings.json'
    registry.write_text(json.dumps({'feat/publication': dict(task=task_id, repo='fixture/project',
        head_repo='fixture/project', url=env['AGENTBOARD_URL'], agent=env['AGENT_ID'],
        model=env['AGENTBOARD_MODEL'], harness=env['AGENTBOARD_HARNESS'])}))
    import shlex
    hook = hooks / 'pre-push'
    hook.write_text('#!/bin/sh\nexec python3 '+shlex.quote(str(guard))+' hook '+shlex.quote(str(registry))+'\n')
    hook.chmod(0o755)
    run(['git', 'config', 'core.hooksPath', hooks], repo)

    def push(head):
        return run(['git', 'push', target, head+':refs/heads/feat/publication'], repo, code=None)

    # Baseline head is behind but clean. The actual API owns evidence/history.
    before = ab('task', 'show', task_id)['task']
    result = push(base)
    assert result.returncode == 0 and 'behind' in result.stderr, result.stderr
    event, = evidence()
    assert event['actor_id'] == env['AGENT_ID'] and event['harness'] == 'codex'
    assert event['body'] == f'publication-base: behind_clean; head={base}; default_ref=staging; default_tip={tip}'
    after = ab('task', 'show', task_id)['task']
    assert after['revision'] == before['revision']+1 and after['assignee_id'] == before['assignee_id']
    assert after['status'] == before['status'] == 'in_progress'
    assert after['claim_expires_at'] == before['claim_expires_at']
    run(['git', '--git-dir', target, 'update-ref', '-d', 'refs/heads/feat/publication'], repo)

    # Owner progress after the guard read races its evidence write. Revision
    # protection refuses the push instead of accepting unrecorded admission.
    env['FIXTURE_REVISION_RACE'] = 'true'
    result = push(base)
    assert result.returncode != 0 and len(evidence()) == 1, result.stderr
    assert run(['git', '--git-dir', target, 'show-ref', '--verify', 'refs/heads/feat/publication'],
               repo, code=None).returncode != 0
    env.pop('FIXTURE_REVISION_RACE')

    # Definitive dirty evidence is retained even though provider write refuses.
    (repo / 'content').write_text('feature\n')
    run(['git', 'commit', '-am', 'Invented conflicting exact head'], repo)
    dirty = run(['git', 'rev-parse', 'HEAD'], repo).stdout.strip()
    result = push(dirty)
    assert result.returncode != 0 and 'conflicts' in result.stderr, result.stderr
    assert evidence()[-1]['body'] == f'publication-base: conflicting; head={dirty}; default_ref=staging; default_tip={tip}'
    assert run(['git', '--git-dir', target, 'show-ref', '--verify', 'refs/heads/feat/publication'],
               repo, code=None).returncode != 0

print('Real CLI/API retained attributed exact-base evidence; revision race refused unrecorded publication; task ownership/status/lease preserved')
