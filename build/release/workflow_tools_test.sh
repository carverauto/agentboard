#!/usr/bin/env bash
set -euo pipefail
# Execute the publication workflow's binary interfaces inside its pinned image.
export PATH=/usr/local/bin:/usr/bin:/bin
for required in git curl sha256sum tar python3; do
  command -v "$required" >/dev/null || { echo "Workflow image is missing $required" >&2; exit 1; }
done
test -x "$TEST_SRCDIR/$1"
tar -xzf "$TEST_SRCDIR/$2" -C "$TEST_TMPDIR"
git --version >/dev/null
curl --version >/dev/null
"$TEST_TMPDIR/gh_2.65.0_linux_amd64/bin/gh" release create --help >/dev/null
sha256sum --version >/dev/null
tar --version >/dev/null
python3 -c 'import json, pathlib, sys'
echo 'Pinned workflow image and explicit pinned tool inputs supply publication dependencies.'
