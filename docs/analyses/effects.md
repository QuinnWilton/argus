# Purity and transaction effects

[Bug-class catalog](../bug-classes.md)

The effect model classifies operations such as I/O, process changes, shared-table
access, time, randomness and code loading. An unclassified call is unknown, not pure.

## Violated purity contracts

`effect_in_context` with `context=pure_contract` · **error**

A function declared `@pure true` reaches an observable effect, directly or through
helpers and closures. This includes state reads such as time or process dictionary
access, as well as writes, receives and process creation. The finding identifies
the operation that violates the contract.

Reachability includes constructed closures, so it can overstate what runs. Unsupported
APIs and unresolved calls can hide effects; those calls should instead prevent a
verified-pure result when recognized as opaque.

## Unverified purity contracts

`purity_unprovable` · **warning**

No known effect was found, but the function reaches dynamic invocation, open protocol
dispatch or an unclassified call. The reasons are `dynamic_call`, `protocol_dispatch`
and `unclassified_call`. Review the missing model or contract before relying on purity.

`purity_verified` is an **info** result when neither an effect nor an opaque call is
found. It is a verification result within the supported model, not a defect or a
claim about code the analysis did not load.

## Effectful functions passed to pure code

`impure_closure_to_pure` · **error**

A caller passes an effectful closure to a declared-pure function that invokes its
function argument. The contract obligation reaches the caller; the related frame
shows the closure's effect. Closure identification and higher-order call summaries
limit which arguments can be matched.

## Effects a transaction cannot roll back

`effect_in_context` with `context=transaction`

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

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
