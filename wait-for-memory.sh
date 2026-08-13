#!/usr/bin/env bash
# Gate-dir entries are controlled names (q.<zero-padded-epoch>.<runner>,
# r.<runner>) with no spaces or newlines, so ls|sort over the glob is safe.
# shellcheck disable=SC2012
# Memory admission gate for CI jobs sharing one incus host.
#
# Admission formula (all MB):
#
#   free = MemTotal - reserve - committed - reservations
#   admit when free >= my_need
#
#   committed    sum of limits.memory over *running* incus containers
#   reservations jobs admitted here whose containers are not launched yet;
#                the consumer's launch step deletes the reservation right
#                after `incus launch`, converting it into committed capacity
#   my_need      --need-mb, or --molecule-scenario <name>: the sum of
#                memory_mb (default 4096) over the platforms in
#                molecule/<name>/molecule.yml relative to the working
#                directory, after ${VAR:-default} resolution
#
# Queueing: FIFO tickets with bounded overtakes. A waiter that fits may
# bypass a blocked head until the head's ticket has been overtaken
# GATE_MAX_OVERTAKES times; then the queue is strict until the head is
# admitted. At the deadline the gate FAILS (exit 1) instead of barging in:
# a starved job is an explicit retryable failure, not an OOM risk.
#
# Usage:
#   wait-for-memory.sh acquire --need-mb <MB> [--label <name>] [--deadline <s>]
#   wait-for-memory.sh acquire --molecule-scenario <name> [--label <name>] [--deadline <s>]
#   wait-for-memory.sh release
#
# Env (an empty value counts as unset — a composite action passes its
# inputs through unconditionally):
#   RUNNER_NAME               one reservation/ticket per runner instance
#   INCUS_HOST                host queried for running containers
#   MOLECULE_SSH_KEY          key for that query (optional if agent/config)
#   MOLECULE_GATE_DIR         default /tmp/molecule-gate
#   INCUS_RESERVE_MB          host OS/runner/incusd reserve, default 12288
#   INCUS_DEFAULT_MEMORY_MB   per-platform default, 4096
#   MOLECULE_GATE_TTL         reservation GC age, default 3600
#   GATE_TICKET_STALE_SECONDS ticket GC age, default 120
#   GATE_MAX_OVERTAKES        bypasses a head tolerates, default 10
#   GATE_MEMINFO              test hook, default /proc/meminfo
#   GATE_INCUS_QUERY          test hook: command emitting `incus list -f json`
#   GATE_POLL_SECONDS         test hook, default 30

set -euo pipefail

cfg() {  # cfg VAR DEFAULT — empty env value counts as unset
  local v="${!1:-}"
  if [ -n "$v" ]; then echo "$v"; else echo "$2"; fi
}

action="${1:?usage: $0 <acquire|release> [args...]}"
shift

GATE_DIR=$(cfg MOLECULE_GATE_DIR /tmp/molecule-gate)
mkdir -p "$GATE_DIR"
chmod 0777 "$GATE_DIR" 2>/dev/null || true
LOCK="$GATE_DIR/.lock"

TTL_SEC=$(cfg MOLECULE_GATE_TTL 3600)
TICKET_STALE_SEC=$(cfg GATE_TICKET_STALE_SECONDS 120)
POLL_SEC=$(cfg GATE_POLL_SECONDS 30)
RESERVE_MB=$(cfg INCUS_RESERVE_MB 12288)
MEMINFO=$(cfg GATE_MEMINFO /proc/meminfo)
# Read now for a single config surface; consumed by the bypass branch below.
MAX_OVERTAKES=$(cfg GATE_MAX_OVERTAKES 10)

runner=$(cfg RUNNER_NAME "runner-$$")
my_resv="$GATE_DIR/r.${runner}"

mem_total_mb() { awk '/^MemTotal:/{print int($2/1024); exit}' "$MEMINFO"; }

incus_query() {
  local q
  q=$(cfg GATE_INCUS_QUERY "")
  if [ -n "$q" ]; then
    $q
  else
    local host key
    host=$(cfg INCUS_HOST "")
    key=$(cfg MOLECULE_SSH_KEY "")
    [ -n "$host" ] || {
      echo "INCUS_HOST or GATE_INCUS_QUERY must be set - refusing to admit blind" >&2
      return 1
    }
    # shellcheck disable=SC2086
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
      ${key:+-i "$key"} \
      "root@${host}" -- incus list -f json --project default < /dev/null
  fi
}

committed_mb() {
  incus_query | python3 -c '
import json, re, sys
total = 0
for c in json.load(sys.stdin):
    if c.get("status") != "Running":
        continue
    mem = (c.get("config") or {}).get("limits.memory") or "0"
    m = re.match(r"(\d+)\s*(GB|GiB|MB|MiB)?", mem)
    if m:
        val = int(m.group(1))
        if (m.group(2) or "MB").upper() in ("GB", "GIB"):
            val *= 1024
        total += val
print(total)
'
}

derive_need_mb() {  # $1 = scenario name; resolves molecule/<name>/molecule.yml from CWD
  python3 -c '
import os, re, sys, yaml
raw = open(sys.argv[1]).read()
raw = re.sub(
    r"\$\{(\w+)(?::-([^}]*))?\}",
    lambda m: os.environ.get(m.group(1), m.group(2) or ""),
    raw,
)
default = int(os.environ.get("INCUS_DEFAULT_MEMORY_MB") or "4096")
platforms = (yaml.safe_load(raw) or {}).get("platforms", [])
print(sum(int(p.get("memory_mb", default)) for p in platforms))
' "molecule/$1/molecule.yml"
}

file_field() {  # $1 file, $2 field index, $3 default when missing/empty
  local v
  v=$(awk -v n="$2" 'NR==1{print $n}' "$1" 2>/dev/null || true)
  echo "${v:-$3}"
}

gc_and_sum_reservations() {  # call under the lock; echoes reserved_mb
  local now total=0 mtime f
  now=$(date +%s)
  shopt -s nullglob
  for f in "$GATE_DIR"/r.*; do
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ $(( now - mtime )) -gt "$TTL_SEC" ]; then
      rm -f "$f"
      continue
    fi
    total=$(( total + $(file_field "$f" 1 0) ))
  done
  shopt -u nullglob
  echo "$total"
}

gc_tickets() {  # call under the lock
  local now mtime f
  now=$(date +%s)
  shopt -s nullglob
  for f in "$GATE_DIR"/q.*; do
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ $(( now - mtime )) -gt "$TICKET_STALE_SEC" ]; then
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

case "$action" in
  acquire)
    need="" label="" scenario="" timeout_s=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --need-mb)           need="$2"; shift 2 ;;
        --molecule-scenario) scenario="$2"; shift 2 ;;
        --label)             label="$2"; shift 2 ;;
        --deadline)          timeout_s="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    if { [ -n "$need" ] && [ -n "$scenario" ]; } || { [ -z "$need" ] && [ -z "$scenario" ]; }; then
      echo "acquire needs exactly one of --need-mb or --molecule-scenario" >&2
      exit 2
    fi
    if [ -n "$scenario" ]; then
      need=$(derive_need_mb "$scenario")
      label="${label:-$scenario}"
    fi
    label="${label:-job}"
    timeout_s="${timeout_s:-2700}"

    total=$(mem_total_mb)
    my_ticket="$GATE_DIR/q.$(printf '%010d' "$(date +%s)").${runner}"
    # An abnormal exit (e.g. committed_mb/derive_need_mb aborting under set -e)
    # must not strand our ticket at the lexical head of the FIFO, where it
    # would block every waiter until stale-GC reclaims it. The unlink is
    # atomic, safe without the lock, and a harmless no-op on the ADMITTED and
    # STARVED paths (both already remove the ticket). It must not touch the
    # reservation file: an admitted job's r.<runner> lives on by design.
    trap 'rm -f "$my_ticket"' EXIT

    printf 'molecule-gate[%s]: acquire label=%s need=%dMB total=%dMB reserve=%dMB timeout=%ds\n' \
      "$runner" "$label" "$need" "$total" "$RESERVE_MB" "$timeout_s"

    deadline=$(( $(date +%s) + timeout_s ))
    attempt=0
    while :; do
      attempt=$(( attempt + 1 ))
      exec 9>"$LOCK"
      flock 9
      if [ -f "$my_ticket" ]; then
        touch "$my_ticket"   # refresh liveness; preserves the overtake counter
      else
        printf '%d %s 0\n' "$need" "$label" > "$my_ticket"
      fi
      gc_tickets
      reserved=$(gc_and_sum_reservations)
      committed=$(committed_mb)
      free=$(( total - RESERVE_MB - committed - reserved ))

      head=$(ls -1 "$GATE_DIR"/q.* 2>/dev/null | sort | head -n1 || true)
      head_need=$(file_field "$head" 1 0)
      head_overtakes=$(file_field "$head" 3 0)

      admit=no
      if [ "$free" -ge "$need" ]; then
        if [ "$head" = "$my_ticket" ]; then
          admit=yes
        elif [ "$head_overtakes" -lt "$MAX_OVERTAKES" ]; then
          # Bounded overtake: keep capacity utilized while the head cannot
          # fit, but count every bypass on the head ticket. At the cap the
          # queue goes strict until the head is admitted, so a heavy
          # job's extra wait is bounded by K admissions' releases.
          admit=yes
          head_label=$(file_field "$head" 2 unknown)
          printf '%s %s %d\n' "$head_need" "$head_label" \
            $(( head_overtakes + 1 )) > "$head"
        fi
      fi

      if [ "$admit" = yes ]; then
        printf '%d %s\n' "$need" "$label" > "$my_resv"
        rm -f "$my_ticket"
        flock -u 9
        printf 'molecule-gate[%s]: ADMITTED committed=%dMB reserved=%dMB free=%dMB need=%dMB (attempt %d)\n' \
          "$runner" "$committed" "$reserved" "$free" "$need" "$attempt"
        exit 0
      fi

      position=$(ls -1 "$GATE_DIR"/q.* 2>/dev/null | sort | grep -n -x -F "$my_ticket" | cut -d: -f1 || true)
      flock -u 9

      now=$(date +%s)
      if [ "$now" -ge "$deadline" ]; then
        exec 9>"$LOCK"
        flock 9
        rm -f "$my_ticket"
        flock -u 9
        printf 'molecule-gate[%s]: STARVED after %ds: position=%s head_need=%dMB head_overtakes=%s committed=%dMB reserved=%dMB free=%dMB need=%dMB\n' \
          "$runner" "$timeout_s" "${position:-?}" "$head_need" "$head_overtakes" "$committed" "$reserved" "$free" "$need" >&2
        exit 1
      fi
      printf 'molecule-gate[%s]: waiting position=%s head_need=%dMB head_overtakes=%s committed=%dMB reserved=%dMB free=%dMB need=%dMB (attempt %d)\n' \
        "$runner" "${position:-?}" "$head_need" "$head_overtakes" "$committed" "$reserved" "$free" "$need" "$attempt"
      sleep "$POLL_SEC"
    done
    ;;

  release)
    exec 9>"$LOCK"
    flock 9
    if [ -f "$my_resv" ]; then
      rm -f "$my_resv"
      printf 'molecule-gate[%s]: released\n' "$runner"
    else
      printf 'molecule-gate[%s]: nothing to release\n' "$runner"
    fi
    rm -f "$GATE_DIR"/q.*."$runner"
    flock -u 9
    ;;

  *)
    echo "usage: $0 <acquire|release> [args...]" >&2
    exit 2
    ;;
esac
