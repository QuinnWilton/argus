# ETS ownership and access

[Bug-class catalog](../bug-classes.md)

These findings concern table lifetime and access patterns. Row-level concurrency
bugs are listed under [races](races.md). Ownership belongs to the process executing
ets.new, which need not be the server whose module contains the call.

## Tables lost with their owner

`ets_unprotected_owner` · **warning**

A table has no known heir and its owner is not known to be kept alive or recreated
by the recognized supervision policy. Owner failure removes the table and all its
rows. Private tables, returned unnamed tables and application-lifetime owners can
be excluded by the ownership model.

This does not prove that another process needs the table after the owner exits.
A deliberately short-lived table may be correct. Unknown options and restart
policies must not be treated as guarantees of recovery.

## Reads during an owner's restart

`ets_read_outside_owner` · **info**

A reader can survive the table's owner and make a read that raises while the table
is absent. Recreating the table on restart leaves a window; it does not make those
reads safe. Readers that end with the owner, recognized presence/creation guards
and handlers for the error are excluded.

Inspect whether the owner can actually stop, whether the caller should retry, and
whether table loss should be a normal result. Restart escalation, trapped links,
mutually exclusive modules and runtime-created names limit the lifetime model.
See [reader lifetimes](../design/restart-state.md#readers-that-outlive-a-table-owner).

## Concurrency options

These are **info** hints, not workload measurements:

| Relation | Trigger |
|---|---|
| `ets_missing_read_concurrency` | Multiple modules read a table without read_concurrency enabled. |
| `ets_missing_write_concurrency` | Multiple modules write without write_concurrency enabled or auto. |
| `ets_ordered_set_contention` | Multiple modules write an ordered_set. |

Module count does not establish concurrent processes or contention. Choose options
and table type from the actual read/write workload and ordering requirements.
The analysis resolves table identities by name, allocation reference or field where
possible; missing options and unresolved references limit these hints.

## Tables that keep growing

`ets_write_only_table` · **info**

A named table receives inserts outside initialization, but no recognized removal
is visible. Entries may accumulate for the owner's lifetime. Fixed-key overwrites,
unknown operations in the creating module and external cleanup affect this inference.
Check whether keys are bounded and whether each record has a defined expiry or removal.

## Unnamed tables retained by a process

`ets_unnamed_in_process` · **info**

A process creates an unnamed table. Its reference is the access path, and any
retained external reference becomes stale when the owner restarts. This is often
intentional; inspect who owns and retains the reference rather than replacing every
unnamed table with a named one.

## Creating a named table in start_link

`ets_created_in_start` · **warning**

A start function creates a named table in its caller's process, commonly the
supervisor. The table survives the server, so the next start fails when ets.new
tries to reuse its name. Create server-owned tables on the server's initialization
stack, or make shared ownership and reuse explicit.

The analysis excludes recognized absence checks and transfers of the same table.
It follows same-process helpers but does not model every custom start API or
ownership-transfer protocol.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/ets.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/ets.ex).

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
