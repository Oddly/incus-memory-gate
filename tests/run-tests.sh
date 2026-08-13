#!/usr/bin/env bash
# Runner for the hermetic memory-gate suite. Each test_*.sh runs in its own
# bash process with a throwaway gate dir; a non-zero exit fails the suite.
# Linux-only (flock, GNU stat); in CI this runs on ubuntu-latest.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
pass=0 fail=0
for t in test_*.sh; do
  echo "== $t"
  if bash "$t"; then
    pass=$(( pass + 1 ))
  else
    fail=$(( fail + 1 ))
    echo "FAILED: $t"
  fi
done
echo "gate tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
