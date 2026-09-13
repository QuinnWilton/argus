# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)

Whole-program BEAM analysis for subtle OTP and supervision bugs.

Argus disassembles compiled `.beam` files, extracts facts from the bytecode,
and evaluates [Souffle](https://souffle-lang.github.io/) Datalog rules to
detect BEAM/OTP-specific anti-patterns: supervision-tree coupling, GenServer
deadlocks, leaked tasks, ETS misuse, atom-table exhaustion, and more.

## Installation

Argus is not published to Hex (the package name is taken); depend on a
tagged release from GitHub:

```elixir
def deps do
  [
    {:argus, github: "QuinnWilton/argus", tag: "v0.7.3"}
  ]
end
```

[Souffle](https://souffle-lang.github.io/install) must be installed and
available on your `PATH`.

## Approach

Argus is inspired by [Doop](https://bitbucket.org/yanniss/doop/src/master/)
(JVM), [cclyzer++](https://github.com/GaloisInc/cclyzer-plusplus) (LLVM IR),
and [Gigahorse](https://github.com/nevillegrech/gigahorse-toolchain) (EVM),
but takes advantage of the BEAM's register-based instruction set to skip
the expensive IR-lifting step those frameworks need. BEAM instructions map
to Datalog facts directly, with no intermediate representation.

```
.beam files → disassemble → emit Layer 1 facts → run extractors (Layer 2) → Souffle rules → results
```

**Layer 1** walks every BEAM instruction and emits base facts about
instructions, registers, control flow, and calls. **Layer 2** extractors
interpret OTP patterns, supervision-tree shape, ETS usage, and other
BEAM-specific constructs into higher-level semantic facts. Both layers
feed into Souffle, which evaluates Datalog rules and returns derived
relations.

## Analyses

Argus ships 27 BEAM/OTP-specific bug detectors (`mix argus --list` prints
the same table):

| Analysis | Detects |
|---|---|
| `atom_safety` | atom table exhaustion, unsafe deserialization, and code injection |
| `call_cycle` | module-level synchronous call cycles (deadlocks) |
| `callback_receive` | `receive` inside an OTP callback, which consumes the behaviour's own mailbox |
| `coverage` | extractor coverage and imprecision (meta-analysis) |
| `deferred_startup_deadlock` | `handle_continue` deadlocks and crash loops |
| `distributed` | RPC without timeouts, `:global` races, init blocking on nodes |
| `error_handling` | swallowed errors, ignored results, exit misuse |
| `ets` | ETS table ownership, concurrency options, and lifecycle |
| `gen_statem` | unreachable states and terminal states that never stop |
| `message_contract` | messages a module sends itself but cannot handle |
| `monitor_leak` | monitors left live after a timed wait gave up |
| `one_for_one_coupling` | cross-branch coupling under `one_for_one` supervisors |
| `process_bottleneck` | synchronous call fan-in (serialization bottlenecks) |
| `process_registry` | duplicate names, `whereis` races, registry collisions |
| `purity` | `@pure` contracts checked against the call graph and an effect model |
| `reply_contract` | `handle_call` clauses that defer a reply they cannot send |
| `request_surface` | dangerous operations reachable from request-handling callbacks |
| `secret_exposure` | schema fields holding secrets that `inspect/1` will print |
| `shutdown_safety` | cleanup in `terminate/2` that a supervisor shutdown will skip |
| `supervision` | supervision tree structure and anti-patterns |
| `sync_call_in_init` | synchronous calls in `init/1` (startup deadlocks) |
| `timeout_chain` | GenServer timeout chains and blocking cast handlers |
| `tls_verification` | TLS connections that do not verify the peer |
| `transaction_safety` | side effects inside a DB transaction that a rollback cannot undo |
| `unbounded_dynamic_children` | unbounded process creation reachable from a request |
| `unlinked_spawn` | unlinked (orphan) process spawns |
| `unsafe_task` | leaked async tasks and unchecked `Task.Supervisor.start_child` |

## Quick start

```bash
mix deps.get
mix compile

# List available analyses.
mix argus --list

# Run an analysis against all project modules.
mix argus supervision
mix argus ets
mix argus unsafe_task

# Scope to specific modules.
mix argus call_cycle --modules MyApp.WorkerA,MyApp.WorkerB

# Fail CI if anti-patterns are found.
mix argus supervision --fail-above 0

# Run ad-hoc Datalog rules.
mix argus custom path/to/rules.dl
```

## Programmatic API

```elixir
# Every analysis, one extraction: structured findings with severity,
# source anchors and remediation hints.
{:ok, %{findings: findings}} = Argus.run_analyses([MyApp.Supervisor, MyApp.WorkerA])

# One analysis, raw output relations.
{:ok, results} = Argus.analyze([MyApp.Supervisor, MyApp.WorkerA], :supervision)

# Ad-hoc Datalog rules over the same facts.
{:ok, results} = Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})
```

## Analyzing an external project

`scripts/analyze_project.exs` runs the analyses against a compiled Mix or
Rebar3 project (umbrella apps are detected):

```bash
mix run scripts/analyze_project.exs /path/to/project              # default analyses
mix run scripts/analyze_project.exs /path/to/project supervision  # one analysis
mix run scripts/analyze_project.exs /path/to/project all          # every analysis
mix run scripts/analyze_project.exs /path/to/project --json out.json
```

## Real-world example

Running the `one_for_one_coupling` analysis against
[Oban](https://github.com/oban-bg/oban) surfaces a coupling between
`Oban.Sonar` and `Oban.Notifier`: Sonar transitively depends on Notifier
(it calls `Notifier.listen/2` and `Notifier.notify/3` from
`handle_continue(:start, ...)`), but both are siblings under a
`:one_for_one` supervisor. If Notifier crashes, Sonar continues running
but can't listen or broadcast — a silent degradation of the pubsub
health monitor that's hard to spot in code review.

```bash
cd /tmp && git clone --depth 1 https://github.com/oban-bg/oban.git
cd oban && mix deps.get && mix compile
cd /path/to/argus && mix run scripts/analyze_project.exs /tmp/oban
```

## License

MIT
