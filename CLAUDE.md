# CLAUDE.md

This project inherits all shared conventions from the top-level CLAUDE.md.

## Project overview

Argus is a BEAM program analysis framework that extracts Datalog facts from BEAM bytecode and evaluates them with Souffle. Inspired by Doop (JVM), cclyzer++ (LLVM IR), and Gigahorse (EVM), but taking advantage of the BEAM's register-based instruction set to skip the expensive IR-lifting step those frameworks require.

### Architecture

```
lib/
├── argus.ex                         # Public API
├── argus/
│   ├── extract.ex                   # Parallel extraction pipeline orchestrator
│   ├── normalize.ex                 # Thin normalization pass (IDs, canonicalization)
│   ├── schema.ex                    # Fact relation definitions
│   ├── emitter.ex                   # Instructions → fact tuples
│   ├── extractor.ex                 # Behaviour for domain extractors
│   ├── extractor/
│   │   └── helpers.ex               # Shared helpers (add_fact, resolve_register, etc.)
│   ├── extractors/
│   │   ├── supervision.ex           # Supervisor + Application child spec extraction
│   │   ├── otp.ex                   # OTP callback pattern detection
│   │   └── ets.ex                   # ETS table creation and access extraction
│   ├── analyses/
│   │   ├── cfg.ex                   # Control flow graph
│   │   ├── callgraph.ex             # Call graph
│   │   ├── reachability.ex          # Code reachability
│   │   ├── reaching_def.ex          # Reaching definitions
│   │   ├── liveness.ex              # Live variable analysis
│   │   ├── tail_call.ex             # Tail call and recursion detection
│   │   ├── message_flow.ex          # Message passing analysis
│   │   ├── supervision.ex           # Supervision tree anti-patterns
│   │   ├── one_for_one_coupling.ex  # Cross-branch coupling under one_for_one
│   │   ├── ets.ex                   # ETS table lifecycle analysis
│   │   ├── call_cycle.ex            # Sync-call cycle (deadlock) detection
│   │   ├── unlinked_spawn.ex        # Orphan process detection
│   │   ├── sync_call_in_init.ex     # Startup deadlock detection
│   │   ├── process_bottleneck.ex    # Sync call fan-in detection
│   │   └── timeout_chain.ex        # GenServer timeout chain detection
│   ├── souffle.ex                   # Souffle execution behaviour
│   ├── souffle/
│   │   └── cli.ex                   # Shell-out implementation
│   └── analysis.ex                  # High-level analysis API
├── mix/
│   └── tasks/
│       └── argus.ex                 # mix argus <analysis> [modules...]
priv/
└── dl/                              # Souffle rule files
    ├── base.dl                      # Shared declarations
    ├── cfg.dl                       # Control flow graph
    ├── callgraph.dl                 # Call graph entry point
    ├── callgraph_rules.dl           # Call graph derivation rules
    ├── call_reachable_rules.dl      # Transitive call reachability
    ├── call_cycle.dl                # Sync-call cycle detection
    ├── reachability.dl              # Code reachability
    ├── reaching_def.dl              # Reaching definitions
    ├── liveness.dl                  # Live variable analysis
    ├── tail_call.dl                 # Tail call / recursion
    ├── message_flow.dl              # Message passing paths
    ├── supervision.dl               # Supervision tree anti-patterns
    ├── child_subtree.dl             # Child subtree helpers
    ├── genserver_api_rules.dl        # Shared GenServer sync API rules
    ├── init_function_rules.dl       # Shared init function identification
    ├── stateful_module_dep_rules.dl # Shared stateful module dependency rules
    ├── one_for_one_coupling.dl      # Cross-branch coupling
    ├── ets.dl                       # ETS table analysis
    ├── unlinked_spawn.dl            # Orphan process detection
    ├── sync_call_in_init.dl         # Startup deadlock detection
    ├── process_bottleneck.dl        # Sync call fan-in
    └── timeout_chain.dl             # GenServer timeout chain detection
scripts/
└── analyze_project.exs              # Analyze external projects
```

### Key dependencies

- **beam_spy** (path dep) — `BeamFile.disassemble/1` for bytecode access
- **stream_data** (test/dev) — property-based testing

### Design principles

- **Exhaustive pattern matching** on BEAM instructions, inspired by exhaustive opcode cataloging patterns.
- **Parallel extraction** — per-module disassembly/emission is embarrassingly parallel.
- **Layered facts** — layer 1 (generic bytecode) + layer 2 (domain extractors) compose cleanly.
- **Souffle as external tool** — shell out initially, design the behaviour for future compiled mode.

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
mix argus cfg            # Run CFG analysis on project modules
mix argus callgraph      # Run callgraph analysis
```
