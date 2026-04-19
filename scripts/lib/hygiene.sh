#!/usr/bin/env bash
# Hygiene invariants — sourced by capture.sh and every adapter.
# Ensures the captured value cannot leak via history, umask, or pipe-failure masking.

set -euo pipefail

# History off — do not write any command line to history while this process runs.
set +o history 2>/dev/null || true
HISTFILE=/dev/null
export HISTFILE

# Restrictive umask for any tempfile we create.
umask 077

# Guard against inherited $IFS weirdness.
IFS=$' \t\n'
