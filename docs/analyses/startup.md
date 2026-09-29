# Startup

[Bug-class catalog](../bug-classes.md)

Startup findings cover work that runs before dependencies are ready. A supervisor
starts children in order and waits for each start to finish. `handle_continue/2`
runs after initialization, but can overlap the start of later children.

## Waiting for a later child

`blocks_on_peer` with `kind=call`, `phase=init`, `ordering=later` or `after_tree` · **error**

A child's initialization waits for a process that starts later. The supervisor
cannot finish the first start to reach the second. The call fails or waits until
its timeout. This includes work in a task that initialization awaits.

The order must be visible in a supervision tree or in a function that starts the
tree before starting the dependency. Calls after `init_ack` do not hold the start.
Put the dependency first or move the dependent work to a phase with an explicit
readiness protocol.

## Requests racing startup

`blocks_on_peer` with `kind=cast` or `window_call`, `ordering=later` · **warning**

Initialization casts to a later child, or makes a call after acknowledgement or
from detached work. The target may not be registered: casts can disappear and
calls can fail with `:noproc`. Moving work to a task does not establish readiness.
A synchronous startup deadlock takes precedence when both findings describe the
same dependency.

## A peer with unknown start order

`blocks_on_peer` with `kind=call`, `ordering=unknown` · **info**

Initialization waits on a peer whose readiness is not established. `detail`
distinguishes unconditional calls from calls behind a branch in `init/1`.
This is a dependency to inspect, not proof of a broken startup. The conditional
classification examines the first call out of `init/1`; it can miss deeper guards.
Known earlier peers and peers assumed to belong to separate running trees are
excluded.

## Supervisor calls during initialization

`blocks_on_peer` with `kind=sup` · **info**

A management operation such as `start_child` or `terminate_child` adds another
process's initialization or shutdown to the caller's startup path. The finding
does not prove a callback cycle. Detached work and calls after acknowledgement
are excluded from this class.

## Waiting on a server that can block

`blocks_on_peer` with `kind=blocking_server` · **warning**

An earlier or otherwise assumed-running peer has a handler that can wait without
a bound. While that handler runs, it cannot answer the initializing child.
The rule considers any handler in the peer, rather than proving that the startup
request enters the blocking clause.

## Continuations racing a sibling

`blocks_on_peer` with `phase=continue`, `kind=call`, `ordering=later` · **warning**

A continuation calls a child the supervisor has not necessarily started yet.
Returning from `init/1` does not make later siblings ready. The analysis considers
all continuation clauses in a module whose initialization requests a continuation;
it does not restrict this finding to the initial continuation tag.

## Calling the parent before the tree is ready

`blocks_on_peer` with `kind=parent`, `phase=continue` or `acked` · **warning**

A continuation, or initialization after acknowledgement, calls its own supervisor
while the supervisor may still be starting other children. This can block and can
form a cycle if a later child needs the caller. A known last child in a fully read
child list is excluded; an open or partly unread list cannot establish that fact.

## Locks and distributed operations

`blocks_on_peer` uses these kinds:

| Kind | Meaning | Severity |
|---|---|---|
| `global` | A lock with unlimited retries delays startup. | error for cluster/unknown nodes; warning for local nodes |
| `global_assumed` | An unread retry count is treated as unlimited. | same grading by node scope |
| `global_bounded` | A finite-retry lock still waits on other nodes. | warning |
| `remote` | RPC, registration, node or store work adds a remote dependency. | warning |

Local finite-retry locks are excluded from the cluster-lock finding. An unknown
node list is treated as potentially distributed. RPC and lock tracking follow
same-process helpers before acknowledgement; other distributed operations are
recognized directly in `init/1`. A finite RPC timeout bounds the delay but does
not remove the startup dependency.

## Socket and mailbox waits

`unbounded_effect_in_init` · **warning** for `recv` and `receive`; **info** for `down`; **error** for `enter_loop`

Before acknowledgement, initialization can wait indefinitely on a TCP/TLS receive
(`recv`) or an untimed mailbox receive (`receive`). A receive accepting its peer's
pinned `DOWN`, or a linked peer's `EXIT` while trapping, is classified `down`: it
can still wait as long as that peer remains alive. `enter_loop` identifies entering
the server loop before acknowledging the start.

Finite socket timeouts, detached receive loops and recognized timer-flush receives
are excluded. Socket coverage is API-specific. Optional local-answer priors can
lower the severity of mailbox waits; the finding then identifies heuristic evidence.

## Connecting without a retry path

`unbounded_effect_in_init` with `kind=connect` · **warning**

Initialization connects or opens a resource and the module has no recognized
later retry path. An unavailable dependency may cause repeated startup failures.
The rule recognizes TCP/TLS connect, UDP open and HTTP requests.

This is approximate: it does not prove that the failed operation aborts initialization,
and any timer, self-message, continuation or state-machine timeout can count as a
retry path even if unrelated. UDP open is a local bind. Unlike startup waits,
connections after acknowledgement still matter because they can crash the child.

## Deferring required work with an idle timeout

`deferral_defect` with `kind=init_timeout` · **info**

Initialization returns a literal timeout, including zero. Any message arriving
first cancels that idle timeout, so required setup may never run. Use a continuation
or an explicit message when the work must happen regardless of mailbox traffic.
The rule does not establish that an earlier message will arrive.

## Catching a continuation's startup failure

`deferral_defect` with `kind=continue_catch` · **warning**

A continuation that races a later sibling also contains a try. Handling the failure
does not repair the ordering and may leave bad state or a restart loop. The check
is broad: the try need not cover the racing call or catch its exit.

## Shared state initialized after the tree

`post_start_initialization` · **info**

A function starts a supervisor, then writes ETS, application environment or
persistent-term state. Children can run before the write. The analysis follows
write helpers but does not prove that a child reads that value. Only ordering
within the function containing `Supervisor.start_link` is recognized.

## Ignored start results

`ignored_start_result` · **warning**

A supported start API's result is overwritten without being read. The caller may
continue after `{:error, reason}` without the expected process. Detection checks
the next instruction, so saving and later ignoring a result can be missed.
Discarded `start_child` results are covered by [failure](failure.md).

## Shared limits

Supervision is compared largely by module, so multiple instances can be conflated.
Runtime-built child lists and unresolved PIDs weaken ordering and target evidence.
A dynamic child started during boot is ordered with its starter only when that
start is direct or one helper away. See the [analysis model](../design/analysis-model.md)
for call resolution and phase boundaries.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/startup.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/startup.ex).
