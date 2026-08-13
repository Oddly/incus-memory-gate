#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"
setup

# 1. blocked head admits as soon as capacity frees (FIFO base case)
set_incus_containers "big:Running:9216MB"        # free = 1024
make_scenario twoG 2048
run_gate first acquire --molecule-scenario twoG --deadline 6 >/dev/null &
fpid=$!
sleep 1
set_incus_containers                              # capacity freed
wait "$fpid" || { echo "head should admit after capacity frees"; exit 1; }
run_gate first release >/dev/null

# 2. a smaller job bypasses a blocked head and increments its counter
set_incus_containers "big:Running:8192MB"        # free = 2048
make_scenario huge 4096
make_scenario tiny 1024
run_gate heavy acquire --molecule-scenario huge --deadline 8 >/dev/null 2>&1 &
hpid=$!
sleep 1                                           # heavy is now the head
GATE_MAX_OVERTAKES=10 run_gate quick acquire --molecule-scenario tiny --deadline 3 >/dev/null \
  || { echo "bypass should admit a fitting job"; exit 1; }
grep -q ' 1$' "$MOLECULE_GATE_DIR"/q.*.heavy \
  || { echo "head counter not incremented"; exit 1; }
run_gate quick release >/dev/null

# 3. owner refresh preserves the counter; at K the queue goes strict
head_ticket=$(ls "$MOLECULE_GATE_DIR"/q.*.heavy)
need=$(awk '{print $1}' "$head_ticket")
lbl=$(awk '{print $2}' "$head_ticket")
printf '%s %s 10\n' "$need" "$lbl" > "$head_ticket"
sleep 1   # heavy keeps polling; if it rewrote its ticket the counter resets
if GATE_MAX_OVERTAKES=10 run_gate quick2 acquire --molecule-scenario tiny --deadline 2 >/dev/null 2>&1; then
  echo "strict phase must refuse bypass at K overtakes"; exit 1
fi
grep -q ' 10$' "$head_ticket" || { echo "owner refresh clobbered the counter"; exit 1; }

# 4. the starved head cleans up its ticket on the way out
wait "$hpid" && { echo "heavy should have starved"; exit 1; }
# ls|grep over the controlled gate dir mirrors the brief's assertion verbatim.
# shellcheck disable=SC2010,SC2143
[ -z "$(ls "$MOLECULE_GATE_DIR" 2>/dev/null | grep '^q\.')" ] \
  || { echo "starved head leaked its ticket"; exit 1; }

# 5. a stale ticket (dead job) stops blocking the queue
set_incus_containers "big:Running:8192MB"        # free = 2048
echo "9999 ghost 0" > "$MOLECULE_GATE_DIR/q.0000000001.ghost"
touch -d '1 minute ago' "$MOLECULE_GATE_DIR/q.0000000001.ghost"
GATE_MAX_OVERTAKES=0 run_gate solo acquire --molecule-scenario tiny --deadline 3 >/dev/null \
  || { echo "stale ticket should be GCd, not block"; exit 1; }
run_gate solo release >/dev/null

echo OK
