# Blocking

[Bug-class catalog](../bug-classes.md)

Blocking findings identify synchronous dependencies that delay a process and its
mailbox. A call graph is not a process graph: client APIs run in their callers, and
detached tasks do not block a server unless it waits for them.

## Nested calls

`call_chain` with `kind=chain` · **warning**

A request passes through several servers before returning. Each server waits for
the downstream work and cannot serve its queue. The finding shows the chain;
inspect whether intermediate servers need to remain synchronously involved.
Request tags refine paths, but unresolved targets and inferred tag attribution
limit accuracy. Paths on cycles are reported separately.

## Synchronous work in a cast handler

`call_chain` with `kind=cast` · **warning**

A cast handler waits for another server. The original sender does not wait, but the
receiver's mailbox still blocks. An asynchronous API alone does not make its
implementation asynchronous.

## Mismatched timeout budgets

`call_chain` with `kind=budget` · **warning**

A caller allows less time than its callee allows for a downstream call. The caller
can fail or retry while downstream work continues. Equal default timeouts, unknown
timeouts and infinite timeouts are excluded. The downstream check is module-wide
and may match a handler clause the original request never enters.

## Infinite waits while serving callers

`unbounded_wait` with `kind=infinity` · **warning**

A GenServer call handler waits indefinitely for a peer whose handler may block.
Known prompt-answer operations and logging/telemetry side paths are excluded.
Any peer handler clause can establish the possible wait. Optional local-answer
priors can lower severity to info and are marked heuristic.

## Call cycles

`call_cycle` · **error**

| Phase | Defect |
|---|---|
| `call` | Two or more processes can synchronously wait on one another. |
| `continue` | Two startup continuations wait on each other before serving messages. |
| `self` | A synchronous call provably targets its own calling process. |

Cycle edges belong to the processes' own stacks or awaited tasks. A self-call
fails with `:calling_self`; other cycles deadlock until a timeout or failure breaks
them. Related frames show the waits, including edges inferred from message tags.

Module-level cycles do not prove that all edges occur simultaneously. Startup-only
waits require additional reachability evidence, and a peer that defers a startup
reply to another callback can be missed. Continuation matching does not distinguish
all initial tags. Self-calls require a resolved PID or exclusive registered name.

## High synchronous fan-in

`sync_call_fan_in` · **warning**

At least five other modules call one shared server process synchronously, and it
answers them in its own handler. It may become a latency bottleneck because it
serializes requests. The threshold counts modules, not call frequency or load;
inspect the workload before redesigning it.

- A caller is a module that makes the call itself or calls the server's client
  API. Modules reaching the server only through another module's function wait
  through it and count once, as that module.
- The callers must share the process. A module whose every start in the program
  is unnamed (`GenServer.start_link/2` and its kin) or named per key (a via name
  with a computed key) runs a process per start and is not counted. A start under
  any other name, a registration, a call by literal name, or a start out of sight
  keeps it.
- A server whose `handle_call/3` only defers (every return is `{:noreply, ...}`,
  none left to a tail call) and starts a process from its own stack hands the
  work off and answers later; it is not counted. Deferring to a continuation or a
  message of its own still does the work in the server.
- When every call waits with `:infinity`, the finding says the callers queue
  rather than time out.

## Receives inside callbacks

`receive_in_callback` · **warning** when unbounded; **info** when timed or peer-exit-bounded

A callback or a helper one call away reads directly from a mailbox managed by its
OTP behaviour. This can delay system messages and other requests. A timed receive
is bounded; a receive tied to DOWN or a trapped EXIT can last until that peer dies.
Recognized timer-flush receives are excluded.

A receive whose `after` takes its timeout from a parameter is untimed on a path
where the callback passes a literal `:infinity` there (`timeout = caller`); a
timeout read from state, computed, or forwarded further is not followed, and such a
receive counts as timed.

Untimed initialization waits belong to [startup](startup.md). Deeper helpers and
some gen_statem state-function paths are missed. The facts distinguish timed from
untimed receives, not the duration of a finite timeout.

## RPC waits

`unbounded_wait` with `kind=rpc` or `rpc_in_callback` · **warning**

`rpc` reports an infinite remote wait unless the target is known to answer promptly
or bound its own wait. Literal infinite timeouts passed by callers are recognized
within the supported forwarding patterns. RPCs on initialization's stack belong to
startup instead.

`rpc_in_callback` reports RPC directly in a GenServer handler regardless of timeout:
the network round trip stalls the server. That variant does not follow helpers or
cover every OTP behaviour. A finite timeout bounds the stall but does not prevent it.

## Socket waits

`unbounded_wait` with `kind=socket` · **warning**

A TCP/TLS receive, connect or handshake without an effective deadline runs on an
OTP callback's stack. The whole server waits for an unresponsive peer. The analysis
follows same-process helpers and forwarded literal infinite timeouts.

Accept loops, detached custom processes and sends are outside this check. Ambiguous
TLS overloads may be skipped. Initialization receives belong to startup; callbacks
sharing an initialization helper can still be affected.

## Global locks

`unbounded_wait` with `kind=global` · **info**

A `:global` operation retries while a lock is held. Cluster-wide operations also
depend on other nodes responding. Startup locks are reported separately.
Unread retry counts are treated as unlimited, and unknown node lists as potentially
distributed. Finite positive retries count when other nodes may participate; finite
local-only retries are excluded. Check the actual arguments and whether a distributed
lock is required.

A `:global.trans` over `[node()]` is excluded whatever its retries: callers take
turns at its function, the lock is released as the function returns or raises or
its holder dies, and bounded retries would turn waiting into a spurious `:aborted`.
A holder that never returns is the defect, reported where it waits when that is
visible. A local `set_lock` without a retry bound is still reported: its lock is
held until a `del_lock` the holder may never reach.

## Catching only one peer failure

`partial_noproc_catch` · **warning**

A call catches `:noproc` but not a peer stopping while the call is in flight.
The relevant exit shapes differ: `{:shutdown, call}` is not
`{{:shutdown, reason}, call}`. Handle the stop outcomes your peer can actually
produce, without swallowing unrelated errors.

The rule distinguishes nested exit shapes but does not resolve each peer's stop
reasons. Handling one recognized self-stop shape is enough to suppress it.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/blocking.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/blocking.ex).
