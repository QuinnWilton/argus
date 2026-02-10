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
│   ├── extractors/
│   │   ├── supervision.ex           # Supervisor + Application child spec extraction
│   │   └── otp.ex                   # OTP callback pattern detection
│   ├── souffle.ex                   # Souffle execution behaviour
│   ├── souffle/
│   │   └── cli.ex                   # Shell-out implementation
│   └── analysis.ex                  # High-level analysis API
├── mix/
│   └── tasks/
│       └── argus.ex                 # mix argus <analysis> [modules...]
priv/
└── dl/                              # Souffle rule files
    ├── cfg.dl
    ├── callgraph.dl
    ├── reachability.dl
    ├── reaching_def.dl
    ├── liveness.dl
    ├── tail_call.dl
    ├── message_flow.dl
    ├── supervision.dl
    └── coupled_siblings.dl
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
  ├── Harbor
  ├── Sonar
  ├── Peer
  ├── Nursery
  └── Notifier
```

**Finding: coupled siblings under one_for_one.** `Oban.Sonar` transitively
depends on `Oban.Notifier` — it calls `Notifier.listen/2` and
`Notifier.notify/3` during its `handle_continue(:start, ...)` callback. Both
are siblings under a `one_for_one` supervisor. If Notifier crashes, Sonar
continues running but cannot listen or broadcast, leading to silent
degradation of the pubsub health monitoring system.

In practice this is mitigated by Oban's design: Notifier starts before Sonar
(position 0 vs 3 in source), and Sonar uses periodic pings that would
eventually detect the failure. A `rest_for_one` strategy would provide
stronger guarantees by restarting Sonar (and everything after) when Notifier
crashes.

**Known limitation.** Child spec positions extracted from bytecode can be
reversed from source order when the compiler builds the children list
bottom-up. The `wrong_start_order` finding was a false positive here — the
actual source order is correct. Accurate position tracking requires either
source-level analysis or smarter literal decompilation.

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
