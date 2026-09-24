# scry

Analysis-only Mix compiler for BEAM projects: incremental argus analyses
via roux, reported as rich compiler diagnostics.

## What it does

Scry runs **after** `:elixir` (`compilers: Mix.compilers() ++ [:scry]`),
reads the `.beam` files the stock compiler produced, and runs argus's
Datalog analyses over them through a roux query graph. Findings are
`Mix.Task.Compiler.Diagnostic` structs whose `details` carry a rendered
pentiment frame (responsible lines, cross-file evidence as continuation
frames, `help:` remediation). Cross-run incrementality comes from
`Roux.Lang.Manifest`: a comment-only edit re-extracts one module and
re-runs zero Souffle solves.

Scry also hosts the **shared analysis layer** (`Scry.Analysis`): the
frontend-agnostic roux query pipeline per-module extraction → semantic
facts (line_info split out — THE early-cutoff seam) → per-relation
projections → per-analysis content-addressed Souffle fact dirs → solve →
line-free findings → late line resolution. Planchette consumes it for
its LSP with an in-memory compile frontend; scry drives it with a
disk-beam frontend.

## Architecture

Two layers over one `Roux.Database`:

1. **Frontend** (`Scry.Frontend`): inputs `beam_meta` (module →
   %{path, mtime, size, hash}, :medium), `module_set`, `env_fingerprint`,
   `producer_digest`, `producers`, `argus_code`, `rules_digest`
   (:high); queries `module_beam` (disk read; the tracked signal is the
   hash input), `file_of` (beam compile_info source, realpath-normalized),
   `module_map`. Registers the same query names as planchette's frontend —
   **query names are the ABI** (roux dispatches by name; memo keys are
   {query_name, key}).
2. **Analysis** (`Scry.Analysis`): never rename a query, never change a
   key or value shape without planchette in the same review.
   `Scry.Fingerprint` stamps what the graph depends on beyond the
   beams:
   - `env_fingerprint` — the runtime and a digest of scry's ebin, read
     by every extraction, the stages, the solves and findings: moving it
     re-runs everything.
   - `producer_digest` per argus producer (`:base` — the emitter,
     `def_use`, `conditional_call` — or one extractor) — the code it
     runs (`Argus.Cache.Code.digest/1`), plus, for the specs extractor,
     the specs environment less argus and the watched apps. Extraction
     is memoized per `{module, producer}` (`producer_extraction`, via
     `Argus.Pipeline.extract_shards/3`), and joined in the `producers`
     input's order where a module's facts are needed whole
     (`module_semantic_facts`, `program_relation_facts`; the line table
     reads the base's alone): an argus edit re-extracts the producers it
     reached, and where their rows come out equal the semantic digest
     validates green. The join is never memoized on scry's path — the
     rows would be stored twice (the manifest grew a third);
     `module_extraction`, the same join as a query, is planchette's. The
     base's digest also keys the relation text (`relation_digest` and the
     stage digests: `Argus.Tsv` is base code). Taking the digests walks
     import tables in a fresh VM (~150ms on realtime), so the runner keeps
     the last run's while `producer_stamp` (runtime, argus's code, the
     specs environment) holds; with `include_deps` there is no stamp.
   - `argus_code` — every argus beam: read by `findings` (prose,
     identity rules; cheap to rebuild) and by a specs extraction that
     read one of argus's modules.
   - `rules_digest` per analysis — the `.dl` and its transitive
     includes, plus the souffle version — read by
     `analysis_input_relations`, `stage0_facts`, `points_to_facts` and
     `souffle_solve`, so a rule edit re-solves exactly the analyses it
     touched and re-extracts nothing. How argus runs Souffle is keyed
     the way argus keys its own solves: by program and solver, not by
     argus's code (after changing that, `--force`).

   The runner prewarms exactly what the edit invalidated (`module =>
   producers`, across the schedulers). A `producer_extraction` that
   finds nothing parked extracts serially: the join's first producer
   (`:base`) re-executes only when what every producer reads moved, so
   it extracts them all in one pass and parks the rest for the join;
   any other producer extracts itself alone. `drop_prewarmed/0` returns
   what no query took (tests assert it is empty). Pin re-extraction in
   tests with `QueryLog.extracted/1` (the modules any producer
   re-extracted), not with `module_extraction`, which scry never runs.

   Argus's shared stages are queries of their own, each a cutoff seam:
   `stage0_facts` (the call graph) and `points_to_facts` (process
   points-to, `Argus.Analysis.points_to_relations/0`), with `:stage0`
   and `:points_to` rules digests; a projection takes a stage's outputs
   from its query, never from extraction. A frontend that never sets
   `rules_digest`, `producer_digest`, `producers` or `argus_code`
   (planchette) reads them as unset: no edge, and the join falls back
   to `Scry.Analysis.producers/0`. The LSP-only surface — supervision
   tree, flowistry focus/slicing, the debug twin — lives in planchette
   (`Planchette.SupTree`, `Planchette.Focus`) and registers its own
   queries next to these.

Driver side (never inside queries): `Scry.Scanner` (beam discovery +
mtime/size/hash diff vs manifest sources), `Scry.Runner` (db lifecycle,
warm start, input sync, souffle check, demand — the analyses solve
concurrently, one task each, after the merged relations are demanded in
the runner's own process, where the prewarmed extractions wait), `Scry.Diagnostics`
(resolved finding → Pentiment.Report → Diagnostic; printing; sidecar for
`diagnostics/0`), `Mix.Tasks.Compile.Scry`, `Mix.Tasks.Scry`.

Key invariants:

- **Durability**: never introduce `:low` anywhere in the input→facts
  chain — durability propagates as the min and `:low` derived memos are
  dropped from the manifest (the fact memos are the bulk of the win).
- **Query values must survive `term_to_binary`** (manifest persistence).
- **Artifact emission and rendering are driver work** from query values,
  never query side effects.
- Souffle missing + `souffle: :warn`: never demand solves (no error
  memos poison the manifest); the souffle version lives in
  `env_fingerprint` so installing it heals everything.
- Souffle scratch root `scry_souffle` is shared with planchette's LSP
  sessions (content-addressed, staged+renamed); `souffle_solve` guards
  with a `File.dir?/1` re-materialize check.

## Test-harness gotchas (learned the hard way)

- `Mix.Project.in_project/3` CACHES loaded projects by app atom — two
  fixtures sharing an app name silently share the first one's config.
  One unique app atom per distinct fixture config.
- Drive the chain with `Mix.Task.clear()` +
  `Mix.Task.run("compile", ["--return-errors", "--no-prune-code-paths"])`:
  without clear, nested compile tasks stay marked as run; without
  --return-errors, an :error status exits the VM; without
  --no-prune-code-paths, the test VM's own apps get pruned off the
  code path inside the fixture.
- Back-to-back fixture edits inside one posix second are invisible to
  :elixir's mtime check — write then `File.touch!` forward (the
  fixture suite's `edit!/2`).
- The scanner never trusts mtime+size for files written within the
  last second (scry runs moments after :elixir; a fast
  edit-compile-edit-compile can rewrite a beam same-second,
  same-size). Do not "simplify" that away.
- Diagnostic file paths are realpath'd (`/private/var` on macOS while
  the checkout says `/var`); `Scry.Diagnostics.relative/2` tolerates
  both spellings.

## Development commands

```bash
mix test                      # run all tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

Souffle-dependent tests are tagged `:souffle` and need a `souffle`
binary on PATH. The incremental≡batch gate (`test/scry/analysis_parity_test.exs`,
every analysis over `test/fixtures/parity` — argus's own fixtures —
cold and across cross-module removals) is tagged `:parity` and excluded
by default: run `mix test --include parity` before touching
`Scry.Analysis`.

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Testing conventions

- Unit tests mirror `lib/` structure in `test/`.
- Test support modules go in `test/support/`.
- Use `stream_data` for property-based testing.
- Compiler tests drive the fixture project in `test/fixtures/depot`
  (copied to a tmp dir by `Scry.Test.Fixture`) via
  `Mix.Project.in_project/3` + `Mix.Task.rerun("compile")`, in a peer
  (`Fixture.in_peer/4`) — the real chain, so `:elixir` genuinely produces the beams scry reads. The
  fixture's cold-build findings (two couplings at the tree definition,
  one leaked task) and rendered frames are golden-pinned; keep it
  self-contained and dependency-free.
- Telemetry edit-replay tests assert exact recompute sets
  (`test/support/query_log.ex`).

### The async rule

Every module is `async: true` unless it mutates VM-wide state in the
test VM itself, and a test that needs VM-wide state runs in a peer
instead. VM-wide means: the Mix project stack and the working directory
(every fixture compile), `PATH` and other env vars, application env,
telemetry handlers (a `QueryLog` sees every roux event in its VM), the
code path, loaded modules and compiler options, and the souffle scratch
root (a prune or a store edit reaches every solve reading it).

- `Scry.Test.Peer` starts a second BEAM from this VM's code path, with
  Mix in `:test`, this VM's compiler options, and its own `TMPDIR` (so
  its own scratch root). `use Scry.Test.Peer` in the test module keeps
  its bytecode, so `Peer.run(peer, fn -> ... end)` runs the module's
  own closures there, assertions and all; an exception comes back with
  the peer's stacktrace. `Fixture.in_peer/4` runs a closure inside a
  checked-out fixture there with a `QueryLog` attached. One peer per
  module (`setup_all`), per test where a test leaves the VM changed.
- Inside a peer, compute temp paths inside the closure
  (`System.tmp_dir!/0` is the peer's), and return plain data: a pid does
  not survive the trip back.
- Still `async: false`: `Scry.ConfigTest` (clears `TYPESAFE_API_KEY`)
  and the spec probes (`AnalysisSpecsTest`, `AnalysisFrontendSpecsTest`:
  code path, module loading, compiler options) — cheap, and they run
  after the async modules.
- `test_helper.exs` points `TMPDIR` at one directory per run, removed
  after the suite: fixture checkouts, the parity build and the main VM's
  scratch root are shared with nothing else on the machine.
- `Scry.Test.Graph.parity!/0` compiles the parity fixture once per run
  (content-keyed, under a lock) and puts it on the code path; hand the
  paths to a peer with `Graph.use_parity!/1`. Never compile it per
  module: two async compiles of one module collide.
- Solve only what a test reads. Only `Mix.Tasks.Compile.ScryTest` pins
  the default set's goldens; tests about config, the souffle gate,
  extraction failures, priors, the task and warm runs use
  `analyses: [:coupling, :mailbox]` — every finding the depot fixture
  has, both read stage 0, and coupling reads the priors.

## Non-goals (v1, keep the README honest)

Umbrella-wide analysis (per-app only; `include_deps: true` is the
escape hatch), incremental Datalog, focus/slicing and
the supervision tree (planchette's LSP defines those queries over this
layer; scry never demands them).

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an
`## Unreleased` section at the top.
