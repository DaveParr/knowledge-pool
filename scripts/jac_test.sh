#!/usr/bin/env bash
# Run `jac test` and fail on any failing or erroring test.
#
# `jac test` exits 1 when an assertion fails, but exits 0 when a test raises
# an exception: it prints "FAILED (errors=N)" and "ERROR: ..." and carries on.
# So check the output as well as the exit code.
set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

jac test "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
    echo "jac test exited with $status" >&2
    exit "$status"
fi
if grep -qE '^(FAILED \(|ERROR: )' "$log"; then
    echo "jac test reported failing or erroring tests (see above)" >&2
    exit 1
fi
