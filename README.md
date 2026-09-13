# incus-memory-gate

A memory admission gate for CI jobs that share one incus host.

Here's the problem it solves. Several jobs each spin up containers on the same
machine. No single job is too big, but if enough of them start at once they run
past physical memory and the OOM killer starts shooting processes. The gate
serialises admission so the sum of everything running stays inside a budget. A
job asks for some number of megabytes, waits until there's room, then launches.

## How the budget is computed

Before it admits a job the gate works out

    free = MemTotal - reserve - committed - reservations

and admits when `free >= my_need`. The three moving parts:

- `committed` is the sum of `limits.memory` over the containers incus currently
  reports as running.
- `reservations` is memory promised to jobs that have been admitted but haven't
  launched their containers yet.
- `reserve` is a flat allowance held back for the host OS, the runners and
  incusd (`INCUS_RESERVE_MB`, default 12288 MB).

The choice that matters is counting committed limits instead of `MemAvailable`.
incus enforces `limits.memory` as a hard cgroup cap, so a container physically
cannot use more than its declared limit. That makes `Σ limits ≤ MemTotal −
reserve` a real no-OOM guarantee, and it holds no matter how much memory the
containers are actually touching at any given moment. A gate watching
`MemAvailable` would happily admit against memory that an admitted-but-idle job
is about to claim, and it would flap around with transient usage. We'd rather be
conservative and right.

When a job can't get in before its deadline the gate gives up and exits
non-zero instead of forcing its way in. A starved job is an explicit, retryable
failure; barging in is an OOM risk. We take the failure every time.

## The queue

Waiters get FIFO tickets, one per runner, stamped when the job first asks.
Strict FIFO on its own wastes the host: if the job at the head is large and
doesn't fit, every smaller job behind it waits too, even when there's room for
them.

So the head can be overtaken, but only so often. A waiter that fits may bypass a
blocked head, and each bypass is tallied against the head's ticket. After
`GATE_MAX_OVERTAKES` bypasses (default 10) the queue goes strict — no more
overtakes until the head is finally admitted. The host stays busy while a heavy
job waits, and that job's extra wait is bounded to at most K admissions' worth
of releases, so it can't be starved forever.

At the deadline the gate prints a verdict line to stderr and exits 1. It reports
the job's queue position, the head's need and overtake count, and the committed,
reserved and free figures at the moment it gave up. That's enough to see why it
didn't fit without re-running anything.

## Using it as an action

It's published as a composite GitHub Action. Acquire before you launch, release
when the job ends. Pin to a full commit SHA and leave the tag it maps to in a
trailing comment — that's the convention this repo expects:

```yaml
- name: Reserve memory
  uses: Oddly/incus-memory-gate@4c8832dfa306acf74f8eda0b15b9ddbe9f20141a # v1.0.4
  with:
    mode: acquire
    molecule-scenario: es_kibana
    incus-host: incus-ci.example
    ssh-key: ${{ steps.ssh.outputs.key-path }}

# ... launch containers, run the job ...

- name: Release memory
  if: always()
  uses: Oddly/incus-memory-gate@4c8832dfa306acf74f8eda0b15b9ddbe9f20141a # v1.0.4
  with:
    mode: release
```

Give the acquire step either `molecule-scenario`, to derive the need from a
molecule scenario in the workspace, or `need-mb` to state the megabytes yourself.
Release takes no size input — it clears whatever this runner holds, and
`if: always()` makes sure that happens even when the job fails.

The inputs map straight onto the script. `need-mb`, `molecule-scenario`, `label`
and `deadline-seconds` become `acquire` flags; `incus-host`, `ssh-key`,
`ssh-timeout-seconds`, `ssh-connect-timeout-seconds`, `reserve-mb`,
`max-overtakes` and `gate-dir` are passed through as environment variables. An
empty input is treated as unset, so the script's own defaults apply. Each SSH
query is bounded by `ssh-timeout-seconds` (15 seconds by default), and its TCP
connection attempt is bounded by `ssh-connect-timeout-seconds` (5 seconds by
default).

## Using it as a plain script

The action is a thin wrapper over `wait-for-memory.sh`, which you can run
directly:

```
wait-for-memory.sh acquire --need-mb <MB> [--label <name>] [--deadline <s>]
wait-for-memory.sh acquire --molecule-scenario <name> [--label <name>] [--deadline <s>]
wait-for-memory.sh release
```

An acquire needs exactly one of `--need-mb` or `--molecule-scenario`. In scenario
mode the need is the sum of `memory_mb` over the platforms in
`molecule/<name>/molecule.yml` (relative to the working directory), with
`${VAR:-default}` references resolved from the environment first, and the label
defaults to the scenario name. The deadline defaults to 2700 seconds. The host to
query and everything else come from the environment below.

## Converting a reservation into committed memory

A reservation is a promise of memory made before the containers exist; committed
limits are the real memory of containers that are already running. The gate
bridges the two with a file. When a job is admitted the script writes a
reservation file `r.<runner>` into the gate directory whose single line is
`<need_mb> <label>`, and that reservation counts against `free` for everyone who
computes the budget after it.

You have to delete the reservation the moment the containers are up. From then on
the same memory is already counted as `committed` through the containers'
`limits.memory`, so leaving the reservation in place double-counts it. Deleting
it is the consumer's job — the gate has no way to know when your `incus launch`
calls have returned. Inside your `flock`'d launch section, right after the last
one:

```bash
# inside the flock'd launch section, after all `incus launch` calls:
if [ -n "$RUNNER_NAME" ]; then
  rm -f "/tmp/molecule-gate/r.${RUNNER_NAME}"
fi
```

That path is the default gate directory. If you've overridden `gate-dir` (or
`MOLECULE_GATE_DIR`), point the `rm` at the same place — otherwise the
reservation lives on and you under-count free memory until it's garbage
collected. After the delete the job is accounted for by its running containers,
and the later `release` call is a harmless no-op against a reservation that's
already gone.

## Environment reference

An empty value counts as unset. A composite action passes all of its inputs
through whether you set them or not, so the script reads empty as "use the
default."

| Variable | Default | Meaning |
| --- | --- | --- |
| `RUNNER_NAME` | `runner-$$` | Identifies the reservation and ticket for this runner instance. |
| `INCUS_HOST` | (none) | Host queried for running containers; required for acquire unless `GATE_INCUS_QUERY` is set. |
| `MOLECULE_SSH_KEY` | (none) | SSH key for that query; optional when an agent or SSH config already provides one. |
| `MOLECULE_GATE_DIR` | `/tmp/molecule-gate` | Shared directory holding the reservation and ticket state. |
| `INCUS_RESERVE_MB` | `12288` | Memory held back for the host OS, runners and incusd. |
| `INCUS_DEFAULT_MEMORY_MB` | `4096` | Per-platform memory assumed when a molecule platform declares no `memory_mb`. |
| `MOLECULE_GATE_TTL` | `3600` | Age in seconds at which a stale reservation is garbage-collected. |
| `GATE_TICKET_STALE_SECONDS` | `120` | Age in seconds at which a stale queue ticket is garbage-collected. |
| `GATE_MAX_OVERTAKES` | `10` | Bypasses a blocked queue head tolerates before the queue goes strict. |
| `GATE_MEMINFO` | `/proc/meminfo` | Source of `MemTotal`; a test hook. |
| `GATE_INCUS_QUERY` | (none) | Command that emits `incus list -f json`, replacing the SSH query; a test hook. |
| `GATE_SSH_TIMEOUT_SECONDS` | `15` | Maximum duration of one SSH query, including a stalled connection. |
| `GATE_SSH_CONNECT_TIMEOUT_SECONDS` | `5` | TCP connection timeout passed to SSH. |
| `GATE_QUERY_RETRIES` | `6` | Attempts to read committed limits before giving up, so a restarting incusd doesn't fail the gate. |
| `GATE_QUERY_RETRY_DELAY` | `2` | Seconds between those attempts. |
| `GATE_POLL_SECONDS` | `30` | Interval between admission attempts while waiting; a test hook. |

## Requirements

The gate host has to be Linux — the script leans on `flock`, GNU `stat` and GNU
`timeout`. Each runner needs `bash`, `flock`, `python3` and PyYAML, the last of which only
matters in scenario mode, where it parses the molecule file. Reading committed
limits needs SSH root on the incus host named by `INCUS_HOST`. The query uses
only `MOLECULE_SSH_KEY` and skips the shared runner known-hosts file; host-key
verification is already disabled for this CI-only connection. If you'd rather
not go through SSH, set `GATE_INCUS_QUERY` to any command that prints
`incus list -f json` and the gate uses that instead.

## Testing

The suite is hermetic and Linux-only. On a Linux machine, run
`bash tests/run-tests.sh`. It stubs `MemTotal`, the incus query and the poll
interval, so there's no real incus host in the loop and every test runs against a
throwaway gate directory. The cases cover need derivation from molecule scenarios
and `limits.memory` unit parsing, fail-fast on a blocked acquire with the verdict
line and ticket cleanup, foreign reservations counting against free, the refusal
to admit when no host is configured, the reservation and ticket lifecycle
including TTL garbage collection, the FIFO base case and bounded-overtake queue
behaviour up to the strict cap, stale-ticket reclamation, and a concurrency
stress test where many workers race for a fixed budget and each verifies under
the lock that the committed sum never exceeds it.
