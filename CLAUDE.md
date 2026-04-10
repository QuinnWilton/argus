# CLAUDE.md

This project inherits all shared conventions from the top-level CLAUDE.md.

## Project overview

Argus is a BEAM program analysis framework that extracts Datalog facts from BEAM bytecode and evaluates them with Souffle. Inspired by Doop (JVM), cclyzer++ (LLVM IR), and Gigahorse (EVM), but taking advantage of the BEAM's register-based instruction set to skip the expensive IR-lifting step those frameworks require.

### Architecture

```
lib/
├── argus.ex                         # Public API (delegates to Argus.Analysis)
├── argus/
│   ├── analysis.ex                  # Analysis behaviour + runtime registry
│   ├── extractor.ex                 # Layer 2 extractor behaviour
│   ├── extractor/
│   │   └── helpers.ex               # scan_functions, scan_remote_calls, resolve_*, add_fact
│   ├── pipeline.ex                  # Top-level orchestrator (was Argus.Extract)
│   ├── pipeline/
│   │   ├── disassemble.ex           # .beam path resolution + BEAM file loading
│   │   ├── normalize.ex             # IDs, register canonicalization
│   │   └── emit.ex                  # Layer 1 fact emission (was Argus.Emitter)
│   ├── schema.ex                    # Layer 1 + Layer 2 relation definitions
│   ├── souffle.ex                   # souffle binary shell-out
│   ├── report.ex                    # JSON report builder
│   ├── extractors/                  # Layer 2 domain extractors
│   │   ├── supervision.ex           # Supervisor + Application child specs
│   │   ├── otp.ex                   # GenServer / behaviour patterns
│   │   ├── ets.ex                   # ETS create/options/ops
│   │   ├── atom_safety.ex           # unsafe atom creation, deserialization, eval
│   │   ├── distributed.ex           # rpc, global, node operations
│   │   ├── error_handling.ex        # bare rescues, trap_exit, ignored results
│   │   ├── gen_statem.ex            # gen_statem state machines
│   │   └── process_registry.ex      # named processes, Registry, via tuples
│   └── analyses/                    # 14 user-facing checks (one .ex per analysis)
│       ├── supervision.ex
│       ├── one_for_one_coupling.ex
│       ├── sync_call_in_init.ex
│       ├── unlinked_spawn.ex
│       ├── call_cycle.ex
│       ├── process_bottleneck.ex
│       ├── timeout_chain.ex
│       ├── unsafe_task.ex
│       ├── process_registry.ex
│       ├── ets.ex
│       ├── atom_safety.ex
│       ├── error_handling.ex
│       ├── gen_statem.ex
│       └── distributed.ex
└── mix/tasks/argus.ex               # mix argus <analysis> [options]

priv/dl/
├── base.dl                          # Layer 1 fact declarations
├── analyses/                        # one .dl rules file per analysis (14 files)
└── clientlib/                       # shared rule library
    ├── imports.dl                   # standard entrypoint (cfg + callgraph + reachable)
    ├── cfg.dl                       # CFG derivation
    ├── callgraph_rules.dl           # call_edge derivation
    ├── call_reachable_rules.dl      # transitive call reachability
    ├── otp.dl                       # init / sync_api / stateful_module_dep
    ├── genserver_api_rules.dl       # included by otp.dl
    ├── init_function_rules.dl       # included by otp.dl
    ├── stateful_module_dep_rules.dl # included by otp.dl
    ├── supervision.dl               # child_subtree / init_reaches helpers
    └── callbacks.dl                 # handle_call / handle_cast detection

scripts/
├── analyze_project.exs              # Analyze an external Mix or Rebar3 project
├── harness.exs                      # Batch harness for analyzing many projects
└── analyze_all.sh                   # Shell wrapper around harness.exs
```

### Key dependencies

- **beam_spy** (path dep) — `BeamFile.disassemble/1` for bytecode access
- **stream_data** (test/dev) — property-based testing

### Design principles

- **Exhaustive pattern matching** on BEAM instructions in `Argus.Pipeline.Emit`.
- **Parallel extraction** — per-module disassembly/emission is embarrassingly parallel.
- **Layered facts** — Layer 1 (generic bytecode) + Layer 2 (domain extractors) compose cleanly.
- **Souffle as external tool** — shell out via `Argus.Souffle` to a `souffle` binary on PATH.
- **BEAM/OTP focus** — every shipped analysis targets a BEAM-specific bug class. Generic
  dataflow primitives belong in `priv/dl/clientlib/`, not in the user-facing analysis surface.

## Commit message style

```
[component] brief description

Optional longer explanation.
```

Examples:
- `[schema] define layer 1 fact relations`
- `[emitter] exhaustive instruction-to-fact extraction`
- `[extract] parallel multi-module pipeline with .facts I/O`

## Example analyses

### Oban (v2.x, ~7k GitHub stars)

Ran `coupled_siblings` analysis against Oban's 69 project modules.

**Supervision structure found:**

```
Oban (one_for_one)
  ├── 0. Notifier
  ├── 1. Nursery
  ├── 2. Peer
  ├── 3. Sonar
  └── 4. Harbor
```

**Finding: coupled siblings under one_for_one.** `Oban.Sonar` transitively
depends on `Oban.Notifier` — it calls `Notifier.listen/2` and
`Notifier.notify/3` during its `handle_continue(:start, ...)` callback. Both
are siblings under a `one_for_one` supervisor. If Notifier crashes, Sonar
continues running but cannot listen or broadcast, leading to silent
degradation of the pubsub health monitoring system.

In practice this is mitigated by Oban's design: Notifier starts before Sonar
(position 0 vs 3), and Sonar uses periodic pings that would eventually detect
the failure. A `rest_for_one` strategy would provide stronger guarantees by
restarting Sonar (and everything after) when Notifier crashes.

```bash
# Reproduce:
cd /tmp && git clone --depth 1 https://github.com/oban-bg/oban.git
cd oban && mix deps.get && mix compile
cd /path/to/argus && mix run scripts/analyze_project.exs /tmp/oban
```

## Quick reference

```bash
mix deps.get             # Fetch dependencies
mix compile              # Compile
mix test                 # Run tests
mix format               # Format code
mix argus --list         # List available analyses
mix argus supervision    # Detect supervision-tree anti-patterns
mix argus ets            # Detect ETS misuse
mix argus unsafe_task    # Detect leaked Task.async results
mix argus coverage       # Measure extractor precision

# Autoresearch loop (iterative coverage improvement)
mix argus.autoresearch init       # scaffold .autoresearch/
mix argus.autoresearch measure    # run coverage on corpus tier
mix argus.autoresearch diff       # diff current vs baseline
mix argus.autoresearch rank       # ranked priority list
mix argus.autoresearch checks     # pre-accept barrier
mix argus.autoresearch accept     # promote current → baseline
mix argus.autoresearch status     # session summary ("resume" command)
```
