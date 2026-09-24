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
  the generic bytecode facts; `base.ex` keeps what the pipeline computes
  of a module for the extractors; `lib/argus/extractors/` — the domain
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
- `lib/argus/cache.ex` and `cache/` — the stores (see "Caches"): entry
  layout and retention, each producer's code key (`Code`), and the
  sharded facts and the solves over them (`Facts`);
  `lib/argus/pipeline/shards.ex` joins producers' directories.
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
  `~/.cache/argus/corpus`) and analyzing it through a store beside it
  (`<checkout>/.argus-facts`, see "Caches" below) — in any worktree of
  the same commit. `mix test --exclude corpus` skips it,
  `ARGUS_CORPUS_ONLY=redix#334` narrows it, `ARGUS_CORPUS_JOBS` sets how
  many checkouts are analyzed at once (default 4), `mix argus.corpus
  fetch` warms the cache and `mix argus.corpus tally` counts every title
  across the trees — the noise check after a rule changes. The tally
  runs in `MIX_ENV=test` and shares the gate's stores; `mix
  argus.corpus prune [--keep N]` reclaims what the retention policy
  lets go. A new rule comes with a pair.
- Tests solve through `Argus.Test.Memo` (`analyze/3`, `run_analyses/2`,
  `run_rules/2` over hand-built facts, `compile_beams/1` for modules a
  test compiles): the same modules and analysis are solved once per run
  and every later caller reads the answer, an immutable term; across
  runs they go through the suite's store. A call with options of its
  own always solves, without the store.
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

## Caches

A store (`Argus.Cache`) keeps extraction and solve results on disk,
keyed by content, so a run redoes only what an edit invalidates. The
corpus keeps one per checkout, the test suite one at
`_build/test/argus-cache` (`Argus.Test.Memo.store/0`), and any caller
names one with `cache:` on `Argus.run_analyses/2`, `Argus.analyze/3` or
`extract_facts/3`.

- **Shards** (`Argus.Cache.Facts`): each producer's rows — `:base` (the
  emitter, def_use, conditional_call) or one extractor — kept apart,
  keyed by the beams (path and content), the code that producer runs
  (`Argus.Cache.Code`: the import-table closure from the extractor and
  from `Argus.Pipeline`, hashed by `Argus.BeamDigest`), the runtime and
  the row-shaping options. The specs extractor's key adds the
  environment (`Argus.Specs.environment_digest/1`, argus left out), and
  its shard records what it read of argus's own beams (the fixtures and
  their library stubs) or found absent, checked on every hit. A missing
  shard is extracted alone (`Argus.Pipeline.run_shards/3`); the rows of
  a producer do not depend on which others run (`ShardsTest`). A run
  makes a facts directory only when a solve misses, and places in it
  only the files that program reads, as symbolic links into the store;
  `Facts.materialize/1` (what `extract_facts/3` returns) is the whole
  directory as hard links, byte-identical to `Argus.Pipeline.run/3`'s.
- **Bases** (`Argus.Pipeline.Base`): each module's base — its
  disassembly, control-flow graphs and reaching definitions (the
  per-function solutions `Argus.Instr.Reaching.export/1` carries) — for
  a set of beams, keyed by the beams, the base's code and the runtime.
  An extraction that computes the base keeps them; one whose base shard
  is kept but an extractor's is not runs that extractor over them —
  on the corpus, a quarter of the cost for most extractors. The decoded facts (`module_data.typed`) are
  not kept: over a kept base they are re-emitted only for
  `Argus.Pipeline.typed_readers/0`, and `CodeClosureTest` fails when
  another extractor computes them — add it to that list.
- **Solves** (`Argus.Souffle.Cache`): keyed by the program with its
  includes, the solver's version and the digests of exactly the files
  the program reads (`Argus.Souffle.input_files/2`). Stage outputs join
  the facts by content, so a solve downstream of a stage whose output
  came out the same is read back — early cutoff.
- **What moves a key**: an extractor edit moves that extractor's shard
  and nothing else (it re-extracts over the kept bases); an edit to
  anything the base reaches (`Argus.Instr`, the extractor helpers, the
  emitter, `Writer`, `Tsv`, `Argus.Schema` — so every schema bump)
  moves every shard and every base, and then the solves run again only
  if the facts came out different; a rule edit moves the programs that
  include it. The solver, the stores, the analyses' prose and the
  corpus harness move nothing. `Argus.Cache.CodeClosureTest` runs each
  producer with call counting, the extractors over kept bases too, and
  fails if one executes a module outside its key.
- **Retention**: within each producer's shards, each program's solves
  and the bases (per set of beams), the three most recent entries and
  anything touched within the hour are spared; the suite's store also
  drops a set untouched for a week. Entries are read-only; a run links
  them into a scratch directory of its own.
- **`ARGUS_NO_CACHE=1`** turns every store off: each run extracts and
  solves afresh, and the store tests (`@tag :cache`) are skipped. Use it
  after changing how a key is made or what a producer can read, when an
  answer looks stale, to measure a cold run, and once before a release.

### The dev loop

- `mix test --exclude corpus` after an edit re-extracts only the
  producers the edit reaches over each fixture set and re-solves only
  what reads what moved; warm, it solves only the tests of the solver
  and the pipeline themselves. `mix test` adds the corpus, which after an
  extractor edit re-extracts that extractor's shard over each checkout.
- Iterating on a rule: `mix test test/analyses/<x>_test.exs` solves only
  that analysis's fixture sets again; then `mix test --only corpus` (or
  `ARGUS_CORPUS_ONLY=…`) and `mix argus.corpus tally --title …`.
- Iterating on an extractor: its extractor tests call the pipeline
  directly; the analysis tests reading its relations re-extract its
  shard alone, over the kept bases, and solve again only where its rows
  changed.
- A refactor of shared extraction code re-extracts everything once;
  when the facts come out byte-identical nothing is solved again.
- Slow properties check a sample; `ARGUS_PROPERTIES=full` runs their
  full count (before a release, or after changing what they cover).

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
ARGUS_NO_CACHE=1 mix test  # Every store off: extract and solve afresh
ARGUS_PROPERTIES=full mix test  # Slow properties at their full count
```
