#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"
setup

# 1. need derivation sums platform memory_mb (molecule mode)
make_scenario demo 4096 2048
out=$(run_gate r1 acquire --molecule-scenario demo --deadline 1)
echo "$out" | grep -q 'need=6144MB' || { echo "derivation: $out"; exit 1; }
run_gate r1 release >/dev/null

# 2. platform without memory_mb falls back to 4096
make_scenario nodefault none
out=$(run_gate r2 acquire --molecule-scenario nodefault --deadline 1)
echo "$out" | grep -q 'need=4096MB' || { echo "default: $out"; exit 1; }
run_gate r2 release >/dev/null

# 3. ${VAR:-default} resolution in molecule.yml
mkdir -p "$REPO_FAKE/molecule/envsub"
cat > "$REPO_FAKE/molecule/envsub/molecule.yml" <<'EOF'
platforms:
  - name: "es-${MOLECULE_DISTRO:-debian12}"
    memory_mb: ${TEST_MEM_MB:-2048}
EOF
out=$(run_gate r3 acquire --molecule-scenario envsub --deadline 1)
echo "$out" | grep -q 'need=2048MB' || { echo "envsub default: $out"; exit 1; }
run_gate r3 release >/dev/null
out=$(TEST_MEM_MB=512 run_gate r4 acquire --molecule-scenario envsub --deadline 1)
echo "$out" | grep -q 'need=512MB' || { echo "envsub override: $out"; exit 1; }
run_gate r4 release >/dev/null

# 4. --need-mb mode with a label; reservation carries the label
out=$(run_gate r10 acquire --need-mb 1536 --label build-job --deadline 1)
echo "$out" | grep -q 'need=1536MB' || { echo "need-mb mode: $out"; exit 1; }
grep -q '^1536 build-job$' "$MOLECULE_GATE_DIR/r.r10" || { echo "label missing"; exit 1; }
run_gate r10 release >/dev/null

# 5. exactly one of --need-mb / --molecule-scenario is required
if run_gate r11 acquire --deadline 1 >/dev/null 2>&1; then
  echo "acquire without a need source must fail"; exit 1
fi
if run_gate r12 acquire --need-mb 512 --molecule-scenario demo --deadline 1 >/dev/null 2>&1; then
  echo "acquire with both need sources must fail"; exit 1
fi

# 6. limits.memory unit parsing; stopped containers ignored
set_incus_containers "a:Running:1GiB" "b:Running:1024MiB" "c:Running:1GB" "d:Stopped:512GB"
make_scenario small 1024
out=$(run_gate r5 acquire --molecule-scenario small --deadline 1)
echo "$out" | grep -q 'committed=3072MB' || { echo "units: $out"; exit 1; }
run_gate r5 release >/dev/null

# 7. blocked -> fail fast with verdict, ticket cleaned up
set_incus_containers "big:Running:8192MB"      # free = 10240 - 8192 = 2048
make_scenario heavy 4096
if out=$(run_gate r6 acquire --molecule-scenario heavy --deadline 1 2>&1); then
  echo "should have starved: $out"; exit 1
fi
echo "$out" | grep -q 'STARVED' || { echo "verdict: $out"; exit 1; }
assert_no_file "$MOLECULE_GATE_DIR/r.r6"
if compgen -G "$MOLECULE_GATE_DIR/q.*" >/dev/null; then echo "ticket leaked"; exit 1; fi

# 8. foreign reservations count against free
set_incus_containers
echo "8192 other" > "$MOLECULE_GATE_DIR/r.other"
make_scenario mid 4096                          # free = 10240 - 8192 = 2048
if run_gate r7 acquire --molecule-scenario mid --deadline 1 >/dev/null 2>&1; then
  echo "reservation not counted"; exit 1
fi
rm -f "$MOLECULE_GATE_DIR/r.other"

# 9. incus query failure -> refuse to admit, non-zero exit; no ticket stranded
make_scenario small2 1024
if GATE_INCUS_QUERY=false run_gate r8 acquire --molecule-scenario small2 --deadline 1 >/dev/null 2>&1; then
  echo "admitted blind on query failure"; exit 1
fi
if compgen -G "$MOLECULE_GATE_DIR/q.*" >/dev/null; then echo "ticket stranded on query failure"; exit 1; fi

# 10. no INCUS_HOST and no GATE_INCUS_QUERY -> clear failure
if (unset GATE_INCUS_QUERY INCUS_HOST; run_gate r9 acquire --molecule-scenario small2 --deadline 1 >/dev/null 2>&1); then
  echo "admitted blind without a query source"; exit 1
fi

# 11. empty-string env counts as unset (the action passes inputs through)
if out=$(INCUS_RESERVE_MB='' run_gate r13 acquire --need-mb 1024 --deadline 1 2>&1); then
  echo "empty INCUS_RESERVE_MB must mean default 12288, which cannot fit: $out"; exit 1
fi
echo "$out" | grep -q 'reserve=12288MB' || { echo "cfg empty-env: $out"; exit 1; }

echo OK
