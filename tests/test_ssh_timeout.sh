#!/usr/bin/env bash
# A stalled SSH query must be bounded so it cannot hold the gate lock forever.
# shellcheck source=tests/helpers.sh disable=SC1091
source "$(dirname "$0")/helpers.sh"

setup
make_scenario small 1024

cat > "$T/ssh" <<'STUB'
#!/usr/bin/env bash
has_known_hosts=no
has_identities_only=no
for arg in "$@"; do
  [ "$arg" = "UserKnownHostsFile=/dev/null" ] && has_known_hosts=yes
  [ "$arg" = "IdentitiesOnly=yes" ] && has_identities_only=yes
done
[ "$has_known_hosts" = yes ] || { echo "missing isolated known-hosts option" >&2; exit 1; }
[ "$has_identities_only" = yes ] || { echo "missing identities-only option" >&2; exit 1; }
exec sleep 30
STUB
chmod +x "$T/ssh"

SECONDS=0
if out=$(
  unset GATE_INCUS_QUERY
  INCUS_HOST=incus.example.test \
  GATE_SSH_TIMEOUT_SECONDS=1 \
  GATE_SSH_CONNECT_TIMEOUT_SECONDS=1 \
  GATE_QUERY_RETRIES=1 \
  GATE_QUERY_RETRY_DELAY=0 \
  PATH="$T:$PATH" \
    run_gate stalled acquire --molecule-scenario small --deadline 10 2>&1
); then
  echo "stalled SSH query was admitted: $out"
  exit 1
fi
[ "$SECONDS" -lt 5 ] || { echo "SSH query exceeded timeout: ${SECONDS}s"; exit 1; }
echo "$out" | grep -q 'after 1 attempts' || {
  echo "unexpected timeout failure: $out"
  exit 1
}
if compgen -G "$MOLECULE_GATE_DIR/q.*" >/dev/null; then
  echo "ticket stranded after SSH timeout"
  exit 1
fi

echo OK
