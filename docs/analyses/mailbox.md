# Mailbox and callback protocols

[Bug-class catalog](../bug-classes.md)

Mailbox findings need evidence of a message, reply or repeated acquisition. A
missing catch-all alone is not a finding: a handler can deliberately accept only
the messages its protocol permits.

## Messages without handlers

`unhandled_info` describes a known message and what happens when it reaches the server.

| Fallback | Meaning | Usual severity |
|---|---|---|
| `crash` | No compatible handle_info clause or receive. | error for direct sends/timers; warning for runtime events |
| `state_crash` | No matching gen_statem info handler, and a state can reject it. | error for direct sends/timers; warning for runtime events |
| `catch_all` | Only a logging or ignoring catch-all accepts it. | info; warning for monitor and socket events |
| `default` | Only GenServer's injected default handler accepts it. | warning |

Message sources include sends, self-timers, monitors, node events, port output,
linked-process exits, tasks, sockets and replies arriving after a timed receive.
Tags and tuple shapes both matter. `start_timer` delivers `{:timeout, ref, message}`,
not the bare message. DOWN and EXIT handlers must accept every relevant reason;
a clause restricted to normal exits does not cover crashes.

The analysis may accept a compatible receive anywhere on the server's own stack
without proving that it consumes this message in time. Dynamic messages, unresolved
targets and state-dependent protocols limit coverage. For gen_statem, handling in
one state can suppress a finding even when another reachable state rejects it.

### Task results

`source=task` · **warning**

An uncollected `Task.Supervisor.async_nolink` sends both `{ref, result}` and DOWN.
Handling the two-element reply alone does not handle the monitor message. Await,
yield or shut down the task, or handle its protocol explicitly. The analysis checks
shapes rather than all possible task return values.

### Late replies

`source=late` · **warning**

A timed receive on a server's stack can expire before a spawned reply or subscribed
event arrives. The eventual message then reaches the server's ordinary handler.
Handle or correlate late messages; unsubscribing does not remove ones already queued.
Recognition is limited to the modeled spawn/subscription and receive shapes.

### Socket closure

`source=socket` · **warning** for every fallback

An active TCP/TLS socket sends `tcp_closed` or `ssl_closed`. A server that crashes on
or ignores that event can retain a dead connection. Active modes and socket kind are
inferred from supported connect/setopts calls and forwarded literal options. Unknown
transport or ownership flow can weaken the match.

## Unhandled gen_statem timeouts

`unhandled_timeout` · **error**

The machine arms an event timeout, named generic timeout or state timeout without a
handler for the resulting event type. These arrive as `:timeout`, `{:timeout, name}`
and `:state_timeout`, respectively; they are not ordinary `:info` messages.
The check is module-wide and does not prove state-specific timing or cancellation.

## Messages a spawned process never receives

`unreceived_message` · **warning**

A literal tagged message reaches a spawned process whose visible receives cannot
accept it. It remains queued and may be scanned repeatedly. The process must have
at least one receive; unresolved apply, function-value calls, enter_loop and
hibernate paths prevent a claim that all its receives are known.

## Cancelling without flushing

`timer_cancel_without_flush` · **warning**

A timer is cancelled and re-armed, but a previously delivered message remains.
Without a timer-specific identity, that message can trigger the next cycle early
or twice. The analysis follows stored references and local arm/cancel pairs.
Termination-only cancellation, cancellation in the timer's own handler and a
recognized later flush are excluded.

An initialization watchdog can still matter when handle_info acts on its stale
message. Flush recognition is conservative and does not prove every runtime path.
Using references or generations to reject stale messages can make the protocol
clearer than relying on cancellation alone.

## Starting a second periodic loop

`timer_loop_rearmed` · **warning**

A handler re-arms its timer on every continuing path, and another repeated callback
arms the same message again. If the existing reference is discarded, or neither
cancelled nor guarded when retained, multiple timer chains accumulate.

The model uses literal self-messages and recognized state fields. Once-only sites,
known cancellation and nil guards can suppress it. It does not infer every keyed
or application-specific timer protocol.

## Repeated live monitors

`monitor_leak` · **warning** for `wait` and `ended`; **info** for `dropped`

The same process can be monitored again before an earlier monitor is released:

- `wait`: a wait returns while its monitor remains live.
- `ended`: bookkeeping is removed while the target and monitor may remain alive.
- `dropped`: repeated code discards the reference, leaving no way to demonitor it.

Freshly started targets, once-only sites and releases covering every return path
are excluded. Whether an external caller actually repeats a registration can remain
unknown, especially for `dropped`. See [monitor lifetimes](../design/monitor-leaks.md).
A queued stale DOWN is a message-handling issue, distinct from a live monitor leak.

## Task lifecycle defects

`task_result_defect` has three variants:

| Kind | Meaning | Severity |
|---|---|---|
| `never_awaited` | A linked async task is neither collected, returned on every path, nor handled through a recognized reply clause. | warning |
| `yield_linked` | The caller expects yield to report a task crash but is linked and not trapping exits at the start. | warning |
| `linked_in_library` | Library code links a task to an unknown caller and awaits it internally. | info |

The caller can die before yield reports the failure. In a trapping caller, normal
linked exits can also become unexpected mailbox messages. Collection and return
tracking are approximate; use the finding's start and handler evidence to check
the actual task protocol.

## Requests and replies that break the callback contract

`reply_defect` · **error**

| Kind | Defect |
|---|---|
| `unhandled_call`, `unhandled_cast` | A module sends its own server a tag the matching callback cannot handle. |
| `dropped_from` | A handle_call return defers the reply on a path that never reads or retains from. |
| `statem_unreplied` | A gen_statem call path returns without replying, postponing or passing from onward. |

A deferred reply needs an address retained for later use. A missing reply leaves the
caller waiting until its timeout, potentially forever for gen_statem calls. Reading
or forwarding from is only evidence that a later reply is possible, not proof it
will happen. Dynamic request targets and broad tag matching can hide defects.

## Registering during LiveView's static render

`static_render_registration` · **warning**

A mount, params, component or on-mount callback subscribes, arms a self-timer or
monitors without a recognized connected guard. During static rendering this registers
the HTTP connection process, and the connected render may register again. Keep
connection-specific work behind the appropriate connected check. Guards and hooks
outside the modeled patterns can be missed.

## Repeated subscriptions

`repeated_subscription` · **warning**

A repeated callback subscribes on each run without a recognized unsubscribe or
once-only/state guard. Multiple subscriptions can deliver duplicate broadcasts.
The rule follows same-process helpers but does not prove that every unsubscribe
matches the topic and path of the subscribe. See the [execution-phase model](../design/runs.md).

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/mailbox.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/mailbox.ex).

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
