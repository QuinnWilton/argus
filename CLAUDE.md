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
   %{path, mtime, size, hash}, :medium), `module_set`, `env_fingerprint`
   (:high); queries `module_beam` (disk read; the tracked signal is the
   hash input), `file_of` (beam compile_info source, realpath-normalized),
   `module_map`. Registers the same query names as planchette's frontend —
   **query names are the ABI** (roux dispatches by name; memo keys are
   {query_name, key}).
2. **Analysis** (`Scry.Analysis`): never rename a query, never change a
   key or value shape without planchette in the same review.
   `Scry.Fingerprint` stamps what the graph depends on beyond the
   beams: `env_fingerprint` (runtime, schema, and digests of the argus
   and scry ebins — read by `module_extraction`, stage 0, the solves and
   findings, so any argus code change re-extracts) and a per-analysis
   `rules_digest` (the analysis's `.dl` and its transitive includes,
   plus the souffle version — read by `analysis_input_relations`,
   `stage0_facts` and `souffle_solve`, so a rule edit re-solves exactly
   the analyses it touched and re-extracts nothing). A frontend that
   never sets `rules_digest` (planchette) reads it as nil. The LSP-only surface —
   supervision tree, flowistry focus/slicing, the debug twin — lives in
   planchette (`Planchette.SupTree`, `Planchette.Focus`) and registers
   its own queries next to these.

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
  `Mix.Project.in_project/3` + `Mix.Task.rerun("compile")` — the real
  chain, so `:elixir` genuinely produces the beams scry reads. The
  fixture's cold-build findings (two couplings at the tree definition,
  one leaked task) and rendered frames are golden-pinned; keep it
  self-contained and dependency-free.
- Telemetry edit-replay tests assert exact recompute sets
  (`test/support/query_log.ex`).

## Non-goals (v1, keep the README honest)

Umbrella-wide analysis (per-app only; `include_deps: true` is the
escape hatch), incremental Datalog, focus/slicing and
the supervision tree (planchette's LSP defines those queries over this
layer; scry never demands them).

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an
`## Unreleased` section at the top.
