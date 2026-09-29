# State-machine structure

[Bug-class catalog](../bug-classes.md)

These checks apply to gen_statem and GenStateMachine in `state_functions` mode.
They use named state functions and extracted return transitions. They do not model
all runtime event sequences or `handle_event_function` state graphs.

## Unreachable states

`unreachable_state` · **warning**

A non-initial state has no incoming transition from another state or helper.
The machine has a known transition graph and no computed target that could reach
an arbitrary state. The state may be dead code or may reveal a missing transition.

When the initial state cannot be read, the analysis uses a graph-based fallback.
Helper returns and state-function recognition are conservative; a dynamic target
suppresses unreachability claims for the module. Confirm the intended transition
before deleting the state.

## States with no exit

`terminal_without_stop` · **info**

A reachable non-initial state has no transition to another state and no stop return,
either directly or through a returned helper result. The process may remain there
indefinitely. This can be a deliberate resting state, so the finding asks for a
lifecycle decision rather than assuming a leak.

Unknown remote/apply returns can hide an exit and suppress the finding. Local
transition structure does not establish whether an external process will eventually
stop the machine.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/state_machine.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/state_machine.ex).

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
