# Panoptes

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/panoptes.svg)](https://hex.pm/packages/panoptes)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/panoptes)

Whole-program BEAM analysis for subtle OTP and supervision bugs. The
package is `panoptes` — Argus Panoptes, the hundred-eyed watchman — and
its modules are `Argus.*`.

Argus disassembles compiled `.beam` files, extracts facts from the bytecode,
and evaluates [Souffle](https://souffle-lang.github.io/) Datalog rules to
detect BEAM/OTP-specific anti-patterns: supervision-tree coupling, GenServer
deadlocks, leaked tasks, ETS misuse, atom-table exhaustion, and more.

## Installation

```elixir
def deps do
  [
    {:panoptes, "~> 0.20"}
  ]
end
```

[Souffle](https://souffle-lang.github.io/install) must be installed and
available on your `PATH`.

## Running it

Every frontend runs the same analyses, incrementally, and renders the
same findings the same way (pentiment frames, or JSON with `--format
json`).

**A Mix project**: the `:argus` compiler runs after every compile and
reports findings as compiler diagnostics; `mix argus` runs once, credo
style.

```elixir
def project do
  [
    compilers: Mix.compilers() ++ [:argus],
    argus: [analyses: [:coupling, :mailbox], severity: [mailbox: :error]]
  ]
end
```

```sh
mix argus                   # the configured analyses
mix argus --all             # every analysis
mix argus --list            # the analyses and the named sets
mix argus --format json     # findings as JSON on stdout
mix argus --fail-above 0    # fail when there are more findings than 0
```

**Anything else built for the BEAM** — a rebar3, Gleam or erlang.mk
project, or a directory of ebins: the `argus` escript, which needs
Erlang/OTP and souffle on `PATH` and never builds the project (it reads
the beams the build left, and says which sources are newer).

```sh
mix escript.install hex panoptes       # or a release's `argus`, checked by its .sha256
argus                                  # the project in the current directory
argus path/to/project --all --format json
argus --project beams --ebin path/to/ebin
argus list | gc | version | help
```

It exits 0, 1 when there are more findings than `--fail-above`, 2 for a
usage, project or configuration error, 3 when the analyses could not run.
A rebar3 project configures it with `{argus, [...]}` in `rebar.config`;
the others with an `argus.config` of Erlang terms beside it.

**rebar3**: the plugin in `integrations/rebar3_argus` runs the escript on
the ebins rebar3 built, as `rebar3 argus` or after every compile:

```erlang
{plugins, [rebar3_argus]}.
{argus_plugin, [{version, "0.20.0"}]}.            % or {escript, Path}, or ARGUS_ESCRIPT
{provider_hooks, [{post, [{compile, argus}]}]}.  % optional
```

Gleam findings point into the Erlang the Gleam build generated
(`build/dev/erlang/<package>/_gleam_artefacts/*.erl`), at the lines the
bytecode names.

This package is also the engine — the extraction pipeline, the rules,
and the in-VM API below.

## Approach

Argus is inspired by [Doop](https://bitbucket.org/yanniss/doop/src/master/)
(JVM), [cclyzer++](https://github.com/GaloisInc/cclyzer-plusplus) (LLVM IR),
and [Gigahorse](https://github.com/nevillegrech/gigahorse-toolchain) (EVM),
but takes advantage of the BEAM's register-based instruction set to skip
the expensive IR-lifting step those frameworks need. BEAM instructions map
to Datalog facts directly, with no intermediate representation.

```
.beam → disassemble → facts (emitter + extractors) → stage 0 call graph → process points-to → Souffle rules → findings
```

The emitter walks every instruction and records the generic facts —
instructions, registers, control flow, calls, literals. The extractors
read the same bytecode for what the analyses reason about: behaviours,
supervision trees, process calls, monitors, ETS, return shapes. A shared
call graph, and which process each pid can be, are derived once per run,
and each analysis is one Souffle program over the facts and a common rule
library, producing findings with a severity, a source anchor and a
remediation hint.

## Analyses

Argus ships 14 analyses, one per concern (`argus list` prints the
same table). An analysis answers "what goes wrong"; the mechanism, the
phase and the proximity to a request are columns on its relations, never
separate analyses, so a defect has one owner.

| Analysis | Concern |
|---|---|
| `startup` | work in `init/1` or `handle_continue/2` that blocks, deadlocks or races the tree's start |
| `shutdown` | cleanup a supervisor shutdown will skip, and teardown that hurts a peer |
| `blocking` | synchronous waits that can last forever or nest: call chains, cycles, fan-in, rpc, locks, receives in callbacks |
| `coupling` | two owners of one relationship across supervisor branches |
| `mailbox` | messages that arrive with no clause for them, and replies that never come |
| `failure` | error paths swallowed, half-caught or ignored |
| `structure` | child specs, registrations and tree shapes that are wrong on their own |
| `races` | check-then-act races on a process name, an ETS key or a Mnesia record that another process can write between the check and the act, ETS values published before the rows they point to, and ETS rows acted on after another process may have removed them |
| `state_machine` | gen_statem states no transition reaches, and terminal states that never stop |
| `ets` | ETS table ownership, concurrency options and lifecycle |
| `effects` | `@pure` contracts, and effects inside a transaction that a rollback cannot undo |
| `unsafe_input` | atom exhaustion, unsafe deserialization, unbounded decompression and code execution reachable from a request |
| `exposure` | secrets that `inspect/1` prints, and TLS that does not verify the peer |
| `coverage` | extractor coverage and imprecision (meta-analysis, opt-in) |

Inside a concern the same rule holds for relations: one relation per
defect, with the mechanism as a column (`sibling_dependency` has a
`reason`, `blocks_on_peer` a `phase` and a `kind`), and witness lists —
the edges of a call cycle, the callers of a bottleneck, the routes that
reach a sink — are related frames of the finding rather than findings of
their own.

[docs/bug-classes.md](docs/bug-classes.md) states every class of bug the
analyses report as a property of the program, with the assumptions its
rule rests on, the fixtures and closed-issue pairs that pin it, and what
is known of its precision; it ends with the consistency issues found
across the concerns and the ranked classes argus does not yet catch.

Named sets stand in for a list: `:all` (everything but `coverage`),
`:default` (what runs unconfigured), `:security`, `:effects` and
`:otp`. `unsafe_input` and `exposure` are `:security`'s, not
`:default`'s: a sink a request reaches is worth reading, but atom
creation no request reaches is mostly library API doing what it is for. The names these replaced in 0.17 (`supervision`,
`error_handling`, `sync_call_in_init`, ...) ran through an alias table
until 0.20, which removed it: a retired name is an unknown analysis now.
The 0.17 entry of the CHANGELOG says where each one's findings went.

## Programmatic API

```elixir
# Every analysis, one extraction: structured findings with severity,
# source anchors and remediation hints.
{:ok, %{findings: findings}} = Argus.run_analyses([MyApp.Supervisor, MyApp.WorkerA])

# One analysis, raw output relations.
{:ok, results} = Argus.analyze([MyApp.Supervisor, MyApp.WorkerA], :startup)

# Ad-hoc Datalog rules over the same facts.
{:ok, results} = Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})

# Keep the graph between calls: a call after an edit runs only what the
# edit reached.
{:ok, found} = Argus.run_analyses(beams, analyses: :all, manifest: "_build/argus.manifest")
```

Every call keeps each module's facts and each solve in a blob store
named by content (`ARGUS_CACHE_DIR`, else `~/.cache/argus/store`; or
`store:`), shared by every run on the machine, so a later call extracts
and solves only what changed; `argus gc` collects it, and every run
collects it at most once a day. Since 0.20 argus has one backend, this
query graph: the batch pipeline's options (`backend:`, `cache:`,
`solve_cache:`, `facts_dir:`, `extractors:`, `relations:`) raise,
naming what replaces each. `Argus.Analysis.extract_facts/3` still
writes a facts directory, and `Argus.Analysis.run_rules/3` solves one
written by hand.

## Priors

Some judgements an analysis needs are ones a reader makes from names —
whether `totp_seed` is a secret, which the thirteen substrings `exposure`
knows cannot say. `Argus.Priors` asks those of a System-One model
(typesafe.ai's Jev) and writes the answers into the facts as a third
layer of relations, `prior_*`, each row with the model's probability in
thousandths — for a class of answers, the sum over it: a field the model
is sure is a secret but splits between token and credential is a secret
at the sum. A rule reads a prior only as a positive premise: it can add
a finding marked `provenance: :heuristic` with its `confidence`, or move
a severity, never remove a structural row. Off by default, and a run
without priors is the run it always was.

```elixir
# Ask the model for what the cache does not hold (needs TYPESAFE_API_KEY).
Argus.run_analyses(mods, analyses: [:exposure], priors: :live)

# Offline and deterministic: answers from the cache only.
Argus.run_analyses(mods, analyses: [:exposure], priors: :cached_only)
```

`mix argus.priors` inspects, clears, exports and imports the cache
(`ARGUS_PRIORS_DIR`, default `~/.cache/argus/priors`); a committed
cassette plus `:cached_only` makes a CI run reproducible without a key.

## License

MIT
