# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/argus_beam.svg)](https://hex.pm/packages/argus_beam)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/argus_beam)

Argus finds OTP and concurrency bugs in Elixir, Erlang and Gleam programs:

- supervisor children that depend on each other but restart independently;
- GenServers that deadlock calling each other;
- races on a registered name or an ETS key.

It analyzes compiled `.beam` files and reports findings at the source lines
involved.

![Argus reports a restart dependency between two children of a one_for_one supervisor](https://raw.githubusercontent.com/QuinnWilton/argus/main/images/coupling.png)

## Install and run

Install [Soufflé](https://souffle-lang.github.io/install) on your `PATH`. The Mix
integration requires Elixir 1.19 or later; prebuilt escripts require Erlang/OTP 28.

### Mix

Add Argus to your dependencies:

```elixir
def deps do
  [
    {:argus_beam, "~> 0.20"}
  ]
end
```

Then fetch dependencies and run an analysis. `mix argus` compiles the project first.

```sh
mix deps.get
mix argus                 # configured analyses, or the default set
mix argus coupling ets    # selected analyses
mix argus --all           # all bug-finding analyses
mix argus --list          # available analyses and sets
mix argus --format json   # findings as JSON
mix argus --fail-above 0  # fail CI on any finding
```

To report findings on every compile, append the `:argus` compiler. Editors can
show the findings as compiler diagnostics.

```elixir
def project do
  [
    compilers: Mix.compilers() ++ [:argus],
    argus: [analyses: [:default, :ets], severity: [mailbox: :error]]
  ]
end
```

By default, error findings fail the compiler run. `mix argus` uses `--fail-above`
to decide whether findings fail the run.

### rebar3

Add this to `rebar.config`, then run `rebar3 argus`. The plugin compiles the
project and downloads the specified Argus escript.

```erlang
{plugins, [rebar3_argus]}.
{argus_plugin, [{version, "0.21.0"}]}.
{argus, [{analyses, [default, ets]}]}.           % optional
{provider_hooks, [{post, [{compile, argus}]}]}.  % optional: run after compilation
```

### Gleam, erlang.mk, or a directory of BEAM files

Install the escript with Mix:

```sh
mix escript.install hex argus_beam
```

Or download a prebuilt escript and its SHA-256 checksum from
[GitHub releases](https://github.com/QuinnWilton/argus/releases). Put `argus` on
your `PATH`.

Build your project, then run:

```sh
argus                                 # current project
argus path/to/project --all
argus --project beams --ebin path/to/ebin
```

The escript reads existing BEAM files and warns about sources newer than their
compiled files. Configuration goes in `argus.config` as Erlang terms. Gleam
findings point to the generated Erlang source.

## Choose analyses

The analyses marked ✓ run by default.

| Analysis | Finds | Default |
|---|---|:---:|
| `startup` | blocking work, deadlocks and races during initialization | ✓ |
| `shutdown` | skipped cleanup and teardown that disrupts a peer | ✓ |
| `coupling` | processes that depend on each other but restart independently | ✓ |
| `structure` | invalid child specs, conflicting registrations and supervision mistakes | ✓ |
| `mailbox` | unhandled messages, missing replies and repeated resource acquisitions | ✓ |
| `failure` | swallowed errors, unchecked results and dropped resources | ✓ |
| `races` | check-then-act races on registered names, ETS keys or Mnesia records | ✓ |
| `blocking` | call cycles, nested waits, bottlenecks and unsafe distributed calls | |
| `state_machine` | unreachable `gen_statem` states and terminal states that never stop | |
| `ets` | table ownership, lifecycle and access-pattern problems | |
| `effects` | violated `@pure` contracts and effects a transaction cannot undo | |
| `unsafe_input` | atom exhaustion, unsafe deserialization and code execution | |
| `exposure` | inspect-visible secrets and TLS connections without peer verification | |

Use analysis names or these sets in `analyses:`:

- `:default`: the analyses marked ✓;
- `:all`: every analysis in the table;
- `:security`: `unsafe_input` and `exposure`;
- `:effects`: `effects`;
- `:otp`: `:all` except `:security` and `:effects`.

The separate `coverage` analysis reports missing analysis information. Request it
explicitly; `--all` excludes it.

`severity:` overrides the level for an analysis or set. See the
[configuration reference](https://hexdocs.pm/argus_beam/Argus.Config.html) for
severity, ignore rules and compiler settings.

## Interpret findings

Argus analyzes your project's code by default. Add `--include-deps` to analyze
dependencies too. Dynamic calls and runtime configuration can leave gaps or
produce findings that do not apply to a particular deployment.

Use the [bug-class catalog](docs/bug-classes.md) to understand each finding's
evidence and limits. For contributors, the [analysis model](docs/design/analysis-model.md)
and [rule guide](docs/design/rule-style.md) explain the implementation.

## License

MIT
