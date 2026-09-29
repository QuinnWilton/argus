# State and lifetimes across restarts

[Bug-class catalog](../bug-classes.md) · [Coupling findings](../analyses/coupling.md) · [ETS findings](../analyses/ets.md)

Independent restarts are safe only when surviving processes can recover the state
or references they depended on. This model asks what one process retains for another
and which readers can survive a table owner.

## Registrations lost by an independent restart

Let A and B occupy different branches under a one_for_one supervisor. Report
restart coupling when:

1. A's [startup phase](runs.md) calls or casts to B.
2. B's matching handler retains something from that request.
3. No recognized link couples their lifetimes.
4. The dependency is not exclusively on an instance A started privately.

`holds_in(A, B, func, tag, how, store)` records the retention:

| How | What B retains |
|---|---|
| `table` | An ETS row. |
| `monitor` | A monitor or link. |
| `dict` | A process-dictionary entry. |
| `state` | A state change beyond the value initialization establishes. |
| `handed` | A request passed to unclassified external code that may retain it. |

If B restarts alone, it can lose A's registration while A continues running. If A
restarts alone, it can register again beside the old incarnation's record. The
finding anchors at the tree and attaches A's startup call and B's retaining operation.
Inferred external retention has weaker severity than a visible store.

Read-only requests and fields reset to their initial values do not establish retained
state. A cached sibling PID is the opposite direction of dependence: A retains B's
identity, which becomes stale after B restarts.

## Limits of the retention model

Request resolution uses names, APIs, points-to results and tag attribution. Unknown
tags can match all handler clauses, including unrelated writes. Multiple instances
of one module can be conflated.

The model does not establish that B restores retained state from durable storage,
or that A repeats registration through a recovery protocol. Conversely, registrations
made only by repeated handlers can be missed. Sends to handle_info, gen_statem
requests, direct writes to another process's table, detached registrations and some
library registries are outside this model. Only one_for_one restart isolation is
reported here; other orderings can have analogous problems.

## Readers that outlive a table owner

For table T created on P's stack, report a potentially unsafe read when:

1. T has no known heir and disappears with P.
2. Some process Q executing the read can outlive P.
3. The read can access T while absent and its error escapes.

`may_hold_table` supplies possible owners. `reader_outlives` must consider every
process that runs a helper: P calling it does not prove that only P calls it.
External library callers can also be readers.

The lifetime model treats Q as ending with P when Q is P, P has application-wide
lifetime, Q is in P's supervised subtree, or a recognized one_for_all/rest_for_one
relationship stops Q with P. A linked spawn can inherit that ending relationship.
For branch relationships, whether the owner is the supervisor's direct child matters:
restarting a nested owner alone need not stop its sibling branch.

A read is excluded when it is handled, guarded by a recognized presence check, or
preceded on every relevant path by creation/ensure of the same table. ets.info is
not a raising read of a missing table. A guard or ensure for another table, after the
read, or on only one path does not establish presence.

## Lifetime assumptions

- Restart-intensity escalation is not modeled. A chain that stops the whole
  application can make an apparent surviving reader irrelevant.
- Linked processes are treated as ending together in some lifetime rules, although
  trapping exits can let the reader survive. This can hide a real window.
- The facts do not prove that a keeper cannot crash or that its exit halts the node.
- Deployment alternatives can appear to run together when configuration selects one.
- Table identity and runtime-created names can leave accesses unresolved.

These limits are why an owner-restart read is informational. Check the actual owner,
reader and supervision path before changing lifetime policy.

Regressions are in `test/soundness/coupling_test.exs` and
`test/soundness/ets_lifetime_test.exs`. Preserve both the independently surviving
reader and the reader correctly stopped with its owner when refining the model.
