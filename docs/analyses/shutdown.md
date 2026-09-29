# Shutdown

[Bug-class catalog](../bug-classes.md)

Shutdown findings cover cleanup, peer lifetimes and deliberate stops. Supervisor
shutdown uses exit signals; it is not equivalent to calling `GenServer.stop` in a
test. Static child order also determines reverse shutdown order.

## Cleanup skipped during shutdown

`cleanup_defect` with `kind=never_runs` · **error**; `kind=unclear` · **warning**

A non-trapping process relies on `terminate/2` for cleanup. Supervisor shutdown
can kill it without running that callback. `never_runs` has a known lasting effect;
`unclear` has work the effect model cannot classify. Reads, logging and resources
automatically released on exit are excluded where ownership is known.

The analysis follows up to three calls. It does not know whether cleanup was
intended only for explicit stops. Trapping on any recognized path, or an unread
trap flag, prevents a definite non-trapping diagnosis. Behaviour-specific lifecycle
semantics, notably event handlers, can still produce false positives.

## Cleanup exceeding the shutdown window

`cleanup_defect` with `kind=truncated` · **warning**

A trapping process performs network or port cleanup in `terminate/2`. The supervisor
may kill it before that work completes. This is a category-based check: it does not
compare the operation's timeout with the child spec's shutdown timeout, and it can
follow detached closures. Other waits, such as an infinite GenServer call, are not
classified as slow effects by this rule.

## Unhandled trapped exits

`unhandled_exit_signal` · **warning**

After enabling `trap_exit`, the process needs to handle linked-process exits.
Kinds distinguish a missing handler (`no_handler`), a partial handler without an
EXIT clause (`no_exit_clause`), and a custom receive loop without such a clause
(`no_receive_clause`). A partial handler may crash; an ignored exit can leave stale
state or an unresponsive shutdown protocol.

A default GenServer handler may hide the missing-handler case. Atom comparisons
can overstate EXIT coverage. Unresolved receive code suppresses custom-loop claims,
and gen_statem is excluded here because it handles exits in state functions.

## Calling a sibling during teardown

`teardown_touches_sibling` with `phase=terminate` · **warning**, or **info** for `call_unordered`

A trapping process calls a sibling during shutdown without handling the exit.
The sibling may already be gone because it starts later and stops earlier (`call`),
or because its crash triggers the caller's termination (`call_restart`). Uncertain
order or strategy is `call_unordered`.

The analysis follows the bare `:shutdown` reason and same-process helpers up to
three calls. Private instances, detached work and suitable exit handlers are excluded.
Dynamic child order, restart escalation and `shutdown: :brutal_kill` are not fully
modeled. An earlier sibling is not necessarily alive if its crash caused the shutdown.

## Stopping a supervised sibling from a handler

`teardown_touches_sibling` with `phase=handler`, `kind=stop` · **warning**

A callback stops a sibling directly or through its client API. The supervisor may
restart it immediately, or it may already be gone during teardown. Ask the
supervisor to manage the child when that is the intended ownership model.

This check uses direct siblings and GenServer handlers. Reachability is broad,
including detached work, and a module's stop API may be attributed imprecisely.
Known privately owned targets are excluded.

## Children outliving their logical owner

`foreign_dynamic_children` · **warning**

A process starts children under another subtree's supervisor without visible
teardown. Those children can remain alive after the starter stops. Starts through
the supervisor's own service API are excluded as intentional shared ownership.

Literal supervisor names are required. Any recognized child cleanup in terminate
can suppress the finding, even if it targets other children or will not run.
Linked tasks can be reported despite dying with their caller.

## Stopping a process while still monitoring it

`kills_monitored_child` · **info**

A server deliberately stops a process but leaves its monitor active. The resulting
DOWN can be mistaken for an unexpected crash. Inspect whether the handler distinguishes
intentional stops, or release the corresponding monitor.

Unknown stop and monitor targets may be paired. A demonitor on the stop's path is
not matched precisely to the reference, and `Process.exit` is not covered here.
A handler that safely ignores removed references may need no demonitor.

## Permanent children that stop normally

`permanent_child_stops_normally` · **warning**

A permanent child's callback returns a normal or shutdown stop. Its supervisor
restarts it anyway, undoing a graceful quit and potentially consuming the restart
budget. Stops from initialization and termination callbacks are excluded. Restart
policy comes from the child spec, including overrides; unread policy is not assumed
permanent. Choose the policy to match the child's intended lifetime.

## Broadway draining that restarts fetching

`drain_keeps_fetching` · **warning**

A producer's drain callback clears the field used to fetch work, but demand handling
does not check a drain flag. New demand can fetch again. The check looks for literal
state-field writes and tests; it does not execute the producer protocol. Stop new
fetches explicitly while allowing in-flight work to finish.

See [restart and reader lifetimes](../design/restart-state.md) for the shared
supervision assumptions.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/shutdown.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/shutdown.ex).

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
