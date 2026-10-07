# Contributing to Argus

A good first change is a finding you can reproduce in a small module. This guide
walks through one, then shows how to experiment with an analysis of your own.
You can follow it knowing Elixir and OTP; the Datalog examples introduce the
pieces as you need them.

## Get started

Use Elixir 1.19 and OTP 28, and install [Rust](https://rustup.rs) 1.88 or newer.
Argus evaluates its Datalog rules with [FlowLog](https://github.com/flowlog-rs/flowlog),
which compiles each program into an engine, a native executable. Argus builds and
caches the engines itself.

```sh
mix deps.get
mix argus.flowlog build
mix test test/analyses/exposure_tls_test.exs --exclude corpus
```

`mix argus.flowlog build` builds every shipped program's engine once per version
of its rules (the first build takes several minutes); `mix argus.flowlog status`
shows what is built and where. The second command runs a small set of TLS tests.
`--exclude corpus` avoids fetching and compiling external projects. Keep that flag
while working on a local example. Tests that need FlowLog are skipped locally if
Rust is missing.

If you are working with unreleased Roux changes, set
`ARGUS_ROUX_PATH=/path/to/roux` before running Mix commands.

## Follow a finding back to its rule

Open `test/fixtures/tls_fixture.ex`. The two modules to compare are:

- `ForcesNone`, which selects `verify_none` when TLS is enabled.
- `OffersChoice`, which also supports `verify_peer`.

Argus reports the first. The second is a useful counterexample: the presence of
`verify_none` alone should not be enough to report a defect.

Save an analysis of just these modules:

```sh
MIX_ENV=test mix argus.debug capture exposure tmp/tls-tour \
  --module Argus.Test.Fixtures.Tls.ForcesNone \
  --module Argus.Test.Fixtures.Tls.OffersChoice
```

`exposure` is the analysis name. `tmp/tls-tour` is a **bundle**: a directory
containing the facts extracted from the compiled modules, a copy of the rules,
and the solver's results. Choose a new directory if you have run this before.
`MIX_ENV=test` makes the test fixtures available to the command.

You can explore this bundle interactively:

```sh
mix argus.debug explore tmp/tls-tour
```

The [Breeze](https://github.com/Gazler/breeze) explorer opens with output relations
first. Press `/` to search for `disables_verification`, then Enter to open its
rows. Enter on a row shows its named fields; Enter on an instruction or function
ID opens the application's source. Press Escape to go back. `d` shows the
relation's description and producers; `r` shows rule references, which you can
also open with Enter. `f` accepts a filter such as `setting=peer`, and `n`/`N`
page through matching rows. Press `?` for the other keys and `q` to quit.

`b` shows the bundle manifest, including the solver, optional priors, application
sources and relation producers. `t` lists retained runs; newer captures save each
successful run's column definitions and rule copy for historical inspection.
The explorer reads existing bundles without building an engine. After editing rules
or running a solve in another terminal, press `R` to load its latest results.
If you use Argus as a dependency in another project, add
`{:breeze, "~> 0.5.5"}` to that project's dependencies to enable the explorer.
If Argus was already compiled without Breeze, recompile it once with
`mix deps.compile argus_beam --force`.

The commands below let you follow the same investigation from a shell.

Now look at the report's rows:

```sh
mix argus.debug rows tmp/tls-tour disables_verification
```

A **relation** is a table. Here, `disables_verification` has a `func` column naming
the function and an `id` column naming the instruction. There should be one row,
for `ForcesNone:opts/1`. The instruction ID ends in an index such as `#8`; that
index identifies an instruction in the compiled function, not a source line.
Copy the ID from your output to find its source location:

```sh
mix argus.debug locate tmp/tls-tour 'Argus.Test.Fixtures.Tls.ForcesNone:opts/1#8'
```

To find the rule that produced the report:

```sh
mix argus.debug source tmp/tls-tour disables_verification
```

This points into the bundle's copy of `analyses/exposure.dl`. The report comes
from `unverified_tls`, whose rule reads:

```prolog
unverified_tls(func, setting) :-
  turns_off_verification(setting, func),
  !module_offers_verification(func),
  !server_setting(setting, func).
```

Read the commas as “and” and `!` as “there is no matching row.” This rule says
that the function turns verification off, its module offers no verified
alternative, and the setting is not exclusively for a server's TLS options.
Those conditions explain why the two fixtures differ.

### Look at the rows behind that decision

The report normally hides intermediate relations. Ask the debugger to save two
of them, then inspect the verified alternative:

```sh
mix argus.debug solve tmp/tls-tour --probe unverified_tls --probe module_can_verify
mix argus.debug rows tmp/tls-tour module_can_verify
```

`module_can_verify` should contain `OffersChoice`. To see the observations that
support it:

```sh
mix argus.debug describe tmp/tls-tour tls_verification
mix argus.debug rows tmp/tls-tour tls_verification
```

`describe` explains the columns and points to the extractor that creates these
facts. The rows show `none` for both fixtures and `peer` for `OffersChoice`.
An **extractor** is Elixir code that recognizes something in BEAM instructions;
in this case, it recognizes literal TLS settings.

For larger examples, narrow the output with `--where column=value` and
`--limit 10`. `mix argus.debug relations tmp/tls-tour` lists the available tables.
See `mix help argus.debug` for the other options.

### Change the rule and see what happens

Edit `tmp/tls-tour/rules/analyses/exposure.dl`. Remove this condition from the
rule above:

```prolog
  !module_offers_verification(func),
```

Then rerun it:

```sh
mix argus.debug solve tmp/tls-tour
mix argus.debug rows tmp/tls-tour disables_verification
```

Both fixtures should now be reported. Restore the condition and rerun: only
`ForcesNone` should remain. This gives you a small way to test your understanding
before changing the project's rules.

Each solve keeps a separate result under the bundle's `runs/` directory, so you
can compare attempts. If a solve fails, inspection still uses the last successful
result. Changes to Elixir code need a new capture; changes to shared stage rules
need `solve --restage`.

The rows are evidence about compiled code, not a recording of a running program.
When an expected row is absent, inspect the tables used by its rule, as we did
above. Also inspect `extraction_error` and `imprecision` for gaps in extraction.
Bundles leave optional classifier priors empty. Source lookup uses the original
source paths, which may not exist on another machine. Before sharing a bundle,
check its facts for sensitive literals.

## Turn an experiment into a fix

Once you understand the cause, change the corresponding file under
`priv/dl/analyses/` and add a test. Keep both a module that should be reported and
a closely related module that should stay quiet. The TLS tests demonstrate why:
a rule that catches `ForcesNone` but also catches `OffersChoice` is too broad.

Put fixture modules in `test/fixtures/` and assertions in `test/analyses/`.
`test/analyses/exposure_tls_test.exs` is a small example to copy. It uses
`Argus.Test.Memo.analyze/2` to share repeated solves. Add `@moduletag :flowlog` to
a test module that solves rules; tests normally use `async: true`.

Start with the affected test file. When it passes, run:

```sh
mix test --exclude corpus
mix format --check-formatted
mix credo --strict
mix dialyzer
```

If your change makes a finding disappear, check the related tests under
`test/soundness/` too: they cover cases where similar-looking code is still
unsafe. The [rule guide](docs/design/rule-style.md) explains how to write the
conditions and evidence for a finding.

## Understand where processes differ

The call graph can lead through a function handed to a spawned process. That
function's actions do not necessarily happen in the caller's process. When
writing a rule, choose the reachability component that answers your question:

| What you want to follow | Component |
| --- | --- |
| The shared call graph, including references to functions | `CallReach` |
| Work on the same process's stack | `SameProcessReach` |
| Same-process work and tasks the caller awaits | `HoldingReach` |

A **component** is a reusable collection of Datalog relations and rules. `.init`
creates an instance; its `seed` or `root` rows tell it where to start. There is a
small executable example in `examples/contributor/reachability.dl`:

```sh
mix argus.flowlog solve examples/contributor/reachability.dl \
  examples/contributor/reachability tmp/reach
```

The second argument is the directory of input facts, one tab-separated
`<relation>.facts` file per input; the command prints each output relation and
writes it to `tmp/reach/<relation>.csv`.

The example compares an ordinary helper call, a detached spawn and an awaited
task. Call reach includes all three; same-process reach includes only the helper;
holding reach includes the helper and the awaited task. Read the example beside
`priv/dl/clientlib/reach.dl` to see how its instances get their starting rows.
The [shared model](docs/design/analysis-model.md) explains the edge semantics.

For the trap-exit case from [PR #8](https://github.com/QuinnWilton/argus/pull/8),
start with `test/analyses/shutdown_trap_exit_test.exs` and the fixtures
`CleansUpEnteringLoop`, `LeaksEnteringLoop`, and `LeaksBesideAnotherLoop`.
The important question is which server the trapping process becomes. Capture
these fixtures together with `OtherLoop`, the server started by the last one:

```sh
MIX_ENV=test mix argus.debug capture shutdown tmp/loops-tour \
  --module Argus.Test.Fixtures.CleansUpEnteringLoop \
  --module Argus.Test.Fixtures.LeaksEnteringLoop \
  --module Argus.Test.Fixtures.LeaksBesideAnotherLoop \
  --module Argus.Test.Fixtures.OtherLoop
mix argus.debug source tmp/loops-tour SameProcessReach
mix argus.debug solve tmp/loops-tour --probe enters_loop_of.reaches
mix argus.debug rows tmp/loops-tour enters_loop_of.reaches
```

The rows pair each function with the server whose loop it enters. The safe
fixture enters its own loop; `LeaksBesideAnotherLoop.run_other/1` enters
`OtherLoop`. A trap in that process cannot protect this module's cleanup.

## Try a small analysis of your own

The wall-clock example reports calls to `:erlang.system_time/0`. Run it with a
fresh bundle directory:

```sh
ARGUS_TUTORIAL_BUNDLE=tmp/clock-tour mix run examples/contributor/run.exs
```

It should report `WallClock.now/0` and leave `MonotonicClock.now/0` quiet. Follow
the example in this order:

1. `examples/contributor/fixtures.exs` contains the two functions being analyzed.
2. `clock_calls.exs` collects wall-clock calls into the `clock_read` relation.
3. `clock.dl` reads those facts and emits `clock_use` rows.
4. `ClockUses`, also in `clock_calls.exs`, gives those rows a message and a source
   anchor. `run.exs` connects the pieces and checks the result.

You can edit the extractor or rule and run again with another bundle directory.
This example uses its own relation declarations and passes the extractor to
`Argus.Debug.capture!`, so it is a convenient place to experiment before adding
an analysis to Argus itself.

### When you want to add it to Argus

The extra wiring depends on what you add:

| Addition | Where to connect it |
| --- | --- |
| An extracted fact | Declare its columns in `lib/argus/schema/`, list it in the extractor's `relations/0`, and include the extractor in the analysis's `extractors/0`. A new schema concern also goes in `Argus.Schema`. |
| An extractor that reads decoded facts | Add it to `Pipeline.typed_readers/0` and its input relations to `typed_relations/0`, so it receives the facts it needs. |
| A built-in analysis | Add an `Argus.Analysis` module in `lib/argus/analyses/` and its rules under `priv/dl/analyses/`. Its `output_relations/0` describes columns and finding identity; `finding/2` builds the message and anchors. |
| A shared stage output | Expose it in `Analysis.Extraction`, declare it as an input in its consumers, and route it through `Graph.Solve`. |

After changing built-in relations or inputs, run `mix argus.gen.dl` and
`mix argus.pins`, then review the generated diff. The schema owns the declarations;
edit it rather than the generated `base.dl`, `layer2.dl` or `priors.dl`.

Most finding changes involve a fixture and a rules file. Work that changes
extraction, caching or integrations needs additional checks. The repository's
[development notes](https://github.com/QuinnWilton/argus/blob/HEAD/AGENTS.md) list
those checks and the dependency-tracking requirements. The code for extraction
is under `lib/argus/pipeline/` and `lib/argus/extractors/`; shared rule concepts are
under `priv/dl/clientlib/`; finding messages live in `lib/argus/analyses/`.
