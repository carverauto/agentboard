"""Validate an OCI layout's content hashes and export its actual layered rootfs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

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
assert config['config']['User'] == '10001:10001'
assert config['config']['Entrypoint'] == ['/app/bin/agentboard']
assert config['config']['Cmd'] == ['start']
assert config['config']['WorkingDir'] == '/app'
assert 'RELEASE_TMP=/tmp/agentboard' in config['config']['Env']
output = str(Path(sys.argv[2]).resolve())
with tempfile.TemporaryDirectory() as root:
    for layer in manifest['layers']:
        # Inputs are pinned/repository-built layers; this image has no whiteouts.
        subprocess.run(['tar', '-xf', str(blob(layer)), '-C', root], check=True)
    assert (Path(root)/'app/bin/agentboard').is_file()
    os.chmod(root, 0o755)
    subprocess.run(['tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner', '-czf', output, '-C', root, '.'], check=True)
