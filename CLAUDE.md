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
│   │   ├── supervision.ex           # Supervisor child spec extraction
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
    └── supervision.dl
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

## Quick reference

```bash
mix deps.get             # Fetch dependencies
mix compile              # Compile
mix test                 # Run tests
mix format               # Format code
mix argus cfg            # Run CFG analysis on project modules
mix argus callgraph      # Run callgraph analysis
```
