# Startup and repeated execution

[Bug-class catalog](../bug-classes.md) · [Shared model](analysis-model.md)

`priv/dl/clientlib/runs.dl` classifies work by what causes it to run. Coupling uses
startup-caused work to find registrations that a peer's restart loses. Mailbox rules
use repeated work to find accumulating monitors, timers and subscriptions.

"Once" means bounded by one process incarnation's startup, not necessarily one
execution. Initialization can send one message per item or monitor several peers.
A helper reached from both initialization and a repeated handler belongs to both phases.

## Message producers

Clause-sensitive callbacks include handle_info, handle_cast, handle_continue,
LiveView handle_async and gen_statem internal-event clauses. Same-name delegates
receiving the whole message retain the callback's process and message identity.

The model connects clauses to known producers:

- Self-sends, self-casts and one-shot timers.
- Monitor and uncollected-task DOWN messages.
- Callback idle timeouts and continuation returns.
- Named LiveView async results and inserted gen_statem events.
- Direct calls to a same-module clause function.

Producers are attributed to startup callbacks, individual clauses or repeated roots
on the same process's stack. Repeated roots include ordinary request callbacks,
receive loops and selected externally callable exports. Sends from other processes,
PubSub broadcasts and intervals can cause repetition. Unknown tags are handled
conservatively; a clause needs at least one known tag producer to be classified once.

## Once-only clauses

A clause is once-only when its known producers are confined to startup or other
once-only clauses, no outside producer can enter it, and production does not cycle
back to the clause. A timer handler that re-arms itself therefore remains repeated
even if initialization started the first timer.

The implementation first propagates repetition through producers and cycles, then
derives once-only clauses from what remains. It does not assume a cycle is once-only
merely because every node refers to another candidate in the cycle.

| Relation | Meaning |
|---|---|
| `once_code(mod, func)` | Work reachable during a supervised module's startup phase. |
| `once_step(mod, func, site, callee)` | The startup-level call to anchor related evidence. |
| `again_code(func)` | Work reachable from repeated execution. |
| `once_clause(func, tag)` | A clause whose producers are startup-bounded. |
| `once_clause_site(site, func)` | Every clause containing the site is once-only. |
| `once_site(site, func)` | A once-only clause site or a proven state-gated site. |

For coupling, `once_code` also includes the initial continuation chain, even if a
later event reuses that continuation. That records what startup may register. It does
not mean the whole continuation function is safe to exclude from repetition checks.

## Once by state

A state gate can make an operation run once despite repeated messages:

```elixir
def handle_info(:registered, %{registered: false} = state) do
  schedule_check()
  {:noreply, %{state | registered: true}}
end
```

`gated_once_site` requires all four conditions:

1. Every path to the site tests a field of the incoming state and admits only known
   atom values.
2. Every completing path after the site returns a state outside those values or
   ends the process.
3. No handler or code_change return reopens the gate or supplies an unknown value.
4. No program call invokes the handler directly with a separately constructed state.

The StateGate extractor provides `state_gate`, `gate_closed`, `state_return` and
`state_excluded`. It reads supported map/record fields and local returned helpers.
A try handler can keep the gate open; a thrown callback result is not automatically
process termination. Repeated reachability cuts a helper edge only when every call
through that edge is gated.

## Assumptions and gaps

- Runtime or library messages are known only through the modeled producer families.
  A dynamic outside send may have a tag absent from the facts.
- Unknown callbacks are attributed through opaque calls or selected module entry
  assumptions. A library callback through a computed module may be missed.
- Protocol-level one-time messages from another process are generally treated as
  repeatable. A retry loop remains repeatable even if it eventually succeeds once.
- gen_statem event type and content do not fully identify the state where an inserted
  event runs. Computed target states weaken phase precision.
- State gates do not cover every nested field, membership test, message-derived value
  or custom callback return shape. Existing `state_decided` filters for subscriptions
  and discarded monitor references are broader than the positive gate proof.
- External state replacement, such as sys.replace_state, is not modeled as reopening
  a gate. Deeper thrown callback results can also escape the state-return model.
- LiveView async facts lack a site, so a start in a clause function can be attributed
  to all of that function's clauses.

When extending the model, keep a repeated counterexample beside every new once-only
case. Relevant regressions are in `test/soundness/runs_test.exs` and
`test/soundness/gated_once_test.exs`; gen_statem extraction has its own tests as well.
