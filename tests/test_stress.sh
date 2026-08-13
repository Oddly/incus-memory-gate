#!/usr/bin/env bash
# Concurrency stress: 12 workers with deterministic mixed needs race for a
# 10 GB budget. After each admission the worker re-reads the ledger under
# the same lock and records a violation if the reserved sum exceeds the
# budget — any over-admission caused by a locking bug is caught by the
# admitting worker's own check before it releases. Ordering guarantees are
# unit-tested in test_queue.sh, not here.
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"
setup

set_mem_total 10240
BUDGET=10240
RANDOM=42                       # fixed seed: needs are reproducible
needs=()
for i in $(seq 1 12); do
  needs+=( $(( 1024 + RANDOM % 3072 )) )
done

worker() {
  local i="$1" need="$2" total f
  if run_gate "w$i" acquire --need-mb "$need" --label "stress$i" --deadline 30 >/dev/null 2>&1; then
    (
      flock -s 9
      total=0
      for f in "$MOLECULE_GATE_DIR"/r.*; do
        [ -f "$f" ] || continue
        total=$(( total + $(awk '{print $1; exit}' "$f") ))
      done
      if [ "$total" -gt "$BUDGET" ]; then
        echo "VIOLATION: reserved=${total}MB > budget=${BUDGET}MB" >> "$T/violations"
      fi
    ) 9>"$MOLECULE_GATE_DIR/.lock"
    sleep "0.$(( 1 + i % 4 ))"
    run_gate "w$i" release >/dev/null
  else
    echo "w$i" >> "$T/starved"
  fi
}

for i in $(seq 1 12); do
  worker "$i" "${needs[$(( i - 1 ))]}" &
done
wait

assert_no_file "$T/violations"
# ls|grep over the controlled gate dir mirrors test_queue.sh's assertion.
# shellcheck disable=SC2010
leftovers=$(ls "$MOLECULE_GATE_DIR" 2>/dev/null | grep -c '^[qr]\.' || true)
assert_eq "$leftovers" "0" "no orphaned tickets or reservations"
if [ -f "$T/starved" ]; then
  echo "note: starved workers: $(tr '\n' ' ' < "$T/starved")"
fi
echo OK
