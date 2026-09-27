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
  `Build`, `Rows`, `Evidence`, `Anchor`, `Names`, `Degradation` and
  `Tooling`.
- `lib/argus/schema.ex` — the fact schema's API; each relation is declared
  once, with its layer and in-process flag, in its concern's module under
  `lib/argus/schema/`. Only schema data lives under `Argus.Schema`, read
  through accessors that record what they return (see "Incrementality"):
  code there is keyed by nobody. `@schema_version` is what
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
- `lib/argus/graph.ex` and `graph/` — the query graph on roux
  (see "The query graph" below; what it keeps in its blob store, and
  what moves it, is "Incrementality"); `lib/argus/driver.ex` — the run every
  frontend makes over a project (a `Roux.Session` over the project's
  manifest, the beams synced with `Roux.Sources`, the analyses
  demanded), returning `Argus.Driver.Result` (`Argus.Located` findings
  and notices); `lib/argus/run.ex` — `run_analyses/2`, `analyze/3` and
  `extract_facts/3` on the graph, one session each (the batch pipeline's
  options raise, naming what replaces them: `Argus.Run.check_options!/1`);
  `lib/mix/tasks/compile.argus.ex` — the `:argus` Mix compiler, and
  `mix argus`.
- The frontends: the `:argus` Mix compiler (`Mix.Tasks.Compile.Argus`),
  `mix argus`, the `argus` escript (`Argus.CLI`, `CLI.Options` shared
  with `mix argus`; `mix escript.build`) and the rebar3 plugin
  (`integrations/rebar3_argus`, Erlang, which runs the escript). Each
  finds its project through an `Argus.Project` adapter (Mix, rebar3,
  Gleam, erlang.mk, bare beams: the program's and the dependencies'
  ebins and a state directory; `Project.Scan` discovers the beams), its
  configuration through `Argus.Config` (`Config.Source`: `argus:` in
  mix.exs, `{argus, ...}` in rebar.config, `argus.config`), and renders
  a driver run through `Argus.Report` (`build/3`, then `Report.Text`,
  `Report.Json` or `Argus.Mix.Diagnostics`; what a reader should know
  about the run is a `Report.Notice`). The source takes the last step of
  a place (`Argus.Locate.Source`: Elixir, Erlang on tokens, opaque
  otherwise). A project's ebins are never put on the code path: callee
  specs come from `Argus.Specs.Source`. The escript carries `priv/dl`
  in its code (`Argus.Dl.Embedded`, unpacked under the blob store);
  `Argus.Dl.root/0` is where the rules are. The in-VM API is
  `Argus.run_analyses/2`, `Argus.Findings.run/2` and
  `Argus.Pipeline.extract/2`.
- Rendering is pinned byte for byte: `Argus.Report.GoldenTest` (the
  depot fixture) and `Argus.Report.ShapesTest` (every shape of a place,
  `Argus.Test.ReportShapes`). A deliberate change records them again
  (`ARGUS_RECORD_GOLDENS=1`) and the diff is the review. The non-Mix
  fixture projects (`test/projects/{rebar3_app,gleam_app,erlang_mk_app}`)
  are built without their tools (`Argus.Test.Projects`); the real tools,
  the built escript and the plugin run under `--include rebar3 --include
  gleam --include escript` (CI's escript job).

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
  `source_process` and `source_table` are staged only for the sources
  the analyses ask about (points_to.dl names them); a rule asking about
  another source adds it there.
- A facts directory a caller hands in may be shared: scry names its
  directories by their content, so derivations over the same facts
  write into the same one at once. A stage solves into a directory of
  its own and renames each output into place whole
  (`Extraction.derive_stage0/2`): Souffle never writes there, and no
  stage removes a file from it.
  `test/argus/analysis/shared_stage_test.exs` holds each race open.
- An absent relation file is never an empty relation. Every writer
  leaves a file per relation, empty when it has no rows
  (`Pipeline.run/3` for every schema relation, Souffle for every output,
  a kept solve for its outputs), so a reader that cannot open one
  answers `Argus.MissingRelationError` naming the relation and the file
  (a tagged error, or raised where the reader returns a value). A new
  writer makes the empty case explicit; a new reader never maps
  `{:error, _}` to `[]`. The relations only the in-process passes read
  (`Argus.Schema.in_process_only/0`) are extracted only for a program
  that reads them (a `{:custom, path}` one: its own packs,
  `module_in_process`); a facts directory made for other analyses has
  no file for them, so a program reading one fails on the missing file
  rather than solving over an empty relation.
- Points-to follows only terms that hold a process or a table, and a
  callee that hands its parameter back returns each call's own argument
  (`passes`): context-insensitive merging through such helpers is what
  made the stage quadratic on a large library (Ash). A program whose
  exact fixpoint still outgrows the stage's budget (points_to.dl's
  `.limitsize`: 500,000 rows of `source_pts` and of `field_pts`) runs it
  bounded (`points_to_bounded.dl`: the leaves a coarse pass finds
  pervasive are resolved by that pass, a sound superset; the rest
  exactly). Never decide the mode by time: a result must be a function
  of the facts, or a store, CI and the incremental ≡ fresh parity
  disagree about the same input. A budget is: Souffle stops at it
  however fast it runs. A new relation of the exact pass must keep a bounded
  counterpart in `clientlib/pervasive.dl`, or a pervasive leaf loses its
  rows: `test/clientlib/pervasive_test.exs` checks the coarse pass reaches
  every exact target.
- Souffle expands a rule with k disjunctive alternatives into k rules,
  each with the whole body: a disjunction over a large join multiplies
  both compile time and the join. Test a condition on a few columns
  with a small relation instead (`check_then_act.dl`'s `may_agree`).
- Souffle is an external tool on PATH, shelled out to via `Argus.Souffle`.
- `test/corpus/pairs.exs` is the closed-issue corpus: for each pair a
  rule's finding is present at the commit before the fix and absent at
  the fix. `Argus.CorpusTest` runs it as part of `mix test`, cloning and
  compiling each tree once into `ARGUS_CORPUS_DIR` (default
  `~/.cache/argus/corpus`) and analyzing it on the graph, its graph kept
  in a manifest beside it per argus worktree
  (`<checkout>/.argus/manifest-<worktree>`, seeded from the newest
  another worktree kept) over the shared blob store (see
  "Incrementality" below). `mix test --exclude corpus` skips it,
  `ARGUS_CORPUS_ONLY=redix#334` narrows it, `ARGUS_CORPUS_JOBS` sets how
  many checkouts are analyzed at once (default 4), `mix argus.corpus
  fetch` warms the cache and `mix argus.corpus tally` counts every title
  across the trees — the noise check after a rule changes. The tally
  runs in `MIX_ENV=test` and shares the gate's store; `argus gc`
  (`mix argus gc`) collects it. A new rule comes with a pair.
- Tests solve through `Argus.Test.Memo` (`analyze/3`, `run_analyses/2`,
  `run_rules/2` over hand-built facts, `compile_beams/1` for modules a
  test compiles): the same modules and analysis are solved once per run
  and every later caller reads the answer, an immutable term; across
  runs they go through the suite's blob store. A call with options of
  its own is the test's to shape.
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

## Incrementality

The query graph keeps what it computed in a blob store (`Roux.Blob`:
`Argus.Graph.store/0`, under `ARGUS_CACHE_DIR`, or `store:` on
`Argus.run_analyses/2`, `Argus.analyze/3` and `extract_facts/3`),
content-keyed, so a run redoes only what an edit reached. A run given a
manifest (the Mix compiler, `mix argus`, the escript and the corpus keep
one per project; `manifest:` on the calls above) restores the graph from
it and checks again only what moved; a run without one opens a session
over the store alone and finds each module's facts by its trace and each
solve by its inputs' digests. The suite's store is
`_build/test/argus/store`.

- **Module facts** (`Argus.Graph.Pack`): each producer's rows — `:base`
  (the emitter, def_use, conditional_call) or one extractor — are a
  segment of their own, one blob per producer with rows, and a module's
  pack indexes them. One trace per module, named by the beam's digest
  and the row-shaping options, keeps for each producer the variants its
  rows were made under: the digest of the code it ran
  (`Argus.Graph.Code`'s `producer_code`: the import-table closure from
  `Argus.Pipeline` and the extractor, `Roux.Code`, without the schema's
  modules) and what it read outside that code as it ran — the schema
  entries (`schema_entry`) and the specs of the modules it called
  (`installed_specs`). A lookup reads the trace alone; a producer no
  variant holds for runs alone, over the module's kept base, and writes
  its own segment. A producer's rows do not depend on which others run
  (`Argus.Graph.Identity.ProducersTest`).
- **Bases** (`Argus.Pipeline.Base`): each module's disassembly, decoded
  facts, control-flow graphs and reaching definitions (the per-function
  solutions `Argus.Instr.Reaching.export/1` carries), kept beside its
  trace by every run that computes them and read back while the base's
  code and the schema entries computing them read hold: after an
  extractor edit, the extractor runs over them — on the corpus, a
  quarter of the cost for most extractors. The decoded facts
  (`module_data.typed`) are read back only for
  `Argus.Pipeline.typed_readers/0`;
  `Argus.Graph.Identity.ProducerClosureTest` fails when another
  extractor computes them — add it to that list. Dependence reads them
  and calls five other extractors, so an edit to any of those
  re-extracts it too.
- **Relations and solves**: a relation's digest is a Merkle digest of
  its modules' chunk digests (`program_relations`), its file assembled
  once per digest and linked where a solve needs it. A solve
  (`Argus.Graph.Solve`) is kept in the store's action cache under its
  program as the solver reads it (`Argus.Souffle.Program.declared_digest/2`:
  of a generated file of declarations — `base.dl`, `layer2.dl`,
  `priors.dl` — only the declarations of the relations Souffle loads for
  it, and no comment), the solver's version and its inputs' digests. The
  relations a program loads are resolved again under every declaration
  (not the comments), so a declaration that breaks a program fails it
  before a solve is kept. Stage outputs join by content, so a solve
  downstream of a stage that came out the same is found again — early
  cutoff.
- **What moves what**: an extractor edit re-runs that extractor over
  each module's kept base, and nothing past the module's facts unless
  its rows changed; an edit to anything the base reaches (`Argus.Instr`,
  the extractor helpers, the emitter, `Writer`, `Tsv`) re-extracts every
  module, and the solves run again only where the facts came out
  different; a rule edit re-solves the programs that include it. A
  schema edit re-runs the modules whose producers read what it changed —
  the columns of the relations the pipeline decodes
  (`Pipeline.typed_relations/0`), nothing else today — and the solves
  that load a relation whose declaration it changed; a new relation, a
  version bump or an edit to prose moves nothing but the resolution of
  each program's inputs. An edit undone finds the rows the code made
  before (a trace keeps four variants of each producer's). The solver,
  the analyses' prose and the corpus harness move no module's facts.
  The recompute sets are pinned with `Roux.QueryLog`
  (`test/argus/graph/rules_test.exs`, the Mix compiler's manifest
  tests).
- **The schema is read through its accessors**: `Argus.Schema` and its
  concern modules are data, left out of every query's code version; each
  of their functions records the entry it returns (`Argus.Schema.Reads`,
  in the process that tracks, carried back with the rows), and a query
  depends on what it recorded. So code reads the schema only by calling
  those functions — never a copy kept in a `persistent_term`, an ETS
  table or another process (a module attribute computed at compile time
  is fine: it is the caller's code, and Mix recompiles the caller).
- **The identity checks** (`test/argus/graph/identity`) hold the keys:
  `SchemaReadsTest` calls every export of every module under
  `Argus.Schema` and fails unless each records a read naming exactly
  what it returned (an export taking arguments must list them there);
  `SchemaPerturbationTest` extracts every fixture in a VM whose schema
  has every entry a producer did not read changed, and fails unless its
  rows are byte-identical; `DeclaredDigestTest` does the same for every
  shipped program and the declarations it does not load;
  `ProducerClosureTest` runs each producer with call counting, the
  extractors over kept bases too, and fails if one executes a module
  outside its closure other than the schema's; `ProducersTest` extracts
  each producer alone, together and over a kept base. All but
  `SchemaReadsTest` are tagged `:identity_verify` and left out of a
  plain `mix test` (they take minutes and only move with the schema, the
  keys or what a producer can read); CI includes them, and so should a
  change to any of those: `mix test --include identity_verify`. Use
  `Argus.Schema.columns/1` when a relation's columns are all a caller
  needs: its prose then keys nothing.
- **Retention** is the store's (`Roux.Blob.gc/2`): it keeps what a
  manifest retains, what a trace or an action-cache entry used within a
  week names, and anything younger than a day. The Mix compiler, the
  driver and the suite collect at most once a day
  (`Roux.Blob.maybe_gc/2`); `argus gc` (`mix argus gc`) collects now.
  Entries are immutable and read-only; a run links them into a scratch
  directory of its own.
- **`ARGUS_NO_CACHE=1`** gives every run a temporary store, removed when
  it returns: each run extracts and solves afresh, and the store tests
  (`@tag :cache`) are skipped. Use it after changing how a key is made
  or what a producer can read, when an answer looks stale, to measure a
  cold run, and once before a release.

### The dev loop

- `mix test --exclude corpus` after an edit re-extracts only the
  producers the edit reaches over each fixture set and re-solves only
  what reads what moved; warm, it solves only the tests of the solver
  and the pipeline themselves. `mix test` adds the corpus, which after an
  extractor edit re-runs that extractor over each checkout's kept bases.
- Iterating on a rule: `mix test test/analyses/<x>_test.exs` solves only
  that analysis's fixture sets again; then `mix test --only corpus` (or
  `ARGUS_CORPUS_ONLY=…`) and `mix argus.corpus tally --title …`.
- Iterating on an extractor: its extractor tests call the pipeline
  directly; the analysis tests reading its relations re-run it alone,
  over each module's kept base, and solve again only where its rows
  changed.
- A refactor of shared extraction code re-extracts everything once;
  when the facts come out byte-identical nothing is solved again.
- Slow properties check a sample; `ARGUS_PROPERTIES=full` runs their
  full count (before a release, or after changing what they cover).

## The query graph

`Argus.Graph` is argus as a roux query graph (the moduledoc draws it):
per-module extraction (`module_facts`, packs of text in a `Roux.Blob`
store found again by one verifying trace per module), the first cutoff
seam (`module_semantic`, without `line_info`), a Merkle digest per
relation over the program's modules (`program_relations`, one
`Runtime.parallel` fan-out), the two stages (the second and third
seams), one solve per analysis (`Argus.Souffle.Solve`, kept in the
store's action cache), line-free `findings`, and `located` (the
bytecode's late step). Invariants:

- **Code identity is inferred, never declared.** Each query's code
  version is the digest of what its role module's import table reaches
  (`use Roux.Query, code: ...`), the schema's modules left out. What is
  reached by name — the extractors, the analyses — is read as a value
  (`Argus.Graph.Code`: `producer_code`, `analysis_code`), so an
  extractor edit re-runs that extractor alone on each module and an edit
  to one analysis rebuilds its findings alone. A new dynamic dispatch
  gets a value there or a declared root; `Argus.Graph.CodeClosureTest`
  runs every query with call counting and fails on code outside its
  closure.
- **The schema is read through its accessors, inside a query.** The
  `around:` hook (`Argus.Graph.Reads.around/2`) turns every schema entry
  a query recorded, and every module whose specs extraction read (from
  the project's `Argus.Specs.Source`, or off the code path without
  one), into `schema_entry`/`installed_specs` edges. Never keep
  what an accessor returned where another query could find it; never
  read the schema in a spawned process without handing its reads back
  (`Argus.Schema.Reads.record_all/1`).
- **Query values must survive `term_to_binary`**, and never name a pid
  or a table: a manifest keeps them. A value naming blobs holds them
  (`Roux.Runtime.hold/1`), and a large one is kept by digest
  (`store: :blob`); a stage output whose entry vanished is derived again
  when a solve needs it (a vanished entry is a miss, never an error).
- **Failures are transient.** A failed solve or stage, and a module
  lost to the per-module timeout, is `transient:`: neither it nor what
  read it is kept, so the next run tries again. Never `:low` anywhere
  in the input → facts chain: durability propagates as the minimum.
- **Rendering is driver work** from query values (`Argus.Located`), never
  a query's side effect; what only the source says (a fragment's line, a
  block's end, the `{guard}` keyword) is `Argus.Located.refine/1`'s,
  which every report and `Argus.run_analyses/2` take alike.
- **What the store keeps is read back by a fresh VM.** A trace names a
  module outside the program by string, never by atom: the VM reading
  it has not made that atom (`Argus.Graph.FreshVmTest`).
- **A warm call costs stats, not reads.** Each module keeps one trace,
  and a lookup that finds every producer's newest variant holding reads
  it and nothing else (the pack it names is in it); what a fresh VM
  would compute again from files
  (beam digests, program walks and digests, line tables, declaration
  lines, a preloaded module's specs) is kept by stamp or by content in
  the VM and the store (`Roux.Stamp`, `Roux.Blob.cached/3`); store and
  hot-path file I/O is raw, never queued behind the VM's file server.
  A new per-call computation over files gets the same treatment, or
  P1/P4 warm regresses.
- **A comment is not an edit.** A program's key reads its text without
  comment lines (`Argus.Souffle.Program.uncommented/1`); a test that
  edits a rule to see a re-solve appends a declaration, not a comment.
- Without a solver nothing is solved: the driver demands no analysis,
  so no error memo reaches a manifest.
- Beams are keyed by path; a beam's `hash` is the digest of it without
  `ExCk` and `Docs` (`Roux.Code.canonical_beam/1`), so a recompile that
  only refreshed Elixir's type checker table moves nothing. The sync
  never trusts a stat stamp younger than two seconds (a fast
  edit-compile-edit can rewrite a beam in the same second with the same
  size): do not "simplify" that away.

### Testing the graph and the Mix compiler

- `mix test --include parity` before touching the graph: every analysis
  over argus's own fixtures (`Argus.Test.Graph.parity!/0`), one
  database's incremental solves ≡ a fresh run's (`Argus.Test.Graph.fresh/2`),
  cold and across cross-module edits.
- Recompute sets are asserted with `Roux.QueryLog` (one database's
  events, or `:all` for a Mix compiler that opens its own). A code edit
  is simulated by registering a query again under another code version;
  a rule edit by editing a copy of `priv/dl` (`:dl_root`, in a peer).
- Tests that drive VM-wide state (the Mix project stack and the working
  directory, `PATH` and other env vars, application env, telemetry
  handlers, the code path, loaded modules, compiler options) run in a
  peer: `use Argus.Test.Peer` keeps the module's bytecode, and
  `Peer.run(peer, fn -> ... end)` runs its closures there, assertions
  and all. Inside a peer, compute temp paths inside the closure and
  return plain data. Peer and Mix-project tests are tagged `:project`.
- The suite and its peers keep the graph's blob store under
  `_build/test/argus/store` (`ARGUS_CACHE_DIR`); a test that must see
  its solver or extractors run gives itself a store of its own
  (`Argus.Test.Graph.new_db(paths, store: :temporary)`,
  `Peer.start!(store: :own)`, or `ARGUS_CACHE_DIR` pointed at a fresh
  directory for the runs it makes).
- `Argus.Test.Graph.new_db/2` stamps no code directory (`app_code`):
  stamping the test VM's code path reads thousands of files. A test
  about a rebuilt directory passes `stamps: true` or sets the stamp it
  moves itself.
- Mix-project tests check out `test/projects/depot` (or the umbrella)
  with `Argus.Test.Fixture` and run the real chain in a peer:
  - `Mix.Project.in_project/3` caches projects by app atom — one unique
    app atom per distinct config;
  - drive it with `Mix.Task.clear()` and `Mix.Task.run("compile",
    ["--return-errors", "--no-prune-code-paths"])`: without the clear,
    nested compile tasks stay marked as run; without `--return-errors`
    an `:error` status exits the VM; without `--no-prune-code-paths`
    the test VM's own applications are pruned off the code path;
  - back-to-back edits within one posix second are invisible to
    `:elixir`'s staleness check: write, then `File.touch!` forward (the
    tests' `edit!/2`);
  - diagnostic paths are realpath'd (`/private/var` on macOS while the
    checkout says `/var`).
- Unload a module a test compiled with `:code.purge/1`, `:code.delete/1`
  and `:code.purge/1` again, never `purge(m) && delete(m)`: `purge`
  answers false for a module with no old code, and the module stays
  loaded, where `:code.which/1` finds it for the next test.

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
ARGUS_NO_CACHE=1 mix test  # A temporary store per run: extract and solve afresh
mix test --include identity_verify  # Also the identity checks of the keys (CI runs these)
mix test --include escript --include rebar3 --include gleam  # The escript, the real tools, the plugin
mix escript.build        # The argus escript (built in :prod)
mix test --include parity  # Also the incremental ≡ fresh gate over argus's own fixtures
mix argus gc             # Collect the blob store now (runs collect it daily)
ARGUS_PROPERTIES=full mix test  # Slow properties at their full count
```
