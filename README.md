# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/argus_beam.svg)](https://hex.pm/packages/argus_beam)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/argus_beam)

Argus is a static analyzer for BEAM programs. It finds OTP and concurrency bugs like:

- supervisor children that depend on each other but restart
  independently;
- GenServers that deadlock calling each other;
- races on a registered name or an ETS key.

Argus reads the compiled `.beam` files of the whole program, so it works on
Elixir, Erlang and Gleam alike. It reports each finding at the source
lines involved.

![A coupling finding reported by mix argus: two children of a one_for_one supervisor, one of which registers with the other in its init/1](https://raw.githubusercontent.com/QuinnWilton/argus/main/images/coupling.png)

## Installation

Argus needs [Soufflé](https://souffle-lang.github.io/install) on your
`PATH`.

In a Mix project, add it to your dependencies:

```elixir
def deps do
  [
    {:argus_beam, "~> 0.20"}
  ]
end
```

For anything else, install the `argus` escript:

```sh
mix escript.install hex argus_beam
```

Each [GitHub release](https://github.com/QuinnWilton/argus/releases) also
has a prebuilt copy of the escript, with its sha256 checksum.

## Running it

### Mix

```sh
mix argus                 # the default analyses
mix argus --all           # every analysis
mix argus --list          # the analyses and the named sets
mix argus --format json   # findings as JSON
mix argus --fail-above 0  # exit non-zero on any finding, for CI
```

To report findings on every compile, add the `:argus` compiler. Its
findings are compiler diagnostics, so your editor shows them too.

```elixir
def project do
  [
    compilers: Mix.compilers() ++ [:argus],
    argus: [analyses: [:default, :ets], severity: [mailbox: :error]]
  ]
end
```

### rebar3

Add the plugin to `rebar.config`, then run `rebar3 argus`:

```erlang
{plugins, [rebar3_argus]}.
{argus_plugin, [{version, "0.20.1"}]}.            % the escript to download
{provider_hooks, [{post, [{compile, argus}]}]}.  % optional: run after every compile
{argus, [{analyses, [default, ets]}]}.           % optional
```

### Gleam, erlang.mk, or a directory of beams

Build the project first, then run the escript in its directory:

```sh
argus                                 # the project in the current directory
argus path/to/project --all
argus --project beams --ebin path/to/ebin
```

The escript reads the beams that your build produced and never builds
them itself. If any source is newer than its beam, argus names it.
Configuration goes in an `argus.config` file of Erlang terms, next to the
project. Gleam findings point into the Erlang that Gleam generates.

## What it looks for

Each analysis covers one concern. The ones marked ✓ run by default.

| Analysis | Finds | Default |
|---|---|:---:|
| `startup` | work in `init/1` that blocks, deadlocks, or races the rest of the supervision tree | ✓ |
| `shutdown` | cleanup that a supervisor's shutdown skips, and teardown that hurts a peer | ✓ |
| `coupling` | processes that depend on each other but restart independently | ✓ |
| `structure` | child specs, registrations and supervision trees that are wrong on their own | ✓ |
| `mailbox` | messages that no clause handles, and replies that never come | ✓ |
| `failure` | errors that are swallowed, half-caught or ignored | ✓ |
| `races` | check-then-act races on a registered name, an ETS key or a Mnesia record | ✓ |
| `blocking` | calls that can wait forever: call cycles, nested calls, bottlenecks, rpc | |
| `state_machine` | `gen_statem` states that nothing reaches, and terminal states that never stop | |
| `ets` | ETS table ownership, concurrency options and lifecycle | |
| `effects` | `@pure` contracts, and side effects that a transaction rollback cannot undo | |
| `unsafe_input` | atom exhaustion, unsafe deserialization and code execution that a request can reach | |
| `exposure` | secrets that `inspect/1` prints, and TLS connections that skip peer verification | |

`analyses:` takes these names and the named sets:

- `:default`: the analyses marked ✓;
- `:all`: every analysis;
- `:security`: `unsafe_input` and `exposure`;
- `:effects`: `effects`;
- `:otp`: everything outside `:security` and `:effects`.

`severity:` changes the severity of an analysis or a set. The
[bug-class catalog](docs/bug-classes.md) explains the findings, their limits,
and the shared analysis models.

## License

MIT
