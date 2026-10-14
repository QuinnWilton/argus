# Transaction effects

[Bug-class catalog](../bug-classes.md)

The effect model (`Argus.EffectModel`) classifies operations such as I/O, process
changes, shared-table access, time, randomness and code loading, and whether each
reads or writes. An unclassified call is unknown, not effect-free.

## Effects a transaction cannot roll back

`effect_in_context` (`context` is always `transaction`)

A recognized Ecto/Postgrex transaction body performs work outside the database
transaction. Rollback does not undo it, and a retry can repeat it.

| Effect | Severity |
|---|---|
| Network I/O, OS or port operations | error |
| Process operations, file I/O, shared-table writes, distribution operations | warning |

Network waits can also occupy a pooled connection while another service responds.
Move effects to an appropriate after-commit protocol when that is the required
contract; simply spawning work does not make it consistent with commit or rollback.

The analysis recognizes selected transaction APIs, wrappers and closure shapes.
It distinguishes some detached process-local effects from lasting external effects,
but cannot model every Ecto.Multi composition, nested transaction or application
compensation protocol. Logging and ordinary reads are not rollback defects here.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/effects.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/effects.ex).
