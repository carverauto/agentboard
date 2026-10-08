#!/usr/bin/env bash
set -euo pipefail
python3 "$TEST_SRCDIR/$1" "$TEST_SRCDIR/$2" "$TEST_SRCDIR/$3" "$TEST_SRCDIR/$4" "$TEST_SRCDIR/$5"
