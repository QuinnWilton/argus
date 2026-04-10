# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/argus.svg)](https://hex.pm/packages/argus)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/argus)

Whole-program BEAM analysis for subtle OTP and supervision bugs.

Argus disassembles compiled `.beam` files, extracts facts from the bytecode,
and evaluates [Souffle](https://souffle-lang.github.io/) Datalog rules to
detect BEAM/OTP-specific anti-patterns: supervision-tree coupling, GenServer
deadlocks, leaked tasks, ETS misuse, atom-table exhaustion, and more.

## Installation

```elixir
def deps do
  [
    {:argus, "~> 0.2.0"}
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

Argus ships 14 BEAM/OTP-specific bug detectors, grouped by what they target:

### Supervision and process structure

- **`supervision`** — transient children depended on by permanent ones,
  unlinked siblings that communicate, children started before their
  dependencies.
- **`one_for_one_coupling`** — siblings under `:one_for_one` that
  communicate but aren't linked, so a callee crash silently degrades
  the caller without restarting it.
- **`sync_call_in_init`** — `init/1` callbacks that transitively make
  synchronous calls, including the guaranteed-deadlock case where
  startup blocks on a sibling that hasn't started yet.
- **`unlinked_spawn`** — bare `spawn/1,2,3` calls without `_link` or
  `_monitor`, which create orphan processes that fail silently.

### GenServer and process behaviour

- **`call_cycle`** — sync-call cycles between GenServer modules. A
  guaranteed deadlock when both processes are mid-call.
- **`process_bottleneck`** — GenServers with five or more distinct
  caller modules: throughput choke points under load.
- **`timeout_chain`** — `handle_call` callbacks that make downstream
  sync calls (timeouts compound unpredictably) and `handle_cast`
  callbacks that block on sync calls (silently serializing the mailbox).
- **`unsafe_task`** — leaked `Task.async` results and unchecked
  `Task.Supervisor.start_child` results, with suppressions for
  GenServer mailbox handlers and LiveView.
- **`process_registry`** — duplicate process-name registrations and
  TOCTOU races on `Process.whereis/1`.

### Storage and concurrency

- **`ets`** — ETS tables created without heir protection (data lost on
  owner crash), missing concurrency options, `ordered_set` contention,
  unnamed tables created in worker processes.

### Safety and correctness

- **`atom_safety`** — atom-table exhaustion via `String.to_atom/1` on
  untrusted input, `:erlang.binary_to_term/1` without `:safe`, and
  reachable `Code.eval_string` / `:os.cmd` callsites.
- **`error_handling`** — bare rescues that swallow exceptions,
  `Process.flag(:trap_exit, true)` without a matching handler, explicit
  `Process.exit/2` calls, and ignored `{:ok, _} | {:error, _}` results
  from common stdlib APIs.
- **`gen_statem`** — unreachable states and terminal states without
  `:stop` actions in `gen_statem` state machines.
- **`distributed`** — `:rpc.call` without timeout, `:global` name
  registration without conflict resolution, and node operations in
  unsafe contexts.

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
# Detect supervision-tree anti-patterns.
Argus.analyze([MyApp.Supervisor, MyApp.WorkerA, MyApp.WorkerB], :supervision)

# Find unsafe atom creation reachable from exported functions.
Argus.analyze([MyApp.Router, MyApp.Auth], :atom_safety)

# Run custom Datalog rules.
Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})
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
