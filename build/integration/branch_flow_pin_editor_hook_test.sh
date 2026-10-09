#!/usr/bin/env bash
set -euo pipefail
"$TEST_SRCDIR/$2" --test "$TEST_SRCDIR/$1"
