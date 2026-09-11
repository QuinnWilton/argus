# CLAUDE.md

## Project overview

Argus is a BEAM program analysis framework that extracts Datalog facts from BEAM bytecode and evaluates them with Souffle. Inspired by Doop (JVM), cclyzer++ (LLVM IR), and Gigahorse (EVM), but taking advantage of the BEAM's register-based instruction set to skip the expensive IR-lifting step those frameworks require.

### Layout

- `lib/argus/pipeline/` — disassemble (via beam_spy), normalize, and emit
  Layer 1 facts; `lib/argus/extractors/` — Layer 2 domain extractors;
  `lib/argus/analyses/` — one module per user-facing analysis (27), each
  declaring its extractors, input relations, and finding builders.
- `lib/argus/schema.ex` — the fact schema (`@schema_version`, pinned by
  `Argus.SchemaVersionTest` and consumers via `Argus.Schema.Pin`);
  `mix argus.gen.dl` regenerates `priv/dl/base.dl` and `layer2.dl` from it.
- `priv/dl/analyses/` — the Souffle rules, one file per analysis;
  `priv/dl/stage0.dl` — the shared call graph (`call_edge`, `call_site`)
  derived once per run; `priv/dl/clientlib/` — the shared rule library.
- `lib/argus/cfg.ex`, `dataflow.ex`, `purity/` — control-flow, def-use,
  and effect models consumed by analyses and by downstream tools.
- `lib/argus/autoresearch/` + `mix argus.autoresearch` — the measure /
  baseline / diff / accept loop for extractor coverage work.
- `scripts/analyze_project.exs` — analyze an external Mix or Rebar3
  project; `scripts/harness.exs` batches it over a corpus.

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
