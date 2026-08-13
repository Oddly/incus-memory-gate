#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"
setup
mkdir -p "$MOLECULE_GATE_DIR"

# 1. release removes reservation and any ticket for the runner
echo "1024 x" > "$MOLECULE_GATE_DIR/r.rel1"
echo "1024 x 0" > "$MOLECULE_GATE_DIR/q.0000000001.rel1"
out=$(run_gate rel1 release)
echo "$out" | grep -q 'released' || { echo "release: $out"; exit 1; }
assert_no_file "$MOLECULE_GATE_DIR/r.rel1"
assert_no_file "$MOLECULE_GATE_DIR/q.0000000001.rel1"

# 2. release after the launcher already converted the reservation is a no-op
out=$(run_gate rel2 release)
echo "$out" | grep -q 'nothing to release' || { echo "noop release: $out"; exit 1; }

# 3. reservations older than the TTL are garbage-collected by acquire
echo "4096 stale" > "$MOLECULE_GATE_DIR/r.dead"
touch -d '2 hours ago' "$MOLECULE_GATE_DIR/r.dead"
make_scenario mid2 8192                # if stale counted: 10240-4096=6144 < 8192
run_gate live acquire --molecule-scenario mid2 --deadline 1 >/dev/null \
  || { echo "stale reservation not GCd"; exit 1; }
assert_no_file "$MOLECULE_GATE_DIR/r.dead"
run_gate live release >/dev/null

echo OK
