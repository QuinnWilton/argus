# Shared analysis model

[Bug-class catalog](../bug-classes.md)

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

## Startup, repetition and lifetimes

Initialization holds a start until it returns or acknowledges it. Post-ack work and
detached work can still race startup without blocking the start itself.

The [execution-phase model](runs.md) distinguishes startup-caused work, repeating
work and state-gated sites. A helper can belong to both phases. The
[restart-state model](restart-state.md) uses supervision order and retained state to
reason about independent restarts and readers that outlive table owners.

## Shared values and effects

`EtsTable` identifies tables by name, allocation site, or module field when stronger
identity is unavailable. `CheckThenAct` carries resource/key identities through
callers and relates a check to the act it controls or supplies. The
[race model](races.md) adds competing processes and concrete harm.

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
[suppression guidance](exclusions.md) when a proposed exclusion relies on an assumption.
The comments beside each clientlib relation are the reference for its precise columns
and supported shapes.
