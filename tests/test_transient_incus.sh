#!/usr/bin/env bash
# A transient incus query failure must NOT fail the gate. When incusd restarts
# (e.g. the twice-daily cert renewal on the CI host runs `systemctl restart
# incus`), `incus list -f json` briefly emits
#   Error: Failed to begin transaction: sql: database is closed
# instead of JSON. The gate must retry that query and, once the daemon is back,
# admit the job — not abort and fail an innocent CI leg.
#
# This differs from the persistent-failure case (test_admission.sh #9,
# GATE_INCUS_QUERY=false) which must still refuse to admit.
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"

setup
set_mem_total 10240
echo '[]' > "$T/incus.json"          # once reachable: no containers, plenty free
make_scenario small 1024

# Stub query: fail the first two calls like a daemon mid-restart, then serve JSON.
export FLAKY_COUNTER="$T/flaky.count"; : > "$FLAKY_COUNTER"
export FLAKY_FAILS=2
export FLAKY_JSON="$T/incus.json"
cat > "$T/flaky-query.sh" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$FLAKY_COUNTER" 2>/dev/null || echo 0); n=$(( n + 1 )); echo "$n" > "$FLAKY_COUNTER"
if [ "$n" -le "${FLAKY_FAILS:-2}" ]; then
  echo "Error: Failed to begin transaction: sql: database is closed" >&2
  exit 1
fi
cat "$FLAKY_JSON"
STUB
export GATE_INCUS_QUERY="bash $T/flaky-query.sh"
export GATE_QUERY_RETRIES=6
export GATE_QUERY_RETRY_DELAY=0.2

if ! run_gate r1 acquire --molecule-scenario small --deadline 30 >/dev/null 2>&1; then
  echo "FAIL: gate aborted on a transient (recoverable) incus query failure"; exit 1
fi
assert_file "$MOLECULE_GATE_DIR/r.r1"

# Confirm it actually retried past the two induced failures rather than getting
# lucky some other way.
n=$(cat "$FLAKY_COUNTER")
[ "$n" -ge 3 ] || { echo "FAIL: expected >=3 query attempts, got $n"; exit 1; }

echo OK
