#!/usr/bin/env bash
# Shared helpers for the memory-gate test suite. Source from test_*.sh.
# Linux-only: needs flock, GNU stat, GNU touch.
set -uo pipefail

GATE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wait-for-memory.sh"

setup() {
  T="$(mktemp -d)"
  export MOLECULE_GATE_DIR="$T/gate"
  export GATE_MEMINFO="$T/meminfo"
  export GATE_INCUS_QUERY="cat $T/incus.json"
  export GATE_POLL_SECONDS=0.2
  export GATE_TICKET_STALE_SECONDS=2
  export INCUS_RESERVE_MB=0
  REPO_FAKE="$T/repo"
  mkdir -p "$REPO_FAKE/molecule"
  echo '[]' > "$T/incus.json"
  set_mem_total 10240
  trap 'rm -rf "$T"' EXIT
}

set_mem_total() {
  printf 'MemTotal:       %d kB\n' $(( $1 * 1024 )) > "$GATE_MEMINFO"
}

# Each argument: "<name>:<status>:<limits.memory>". No arguments = no containers.
set_incus_containers() {
  python3 - "$T/incus.json" "$@" <<'PY'
import json, sys
out = []
for spec in sys.argv[2:]:
    name, status, limit = spec.split(":")
    out.append({"name": name, "status": status,
                "config": {"limits.memory": limit}})
json.dump(out, open(sys.argv[1], "w"))
PY
}

# make_scenario <name> <memory_mb...>; pass the literal word "none" for a
# platform that omits memory_mb (exercises the 4096 default).
make_scenario() {
  local dir="$REPO_FAKE/molecule/$1" i=0 mb
  mkdir -p "$dir"
  {
    echo "platforms:"
    shift
    for mb in "$@"; do
      i=$(( i + 1 ))
      echo "  - name: p$i"
      if [ "$mb" != none ]; then
        echo "    memory_mb: $mb"
      fi
    done
  } > "$dir/molecule.yml"
}

# run_gate <runner-name> <acquire|release> [args...] — runs from the fake
# repo root so scenario paths resolve like they do in CI.
run_gate() {
  local name="$1"
  shift
  (cd "$REPO_FAKE" && RUNNER_NAME="$name" bash "$GATE_SCRIPT" "$@")
}

assert_eq() {
  [ "$1" = "$2" ] || { echo "assert_eq failed: got '$1' want '$2' ($3)"; exit 1; }
}
assert_file() { [ -f "$1" ] || { echo "missing file: $1"; exit 1; }; }
assert_no_file() { [ ! -f "$1" ] || { echo "unexpected file: $1"; exit 1; }; }
