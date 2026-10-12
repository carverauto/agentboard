#!/usr/bin/env bash
# Build a temporary, pinned Node module tree. Never contacts a native daemon.
set -euo pipefail

resolve_path() {
  if [[ "$1" = /* ]]; then
    printf '%s\n' "$1"
  elif [[ -n "${TEST_SRCDIR:-}" ]]; then
    printf '%s/%s\n' "$TEST_SRCDIR" "$1"
  else
    printf '%s/%s\n' "$PWD" "$1"
  fi
}

client="$(resolve_path "${1:?expected RPC client module path}")"
node="$(resolve_path "${2:?expected Node executable path}")"
archive="$(resolve_path "${3:?expected pinned ws archive path}")"
sources="$(dirname "$client")"
if [[ -n "${TEST_SRCDIR:-}" ]]; then
  fixtures="$TEST_SRCDIR/$TEST_WORKSPACE/build/integration"
else
  fixtures="$(cd "$(dirname "$0")" && pwd)"
fi

# Recheck even for non-Bazel callers, before unpacking any dependency source.
"$node" --input-type=commonjs - "$archive" <<'NODE'
const { createHash } = require('node:crypto');
const { readFileSync } = require('node:fs');
const digest = createHash('sha256').update(readFileSync(process.argv[2])).digest('hex');
if (digest !== 'ca9b3798b2e11ce8fac6713f50ef0501aa12b09b330623c1dc409dff94e7abc8') {
  throw new Error('ws 8.22.0 archive checksum mismatch');
}
NODE

runtime="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/codex-rpc-test.XXXXXX")"
trap 'rm -rf "$runtime"' EXIT
library="$runtime/internal/nativequeue/codex"
mkdir -p "$runtime/node_modules/ws" "$runtime/build/integration" "$library"
tar -xzf "$archive" --strip-components=1 -C "$runtime/node_modules/ws"
for source in rpc-client.mjs socket-discovery.mjs rpc-wire.mjs inherited-client.mjs owner-control.mjs transport.mjs journal.mjs; do
  cp "$sources/$source" "$library/$source"
done
for fixture in codex_rpc_client_test.mjs codex_rpc_socket_test.mjs codex_owner_control_test.mjs; do
  cp "$fixtures/$fixture" "$runtime/build/integration/$fixture"
done

# Pure JavaScript ws only. Optional native addons are never installed or loaded.
export WS_NO_BUFFER_UTIL=1 WS_NO_UTF_8_VALIDATE=1
export PATH="$(dirname "$node"):$PATH"
"$node" "$runtime/build/integration/codex_rpc_client_test.mjs" "$library/rpc-client.mjs"
"$node" "$runtime/build/integration/codex_rpc_socket_test.mjs" "$library/rpc-client.mjs"

"$node" "$runtime/build/integration/codex_owner_control_test.mjs" "$library/rpc-client.mjs"
