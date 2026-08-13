# incus-memory-gate

Memory admission gate for CI jobs that share one incus host:
a committed-limits ledger, a FIFO queue with bounded overtakes,
and fail-fast semantics. Ships as a composite GitHub Action and
as a plain script.

Documentation lands with the first release; see `action.yml` and
the header of `wait-for-memory.sh` for the contract.
