# Race detection

[Bug-class catalog](../bug-classes.md) · [Race findings](../analyses/races.md)

The analysis reports a check-then-act pair only when a competing operation can
interleave and a harm witness explains the consequence. Sharing a table or writing
it twice is not enough.

## Pair, rival and harm

`CheckThenAct.meets` connects a read to an act it controls or supplies. Resource and
key identities are translated through parameters, helper returns and loops. The
meeting function is where the read's value and the act's dependency meet.

A rival is either another execution of the pair or a separate compatible operation
in another process. Parameter-keyed writes are considered at the callers that supply
the key. An accessor used for many literal keys must not become an arbitrary write
to every row.

The harm is evaluated in the pair's own context:

- A read-derived write can lose another update or restore a removed row.
- A replacement can clobber a counter or renewed state.
- Two callers can both claim or take the same resource.
- A stale guard can admit conflicting updates.
- A decision can duplicate external effects or writes to other shared state.
- A delayed refill can undo invalidation or replacement.

`PairCarries` follows this pair's read toward its write. `MadeOfRead` answers the
broader question of whether a rival writes back a read-derived value. Confusing the
two can join one accessor caller's read to another caller's decision.

ETS and Mnesia share this structure. Mnesia adds dirty searches that can violate
uniqueness across different record keys. Registry claims need a competing claimant
and an unhandled losing outcome. See the catalog for relation kinds and severities.

## Identity and row separation

`EtsTable` uses a table's literal name, allocation site or module field. CheckThenAct
lifts identities into the caller's terms. Unknown external parameters can denote
any compatible key.

Known distinct literal keys, incompatible shapes and independently minted keys can
separate rows. Keys based on each process's own PID can separate concurrent instances.
`held_row` also treats tables whose row-creating writes all mint keys as per-holder
storage. That is an assumption about how those keys are shared, not full reference
ownership tracking.

Important limits:

- Some computed keys are treated as distinct from literals. A computed value that
  equals that literal can therefore hide interference.
- A minted key passed to multiple processes defeats the per-holder assumption.
- Extracted ETS row-key identity assumes the first tuple element; custom keypos can
  make that assumption wrong.
- An unknown refill source is treated as potentially changing. Missing an effect in
  a supposedly pure helper can instead hide a stale refill.

## Which processes run a function

`RunsConcurrently` derives execution from process entries, instance multiplicity,
request handlers and external library callers.

`single_process(f)` requires one known process instance and no competing request or
external-caller path. `runs_beside(m, f, g, x)` asks whether another process can execute
g on its way to x while m executes f. A helper used by the owner and a janitor runs
in both; evidence that the owner runs it does not establish exclusive ownership.
`runs_beside_up` restricts the other process to work after startup where the consumer
requires that assumption.

Startup-only writes are often treated as earlier than normal work. Later sibling
initialization and independently restarted writers can violate that ordering.
Locally single-process Mnesia access also does not establish one writer across nodes.
External calls and dynamically invoked exports can overstate concurrency in dead or
configuration-specific code.

## Loader handoff

A loader and server can touch the same tables without overlap when a complete handoff
orders them. `handed_off` requires:

1. One loader is spawned by initialization for this server incarnation.
2. Its last action sends a known report to that server, with no subsequent work.
3. No other producer can deliver that report tag to the server.
4. Every server path to the relevant operation waits for that report, directly or
   through a state gate only the report opens.

The state gate uses initial values, excluded states and callback returns. Unknown
writes, another gate-opening return or a direct handler call defeat the proof.
A callback-name helper is not automatically a runtime callback.

Recognized call/cast request tags can exclude clauses no request enters, but unknown
messages remain possible requests. The handoff is within one incarnation: an old
unlinked loader still writing after the server restarts is not ruled out by it.

## Other ordering and serialization limits

A Mnesia pair may be treated as serialized when every visible table writer runs
under a global transaction lock. The current check does not compare lock identities;
different locks can invalidate that assumption. Unmodeled locks, remote constraints
and application protocols can instead cause false positives.

Publication-order races require a first-table reference to become visible before
its target row exists, plus a concurrent reader whose missing-row error escapes.
Missing-row races require a check, a later raising use and a possible intervening
remover. Neither presence checks nor individual atomic operations reserve the row
across a larger sequence.

## Maintaining the model

Preserve the pair's caller context and the process responsible for each operation.
An ordering proof must cover every path it excludes. Keep regressions for unrelated
keys, shared accessors, a helper used by two processes, a second loader, another
producer of the handoff tag and a gate that reopens.

Relevant suites include `test/soundness/races_test.exs`,
`test/soundness/races_order_test.exs`, and the ETS/Mnesia/registry tests under
`test/analyses/`. The older corpus tallies and rewrite chronology live in Git history;
they are not measurements of the current rules.
