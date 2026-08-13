# incus-memory-gate

## What it is

This is a memory admission gate for CI jobs that share a single incus host. When several
jobs each launch containers on the same machine, the danger is not that any one of them is
too large, but that enough of them start at once to exceed physical memory and drive the
host into the OOM killer. The gate serialises admission so that the sum of everything
running stays within a safe budget. A job asks to be admitted for some number of megabytes,
waits until there is room, and only then launches its containers.

The budget is expressed in committed limits rather than observed free memory. Before it
admits a job the gate computes `free = MemTotal - reserve - committed - reservations`, where
`committed` is the sum of `limits.memory` over the running incus containers, `reservations`
is the memory promised to jobs that have been admitted but have not launched their
containers yet, and `reserve` is a fixed allowance held back for the host OS, the runners
and incusd. A job is admitted only when `free >= my_need`. We count committed limits, not
`MemAvailable`, on purpose. incus applies `limits.memory` as a hard cgroup cap, so a
container can never use more than its declared limit. That makes `Σ limits ≤ MemTotal −
reserve` a genuine no-OOM guarantee that holds regardless of how much memory the containers
happen to be touching at any given instant, whereas a gate that watched `MemAvailable` would
admit against memory that admitted-but-idle jobs are about to claim and would oscillate with
transient usage. The gate is deliberately fail-fast: when a job cannot be admitted within its
deadline it exits non-zero rather than forcing its way in, on the principle that a starved job
is an explicit, retryable failure and never an OOM risk.

## Queue policy

Waiters are ordered by FIFO tickets, one per runner, timestamped when the job first asks to
be admitted. Strict FIFO alone wastes capacity: if the job at the head of the queue is large
and does not fit, every smaller job behind it would block too, even when there is room for
them. So the queue allows bounded overtakes. A waiter that fits may bypass a blocked head,
and each bypass is counted against the head's ticket. Once the head has been overtaken
`GATE_MAX_OVERTAKES` times (default 10) the queue goes strict: no further overtakes are
allowed until the head is finally admitted. This keeps the host busy while a heavy job waits,
but bounds that job's extra wait to at most K admissions' worth of releases, so it cannot be
starved indefinitely.

At the deadline the gate emits a verdict line to stderr and exits 1. The line reports the
job's queue position, the head's need and overtake count, and the committed, reserved and
free figures at the moment it gave up, so a starved job leaves behind exactly the numbers you
need to understand why it did not fit.

## Usage as an action

The action is published as a composite GitHub Action. Acquire memory before you launch, and
release it when the job finishes. Pin the action to a full commit SHA and note the tag it
corresponds to in a trailing comment, which is the convention this repository expects:

```yaml
- name: Reserve memory
  uses: Oddly/incus-memory-gate@<full-sha> # v1.0.0
  with:
    mode: acquire
    molecule-scenario: es_kibana
    incus-host: incus-ci.example
    ssh-key: ${{ steps.ssh.outputs.key-path }}

# ... launch containers and run the job ...

- name: Release memory
  if: always()
  uses: Oddly/incus-memory-gate@<full-sha> # v1.0.0
  with:
    mode: release
```

Give the acquire step either `molecule-scenario`, to derive the need from a molecule
scenario in the workspace, or `need-mb` to state the megabytes directly. The release step
takes no size input; it clears whatever this runner holds, and running it under `if: always()`
ensures the reservation is freed even when the job fails. The action's inputs map directly
onto the script's flags and environment: `need-mb`, `molecule-scenario`, `label` and
`deadline-seconds` become the corresponding `acquire` flags, while `incus-host`, `ssh-key`,
`reserve-mb`, `max-overtakes` and `gate-dir` are passed through as environment variables. Any
input left empty is treated as unset, so the script's own defaults apply.

## Usage as a plain script

The action is a thin wrapper over `wait-for-memory.sh`, which you can run directly:

```
wait-for-memory.sh acquire --need-mb <MB> [--label <name>] [--deadline <s>]
wait-for-memory.sh acquire --molecule-scenario <name> [--label <name>] [--deadline <s>]
wait-for-memory.sh release
```

Exactly one of `--need-mb` or `--molecule-scenario` is required for an acquire. In scenario
mode the need is the sum of `memory_mb` over the platforms in `molecule/<name>/molecule.yml`
relative to the working directory, with `${VAR:-default}` references resolved from the
environment first, and the label defaults to the scenario name. The deadline defaults to 2700
seconds. The host to query and everything else come from the environment described below.

## The conversion contract

A reservation is a promise of memory made before the containers exist; committed limits are
the real memory of containers that are running. The gate bridges the two with a file. When a
job is admitted the script writes a reservation file `r.<runner>` into the gate directory
whose single line is `<need_mb> <label>`, and that reservation counts against `free` for
everyone who computes the budget after it. The reservation must be deleted the moment the
containers are launched, because from that point the same memory is already counted as
`committed` through the containers' `limits.memory`, and leaving the reservation in place
would double-count it.

Deleting the reservation is the consumer's responsibility. Inside the `flock`'d launch
section, immediately after all the `incus launch` calls have returned, remove the file for
this runner:

```bash
# inside the flock'd launch section, after all `incus launch` calls:
if [ -n "$RUNNER_NAME" ]; then
  rm -f "/tmp/molecule-gate/r.${RUNNER_NAME}"
fi
```

From then on the job is accounted for by its running containers, and the later `release` call
is a harmless no-op against the already-deleted reservation.

## Environment reference

An empty value counts as unset, because a composite action passes all of its inputs through
unconditionally and relies on the script to fall back to these defaults.

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
| `GATE_MAX_OVERTAKES` | `10` | Number of bypasses a blocked queue head tolerates before the queue goes strict. |
| `GATE_MEMINFO` | `/proc/meminfo` | Source of `MemTotal`; a test hook. |
| `GATE_INCUS_QUERY` | (none) | Command that emits `incus list -f json`, replacing the SSH query; a test hook. |
| `GATE_POLL_SECONDS` | `30` | Interval between admission attempts while waiting; a test hook. |

## Requirements

The gate host must be Linux; the script relies on `flock` and GNU `stat`. The runner needs
`bash`, `flock`, `python3` and PyYAML, the last of which parses the molecule scenario in
scenario mode. Querying committed limits needs SSH root access to the incus host named by
`INCUS_HOST`, or you can bypass SSH entirely by setting `GATE_INCUS_QUERY` to any command
that prints `incus list -f json`.

## Testing

The suite is hermetic and Linux-only; on a Linux machine run it with `bash tests/run-tests.sh`.
It stubs `MemTotal`, the incus query and the poll interval, so no real incus host is involved
and each test runs against a throwaway gate directory. The cases cover need derivation from
molecule scenarios and `limits.memory` unit parsing, fail-fast on a blocked acquire with the
verdict line and ticket cleanup, foreign reservations counting against free, the blind-admit
refusal when no host is configured, the reservation and ticket lifecycle including TTL
garbage collection, the FIFO base case and bounded-overtake queue behaviour up to the strict
cap, stale-ticket reclamation, and a concurrency stress test in which many workers race for a
fixed budget and each verifies under the lock that the committed sum never exceeds it.
