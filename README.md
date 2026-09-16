# Panoptes

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/panoptes.svg)](https://hex.pm/packages/panoptes)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/panoptes)

Whole-program BEAM analysis for subtle OTP and supervision bugs. The
package is `panoptes` — Argus Panoptes, the hundred-eyed watchman — and
its modules are `Argus.*`.

Argus disassembles compiled `.beam` files, extracts facts from the bytecode,
and evaluates [Souffle](https://souffle-lang.github.io/) Datalog rules to
detect BEAM/OTP-specific anti-patterns: supervision-tree coupling, GenServer
deadlocks, leaked tasks, ETS misuse, atom-table exhaustion, and more.

## Installation

```elixir
def deps do
  [
    {:panoptes, "~> 0.11"}
  ]
end
```

[Souffle](https://souffle-lang.github.io/install) must be installed and
available on your `PATH`.

To run the analyses over a project, use [scry](https://github.com/QuinnWilton/scry),
the Mix compiler built on this library: it runs them incrementally after
every compile and reports findings as compiler diagnostics. This package
is the engine — the extraction pipeline, the rules, and the in-VM API
below.

## Approach

Argus is inspired by [Doop](https://bitbucket.org/yanniss/doop/src/master/)
(JVM), [cclyzer++](https://github.com/GaloisInc/cclyzer-plusplus) (LLVM IR),
and [Gigahorse](https://github.com/nevillegrech/gigahorse-toolchain) (EVM),
but takes advantage of the BEAM's register-based instruction set to skip
the expensive IR-lifting step those frameworks need. BEAM instructions map
to Datalog facts directly, with no intermediate representation.

```
.beam → disassemble → facts (emitter + extractors) → stage 0 call graph → Souffle rules → findings
```

The emitter walks every instruction and records the generic facts —
instructions, registers, control flow, calls, literals. The extractors
read the same bytecode for what the analyses reason about: behaviours,
supervision trees, process calls, monitors, ETS, return shapes. A shared
call graph is derived once per run, and each analysis is one Souffle
program over the facts and a common rule library, producing findings with
a severity, a source anchor and a remediation hint.

## Analyses

Argus ships 27 BEAM/OTP-specific bug detectors (`mix scry --list` prints
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

## License

MIT
