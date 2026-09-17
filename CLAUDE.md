# CLAUDE.md

## Project overview

Argus (hex package `panoptes`; the modules keep the `Argus` namespace) is a
BEAM program analysis framework: it disassembles compiled `.beam`
files, extracts Datalog facts from the bytecode, and evaluates them with
Souffle. Inspired by Doop (JVM), cclyzer++ (LLVM IR) and Gigahorse (EVM), but
the BEAM's register-based instruction set lets it skip the IR-lifting step
those frameworks need.

### Layout

- `lib/argus/pipeline/` — disassemble (via beam_spy), normalize, and emit
  the generic bytecode facts; `lib/argus/extractors/` — the domain
  extractors; `lib/argus/analyses/` — one module per analysis, declaring
  its extractors, output relations and finding builders.
- `lib/argus/schema.ex` — the fact schema. `@schema_version` is what
  downstream tools key their caches on; `Argus.SchemaVersionTest` pins its
  shape digest, and every bump gets a CHANGELOG entry. `mix argus.gen.dl`
  regenerates `priv/dl/base.dl` and `layer2.dl` from it.
- `priv/dl/stage0.dl` — the call graph derived once per run;
  `priv/dl/clientlib/` — the shared rule library; `priv/dl/analyses/` —
  one Souffle program per analysis.
- `lib/argus/cfg.ex`, `dataflow.ex`, `purity/` — control flow, def-use and
  effect models, also consumed by downstream tools (gloss, planchette).
- There is no CLI here: scry's Mix compiler is how the analyses are run
  over a project; this package is the engine and the in-VM API
  (`Argus.run_analyses/2`, `Argus.Findings.run/2`, `Argus.Pipeline.extract/2`).

### Design principles

- Exhaustive pattern matching on BEAM instructions in `Argus.Pipeline.Emit`.
- Per-module extraction is embarrassingly parallel and deterministic
  (`ordered: true`); the same modules yield `==` facts.
- Stage 0 keeps the volatile instruction-level relations out of every
  analysis's input set; `test/argus/dl_declarations_test.exs` pins each
  analysis's inputs so an incrementality regression cannot land silently.
- Souffle is an external tool on PATH, shelled out to via `Argus.Souffle`.
- `test/corpus/pairs.exs` is the closed-issue corpus: for each pair a
  rule's finding is present at the commit before the fix and absent at
  the fix. `Argus.CorpusTest` runs it as part of `mix test`, cloning and
  compiling each tree once into `ARGUS_CORPUS_DIR` (default
  `~/.cache/argus/corpus`); `mix test --exclude corpus` skips it,
  `ARGUS_CORPUS_ONLY=redix#334` narrows it, `mix argus.corpus fetch`
  warms the cache and `mix argus.corpus tally` counts every title
  across the trees — the noise check after a rule changes. A new rule
  comes with a pair.
- `test/argus/analysis_inputs.exs` pins what each analysis reads;
  `mix argus.pins` regenerates it and its diff is the review.
- Every shipped analysis targets a BEAM-specific bug class. Generic
  vocabulary belongs in `priv/dl/clientlib/`, not in an analysis file.
- Over-approximate in the direction that stays quiet: a fact that cannot
  be sure says `"dynamic"`, and rules ask what is NOT handled.

## Commit message style

```
[component] brief description

Optional longer explanation: why, and what was rejected.
```

## Quick reference

```bash
mix deps.get             # Fetch dependencies
mix test                 # Run tests (souffle must be on PATH)
mix format && mix credo --strict && mix dialyzer
mix argus.gen.dl         # Regenerate priv/dl/{base,layer2}.dl after a schema change
mix argus.pins           # Regenerate test/argus/analysis_inputs.exs after a rule change
mix argus.corpus fetch   # Warm the closed-issue corpus cache; `tally` counts titles across it
mix test --exclude corpus  # The suite without the corpus
```
