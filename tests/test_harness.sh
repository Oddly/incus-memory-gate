#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"
setup

set_mem_total 4096
grep -q 'MemTotal:       4194304 kB' "$GATE_MEMINFO" || { echo "meminfo fixture broken"; exit 1; }

set_incus_containers "a:Running:2GiB" "b:Stopped:1GB"
python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data) == 2, data
assert data[0]["config"]["limits.memory"] == "2GiB", data
' "$T/incus.json"

make_scenario demo 4096 none
grep -q 'memory_mb: 4096' "$REPO_FAKE/molecule/demo/molecule.yml" || exit 1
assert_eq "$(grep -c 'name: p' "$REPO_FAKE/molecule/demo/molecule.yml")" "2" "two platforms"

echo OK
