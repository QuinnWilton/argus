# Shared analysis model

[Bug-class catalog](../bug-classes.md) · [Contributor workflows](../../CONTRIBUTING.md)

Argus extracts facts from compiled BEAM code, resolves shared call and value-flow
relations, then evaluates the individual analyses. Missing facts and approximations
are part of the model: a finding explains evidence, not every possible execution.

## Facts, rules and findings

- `lib/argus/schema/` defines relation names, columns, types and documentation.
- `priv/dl/base.dl`, `layer2.dl` and `priors.dl` are generated schema declarations.
- `priv/dl/stage0.dl` derives shared call information.
- `priv/dl/points_to.dl` resolves process and table flow for later analyses.
- `priv/dl/clientlib/` supplies shared concepts and reachability components.
- `priv/dl/analyses/` detects defects and emits report/evidence relations.
- `lib/argus/analyses/` declares outputs and turns their rows into findings.

Schema layers distinguish bytecode facts, higher-level extracted facts and optional
priors. Some relations are used only by in-process passes. Importing declarations
does not mean an analysis consumes every relation; its actual dependencies come
from the rules it evaluates.

## Calls are not process execution

`call_edge` includes direct calls, resolved apply targets, closure ownership and
functions passed to calls. It deliberately over-approximates execution. An unresolved
apply can also omit a real edge.

Choose the reach component that matches the question:

| Concept | Use |
|---|---|
| `CallReach` and forward variants | Work reachable through the shared call graph. |
| `SameProcessReach` | Work on one process's own stack. |
| `HoldingReach` | Same-process work plus tasks the caller awaits. |
| Intra-module variants | Restrict traversal to the relevant module. |
| Cut variants | Exclude phase boundaries or side paths. |
| Guarded variants | Follow paths lacking a specified handler or condition. |

`runs_elsewhere` identifies detached or deferred function execution. `side_call`
excludes modeled logging and telemetry paths in analyses that use it. Those
exclusions assume the library machinery does not introduce a relevant callback into
the application; custom handlers can violate that assumption.

## Process identity and entries

Behaviours and explicit starts identify process modules. Callback tables define
`process_entry`; analyses needing gen_statem state functions also include
`process_statem.dl`. Unsupported behaviours and computed callback modules can leave
entries unknown.

A server callback runs in the server; its public client API normally runs in the
caller. `server_side`, `RunsInServer` and `server_caused` answer different questions:
work in the server's own module, work anywhere on its stack, and work it causes
including detached execution.

Points-to relations track starts, names, parameters, returns, fields, callback
state and messages. They can distinguish some start instances and privately retained
processes, but many supervision and dependency questions remain module-based.
Bounded points-to results are supersets; do not treat a coarse set as one exact identity.

## Requests and messages

A synchronous dependency can resolve through a literal name, client wrapper, PID
flow or sufficiently specific message tag. Tag attribution is weaker than a resolved
target and should remain visible in the evidence. Generic tags are not reliable
server identities.

`sync_request_at` and `async_request_at` associate a request with its own site and
tag. Unknown tags may enter every handler clause. Clause facts refine which calls
or returns belong to a message, but do not reconstruct the entire process protocol.
Runtime message shapes, such as DOWN and timer tuples, have dedicated helpers.

## Startup and repeated execution

`priv/dl/clientlib/runs.dl` distinguishes startup-caused work from repeated work.
Coupling uses startup work to find registrations that a peer's restart loses;
mailbox analyses use repeated work to find accumulating monitors and subscriptions.

Initialization holds the start until it returns or acknowledges it. Post-ack and
detached work can still race startup without holding the start. "Once" means bounded
by one incarnation's startup, not necessarily one execution: startup can send one
message per item. A helper reached from both startup and a repeated handler belongs
to both phases.

### Once-only clauses

The model connects callback clauses to self-sends, casts, one-shot timers, monitor
and task DOWN messages, idle timeouts, continuation returns, LiveView async results,
gen_statem internal events and direct same-module calls. Same-name delegates carrying
the whole message retain its process and message identity.

A clause is once-only when its producers are confined to startup or other once-only
clauses, no outside producer can enter it, and production does not cycle back to it.
At least one known tag producer is required. Request callbacks, receive loops,
selected external exports, outside sends, broadcasts and intervals can cause repetition.
A timer handler that re-arms itself therefore remains repeated. The implementation
propagates repetition through cycles before deriving once-only clauses.

`once_code` and `once_step` describe startup work and its evidence anchor;
`again_code` describes repeated work. `once_clause` classifies a callback clause,
while `once_clause_site` requires every clause containing the site to be once-only.
`once_site` also accepts a proven state gate. For coupling, `once_code` includes the
initial continuation chain even if later events reuse it; this does not make the
whole continuation safe to exclude from repetition checks.

### Once by state

Repeated messages can reach an operation only once when it closes its own state gate:

```elixir
def handle_info(:registered, %{registered: false} = state) do
  schedule_check()
  {:noreply, %{state | registered: true}}
end
```

`gated_once_site` requires every path to test the incoming field against known atoms,
every completing path to return a state outside those values or end the process,
and no handler or code_change return to reopen the gate or return an unknown value.
Direct program calls to the handler with separately constructed state defeat the proof.

The StateGate extractor follows supported map/record fields and local returned
helpers. A try handler can keep the gate open; a thrown callback result does not
necessarily end the process. Repeated reachability cuts a helper edge only when
every call through it is gated.

### Execution-phase limits

Dynamic outside sends and computed library callbacks can be missed. Protocol-level
one-time messages from another process are generally treated as repeatable. gen_statem
event type/content do not fully identify the target state; LiveView async facts lack
sites and can be attributed to every clause in a function.

State gates do not cover every nested field, membership test, message-derived value
or callback return. Deeper thrown returns can escape the model, and external state
replacement such as sys.replace_state is not modeled as reopening a gate. Existing
`state_decided` filters are broader than the positive gate proof.

## Restart lifetimes

Surviving processes can lose registrations or table access when a peer restarts.
The [coupling guide](../analyses/coupling.md#restart-isolation)
explains retained registrations; the [ETS guide](../analyses/ets.md#reads-during-an-owners-restart)
explains readers that outlive table owners. Both depend on process identity and the
actual supervision path, not just the module containing a call.

## Shared values and effects

The [intraprocedural value-flow model](value-flow.md) describes TermFlow's
register and container summaries, convergence contract and coverage limits.

Parameter flow follows actual returns from helpers in the same module and from
supported collection callbacks, including their captured values. A helper that
returns a constant does not pass its argument through. Recursive helpers converge
on finite parameter summaries; an unknown external call still has an unknown
result. These summaries are extracted from the whole module, so a helper-body
change also invalidates its callers' summaries.

Security value facts distinguish call results, parameters and nested tuple or map
fields. A safety fact belongs to the particular argument used at a call. Size
guards must constrain that same value before use on every path to the operation;
a bound on the encoded input does not bound the output of decompression. Missing
identity or guard facts do not establish safety.

Result-use facts retain the producing invocation and distinguish a payload use
from forwarding the complete result, testing it, or raising with it. A required
literal verdict or excluded failure value must belong to that same invocation
and hold before the particular use on every path, including exception handlers.

Runtime callback origins are separate from parameter flow. They describe content
returned by an unresolved function invocation, without asserting attacker control.
Template analysis carries necessary literal conditions back through exact call
sites, so a caller passing a flag that disables evaluation can be distinguished
from another call to the same helper that enables it.

`EtsTable` identifies tables by name, allocation site, or module field when stronger
identity is unavailable. `CheckThenAct` carries resource/key identities through
callers and relates a check to the act it controls or supplies. The
[race analysis](../analyses/races.md#interference-model) adds competing processes and concrete harm.

The effect model distinguishes known reads/writes, pure operations and unknown
calls. Exception helpers track whether a handler covers the relevant site, accepts
the raised class and continues. A try elsewhere in the function does not necessarily
protect the operation in question.

## Scope, uncertainty and priors

External exports, request handlers and runtime callbacks are different entry types.
Dynamic dispatch, callbacks supplied by dependencies and callers outside the analyzed
modules can produce missing edges. Conversely, all visible alternatives may be
considered possible even when deployment configuration chooses only one.

Optional `prior_*` facts add classifier evidence or adjust severity. Rules consume
priors positively; absence of a prior is not negative evidence. Findings based on
priors identify their heuristic provenance. Structural tooling/test classification
can also lower severity without removing the finding.

Use [coverage findings](../analyses/coverage.md) to inspect unresolved facts, and
[suppression guidance](rule-style.md#suppressions) when a proposed exclusion relies on an assumption.
The comments beside each clientlib relation are the reference for its precise columns
and supported shapes.
