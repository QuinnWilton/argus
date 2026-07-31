# Changelog

All notable changes to Argus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.0 — Unreleased

Autoresearch loop — the tooling layer that turns the 0.4.0 measurement
surface into an iterative improvement workflow. Measure a corpus,
baseline the results, edit an extractor, re-measure, diff, accept or
revert, repeat. Inspired by pi-autoresearch's event-log + living-doc
pattern, adapted for Argus's multi-dimensional categorical metrics.

### Fixed (performance)

- `clientlib/cfg.dl` no longer forces `.output cfg_edge`. The directive
  made Souffle materialize and write the control-flow graph on every
  solve even though no analysis reads `cfg_edge` or `cfg_reachable`, and
  every consumer then parsed the CSV back in only to discard it. Over a
  555-beam corpus that was ~10.3M rows / ~1.07GB written per solve; a
  single `unsafe_task` run went from 4.03s to 0.56s (7.2×), with
  byte-identical output. Analyses and tests that genuinely want the
  relation now declare `.output cfg_edge` themselves.

### Fixed (precision — 15-project OTP corpus audit)

Ran every analysis against 15 OTP libraries (bandit, broadway, cachex,
commanded, db_connection, finch, gen_stage, horde, libcluster,
nimble_pool, oban, phoenix_pubsub, quantum, redix, swarm) and verified
each finding against source. Total findings fell from ~260 to 88 with no
true positive lost; the remaining findings are the verified real ones
(the two `atom_safety` errors, Oban's coupling, the genuine timeout
chains) plus intentional-pattern warnings. Five analyses had systematic
false-positive mechanisms:

- **`gen_statem` (108 → 0, all false).** Three root causes.
  `state_functions` mode treated every arity-3 function as a state; it is
  now an arity-3 function that is exported, not called locally, and
  returns a gen_statem action — which excludes private helpers, compiler
  closures, exported client wrappers (`connect_to_node/3`), and
  action-returning helpers a state calls (`disconnect/3`). The initial
  state was inferred topologically, letting a dead state that transitions
  out masquerade as the entry point; it is now read from `init/1`'s
  return (schema v6 `statem_initial`). `handle_event_function` mode
  harvested every atom in `handle_event/4` (`:DOWN`, `:badarg`, module
  aliases) as a state; the structural rules are now scoped to
  `state_functions` mode. `extract_transitions` also models the remaining
  action forms (`repeat_state`, `stop_and_reply`, bare
  `:keep_state_and_data`), so every state now implies a transition —
  making `coverage_statem_no_transitions` unfireable, and it is removed.
- **`timeout_chain` (32 → 3).** All 29 false positives came from one
  `callback_sync_dep` clause built on `stateful_module_dep`, which (via
  its module-level heuristic) counted reaching a *pure* function
  (`Config.get/2`, an ETS read) as calling that module's server, never
  tied the dependency to the handle_call, and pulled `async_cast` edges
  into a "synchronous" chain. The clause is removed; the genuine chains
  derive from the `genserver_sync_api` rules. `timeout_chain_risk` gains a
  `[:from, :to]` dedup key so a cycle yields one finding, not one per
  depth.
- **`error_handling` (25 → 8).** `swallowed_error` never checked that the
  handler discards the exception — the idiom
  `catch kind, reason -> {:error, …}` was flagged; a liveness scan now
  clears a handler that reads the caught exception registers before
  overwriting them, and `raw_raise` (the OTP-21 compiled form of
  `:erlang.raise/3`) is recognized as a re-raise.
  `trap_exit_without_handler` no longer fires on gen_statem modules
  (which receive `{:EXIT, …}` in state functions). `exit_in_callback` no
  longer treats `:erlang.exit/1` (a let-it-crash self-exit) as an
  imperative kill, and is downgraded to `:info` since a `Process.exit/2`
  in a callback is usually a deliberate protocol.
- **`distributed` (21 → 5).** `rpc_in_genserver_callback` reported RPCs
  reachable transitively through a guarded dispatcher (Cachex's
  `Router.route`, whose clauses the function-granularity call graph
  collapses) — all 13 corpus findings were false; only an RPC directly in
  a callback is now reported, and the sites stay covered by
  `rpc_without_timeout` (whose message no longer claims "default" for an
  explicit `:infinity`).
- **`supervision` (1 → 0).** `wrong_start_order` fired on `init_reaches`,
  which counts a child's `init/1` calling any function in a dependency's
  module — including a pure helper (Horde's
  `NodeListener.make_members/1`). It now requires an actual process
  interaction (sync call / cast) to the dependency at init.

The harness (`scripts/harness.exs`, `analyze_project.exs`) was
modernized for this audit: it runs every analysis by default, and the
report gains an `otp_findings` section — severity-ranked findings with
source-line-resolved anchors — feeding a cross-project `triage.json`
index. Fixes along the way: ebin discovery now finds `_build/shared`
(projects with `build_per_environment: false`), and `--resume` rebuilds
the triage index from all results on disk rather than clobbering it.

### Added

- **`port_open` relation + Ports extractor (schema version 7).** A new
  `Argus.Extractors.Ports` records external port creation sites —
  `Port.open`/`:erlang.open_port` (Elixir's `Port.open` compiles to the
  latter), `System.cmd`, `System.shell`, `:os.cmd` — as
  `port_open(id, func, mechanism, target)`, with the spawned
  command/executable resolved when it's a literal. A port is owned by the
  opening process and dies with it, so consumers can attribute it to that
  process in the supervision tree, the same way ETS tables are.
- **Dataflow primitives for value provenance.** `Argus.Extractor.Helpers`
  gains `recent_writer/3` (the most recent instruction that wrote a
  register, raw — for inspecting provenance) and `keyword_value_register/4`
  (the register holding a given key's value in a runtime-built keyword
  list — for tracing a computed option like `name:` back to its source).
  `call_result_origin/3` now also reports **local** (`call`) origins, not
  just remote ones, so a value produced by a `defp` helper can be traced
  into that helper. General-purpose backward-dataflow building blocks.
- **Via-tuple (`Registry`) registration names.** The supervision extractor
  recognizes children registered under `{:via, Registry, _}` tuples built
  by a `*.Registry.via(name, role)` helper (the Oban idiom), recording the
  static *role* as the child's registered name — on both the registration
  side (`{DynamicSupervisor, name: Registry.via(conf.name, Foreman)}`) and
  the `start_child` side (`start_child(Registry.via(conf.name, Foreman),
  _)`, resolved through one level of local helper). So a queue supervisor
  Oban starts into the "Foreman" via nests under the DynamicSupervisor that
  holds it, instead of appearing unanchored. The runtime registry name is
  dropped — anchoring matches on the role alone, a deliberate
  over-approximation (correct for a single library instance).
- **`supervisor_child_name` relation (schema version 4).** A child spec's
  registered `:name` option — the `MyApp.Pool` in
  `{DynamicSupervisor, name: MyApp.Pool}` — recorded alongside
  `supervisor_child` by `{sup, position}`. Lets a consumer anchor a
  `dynamic_child` parented by a registered name (the parent of
  `DynamicSupervisor.start_child(MyApp.Pool, _)` is the *name*, not any
  module) to the child that registers it. Only atom names are recorded;
  `{:via, _, _}`/`{:global, _}` names are not, since name-based
  `start_child` targets are always atoms.
- **`use DynamicSupervisor` modules recognized as supervisors.** The
  supervision extractor now emits a `supervisor` fact for
  `DynamicSupervisor` behaviour modules (strategy read from
  `DynamicSupervisor.init/1`, `:one_for_one` otherwise — the only strategy
  the behaviour accepts). A `start_child` call whose supervisor argument
  can't be resolved to an atom now anchors to the enclosing module when
  that module is itself a supervisor (the idiomatic `start_x(sup, …)`
  helper), instead of dropping to the `"dynamic"` sentinel.
- **In-memory embedding surface.** `Argus.Pipeline.extract/2` accepts
  raw beam data binaries alongside module atoms and `.beam` paths
  (recognized via `BeamSpy.BeamFile.beam_data?/1`), and
  `Argus.Pipeline.write_facts/2` is public, so embedders that hold
  bytecode in memory and merge per-module fact maps themselves can
  produce a Souffle-ready facts directory without temp-file round
  trips. Together with `Argus.Analysis.run_rules/3` and
  `Argus.Analysis.filter_to_outputs/2`, this is the blessed surface for
  incremental consumers (the lowdown pattern: assert
  `Argus.Schema.version/0` at compile time and decode with
  `Argus.Facts.decode/1`).
- **Post-dominators and control dependence on `Argus.Cfg`.**
  `Cfg.Function` gains `ipdom` (immediate post-dominators — the same
  Cooper–Harvey–Kennedy fixpoint over the reversed CFG from a virtual
  `:exit`; blocks that never reach the exit are absent),
  `postdominates?/3`, and `control_deps/1` (Ferrante–Ottenstein–Warren
  block-level control dependence). In-process API only — no fact-schema
  change. Powers planchette's flowistry-style slicing.
- **`Argus.Lines`** — line tables built from `line_info` facts
  (`from_facts/1`, `from_facts_dir/1`) with best-effort `resolve/2` for
  instruction IDs (exact line), function IDs and MFAs (first line), and
  `Argus.InstrId` structs. `mix argus` text output and
  `scripts/analyze_project.exs` now annotate every resolvable ID cell
  with its source line.

### Changed (schema version 3) — per-line finding anchors

- **`line_info` covers every instruction.** Rows were emitted only at
  the `{:line, ref}` markers themselves, but anchors name *call-site*
  instruction IDs — so an exact `by_instr` lookup could never hit and
  every consumer silently degraded to function-first-line resolution.
  The emitter now tracks the line in effect and stamps it onto each
  instruction until the next marker; a no-location marker (reference 0,
  compiler-generated code) resets it to unknown, so generated code never
  inherits a source line it isn't from. Instruction-level anchors now
  resolve to their exact source line.
- **`supervisor` gained a `site` column** — the instruction ID of the
  `Supervisor.init`/`start_link` call (or Erlang-style flags literal)
  that defines the tree, `"dynamic"` when not statically found — and
  **`statem_state` gained a `site` column** (the state function in
  `state_functions` mode, the matching instruction in `handle_event`
  mode). Both are trailing additions; the schema version bump to **3**
  covers the `line_info` meaning change and these shape changes.
- **Every module-anchored finding now carries a per-line anchor.**
  Analysis output relations gained witness columns threaded from their
  rule bodies (`stateful_module_dep`, `init_reaches`, `module_reaches`,
  `sync_dep`, `sync_caller` and friends now carry the witnessing
  function; `ets`/`process_registry`/`distributed` relations carry the
  already-bound instruction), and `finding/2` anchors upgraded from
  `at_module` (line 1) to the witness. Only `coverage`'s absence
  findings stay module-level — they have no code location by nature.
- **Supervision-family findings anchor at the tree definition.**
  `one_for_one_coupling`, `wrong_start_order`, and
  `suspect_transient_dependency` now anchor at the supervisor's
  strategy line — the defect is the composition and that is where the
  fix goes — with the coupling call demoted to a labelled related
  location in the child.
- **The coupling analyses no longer overlap.**
  `unlinked_coupled_siblings` was `one_for_one_coupling`'s rule plus a
  link-negation — a strict subset, so running both analyses reported
  every unlinked coupled pair twice (four stacked diagnostics on one
  strategy line). The link-exclusion now lives inside
  `one_for_one_coupling` itself (a linked pair's exit propagates and
  both restart together — the hazard is already mitigated, so this is
  also a precision win), `unlinked_coupled_siblings` is removed, and
  the duplicated `wrong_start_order` keeps a single home in the
  `supervision` analysis. On eusapia: `one_for_one_coupling: 2`
  (unchanged), `supervision` now passes.
- **Witness rows deduplicate deterministically.** A relation provable
  through several call sites yields one Souffle row per witness; output
  relations now declare a `:key` (the fields that identify a logical
  finding) and `Argus.Findings.dedupe_rows/2` — public for in-process
  embedders — keeps the lexicographically least row per key, so finding
  counts never depend on witness multiplicity or row order.

### Fixed (analysis rules; schema version 5)

Five shipped rules produced wrong output; all five lived in analyses
that had **no analysis-level tests** (only their input extractors were
tested), which is how they shipped. Each fix lands with a new
`test/analyses/` file pinning positive and negative cases through real
Souffle — every analysis now has one.

- **`ignored_start_result` had never fired.** Souffle's
  `contains(needle, haystack)` takes the needle first; the rule asked
  "is the callee a substring of `'start_link'`" — false for every real
  callee, so the relation had never produced a row. Fixed the argument
  order and matched the delimited name (`.start_link/`, `.start/`) so
  `Mod.restart_link/1` cannot substring-match. Audited every other
  `contains()` in `priv/dl`: none had a swapped needle.
- **`timeout_insufficient` flagged the default-vs-default chain.**
  `t_ab <= t_bc` marked two chained calls both using the
  `GenServer.call` default (5000 vs 5000) as an `:error` — the
  universal configuration. The comparison is now strict (the equality
  trade-off is documented in the rule), and the via-API timeout rules
  no longer attribute an unrelated resolved sync call's timeout to the
  wrapper's module (callee must be the target module or `"dynamic"`).
- **`distributed` flagged any module's `init/1`.** Its local
  `init_function` had no behaviour gate, so a plain module's ordinary
  `init/1` was treated as supervisor startup; now uses the clientlib's
  behaviour-gated rule. Also: `:net_kernel.monitor_nodes` in init was
  flagged (the exclusion tested `"monitor"` but the extractor emits
  `"monitor_nodes"` — a subscription flag, not a connection attempt),
  and `global_register_risk` fired on `:global.register_name/3` — the
  arity that supplies a conflict resolver, i.e. the fix for the race
  being reported. `global_register` gained a trailing arity column
  (**schema version 5**) and the rule flags only `/2`.
- **`gen_statem` structural rules gated on extraction confidence.** A
  module whose transitions failed to extract (delegating state
  functions, unrecognized return shapes) had every state flagged both
  unreachable AND terminal — extraction-gap noise presented as
  findings. Both rules now require a concretely-resolved transition in
  the module (`coverage_statem_no_transitions` still reports the gap),
  and `unreachable_state` requires no dynamic-target transition. The
  unused `statem_timeout` input and the moduledoc's advertised-but-
  unimplemented timeout/nondeterminism checks are gone.
- **`supervision` now flags `:temporary` siblings.**
  `suspect_transient_dependency` matched only `:transient`, missing the
  strictly-worse case (a temporary child is never restarted, not even
  after a crash). Renamed to `suspect_nonpermanent_dependency` with a
  `restart` column covering both policies.
- Known limitation now pinned by a test: `trap_exit_without_handler`
  cannot fire for `use GenServer` modules — the macro compiles a
  default `handle_info/2` into every module, so the
  function-existence heuristic is vacuous for idiomatic Elixir code. A
  real fix needs clause-level pattern facts. Also dropped the unused
  `registry_op`/`via_tuple`/`named_process` input declarations.

### Fixed (schema version 2)

- **`line_info` now carries real source lines.** The emitter passed
  beam_disasm's `{:line, ref}` operand straight through, so the `line`
  field held a Line-chunk *reference* despite being documented as a
  source line number. The Disassemble stage now parses the module's Line
  chunk (`BeamSpy.Source.parse_line_table/1`) and the emitter resolves
  every marker at emit time. No-location markers (reference 0, on
  compiler-generated code) and modules without a parseable Line chunk
  emit no rows — `line_info` never contains raw references. The schema
  version is bumped to **2** for this meaning change; the relation's
  shape is unchanged.

### Fixed

- **Same-module supervisor children no longer collapse.** Child spec
  dedup keyed on the module alone, so three `{DynamicSupervisor, name: …}`
  children (or two `Livebook.Utils.SupervisionStep` steps) were recorded
  as one. Dedup now keys on `{module, registered_name}`, so children that
  register different names stay distinct; nameless same-module duplicates
  still collapse (nothing distinguishes them).
- **`debug_line` markers resolve to source lines.** OTP 28 debug builds
  (`beam_debug_info`) carry a `debug_line/4` on every executable line;
  the emitter now treats it as a line marker (same sticky semantics as
  `line`), so `line_info` covers debug twins — including the pure-data
  lines the production build never marks. `executable_line` stays
  ignored.
- **Calls now carry def/use facts.** No call form emitted `use` facts
  for its argument registers (x0..x(arity-1)), and label-form local
  calls missed their `def x0` — so data dependence broke at every call
  boundary and a pipeline (a chain of calls threading x0) produced no
  def→use edges at all. Every call form (`call`/`call_ext`/`call_fun`/
  `call_fun2`/`apply` and the tail variants) now emits argument uses,
  and returning forms define x0. `Argus.Dataflow` edges flow through
  call chains; lowdown's line-mapping goldens moved where Rule A can
  now pull argument-setup moves to their consuming call's line — the
  drift its goldens had documented as a known-coarse gap.
- **Supervision children survive runtime list construction.** One
  runtime element in a children list (the stock Phoenix `Application`
  shape — `{DNSCluster, query: Application.get_env(...)}`) splits the
  list into cons cells, and the extractor missed every literal member
  riding in `put_list` operands (bare module heads, the literal tail) —
  zero children extracted, `⚠ children not statically resolved`. The
  extractor now recovers members from cons construction (membership
  over perfect ordering: elements interleaved with runtime construction
  can land out of position), and the runtime-tuple scan accepts any
  `Elixir.`-prefixed module atom instead of requiring the module to be
  loadable in the analyzing VM — the analyzed project's deps never are.
- **Concurrent VMs no longer share temp directories.** Analysis work
  dirs and Souffle output dirs were named with `System.unique_integer/1`
  alone — a VM-local counter — so concurrent `elixir` subprocesses
  (e.g. `mix argus.autoresearch measure`'s per-project workers) drew the
  same names and silently clobbered each other's facts mid-run, making
  corpus measurements nondeterministic (the long-standing "47 vs 73 vs
  146" variance; three of five projects could return byte-identical
  reports for the wrong codebase). Names now include `:os.getpid()`.
  Consecutive corpus measures are exactly reproducible.
- **The `:dynamic` placeholder atom can no longer leak into facts.**
  Partial register resolution marks unknown structure components with
  the `:dynamic` atom; three paths let it escape into fact fields as
  the string `":dynamic"`, which every `"dynamic"` filter in the rules
  fails to match. `resolve_register/3` now reports a top-level
  placeholder as unresolved, and the GenServer `name:` option /
  `{:local, name}` / via-tuple consumers guard their nested slots.
  On the corpus this removed two forged
  `coverage_named_process_unreachable` rows (phoenix_pubsub) and
  surfaced two honest `gen_server_start_name` imprecision events in
  their place.

### Changed

- **`atom_safety` and `whereis_race` rows anchor at the call site.**
  `atom_exhaustion_risk`, `unsafe_deserialization_finding`,
  `code_injection_risk` (now `(id, func, api)`) and `whereis_race` (now
  `(id, func, name)`) carry the offending instruction ID, and the
  exhaustion/injection rules key rows by site instead of by reaching
  export (one row per unsafe call, anchored where the fix goes, rather
  than one per exported entry). Consumers of these output relations
  must account for the new leading `id` field.

### Added

- **`Argus.Extractor.Helpers.call_result_origin/3`** — traces a register
  back to the remote call whose result it holds, following move chains
  with sound register lifetimes (y registers survive calls; non-x0 x
  registers stop at call boundaries). The ETS extractor uses it to map
  operations on table references back to their same-function
  `:ets.new/2` site, so create-and-seed patterns join their `ets_new`
  rows by name instead of falling back to `"dynamic"`. (Both corpus
  tiers are unchanged by this — their remaining ref-based ops live in
  different functions than the creation, which needs cross-function
  dataflow.)
- **`Argus.run_analyses/2` — structured findings API.** Runs a selection
  of built-in analyses (`:all` by default, excluding the `coverage`
  meta-analysis) against one shared fact extraction and returns
  `{:ok, %Argus.Findings{}}`: every output-relation row becomes a finding
  map (`%{analysis, severity, title, detail, module, mfa, instr,
  related}`) with prose explaining why it matters and the most precise
  code anchor the row allows (instruction ID → `Argus.InstrId`, function
  ID → `{m, f, a}`, module string → module atom). Severities are assigned
  per relation by each analysis module's new optional `finding/2`
  callback and documented in its moduledoc. Degradation is explicit:
  missing Souffle → `{:error, :souffle_not_found}`; a single failing
  analysis → a `degraded` note while the others still run. Analyses
  share one facts directory (new `Argus.Analysis.extract_facts/3` +
  `run_rules/3`, which `Argus.Analysis.run/3`, the mix task, and the
  report builder now all compose) and evaluate in parallel — all 15
  analyses finish in ~250 ms for a single module.
- **`Argus.InstrId.parse_func/1`** — parses function ID strings
  (`"Mod:func/arity"`, the instruction ID format without `#idx`) with
  the same right-anchored rules as `parse/1`.
- **`Argus.Dataflow`** — reaching definitions over Layer-1 facts:
  `def_use_edges/1` returns the def→use edge set (which instruction's
  register write feeds which read), computed block-locally (straight-line
  chains, gen/kill summaries, worklist fixpoint, one local resolution walk).
  The successor relation comes from the explicit control-transfer facts
  (`next`/`jump`/`branch`/`select_branch`); exception and bif-fail edges
  are deliberately not followed (the handler's VM-materialized `x0`–`x2`
  have no `def` facts, so following them would fabricate flows).
- **`type_test` facts for the structural pattern tests.** `is_nonempty_list`
  and `is_tagged_tuple` now emit `type_test` rows alongside the guard-style
  unary tests. Both type-test their first operand (the `src` field);
  `is_tagged_tuple`'s arity/tag operands are not recorded. The relation
  shape is unchanged — only its row coverage grows.
- **Typed fact API for in-process consumers.** `Argus.Pipeline.extract/2`
  accepts `format: :typed`, decoding rows against the schema via the new
  `Argus.Facts.decode/1` — field-name-keyed maps with integers for
  `number`/`label` fields and `Argus.InstrId` structs (right-anchored parse,
  safe for generated `-fun-N-` names) for instruction IDs. The Souffle
  `.decl`/`.facts` surface is byte-identical: the new semantic field kinds
  (`:instr_id`, `:func_id`, `:label`) collapse to `symbol`/`number`.
- **`Argus.Schema.version/0`** — a fact-schema version (now 1) for consumers
  to assert against at compile time; bumped on any relation/field change.
- **`Argus.Cfg`** — basic-block control-flow graphs from Layer-1 facts:
  leader-algorithm blocks with typed edges (fallthrough/jump/branch-pass/
  branch-fail/select-arm/select-fail/exception), a dominator tree (iterative
  Cooper–Harvey–Kennedy over reverse postorder), natural-loop headers, and
  per-function entry resolved from `function_def`'s entry label (instruction
  0 is the func_info failure pad, not the entry). Region/dominance helpers
  on `Argus.Cfg.Function`.
- **Receive-loop control-flow facts.** `loop_rec` now emits its empty-mailbox
  branch, `loop_rec_end`/`wait` their loop-back jumps, and `wait_timeout` its
  message-arrival branch — receive loops previously had no back edges in the
  fact base, so no analysis could see them as loops.

- **`mix argus.autoresearch` Mix task** with 9 subcommands:
  `init`, `measure`, `diff`, `rank`, `checks`, `accept`, `revert`,
  `status`, `note`. Each wraps a public API function in
  `Argus.Autoresearch` so the logic is unit-testable.
- **Corpus measurement** (`Argus.Autoresearch.Measure`) — parallel
  per-project subprocess fanout extracted from `scripts/harness.exs`.
  One implementation, two entry points. Ebin discovery via runtime
  `:code.get_path/0` (replaces harness's compile-time `Path.wildcard`).
- **Canonicalized snapshot** (`Argus.Autoresearch.Snapshot`) — reduces
  per-project coverage reports to a deterministic, diffable form.
  Strips nondeterministic fields (timestamp, duration), sorts all
  lists, caps sample_funcs at 10. JSON round-trip preserving.
- **Structural diff** (`Argus.Autoresearch.Diff`) — per-category and
  per-shape-gap deltas with improvements/regressions views, net total,
  and new/removed category tracking. Schema-version-aware (refuses
  cross-version diffs).
- **Priority ranker** (`Argus.Autoresearch.Ranker`) — scores by
  `delta_weight × severity × spread_bonus × stickiness_dampener`.
  Shape-gaps get 3× severity. Dead-end exclusion from notes.md.
  `suggested_extractor` maps 25 category prefixes to source files.
- **Checks barrier** (`Argus.Autoresearch.Checks`) — configurable
  command sequence (default: format + compile + test + dialyzer) plus
  canary correctness cross-check against a committed fixture.
- **Session event log** (`Argus.Autoresearch.Session`) — append-only
  JSONL with event types: baseline_set, measure, rank, attempt_start,
  checks, remeasure, attempt_end, baseline_promoted, revert, note.
- **Baseline store** (`Argus.Autoresearch.Baseline`) — committed
  `.autoresearch/baseline/` with snapshot.json, metadata.json, and
  canary_correctness.json. Promote/read/exists? API.
- **Config** (`Argus.Autoresearch.Config`) — `.autoresearch/config.exs`
  with named corpus tiers (fast/medium/full), canary project, barrier
  commands, concurrency settings.
- **Claude Code skill** at `.claude/skills/argus-autoresearch/SKILL.md`
  — 9-step iteration workflow with two confirmation gates, commit
  protocol (two commits per accepted iteration), dead-end protocol,
  and safety rules.
- **Initial baseline** for the fast-tier corpus (poolboy, phoenix_pubsub,
  plug, jason, bandit): 95 imprecision events across 12 categories,
  19 shape-gap rows.

### Changed

- **beam_spy is now a workspace path dependency** (was hex `~> 0.1.0`):
  argus needs beam_spy's unreleased Line-chunk table fix for `line_info`
  resolution, and lowdown already overrides the dep to the sibling.
- **`scripts/harness.exs`** — subprocess invocation delegated to
  `Argus.Autoresearch.Measure.run_analysis_subprocess/4`. The harness
  still owns compile orchestration and triage; only the subprocess
  primitive is shared.

### Fixed

- **`branch` relation fields told the wrong story.** The emitter has always
  put the test's *fail* label in the field documented as `on_true` ("label if
  condition holds"). Fields are now `fail`/`reserved` (names only — `.facts`
  output is positional and unchanged), and the never-firing false-arm rule in
  `clientlib/cfg.dl` is gone.

### Notes

Day-zero baseline counts (fast tier):

| Category | Count |
|---|---|
| ets_table_ref_op | 30 |
| ignored_result_unknown_api | 22 |
| genserver_callee | 19 |
| registry_op_key | 8 |
| gen_server_start_name | 5 |
| deferred_reply_from | 2 |
| ets_table_name_new | 2 |
| process_link_target | 2 |
| supervisor_child_module | 2 |
| delayed_target | 1 |
| exit_call_target | 1 |
| sync_call_timeout | 1 |
| **Total imprecision** | **95** |

Shape-gap rows: 19 across 4 relations
(coverage_genserver_isolated: 11, coverage_ets_unused: 3,
coverage_named_process_unreachable: 3, coverage_supervisor_no_children: 2).

## 0.4.0 — Unreleased

Coverage and precision instrumentation — Argus can now measure its own
extractor pipeline. Every fallback to a dynamic placeholder is recorded
as a fact, and passive Datalog rules derive "recognized shape but no
detail extracted" findings from the existing fact base. This closes
the feedback loop for iterative precision work: run coverage, change a
resolver, re-run, see whether the imprecision count dropped.

### Added

- **`coverage` analysis** — new built-in meta-analysis measuring the
  extractor pipeline itself. Exposes raw `imprecision_event` events
  (one row per extractor fallback site that fired) plus five shape-gap
  relations derived from the existing fact base:
  - `coverage_supervisor_no_children` — supervisor recognized but no
    static or dynamic children recovered
  - `coverage_genserver_isolated` — GenServer with zero observed
    sync/async traffic in the corpus
  - `coverage_ets_unused` — concretely-named table with no observed
    read or write operations
  - `coverage_statem_no_transitions` — gen_statem with states but no
    transitions extracted
  - `coverage_named_process_unreachable` — registered name with no
    traffic targeting it
  Not in the default correctness set — it's a developer-facing
  meta-analysis. Users opt in via `mix argus coverage`.
- **`imprecision` Layer 2 fact relation** — records extractor
  fallback events (`category`, `func`, `relation`, `reason`). Categories
  are namespaced (`genserver_*`, `supervisor_*`, `ets_*`, `statem_*`,
  etc.) and documented in CHANGELOG as a versioned vocabulary.
- **`track_dynamic/5`, `track_imprecision/5`, `enable_tracing/0`,
  `disable_tracing/0` helpers** — gated on a per-process flag so
  non-coverage runs incur only a single process-dict read per
  fallback site. `Argus.Analysis.run/3` flips the flag on
  automatically when the analysis is `:coverage`.
- **28 tracking call sites across 8 extractors** — every `resolve_*`
  fallback site now either calls `track_dynamic` (when a dynamic
  placeholder is emitted) or `track_imprecision` with reason `:skipped`
  / `:missing` / `:unresolvable` (when the fact is suppressed entirely).
  Coverage categories shipped: `genserver_callee`, `process_link_target`,
  `delayed_target`, `delayed_message_pattern`, `deferred_reply_from`,
  `sync_call_timeout`, `dynamic_supervisor_parent`,
  `dynamic_supervisor_child`, `supervisor_child_module`,
  `supervisor_strategy`, `ets_table_name_new`, `ets_table_ref_op`,
  `ets_options_unresolved`, `process_register_name`, `registry_op_key`,
  `via_tuple_registry`, `via_tuple_key`, `whereis_target`,
  `gen_server_start_name`, `rpc_timeout`, `global_register_name`,
  `global_op_retries`, `exit_call_target`, `trap_exit_unresolved`,
  `ignored_result_unknown_api`, `statem_transition_target`,
  `statem_timeout_value`, `statem_callback_mode_unknown`,
  `unsafe_deserialization_safety`, `gen_event_handler_unresolved`.

### Notes

`mix argus --list` now shows 16 analyses. Existing 15 analyses are
unchanged — the imprecision side-channel is purely additive and gated
off by default, so `mix argus <anything-but-coverage>` incurs no cost
and produces empty `imprecision.facts`.

## 0.3.0 — Unreleased

Bytecode-analysis precision improvements and one new analysis built on
top of them. Implements the punch list from the post-prune gap audit.

### Added

- **`deferred_startup_deadlock` analysis** — narrowly-scoped detector
  for three `handle_continue/2` patterns: mutual continue cycles
  between two GenServers, continue calls to a sibling started later
  under `:one_for_one`, and continue calls back into the parent
  supervisor while it's still mid-`start_link`. Plus a separate
  `continue_crash_loop_risk` finding for defensively-wrapped variants
  (try/catch :exit) that catch the literal deadlock but create
  supervisor restart loops. Verified zero false positives against the
  ~100-project sample corpus, including Oban.
- **`gen_event` extractor** — covers `:gen_event.sync_notify/2`,
  `notify/2`, `call/3,4`, `add_handler/3`, `add_sup_handler/3`. Reuses
  `sync_call`/`async_cast` so existing analyses (`call_cycle`,
  `process_bottleneck`) automatically catch gen_event patterns.
- **PartitionSupervisor child shape support** — `{PartitionSupervisor,
  child_spec: SomeWorker}` now extracts to the underlying worker
  module instead of treating PartitionSupervisor as the worker.
- **DynamicSupervisor.start_child extraction** — adds a new
  `dynamic_child(sup, child_mod, caller_func)` fact and extends
  `child_subtree` so `one_for_one_coupling` and friends see workers
  added at runtime (oban Midwife, Phoenix Channels, Plug.Upload).
- **`closure_def` Layer 1 fact** — every `make_fun3` instruction now
  emits an edge from the parent function to the lifted closure body.
  Treated as a static call edge in the call graph, so `call_reachable`
  follows execution into closures passed to `Enum.map`,
  `:telemetry.span`, `Task.async`, `Phoenix.PubSub` callbacks, etc.
  Concrete fix: `Oban.Peers.Global.handle_info → :global.set_lock`,
  which lives inside a telemetry-span closure, is now reachable.
- **Function-entry barrier and `arg_position/3` helper** — backward
  resolution can now distinguish function parameters from "I don't
  know" without changing `resolve_register/3`'s value contract.
- **Pattern-matched destructuring resolution** — `{:ok, val} = call()`
  resolves to `{:call_field, "Mod:func/arity", 1}` instead of
  `:dynamic`. Foundation for future analyses that correlate
  destructured values with their originating call sites.
- **Pure-BIF whitelist** — `:erlang.element/2`, `tuple_size/1`,
  `length/1`, `byte_size/1`, `atom_to_binary/1`, `++/2`, `hd/1`,
  `tl/1`, `map_size/1`. Resolves to literals when args are statically
  known, otherwise falls back to `:dynamic`.
- **`:via` tuple resolution in OTP** — `GenServer.call({:via, Registry,
  {MyApp.Registry, key}}, _)` now emits a `sync_call_via` fact and
  tags the legacy `sync_call` with `"via:RegistryInstance"` so existing
  analyses can group calls to the same via target.
- **`:global` retries-aware blocking classification** — new `global_op`
  fact captures `:global.set_lock`, `:global.trans`, `:global.del_lock`
  with the resolved retries argument. Datalog rules derive
  `global_blocking_op` only when retries is `"infinity"` or a positive
  integer (NOT `"0"`), so non-blocking try-locks like
  `:global.set_lock(_, _, 0)` are correctly not flagged.
- **`Process.send_after` / `:timer.send_after` / `:timer.apply_after`
  tracking** — new `delayed_message(sender_func, target, message)`
  fact captures implicit `handle_info` sources. Self() targets are
  recognized via the new `last_call_writer/3` helper.
- **`GenServer.reply/2` `deferred_reply` fact** — infrastructure-only;
  no analysis consumes it yet but documents the deferred-reply pattern
  for future timeout-window analysis.
- **`named_process` emission** — ProcessRegistry now actually emits
  the schema-defined relation it previously only documented.
- **Layer 1 emit additions** — `tuple_field_access(id, src, idx, dst)`
  captures `get_tuple_element` indices, `type_test(id, name, src, fail)`
  captures unary type-test names that the generic `branch` fact
  discarded, and `unhandled_op(id, op)` records every opcode that
  fell through the catch-all (so production runs surface what we're
  silently dropping).

### Changed

- **`scripts/analyze_project.exs`** — `:deferred_startup_deadlock`
  added to `@correctness_analyses` default set.
- **OTP extractor `:via` tuple handling** — sync calls against
  `{:via, _, _}` targets now emit a structured `sync_call_via` fact
  alongside the legacy `sync_call` (callee tag becomes
  `"via:RegistryInstance"`).
- **Schema cleanup** — dropped `process_monitor` (extracted but never
  consumed). Verified `supervisor.strategy` IS still consumed by
  `one_for_one_coupling` and `supervision` rules, so kept it.

### Notes

`mix argus --list` now shows 15 analyses. The new
`deferred_startup_deadlock` is wired into both the mix task and the
default `analyze_project.exs` correctness set.

## 0.2.0 — Unreleased

A focused refactor: prune the analysis surface from 28 to 14 BEAM/OTP-specific
detectors, clarify pipeline boundaries, and shrink the codebase by ~40%
without losing the bug-finding power that matters.

### Removed

- **12 generic dataflow primitives** — `cfg`, `callgraph`, `callgraph_ctx`,
  `reachability`, `reaching_def`, `liveness`, `dominators`, `loops`,
  `tail_call`, `constant_propagation`, `function_summary`, `message_flow`.
  These were classic compiler dataflow building blocks with no direct
  bug-finding value for end users. The shared rule library that backs the
  kept analyses (`priv/dl/clientlib/`) is preserved.
- **2 non-BEAM analyses** — `phoenix_security` (framework-specific, better
  handled by web tooling) and `resource_lifecycle` (generic, high false-
  positive risk).
- **`Argus.Souffle` behaviour** — was a 13-line indirection over a single
  `Argus.Souffle.CLI` implementation. Inlined into `Argus.Souffle`.
- **DOT output format from `mix argus`** — only worked for the cut
  cfg/callgraph analyses.
- Orphaned `priv/dl/clientlib/dataflow.dl` and `priv/dl/clientlib/concurrency.dl`.
- Schema relations populated only by removed extractors.

### Changed

- **Pipeline namespace.** `Argus.Extract`, `Argus.Normalize`, and
  `Argus.Emitter` are now `Argus.Pipeline`, `Argus.Pipeline.Normalize`,
  and `Argus.Pipeline.Emit`. A new `Argus.Pipeline.Disassemble` module
  owns module-path resolution and BEAM file loading.
- **Extractor helpers.** New `scan_functions/4`, `scan_remote_calls/4`,
  `resolve_callee/1`, and `resolve_atom/3` helpers in
  `Argus.Extractor.Helpers` removed ~166 lines of duplicated per-instruction
  scan boilerplate across six extractors.
- **`mix argus` discover_dep_modules** now uses `Mix.Project.build_path/0`
  + `Mix.Project.deps_apps/0` instead of a hardcoded `_build/{env}/lib/*/ebin`
  glob. The previous version only worked when each dep had its own `_build`.
- **`mix argus` module discovery** wraps `String.to_existing_atom/1`, so
  stale `.beam` files for unloaded modules are silently skipped instead
  of crashing discovery.
- **README and docs** refreshed to focus on the kept BEAM/OTP analyses,
  with grouped descriptions and a real Oban example.

### Added

- `CHANGELOG.md` (this file).

### Notes for upstream users

This is a 0.x project with no published Hex releases. Anyone using
`Argus.Extract`, `Argus.Normalize`, or `Argus.Emitter` directly will need to
update to the `Argus.Pipeline.*` names. Anyone running cut analyses
(`mix argus cfg`, `mix argus callgraph`, etc.) will need to migrate to one
of the kept analyses or write a `mix argus custom` rules file against the
preserved `priv/dl/clientlib/` rule library.

## 0.1.0

Initial research release with 28 analyses spanning generic dataflow primitives,
BEAM/OTP bug detectors, and framework-specific checks.
