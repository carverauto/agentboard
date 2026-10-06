#!/usr/bin/env bash
set -euo pipefail
tar -xzf "$TEST_SRCDIR/$1" -C "$TEST_TMPDIR"
cd "$TEST_TMPDIR"
sha256sum --check SHA256SUMS
test "$(./agentboard-linux-amd64 version)" = 0.1.0
file agentboard-linux-amd64 | grep -q 'ELF 64-bit.*x86-64.*statically linked'
file agentboard-linux-arm64 | grep -q 'ELF 64-bit.*ARM aarch64.*statically linked'
file agentboard-darwin-amd64 | grep -q 'Mach-O 64-bit x86_64'
file agentboard-darwin-arm64 | grep -q 'Mach-O 64-bit arm64'
dpkg-deb -x "$TEST_SRCDIR/$2" "$TEST_TMPDIR/qemu"
test "$("$TEST_TMPDIR/qemu/usr/bin/qemu-aarch64-static" ./agentboard-linux-arm64 version)" = 0.1.0
echo 'Linux amd64 executed natively; Linux arm64 executed with pinned QEMU.'
echo 'Darwin runtime execution untested: remote executor is Linux.'
