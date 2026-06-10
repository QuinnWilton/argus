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

### Added

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
