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
   `extraction_code`, `argus_code`, `rules_digest` (:high),
   `graph_layout` (:low, driver bookkeeping); queries `module_beam` (disk
   read; the tracked signal is the hash input), `file_of` (beam
   compile_info source, realpath-normalized), `module_map`. Registers the
   same query names as planchette's frontend — **query names are the
   ABI** (roux dispatches by name; memo keys are {query_name, key}).
   Planchette's tests pin `module_extraction` executions: it is THE
   per-module extraction query, and scry demands it itself.
2. **Analysis** (`Scry.Analysis`): never rename a query, never change a
   key or value shape without planchette in the same review.
   `Scry.Fingerprint` stamps what the graph depends on beyond the
   beams:
   - `env_fingerprint` — the runtime, a digest of scry's ebin and the
     specs environment (every application on the code path, less
     argus's own and the watched ones' beams; nothing of argus's, its
     schema included) — read by `module_extraction`, the stages, the
     solves and findings: moving it re-runs everything. Hashing the dependencies' beams cost ~1 s a
     run on a large project; argus keeps each ebin's hashes under a stat
     stamp (name, mtime, size, inode; an ebin with a beam younger than
     2 s is read whole) in the store `Scry.Runner.cache_dir/0`
     (`<manifest_path>/compile.scry.cache`, `Argus.Cache` layout,
     `ebins/`; atomic staging+rename writes, safe across VMs). `--force`
     drops it (`env/2`'s `refresh:`; a VM's in-memory copy stands);
     pruned when the fingerprint moves; `ARGUS_NO_CACHE` turns it off.
     Known edge: a beam rewritten in place, same size, mtime set back,
     keeps its old hashes — the scanner's own prefilter has the same
     one.
   - `extraction_code` — ONE digest of the code argus's fact producers
     run: the union of `Argus.Cache.Code.closure/2` over `:base` and
     every extractor scry runs, with `schema: :recorded`: the schema's
     modules are walked through but left out, since each query is keyed
     by the entries it read (`schema_read`, below)
     (`extraction_closure/0`), each by `Argus.BeamDigest`, with the
     producer list. Read by
     `module_extraction` (an extractor or base edit re-extracts every
     module; equal rows backdate at the semantic digest, so nothing
     above runs) and by `relation_digest`/`stage0_digest`/
     `points_to_digest` (the text is `Argus.Tsv`'s, base code). ~25 ms
     per run, taken every run. An argus edit outside it (findings
     prose, analyses modules, the Souffle wrapper, caches, corpus)
     extracts nothing.
   - `argus_code` — every argus beam with debug info: read by `findings`
     (rebuilt on any argus edit, cheaply) and by a `module_extraction`
     whose specs reads reached an argus module. Its per-beam digests
     are kept in the store's `ebins/` under the same stamp as the
     dependencies' (`Argus.Specs.ebin_digests/2`): a warm run stats
     argus's beams instead of reading them.
   - `rules_digest` per analysis — the program as a solve of it loads it
     (`Argus.Souffle.Cache.declared_digest/2` over
     `Argus.Souffle.input_relations/2`: the `.dl` and its transitive
     includes, but of a generated declarations file only the
     declarations of the relations the program loads), plus the
     solver's version (`Argus.Souffle.Cache.version/2`) — read by
     `analysis_input_relations`, `stage0_facts`, `points_to_facts` and
     `souffle_solve`, so a rule edit re-solves exactly the analyses it
     touched and re-extracts nothing, and a schema edit re-solves only
     the programs that load a relation whose declaration it changed.
     The loaded relations and the solver's version are kept in the
     store's `programs/` (the version under a stamp of the solver's
     binary; `--force` drops it): a warm run starts no solver. How argus
     runs Souffle and reads its output is keyed the way argus keys its
     own solves: by program and solver, not by argus's code (after
     changing that, `--force`).

   Extraction runs `Argus.Pipeline.extract_shards/3` over every producer
   and joins their rows (sorted per relation, as `extract/2` would give
   them) for its `installed` reads — every module whose specs or types
   the specs extractor looked up — which record an edge per read that
   the environment digest does not cover: a program module → its
   `file_of`, an ignored one → its `ignored_beam`, an argus one →
   `argus_code`. Memoizing per producer (`{module, producer}`) was tried
   and reverted: it made an extractor edit ~40% cheaper but a project
   edit slower and the manifest 12% bigger, and scry's users edit their
   project.

   Argus's schema (`Argus.Schema`) is data, and each accessor records
   the entry it returned (`Argus.Cache.Reads`). `schema_read(entry)` is
   one entry's digest now (`"columns call_arg"` →
   `Argus.Cache.Reads.digest/1`), reading `argus_code`: a QUERY, not an
   input, because an extraction's reads are known only after it ran,
   often inside the graph, where no input can be set. Every query that
   reads the schema runs the read inside `reading_schema/2` and depends
   on each entry it read: `module_extraction` (the producers' decoding,
   `extract_shards/3`'s `reads`, and scry's interning), `relation_rows`
   (`fetch <relation>`: is it a prior), `relation_facts` and the three
   digests (the text is written by the columns), and the relation lists
   of `analysis_input_relations` and the stages (`columns <name>` per
   name, never `names`), and the stages' interned outputs. An argus edit
   re-digests the entries read so far and backdates the unchanged ones;
   a moved entry reruns exactly its readers. Rules: never read the
   schema in a query outside `reading_schema/2`, never demand a query
   inside one (its reads would be charged to the caller), and read the
   narrowest accessor (`columns/1`, `fetch/1`: `layer_3/0` or `names/0`
   move with any relation). A frontend without `argus_code`
   (planchette) records no schema edges.

   Argus's shared stages are queries of their own, each a cutoff seam:
   `stage0_facts` (the call graph) and `points_to_facts` (process
   points-to, `Argus.Analysis.points_to_relations/0`), with `:stage0`
   and `:points_to` rules digests; a projection takes a stage's outputs
   from its query, never from extraction. A frontend that never sets
   `rules_digest`, `extraction_code` or `argus_code` (planchette) reads
   them as unset: no edge. The LSP-only surface — supervision tree,
   flowistry focus/slicing, the debug twin — lives in planchette
   (`Planchette.SupTree`, `Planchette.Focus`) and registers its own
   queries next to these.

Driver side (never inside queries): `Scry.Scanner` (beam discovery +
mtime/size/hash diff vs manifest sources), `Scry.Runner` (db lifecycle,
warm start, input sync, souffle check, demand — the analyses solve
concurrently, one task each, after the merged relations are demanded in
the runner's own process, where the prewarmed extractions wait; with
nothing prewarmed they are left in the memo table, since serving them
copies tens of MB onto the runner's heap), `Scry.Diagnostics`
(resolved finding → Pentiment.Report → Diagnostic; printing; sidecar for
`diagnostics/0`), `Mix.Tasks.Compile.Scry`, `Mix.Tasks.Scry`.

Key invariants:

- **Durability**: never introduce `:low` anywhere in the input→facts
  chain — durability propagates as the min and `:low` derived memos are
  dropped from the manifest (the fact memos are the bulk of the win).
- **Query values must survive `term_to_binary`** (manifest persistence).
- **Manifest layout**: `Scry.Runner`'s `@layout` is recorded in the
  manifest (`graph_layout`), and a manifest of another layout (or none)
  is dropped unread — a cold run. Bump it with any change that renames,
  removes or re-keys a query, or changes what a memo holds: an old memo
  naming a query that no longer exists raises when validated.
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
