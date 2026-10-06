"""Validate an OCI layout's content hashes and export its actual layered rootfs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import shutil
from pathlib import PurePosixPath

layout = Path(sys.argv[1])

def blob(descriptor):
    algorithm, digest = descriptor['digest'].split(':')
    assert algorithm == 'sha256'
    path = layout / 'blobs' / algorithm / digest
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
    return path

manifest = json.loads(blob(json.loads((layout/'index.json').read_text())['manifests'][0]).read_text())
config = json.loads(blob(manifest['config']).read_text())
assert config['os'] == 'linux' and config['architecture'] == 'amd64'
profile = sys.argv[3] if len(sys.argv) > 3 else 'dashboard'
if profile == 'dashboard':
    assert config['config']['User'] == '10001:10001'
    assert config['config']['Entrypoint'] == ['/app/bin/agentboard']
    assert config['config']['Cmd'] == ['start']
    assert config['config']['WorkingDir'] == '/app'
    assert 'RELEASE_TMP=/tmp/agentboard' in config['config']['Env']
elif profile != 'cnpg':
    raise ValueError('Unknown image profile')
output = str(Path(sys.argv[2]).resolve())
with tempfile.TemporaryDirectory() as root:
    for layer in manifest['layers']:
        archive = blob(layer)
        # OCI whiteouts remove only previous-layer content. Apply them before
        # extracting this layer, excluding marker files from the resulting rootfs.
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            for member in members:
                relative = PurePosixPath(member.name)
                assert not relative.is_absolute() and '..' not in relative.parts
                if not relative.name.startswith('.wh.'):
                    continue
                parent = Path(root).joinpath(*relative.parent.parts)
                targets = list(parent.iterdir()) if relative.name == '.wh..wh..opq' and parent.exists() else [parent / relative.name[4:]]
                for target in targets:
                    if target.is_symlink() or target.is_file():
                        target.unlink()
                    elif target.is_dir():
                        shutil.rmtree(target)
            tar.extractall(root, members=[m for m in members if not PurePosixPath(m.name).name.startswith('.wh.')])
    if profile == 'dashboard':
        assert (Path(root)/'app/bin/agentboard').is_file()
    else:
        assert (Path(root)/'usr/lib/postgresql/18/bin/postgres').is_file()
        assert (Path(root)/'usr/lib/postgresql/18/lib/pg_textsearch.so').is_file()
    os.chmod(root, 0o755)
    subprocess.run(['tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner', '-czf', output, '-C', root, '.'], check=True)
