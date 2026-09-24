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
- `lib/argus/analysis.ex` — the analysis behaviour and the entry points
  for running one; `analysis/` holds what they delegate to (`Sets`:
  concerns and named sets, `Catalog`: discovery, `Extraction`: the facts
  directory, stage 0, the points-to stage, priors). `lib/argus/findings.ex` — the finding
  struct, types and the constructors a builder calls (one alias:
  `Findings.new/4`, `Findings.at_site/2`, ...); `findings/` holds
  `Runner`, `Build`, `Rows`, `Evidence`, `Anchor` and `Names`.
- `lib/argus/schema.ex` — the fact schema's API; each relation is declared
  once, with its layer and in-process flag, in its concern's module under
  `lib/argus/schema/`. `@schema_version` is what
  downstream tools key their caches on; `Argus.SchemaVersionTest` pins its
  shape digest, and every bump gets a CHANGELOG entry. `mix argus.gen.dl`
  regenerates `priv/dl/base.dl` and `layer2.dl` from it.
- `priv/dl/stage0.dl` — the call graph derived once per run;
  `priv/dl/points_to.dl` — process points-to (`clientlib/processes.dl`)
  derived once per run after it, read by the analyses as facts through
  `clientlib/staged_processes.dl`; `priv/dl/clientlib/` — the shared
  rule library; `priv/dl/analyses/` — one Souffle program per analysis.
- `lib/argus/cfg.ex`, `dataflow.ex`, `purity/` — control flow, def-use and
  effect models, also consumed by downstream tools (gloss, planchette).
- There is no CLI here: scry's Mix compiler is how the analyses are run
  over a project; this package is the engine and the in-VM API
  (`Argus.run_analyses/2`, `Argus.Findings.run/2`, `Argus.Pipeline.extract/2`).

### Design principles

- One reading of the instruction set: `Argus.Instr` says what every
  instruction reads, writes and where control goes (its test asserts
  every instruction in OTP, Elixir and the deps is known). The emitter's
  `def`/`use`/`next` rows come from it; a backward register walk asks
  `Argus.Instr.Reaching` for the writes that reach (through the
  `Argus.Extractor.Resolve` walks or `Resolve.trace/5`), and a forward one steps with
  `Argus.Instr.carry/2`. `Argus.Cfg` reads fall-through from the `next`
  facts the emitter derives from it. A new walk keeps no instruction
  table of its own; a walk may refine what Instr says only where it knows
  more than the instruction does, and says why (catch_clauses ends a
  path at `raw_raise` because a handler re-raises a class that is
  always valid).
- Per-module extraction is embarrassingly parallel and deterministic
  (`ordered: true`); the same modules yield `==` facts in any VM. A VM
  iterates a small map or set holding atoms in atom-table order, so a
  column spelling a literal goes through `Helpers.spell/1` (map keys
  sorted) and rows built from such a set are sorted;
  `Argus.Pipeline.DeterminismTest` extracts in two VMs whose atom tables
  were seeded in opposite orders.
- `module_data.typed` holds the relations `Argus.Pipeline.typed_relations/0`
  names, not every Layer-1 relation: an extractor that reads another adds
  it there (`Argus.Pipeline.TypedRelationsTest` fails until it does).
- Stage 0 keeps the volatile instruction-level relations out of every
  analysis's input set; `test/argus/dl_declarations_test.exs` pins each
  analysis's inputs so an incrementality regression cannot land silently.
- A whole-program fixpoint several analyses need is a stage, not a
  clientlib include: included, it is recomputed in every solve that asks
  (process points-to was ~90% of seven analyses' solves on a large
  program). The points-to stage stages only what analyses read (the
  processes and targets, not the terms that hold them: `source_pts` is
  100+ MB on a large program); a rule that needs another of its
  relations adds it to `points_to.dl`'s outputs and to
  `staged_processes.dl`. Anything a program adds to the fixpoint's
  inputs belongs in the stage, for every analysis alike, and must leave
  the others' rows unchanged (signals are staged apart for that).
- Souffle expands a rule with k disjunctive alternatives into k rules,
  each with the whole body: a disjunction over a large join multiplies
  both compile time and the join. Test a condition on a few columns
  with a small relation instead (`check_then_act.dl`'s `may_agree`).
- Souffle is an external tool on PATH, shelled out to via `Argus.Souffle`.
- `test/corpus/pairs.exs` is the closed-issue corpus: for each pair a
  rule's finding is present at the commit before the fix and absent at
  the fix. `Argus.CorpusTest` runs it as part of `mix test`, cloning and
  compiling each tree once into `ARGUS_CORPUS_DIR` (default
  `~/.cache/argus/corpus`) and caching each tree's facts beside it,
  keyed by the beams, the code and Datalog extraction reaches
  (`Argus.Corpus.engine_modules/0` — not prose or rules, hashed by
  `Argus.BeamDigest`, which leaves out where argus was built), the
  runtime and the solver, so a warm run extracts nothing — in any
  worktree of the same commit. Each entry keeps its solves too, under `solves/`
  (`Argus.Souffle.Cache`), keyed by the program with its transitive
  includes, the solver, and for a reader of the points-to stage that
  stage's program: a warm run with no rule edited solves nothing and
  reads the entry's facts in place, and a rule edit re-solves only the
  programs it reaches. `mix test --exclude corpus` skips
  it, `ARGUS_CORPUS_ONLY=redix#334` narrows it, `ARGUS_CORPUS_JOBS` sets
  how many checkouts are analyzed at once (default 4), `mix argus.corpus
  fetch` warms the cache and `mix argus.corpus tally` counts every title
  across the trees — the noise check after a rule changes. The tally
  runs in `MIX_ENV=test` and shares the gate's entries; each checkout
  keeps its three most recent entries beyond any used in the last hour,
  and each entry the three most recent solves of each program, so a
  before-change tally stays warm for the after-change one, and
  `mix argus.corpus prune [--keep N]` reclaims the rest. A new rule
  comes with a pair.
- A test module whose tests each solve a small fixture set of one
  analysis solves them all once in `setup_all` (`Argus.Test.Batch`) and
  each test reads its set's rows. The sets in a batch are disjoint; a
  set that shares a module with another test's is about the modules
  together and is solved on its own (`:alone`). After adding a set or
  changing a rule the fixtures meet, run the module with
  `ARGUS_VERIFY_BATCH=1`: every slice is checked against a solve of its
  set alone.
- Test modules are `async: true` unless they touch VM-wide state (the
  environment, `Mix.shell/1`, compiler options); a sync module says why
  in a comment above its `use ExUnit.Case`.
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
