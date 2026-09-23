# Changelog

## Unreleased

- What extraction could not do is reported beside the findings, as a
  warning that the analyses ran on partial facts (distinct from an
  analysis that degraded and reported nothing): a module that could not
  be extracted at all, and each step argus recorded as failing on a
  module (`extraction_error`, argus schema 55 — an extractor that
  raised, a module that outlived the per-module timeout). Neither is a
  permanent memo: a module whose extraction failed is extracted again
  on the next run (`:extraction_attempt`, a new frontend input), so a
  timeout under load heals by itself. `Scry.Analysis.extraction_errors/2`
  lists them; the runner's result carries `extraction_errors`. The
  application environment's `:scry, :extraction_timeout` overrides
  argus's per-module timeout.
- Fact files are written and read with `Argus.Tsv` (argus schema 55):
  a field holding a backslash, tab, newline or carriage return is
  escaped as argus escapes it. A function named with a tab used to
  write a row with one column too many, and Souffle refused every
  analysis that read the relation.
- An analysis that raises (argus's rules and code out of step, a bug)
  degrades with a diagnostic naming the exception, and the other
  analyses still report; it used to take the whole compile down.
- A fact directory another process prunes while Souffle is reading it
  is rebuilt and solved again, instead of reporting the analysis
  degraded; a relation file missing from the shared store, or replaced
  by something that is not one, when a directory links it is stored
  again instead of failing the run with `File.CopyError`.
- Typespec facts (argus schema 54) stay current incrementally. A
  module's extraction records the specs of the remote functions it
  calls, read off the code path; the environment fingerprint now
  includes `Argus.Specs.environment_digest/1` (every application on the
  code path, with its version, and a dependency outside OTP and Elixir
  also by its beams), so a dependency or OTP upgrade re-extracts, and so
  does a path dependency or umbrella sibling whose code changed without
  a version bump. The applications whose ebins the scan reads — the
  project, and its dependencies under `include_deps` — are left out:
  the graph tracks each of their beams itself, and a digest over them
  would re-extract every module on every edit. When the callee is one of the project's own modules, a
  caller's extraction now depends on the callee being there: removing
  it re-extracts its callers, whose memoized rows otherwise went on
  describing the removed module's specs.
- The analyses solve concurrently, up to one per scheduler: each solve
  is its own Souffle process, and everything upstream of the fact
  directories is computed once for whichever demands it first. A
  one-module removal on realtime (350 modules) went from 15.0s to 5.3s
  under the same machine load.
- The manifest no longer stores every module's facts twice.
  `module_semantic_facts` — the early-cutoff seam under a line-only
  edit — held a copy of `module_extraction`'s facts minus `line_info`;
  it now holds their digest (`{:ok, md5}`), and `program_relation_facts`
  reads the facts from the extraction through it. On logflare (859
  modules) that was 15 MB of an 85 MB manifest. The vsn attribute,
  meant to be left out of the seam, is: the filter matched the string
  rows extraction produced before rows were interned, and had matched
  nothing since.
- The scratch root's pruning no longer deletes the shared relation store.
  It pruned every directory beyond the 24 newest, and the store is a
  directory: once its mtime fell outside the window, every relation file
  went, and the next run stringified every relation again. Pruning also
  runs at most once a minute per VM instead of on every fact directory
  written.
- Labels on the same span of the same file render as one label whose
  messages join in order. A call cycle's anchor and the frame for the
  edge it starts sit on the same call, and drew two underlines of one
  span, each with its own tail ("one direction of the cycle" / "cycle
  edge A → B"); they now read `one direction of the cycle; cycle edge
  A → B` under one underline. The JSON report keeps every frame.
- A beam deleted between discovery and hashing (a concurrent compile
  pruning it) is left out of the run instead of crashing it in
  `File.stat!`.
- With `include_deps: true`, a module defined in more than one ebin is
  taken from the first — the project's own, then dependencies in path
  order — and reported with a warning naming the beam analyzed and the
  ones passed over. It used to be whichever ebin the scan read last.
  `Scry.Scanner.scan/1` returns `%{modules: ..., duplicates: ...}`
  (`Scry.Scanner.discover/2` over explicit ebins), and the runner's
  result carries `duplicates`.
- Configuration errors raise `Scry.ConfigError` (printed like
  `Mix.Error`, without a stacktrace) naming the entry's path
  (`:scry → :severity → :mailbx`), what was expected, and the valid
  name it most resembles (`did you mean :mailbox?`). Entries that were
  silently ignored now fail: a severity keyed by an unknown analysis, a
  severity level outside `:error`/`:warning`/`:info`, an unknown key
  under `ignore:`. `ignore: :nope` and a non-keyword config no longer
  crash with a `FunctionClauseError`. A severity keyed by a set
  (`severity: [default: :error]`) applies to each member, and later
  entries win.
- A related frame's line is refined from its source fragment (argus
  `Findings.related/3` `at_source:`) as a finding's is. An unreceived
  message's "the receive it never matches" frame now sits on the
  `receive`, bracketed to its last clause, instead of the function
  head the bytecode alone gives it.
- A failed solve no longer outlives the run it failed in. A solver
  crash, timeout or unloadable rules file was memoized as the
  analysis's result and persisted, so every later run replayed "the
  mailbox analysis degraded" until `--force`; now the failure, and
  everything computed from it, is dropped before the manifest is
  written, and the next run solves again. A failure to resolve the
  relations an analysis reads is reported as such instead of solving
  over none of them.
- A failed stage 0 (the shared call-graph derivation) no longer crashes
  the compile with a `MatchError`: the analyses that read the call
  graph degrade with a diagnostic naming it, the rest report as usual,
  and the next run derives it again.
- The environment fingerprint records Souffle's version and word size
  (`2.5 (64-bit words)`). It recorded the first line of `souffle
  --version`, which is a rule of dashes, so upgrading the solver never
  invalidated a memoized solve.
- Warm runs no longer serve findings from rules or extractors argus has
  since changed. The fingerprint keyed on the argus app version, which
  a rule or extractor commit does not move (and a path dependency never
  does), so a warm `mix compile` kept reporting what the old rules
  found until `--force`. `Scry.Fingerprint` now digests the argus and
  scry ebins into `:env_fingerprint` (any code change re-extracts), and
  each analysis's Datalog — its rules file, everything it includes, and
  the solver version — into a new `:rules_digest` input: a rule edit
  re-solves only the analyses whose programs contain the edited file,
  and re-extracts nothing. A solver upgrade re-solves without
  re-extracting.
- `mix compile` from an umbrella root no longer crashes with "umbrellas
  have no app": `compile.scry` is recursive, so Mix runs it inside each
  child that lists it (per-app analysis, as documented) instead of once
  at the root.
- A finding or related frame that closes a span (`to_instr`, argus
  schema 43) renders as a bracket from its anchor line to the end line —
  a guarded call through its `catch` — and the JSON report carries
  `end_line` on entries and related frames. Where the bytecode gave no
  end and the finding names the block its anchor sits in (`to_block`),
  `Scry.SourceAnchor.block_end/3` reads the source for it: the guarding
  `rescue`/`catch`/`after` clauses to their `end`, a `receive` to its
  `end`, a function clause to its `end`, or every clause of a function.
  Formatting is the evidence; any mismatch leaves the frame on its line.
  Prose that says `{guard}` — bytecode cannot tell a `rescue` from a
  `catch` — gets the keyword the source shows at the anchor
  (`Scry.SourceAnchor.guard_keyword/2`), or `handler`.
- A beam whose recorded source path is not on this machine — a moved
  checkout, a release built in a container — anchors at the longest
  tail of that path that exists under the project root (`:project_root`,
  a new frontend input the runner sets from the working directory), and
  at the beam itself only when nothing does.
- A finding that names a source fragment (`Argus.Findings` `at_source`)
  resolves to the first line at or after its bytecode anchor containing
  the fragment as a whole token (`Scry.SourceAnchor`). An unredacted
  secret now lands on its `field :api_key` line rather than `defmodule`:
  every function Ecto generates carries the `schema do` line, and the
  field's own line is only in the source. A bare underline marks an
  anchor whose analysis has no `at_label` (pentiment no longer draws an
  empty `╰──` tail).
- Priors: argus's layer-3 relations — a classifier's answers about
  names, with a probability (`Argus.Priors`) — as a roux input.
  `priors:` in the `scry:` keyword is `:off` (the default), `:cached_only`
  or `:live`, or a keyword with `mode:` and the `Argus.Priors` options
  (`cassette:` a JSONL file imported into the cache first, `cache_dir:`,
  `model:`, `oracle:`). `Scry.Priors.sync/2` sets `:prior_rows` for every
  prior relation on every run — empty when off — from the program's
  memoized relations, so the projections always find the file they
  expect, the findings without priors are the findings there always
  were, and with them a superset: a prior adds a finding marked
  heuristic or moves a severity, never removes a row. The rows live in
  the manifest at `:medium` durability, and `Input.set`'s cutoff means an
  unchanged answer re-solves nothing; a `:live` run without
  `TYPESAFE_API_KEY` fails at configuration. Resolved entries and the
  JSON report carry `provenance` (`:structural | :heuristic`) and
  `confidence` (the prior's probability in thousandths). Depends on argus
  0.19.0 (the v0.19.0 tag until it is on Hex).

## 0.1.24 — 2026-09-21

- argus 0.18 merged the relations inside each concern and turned witness
  lists (cycle edges, bottleneck callers, sink endpoints) into related
  frames of their finding. scry builds findings through
  `Argus.Findings.build/2` now instead of mirroring it, so those frames
  reach the diagnostics as related information and the info-grade
  witness findings are gone. Depends on the v0.18.1 tag until it is on Hex.

## 0.1.23 — 2026-09-21

- argus 0.17 regrouped its analyses by concern (one analysis answers
  "what goes wrong": `coupling`, `startup`, `mailbox`, `failure`, ...),
  and scry follows. The default set is argus's `:default`
  (`Argus.Analysis.set/1`) instead of a list of its own; diagnostic codes
  are the concern (`[scry.coupling]`, `[scry.mailbox]`); `analyses:` and
  the positional arguments accept the named sets (`:all`, `:default`,
  `:otp`, `:security`, `:effects`), and `mix scry --list` prints them. A
  retired name in `analyses:` or `severity:` still loads: it expands to
  the concerns its findings live in now, with a notice — the code on the
  finding is the concern's. The default set is wider than the six names
  it replaces: `mailbox` and `failure` bring the handle_info, monitor,
  contract and swallowed-error rules that `error_handling`,
  `monitor_leak`, `message_contract` and `reply_contract` held, so a
  project may see findings it did not before.
- Depends on argus (`panoptes`) 0.17.1 from its GitHub tag until it is on
  Hex.

## 0.1.22 — 2026-09-16

- panoptes ~> 0.13. Stage 0 now writes a fourth file, `call_tag.facts`
  (the message tag each call/cast sends, which the clientlib uses to
  resolve dynamic call targets); `stage0_facts` reads it and the
  analyses that declare it are fed from stage 0 rather than extraction.

## 0.1.21 — 2026-09-16

- Depends on `roux` from Hex (`~> 0.1.4`); every dependency is a Hex
  package now, so scry itself is published.

## 0.1.20 — 2026-09-16

- Depends on `panoptes` from Hex (`~> 0.11`) instead of a GitHub tag, so
  an argus release no longer needs a scry release to follow it.

## 0.1.19 — 2026-09-16

- Argus 0.11.0 is the `panoptes` package and application (the modules
  keep the `Argus` namespace); scry depends on `:panoptes`. `mix argus`
  is gone from argus — `mix scry` is the way to run the analyses.

## 0.1.18 — 2026-09-16

- Fixes 0.1.17, which sorted a module's memoized rows by symbol id. An
  id's value depends on the order the table met its symbol in — which
  parallel extraction does not fix — so row order, and everything
  downstream that keeps it (the supervision tree's resource lists),
  varied from run to run for the same beam. Rows are sorted as strings
  before they are interned.

## 0.1.17 — 2026-09-16

- **Memoized rows are interned.** Extraction hands back tuples of
  `Argus.Symbols` ids (argus 0.10.0's `format: :interned`) minted against
  one of the database's `Roux.Intern` tables, so the ids persist in the
  manifest with the rows they describe. Every copy of the fact set —
  the module memos, the program union, the per-relation slices, the
  served-value cache, the manifest — is a third to a fifth of its former
  size. On a 600-module project peak memory went from 4.2 GB to 2.2 GB
  (warm: 2.5 GB to 1.5 GB), a cold `mix scry --all` from 38 s to 30 s
  and a warm run from 5.0 s to 4.3 s; on a 64-module project the peak
  went from 639 MB to 324 MB. Findings are unchanged. New queries:
  `relation_rows` (interned) and `relation_digest` over the strings the
  files hold; `relation_facts` keeps returning strings for consumers
  outside this layer, and `Scry.Symbols.for_db/1` is the table to decode
  memoized rows with (planchette's focus path does).

## 0.1.16 — 2026-09-16

Performance: a cold `mix scry --all` on a 600-module project went from
126 s to 38 s, its peak memory from 7.7 GB to 4.2 GB, and a warm run
from 15.7 s to 5.0 s (on a 64-module project: 12.5 s → 7.0 s cold,
1.6 s warm). Findings are unchanged.

- **One pass over the modules builds every relation's rows.** The
  per-(module, relation) query it replaces read a module's whole fact
  map out of the memo table once per relation — 47,000 reads on that
  project, most of the run. `program_relation_facts` reads each module
  once; `relation_facts` is a lookup into it and still backdates per
  relation, so the projections and solves downstream validate without
  executing exactly as before. `module_relation_facts` is gone.
- **Fact directories are named from per-relation digests**
  (`relation_digest`), computed once per relation change rather than by
  re-serializing every projected row per analysis, and each relation's
  file is written once under `scry_souffle/relations/` and hard-linked
  into every directory that projects it.
- **Extraction runs across the schedulers.** The graph executes one
  query at a time, so every module was extracted serially; the runner
  now extracts the modules that cannot be memo hits in parallel before
  demanding, and `module_extraction` picks the result up (keyed by the
  canonical beam's digest, so a beam that moved in between is extracted
  again).
- **An unchanged run does not rewrite the manifest.** No input moved, so
  no revision advanced and every entry is as the manifest already has
  it; rewriting it was most of a warm run.
- Roux 0.1.3: memo hits are served from a per-process cache instead of a
  fresh copy out of ETS on every read, and manifests serialize memo
  entries one at a time (format 2 — the first run after upgrading is
  cold).

## 0.1.15 — 2026-09-16

- Argus 0.9.1 (schema 31): `whereis_race` only for results used without
  a nil check, and a literal `System.cmd` command no longer counts as
  code execution whatever its arguments. Warm manifests re-extract once.

## 0.1.14 — 2026-09-12

- Argus 0.9.0: the memory release. No finding changes. Solves that
  joined the call graph's transitive closure (up to 690 MB each on a
  2,400-module project) now propagate from the few functions that
  matter and run in under 160 MB; the batch extractor streams facts to
  disk instead of holding the program's fact set in memory. Scry's own
  per-module extraction and per-analysis solves pick both up unchanged.

## 0.1.13 — 2026-09-12

- Argus 0.8.1: no analysis changes; `mix argus` and the project script now
  point a missing `souffle` at the install page before extracting.

## 0.1.12 — 2026-09-12

- Fixes 0.1.11, which listed the `Argus.Extractors.Ports` extractor argus
  0.8.0 folded into `Argus.Extractors.ApiCalls`; every extraction raised
  `UndefinedFunctionError`. The resource extractors the supervision-tree
  overlay needs are now `ETS` and `ApiCalls`.

## 0.1.11 — 2026-09-12

- Argus 0.8.0 (schema 30): the consolidation release. No finding scry
  reports changes except the ETS false positive it fixes on Erlang
  application modules; extraction is 9-37% faster on the corpus.

## 0.1.10 — 2026-09-11

- Pins argus v0.7.3. 0.1.9 said it did and still pinned v0.7.2; a
  project depending on both scry and a newer argus saw a divergence.

## 0.1.9 — 2026-09-11

- Elixir requirement lowered to `~> 1.18` (roux v0.1.1, argus 0.7.3);
  OTP 28 remains required. The compiler's fixture projects declare the
  same.

## 0.1.8 — 2026-09-11

- Argus 0.7.2: `init_waits_on_blocking_server` counts only unbounded
  handler operations; `permanent_child_stops_normally` and inferred
  `rest_for_one_orphaned_children` rows are `:info`.

## 0.1.7 — 2026-09-11

- Argus 0.7.1 (schema 28): `monitor_leak` reports a monitor whose ref is
  discarded at the call site, and reaches helpers through closures.

## 0.1.6 — 2026-09-11

- Argus 0.7.0 (schema 27): ten new rules from replaying historical OTP
  bug fixes — supervisor management calls from `init/1`, an init waiting
  on a server whose handler blocks, permanent children that stop
  themselves, `rest_for_one` owners of processes in earlier siblings,
  `trap_exit` without an `{:EXIT, ...}` clause, `handle_info/2` without a
  catch-all, monitors a server never releases, write-only ETS tables,
  gen_statem states without an `:info` catch-all and timeouts nobody
  handles. Trees built with `Keyword.get/3` defaults and cons-built child
  lists extract in source order.

## 0.1.5 — 2026-09-11

- Argus 0.6.1: supervision trees defined outside `Supervisor` modules
  (a GenServer's `init/1` calling `Supervisor.start_link/2`) and child
  specs built by helpers and comprehensions are extracted, so more
  `sync_call_in_init` findings are proven safe by an earlier sibling.

## 0.1.4 — 2026-09-11

- Argus 0.6.0: stage 0 now also yields `unconditional_call_edge`, which
  the fact projections carry like `call_edge` and `call_site`;
  `sync_call_in_init` findings say whether the blocking call is
  conditional on a branch in `init/1`.

## 0.1.3 — 2026-09-11

- Argus 0.5.1: literal facts drop Logger location metadata (a comment
  above a `Logger.warning` no longer re-solves analyses), coupling
  findings are graded call vs cast, unverified `sync_call_in_init` rows
  are `:info`, and any module with `handle_info/2` counts as consuming
  its task replies.
- Beams are hashed and memoized in canonical form (`Scry.Beam.canonical/1`
  drops the `ExCk` and `Docs` chunks). Elixir rewrites the `ExCk` chunk of
  every compile-time dependent when a module is recompiled, so a
  comment-only edit re-extracted two to six modules on the projects
  surveyed (Finch, Postgrex, Oban, Cachex, ...) before the semantic
  cutoff caught them; now it re-extracts exactly the edited one.

## 0.1.2 — 2026-09-11

- `mix scry` compiles with `--no-prune-code-paths`. In a project with an
  explicit `applications:` list, Mix's code-path pruning removed scry
  itself after the compile step and the task died with `Scry.Config is
  not available` (found on `amqp`). The `:scry` compiler in such projects
  needs `prune_code_paths: false`; the README says so.

## 0.1.1 — 2026-09-11

- `makeup_elixir` and `makeup_erlang` are optional dependencies. A hard
  dependency collided with the `only: :docs` / `only: :dev` restriction
  projects put on the makeup lexers (Phoenix declares them that way, and
  ex_doc pulls them in `only: :dev` everywhere else), which made scry
  impossible to add to such a project. Add the lexers to your own deps to
  keep highlighted terminal frames; without them frames render plain.

## 0.1.0 — 2026-09-11

Initial release: an analysis-only Mix compiler for BEAM projects.

- **Scry is the compiler and the shared analysis layer, nothing more**:
  the supervision tree, flowistry focus/slicing, and the debug twin
  (`Scry.SupTree`, `Scry.Flow`, `Scry.DebugSlice`, and the
  `supervision_tree`, `refined_line_table`, `debug_twin`,
  `debug_bundle`, `module_flow`, `function_flow` queries) moved to
  planchette, whose LSP is their only consumer and the only frontend
  that supplies the `source_text` input they need. Query names are
  unchanged, so planchette manifests stay warm. Scry no longer depends
  on gloss or beam_spy.
- **Extraction memos follow the argus schema**: `module_extraction`
  now reads `env_fingerprint` (which carries `Argus.Schema.version/0`),
  so a warm manifest re-extracts after an argus upgrade instead of
  serving rows the previous encoder wrote. The compile-time
  `Argus.Schema.Pin` is gone with it — argus removed the mechanism.
- **Labels span the line's code**: finding anchors render as inline
  labels under the anchored line's code extent (first non-blank column
  to the end of the trimmed line) instead of column-1 bracket labels.
  BEAM anchors are still line-granular; a source line that cannot be
  read degrades to a one-column span.

- **Syntax-highlighted terminal diagnostics**: the stderr frames now
  colorize their source excerpts (via pentiment's optional makeup
  lexers, included as scry dependencies). The `details` field on
  `Mix.Task.Compiler.Diagnostic` and the sidecar remain plain text.

- **The shared analysis layer**, extracted verbatim from planchette:
  `Scry.Analysis` (per-module argus extraction → semantic-facts cutoff
  seam → per-relation projections → content-addressed Souffle fact
  dirs → solve → line-free findings → late line resolution). Query
  names are the ABI — planchette's LSP consumes the same layer with its
  in-memory compile frontend. `souffle_solve` re-materializes its fact
  directory when a concurrent prune removed it (the scratch window is
  shared between LSP sessions and compiler runs).
- **`mix compile.scry`** (`compilers: Mix.compilers() ++ [:scry]`): a
  disk-beam roux frontend over the ebin the stock compilers just
  wrote, with cross-run incrementality via `Roux.Lang.Manifest` — a
  warm run re-analyzes nothing, a comment-only edit re-extracts one
  module and re-runs zero solves, and prior findings re-emit from memo
  hits on every run. Configuration under the `scry:` project key:
  `analyses`, per-analysis `severity` overrides, `ignore`
  (modules/files), `include_deps`, `fail_on`, and `souffle`
  (`:warn` degrades with one notice and demands no solves — nothing
  poisons the manifest, and the souffle version in the environment
  fingerprint heals everything when the solver appears; `:require`
  makes it an error).
- **Pentiment-rendered diagnostics**: labels on the line-granular
  anchors annotated with the finding's `at_label`,
  cross-file evidence as `├─` continuation frames against their own
  files, detail as a note, and `help` remediation trailers. Editors
  get a short message + line via the standard compiler diagnostics;
  terminals get the full frame.
- **`mix scry`**: the credo-style one-shot over the same manifest —
  positional analysis selection, `--all`, `--list`, `--format json`
  (stable machine schema), `--fail-above N`, `--include-deps`,
  `--force`.
