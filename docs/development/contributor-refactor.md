# Contributor workflow refactor

This records the baseline, implementation plan and verification for making
Argus usable by contributors who know OTP but are new to its analysis model.
It is a change record, rather than another reference for current semantics.

## Baseline

The checkout at the start of this work has no contributor guide or supported
debugging command. README links to the shared model and rule guide. Those explain
semantics, but do not give a runnable investigation or extension workflow.

* **A — PR #8:** `mix test test/analyses/shutdown_trap_exit_test.exs` runs the
  safe `CleansUpEnteringLoop` case and the leaking `LeaksEnteringLoop` and
  `LeaksBesideAnotherLoop` cases. Soufflé tagging is already fixed. To inspect
  `traps_elsewhere`, `enters_own_loop` or a reach component, a contributor must
  discover `Argus.Analysis.extract_facts/3`, retain its scratch directory,
  modify output declarations in a rules copy, supply its includes, and invoke
  the solver. Test helpers select some report columns by name; arbitrary fact
  and intermediate rows have no corresponding inspection interface.
* **B — another finding:** the normal CLI renders source locations and evidence,
  but does not retain a reproduction with its facts, rules and raw outputs.
  Finding-to-rule investigation requires manually joining IDs to `line_info`
  and following the report builder and included Datalog files.
* **C — extension:** `Argus.Extractor` describes its callbacks, but its advice to
  pass `extractors:` to `Analysis.extract_facts/3` is obsolete: `Argus.Run`
  rejects that option. A contributor must discover `Pipeline.run/3` and the
  direct solver interface themselves. Built-in extensions also require schema
  declarations, the analysis's producer list, typed-reader registration when
  applicable, regeneration, and dependency checks.

## Priorities

1. Add one opt-in `mix argus.debug` workflow and `Argus.Debug` API for capturing a
   portable reproduction, rerunning editable rules, inspecting named columns and
   intermediate/component relations, finding source definitions, and resolving
   IDs. Reuse Pipeline, shared stages, Soufflé, schema accessors and TSV encoding.
   Normal CLI and query performance remain outside this instrumentation.
2. Separate CFG-derived facts from pipeline scheduling and lifecycle management;
   keep existing instruction semantics and failure boundaries. Organize shutdown
   defect families so a contributor can navigate the relevant rules directly.
   Consolidate duplicated row-selection mechanics if the resulting API helps
   both tests and debugging.
3. Add a concise contributor entry point, executable reachability examples, and
   a custom extraction/analysis tutorial. Correct stale API guidance and remove
   misleading duplication. Document authoritative registration/dependency paths.
4. Execute A, B and C using the documented interfaces. Record commands, outputs,
   before/after effort, focused and required broader checks here. Reproducible
   walkthroughs are evidence of functionality, not human usability studies.

## Completion evidence

The baseline commit is `b710a68f851d892e427a9723bfca343ba508496e`.
All commands below used Elixir 1.19.4, OTP 28.3, Soufflé 2.5, and
`ARGUS_ROUX_PATH=/Users/quinn/dev/beam_box/roux`. They exercise the interfaces in
CONTRIBUTING.md; this is reproducibility evidence, not a human usability study.
Since 0.22 argus solves with FlowLog: in place of `souffle -D DIR PROGRAM`, run
`mix argus.flowlog solve PROGRAM FACTS_DIR DIR` (the reachability example's facts
are in `examples/contributor/reachability`, and `forward.reaches` is written as
`forward_reaches`).

### A — PR #8

```sh
mix test test/analyses/shutdown_trap_exit_test.exs --exclude corpus
MIX_ENV=test mix argus.debug capture shutdown tmp/pr8 \
  --module Argus.Test.Fixtures.CleansUpEnteringLoop \
  --module Argus.Test.Fixtures.LeaksEnteringLoop \
  --module Argus.Test.Fixtures.LeaksBesideAnotherLoop \
  --module Argus.Test.Fixtures.OtherLoop
mix argus.debug rows tmp/pr8 cleanup_defect --where kind=never_runs
mix argus.debug describe tmp/pr8 trap_exit
mix argus.debug source tmp/pr8 SameProcessReach
mix argus.debug solve tmp/pr8 --probe traps_elsewhere \
  --probe enters_own_loop --probe enters_loop_of.reaches
mix argus.debug rows tmp/pr8 traps_elsewhere
mix argus.debug rows tmp/pr8 enters_own_loop
mix argus.debug rows tmp/pr8 enters_loop_of.reaches --limit 10
```

The focused regression file passed all 8 tests. `cleanup_defect` reports
`LeaksEnteringLoop` and `LeaksBesideAnotherLoop`, both `never_runs`, `io`,
`File.write!/2`. The safe module is absent. Intermediate rows are:

```text
traps_elsewhere(func):
  Argus.Test.Fixtures.LeaksBesideAnotherLoop:run_other/1
enters_own_loop(func):
  Argus.Test.Fixtures.CleansUpEnteringLoop:init/1
  Argus.Test.Fixtures.LeaksEnteringLoop:init/1
enters_loop_of.reaches(func, target):
  Argus.Test.Fixtures.CleansUpEnteringLoop:init/1 -> Argus.Test.Fixtures.CleansUpEnteringLoop
  Argus.Test.Fixtures.LeaksEnteringLoop:init/1 -> Argus.Test.Fixtures.LeaksEnteringLoop
  Argus.Test.Fixtures.LeaksBesideAnotherLoop:run_other/1 -> Argus.Test.Fixtures.OtherLoop
```

`describe` identifies `Argus.Extractors.ErrorHandling`, field names and meanings.
`source` finds `.comp SameProcessReach` in `clientlib/reach.dl` and its
instantiations in `clientlib/trapping.dl` and `shutdown/trapped_exits.dl`.
`DebugTest` also compares every raw built-in output against the normal graph
solve, including evidence, and resolves fixture function IDs to source lines.

Previously a contributor had to discover scratch-directory extraction APIs,
construct a rules copy/include environment, add output declarations and join
line facts manually. Capture now owns those lifecycle steps; `source`, probes,
named rows and `locate` supply the investigation. Contributors learn one bundle
and one command family; they still need the distinctions between process and
call reachability, which are inherent to this bug.

### B — TLS verification

```sh
MIX_ENV=test mix argus.debug capture exposure tmp/tls \
  --module Argus.Test.Fixtures.Tls.ForcesNone \
  --module Argus.Test.Fixtures.Tls.OffersChoice
mix argus.debug rows tmp/tls disables_verification
mix argus.debug locate tmp/tls 'Argus.Test.Fixtures.Tls.ForcesNone:opts/1#8'
mix argus.debug source tmp/tls disables_verification
mix argus.debug solve tmp/tls --probe unverified_tls --probe module_can_verify
mix argus.debug rows tmp/tls unverified_tls
mix argus.debug rows tmp/tls module_can_verify
mix argus.debug rows tmp/tls tls_verification
mix argus.debug describe tmp/tls tls_verification
```

The output is `ForcesNone:opts/1`, anchored at instruction `#8`, resolved to
`test/fixtures/tls_fixture.ex:12`. `unverified_tls(func, setting)` retains that
same pair. `module_can_verify(mod)` contains `OffersChoice`. Extracted
`tls_verification(id, func, setting)` shows `ForcesNone:opts/1#8 = none`,
`OffersChoice:opts/1#7 = none`, and `OffersChoice:opts/1#10 = peer`.
`source` leads to `exposure.dl`'s report and detection rules; `describe` leads to
`Argus.Extractors.Tls`. The finding builder is in
`lib/argus/analyses/exposure.ex`.

The rule-edit experiment removed `!module_offers_verification(func)` from the
bundle copy, reran `Debug.solve!`, verified both modules were reported, restored
the rule, and verified the original single result returned. It also built the
normal exposure finding and resolved its source anchor. Only the bundle copy
was edited; prior successful runs remained available.

Previously the output-to-producer trace required searching declarations,
reading positional tuples and manually joining line facts. It now uses the
same capture/inspect/probe/locate path as A. Missing tuples still require
inspection of relevant conjuncts; source references and recorded tuples are
not claimed as complete provenance.

### C — extraction and an analysis consumer

```sh
ARGUS_TUTORIAL_BUNDLE=tmp/clock-v2 mix run examples/contributor/run.exs
mix argus.debug describe tmp/clock-v2 clock_read
mix argus.debug rows tmp/clock-v2 clock_use
mkdir -p tmp/reach-v2
souffle -D tmp/reach-v2 examples/contributor/reachability.dl
cat tmp/reach-v2/reachable.csv tmp/reach-v2/forward.reaches.csv
mix argus.gen.dl
mix argus.pins
```

The clock tutorial reports exactly:

```text
site                                  func
Argus.Examples.WallClock:now/0#4        Argus.Examples.WallClock:now/0
info: Reads wall-clock time at examples/contributor/fixtures.exs:2
```

Its executable assertion excludes `MonotonicClock`. `describe clock_read`
reports named `site` and `func` columns, the `ClockCalls` producer and the copied
custom declaration/consumer. The reachability program emits all three targets
for call reach, only `inline` for same-process reach, and `inline` plus `awaited`
for holding reach. Its forward component includes the root itself.

This tutorial has one producer registration (`relations/0`) and one standalone
Datalog declaration/consumer, wired through `Debug.capture!`'s extractor option.
The finding builder demonstrates the output contract and source anchor. It does
not require a production schema entry or invent a defect class. CONTRIBUTING.md
separately enumerates the built-in schema, typed-reader, producer, staged-output,
generation, pin and tracked-dependency steps. Regeneration changed neither the
production declarations nor input pins. Previously the documented extractor
option was rejected by the normal Run API and no runnable end-to-end example
explained the alternative. Empty custom relations now have actual files even
when an extractor returns no rows.

### Simplifications and verification

- `Pipeline.Derive` owns CFG-derived rows; Pipeline retains scheduling, prepared
  data and failure boundaries. No instruction table or new analysis semantics
  were introduced.
- Shutdown's family files retain the original shared namespace and explicit
  cross-family dependencies. Expanding their includes reproduces the original
  program, including every comment, rule and output, modulo blank lines.
- The private one-shot compile helper and fixture row-selection implementation
  were removed in favor of shared implementations used by normal and debug
  paths. Stale extractor and discovery guidance was replaced at its authority.
- Debug metadata uses the compiler's AST for columns. Source matching is only
  navigation and never decides production dependency or cache keys. Shared-stage
  reruns use existing stage publication and bounded points-to policy.

Focused declaration, relation, behaviour, debug and PR #8 checks passed (39
tests); the final debug/selection checks passed (14 tests). Credo strict and
Dialyzer passed. Formatting and `git diff --check` passed. Documentation builds;
its existing hidden/private reference warnings remain, with no warnings from the
new guide or debugger. The local Hex package contains the guide, examples, and
all shutdown fragments; build it without the local Roux override because Hex
rejects path dependencies. Referenced design and analysis guides ship with it.

The broad run was:

```sh
mix test --include identity_verify --include escript --include rebar3 \
  --include gleam --exclude corpus --max-cases 8
```

It finished with 62 doctests, 38 properties and 3230 tests: four failures and
one skip. Identity, extraction, finding/rendering and ordinary analysis checks
had no failures. Three failures were escript/rebar3 encoding: the inherited
`LANG=C.UTF-8` is unavailable on this Mac, so external OTP output escaped Unicode
characters and corrupted JSON. This focused rerun passed all 11 tests:

```sh
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 mix test test/argus/escript_test.exs \
  test/integrations/rebar3_test.exs test/integrations/gleam_test.exs \
  --include escript --include rebar3 --include gleam --exclude corpus --no-compile
```

The remaining failure is the existing task-flow property at
`test/analyses/task_library_flow_test.exs:560`, seed `373025`. Its failing chain
uses `Keyword.get/2`, `Map.replace/3`, `:maps.with/2` and `Map.from_struct/1`.
To check the refactor, a separate VM loaded the original Pipeline from the
baseline commit in memory (verified against its BEAM MD5), required the same
property in a temporary wrapper, and ran it with caching disabled and the same
seed. It reproduced the same generated case after two successful runs. No
project BEAM was replaced, rule changed or expectation relaxed. The unrelated
property failure remains; the full suite is not claimed green.

The first broad attempt ran alongside other checks and was interrupted after
resource timeouts and concurrent compilation removed consolidated protocol
files. That attempt is not counted as verification. These sequential runs passed:

```sh
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ARGUS_VERIFY_BATCH=1 mix test \
  test/analyses/shutdown_trap_exit_test.exs test/analyses/shutdown_test.exs \
  test/analyses/shutdown_drain_test.exs test/analyses/shutdown_monitor_test.exs \
  test/analyses/shutdown_supervision_test.exs test/analyses/exposure_tls_test.exs \
  test/soundness/shutdown_test.exs test/soundness/exposure_test.exs \
  test/soundness/exposure_precision_test.exs --exclude corpus --max-cases 8
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 mix test --only parity --no-compile
env -u ARGUS_ROUX_PATH LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
  mix hex.build --output tmp/contributor-verification/argus_beam.tar
```

Batch/soundness: 76 tests, zero failures. Parity: one test exercising cold solves
and cross-module edits across all analyses, zero failures. The package contains
the referenced design/rule guides and runnable examples; the development change
record is excluded. This real-project cleanup regression passed for both
defective and fixed revisions:

```sh
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ARGUS_CORPUS_ONLY='anubis-mcp#209' \
  mix test --only corpus --no-compile
```

One selected pair passed; 91 unrelated corpus pairs were skipped by the selector.
The full corpus was not run. The remaining full-suite task-flow failure and
existing ExDoc warnings are recorded above. Debug bundles intentionally omit
optional classifier priors, retain original source paths rather than source
copies, and expose tuples and source references without complete derivation
provenance. No TUI or additional runtime dependency was required.
