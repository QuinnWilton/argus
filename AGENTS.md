# Working on Argus

Argus extracts facts from compiled BEAM files and runs Souffle Datalog analyses.
The Hex package and OTP application are `argus_beam`; modules use `Argus`.

## Setup and checks

Use Elixir 1.19 and OTP 28 (CI uses 1.19.4 / 28.3). Souffle must be on `PATH`;
without it `mix test` excludes the tests tagged `:souffle` and runs the rest
(under `CI` a missing souffle is an error). Tag a new test that solves with
`@tag :souffle`, or its `describe` or module with `@describetag`/`@moduletag`;
where most of a module or `describe` solves, tag it and opt the rest out with
`souffle: false`.

```sh
mix deps.get
mix test --exclude corpus
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Run checks relevant to the change; documentation-only edits need no tests. Start
with the affected test files. Plain `mix test` includes the closed-issue corpus,
which can fetch and compile external projects and is expensive when cold.

Use `ARGUS_ROUX_PATH=../roux` with Mix commands when testing unreleased Roux
changes. Extraction requires that checkout's query deadlines, packed traces and
reverse dependency tracking until a Roux release includes them.

| Change | Additional checks |
|---|---|
| Analysis rules | Positive fixtures and nearby counterexamples in `test/analyses/` and `test/soundness/`; add a corpus pair for a new bug class. |
| Batched fixtures or rules they exercise | `ARGUS_VERIFY_BATCH=1 mix test <test-file>` compares batch slices with separate solves. |
| Schema, cache keys or producer dependencies | `mix test --include identity_verify --exclude corpus`; use `ARGUS_NO_CACHE=1` to compare fresh results when needed. |
| Query graph or incrementality | `mix test --only parity`. |
| Frontends or packaging | `mix test --include escript --include rebar3 --include gleam --exclude corpus` with the relevant tools installed. |

For a focused corpus run, use `ARGUS_CORPUS_ONLY=redix#334 mix test --only corpus`
with an ID from `test/corpus/pairs.exs`. `mix argus.corpus tally` checks changes in
finding counts; do not update expected output merely to make a failure disappear.

## Where to edit

- `lib/argus/pipeline/` and `extractors/`: bytecode facts and domain extraction.
  `Argus.Instr`, `Instr.Reaching` and `Extractor.Resolve` provide instruction and
  register-flow semantics; do not duplicate their instruction tables.
- `lib/argus/schema/`: relation declarations. Regenerate
  `priv/dl/{base,layer2,priors}.dl` with `mix argus.gen.dl`; do not edit generated
  declarations directly. Schema shape changes require a changelog entry.
- `priv/dl/clientlib/`: shared rule concepts. `priv/dl/analyses/` detects defects;
  `lib/argus/analyses/` declares outputs and builds findings.
- `priv/dl/stage0.dl` and `points_to.dl`: shared whole-program stages. New staged
  outputs must also be exposed to their consumers. `mix argus.pins` refreshes
  `test/argus/analysis_inputs.exs`; review the input-set changes.
- `lib/argus/graph/`: incremental extraction and solving. `Driver`, `Project`,
  `Config` and `Report` serve the Mix compiler, CLI, escript and rebar3 integration.
  Keep rendering out of queries and analyzed projects' ebins off the VM code path.
- `docs/bug-classes.md`: finding guides. Read the
  [shared model](docs/design/analysis-model.md) and
  [rule guidance](docs/design/rule-style.md) when changing analysis behavior.

## Correctness constraints

- Facts must be deterministic across VMs. Use `Helpers.spell/1` for literal values
  and sort rows derived from atom-keyed maps or sets.
- A missing relation file is an error, not an empty relation. Writers must create
  empty files for empty outputs. Stages write into private scratch directories and
  atomically install outputs; never delete files from a caller's shared facts directory.
- Keep uncertainty explicit. A suppression must establish safety for the relevant
  operation and paths; preserve a nearby defect it must still report.
- Points-to fallback must be deterministic and a superset of exact results. Use
  row budgets, not elapsed time; keep corresponding coarse relations in
  `clientlib/pervasive.dl` when extending the exact pass.
- Keep shared fixpoints in stages rather than recomputing them in each analysis.
  Factor large disjunctive joins into helper relations to avoid multiplying work.
- Extractors using decoded facts must be listed in `Pipeline.typed_readers/0`, and
  their required relations in `Pipeline.typed_relations/0`.

## Cache and query constraints

- Read schema through its accessors inside the query. Do not cache returned values
  across queries. Record reads from spawned processes back in the caller with
  `Schema.Reads.record_all/1`.
- Code identity follows import closures. Dynamic dispatch needs an explicit tracked
  value or code root in `Argus.Graph.Code`. A producer's rows must not depend on
  which other producers run alongside it.
- Query values must serialize without PIDs or ETS tables. Hold referenced blobs
  with `Roux.Runtime.hold/1`; treat vanished blobs as cache misses and failures as
  transient. Do not use `:low` durability in the input-to-facts chain.
- Preserve warm-run shortcuts and the two-second guard against trusting fresh file
  timestamps. Cache-key changes must preserve incremental/fresh parity.

## Test and commit conventions

Use `Argus.Test.Memo` for shared solves and `Argus.Test.Batch` for disjoint fixture
sets. Tests are normally `async: true`; isolate VM-wide state with `Argus.Test.Peer`
or explain why a test must be synchronous. Deliberate rendering changes can update
goldens with `ARGUS_RECORD_GOLDENS=1`; review the resulting diff.

Commit subjects use `[component] brief description`; `.presubmit.exs` defines the
checks. Keep user-facing release notes in `CHANGELOG.md`, with implementation detail
in code and commit descriptions.
