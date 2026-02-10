# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/argus.svg)](https://hex.pm/packages/argus)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/argus)

BEAM program analysis via [Souffle](https://souffle-lang.github.io/) Datalog.

## Installation

Add `argus` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:argus, "~> 0.1.0"}
  ]
end
```

[Souffle](https://souffle-lang.github.io/install) must be installed and available on your `PATH`.

## Approach

Argus extracts Datalog facts directly from BEAM bytecode and evaluates them with Souffle to perform whole-program, multi-module analysis. This is the same approach used by [Doop](https://bitbucket.org/yanniss/doop/src/master/) (JVM), [cclyzer++](https://github.com/GaloisInc/cclyzer-plusplus) (LLVM IR), and [Gigahorse](https://github.com/nevillegrech/gigahorse-toolchain) (EVM)—but the BEAM's register-based instruction set lets us skip the expensive IR-lifting step those frameworks require. BEAM instructions map to Datalog facts without an intermediate representation.

## Pipeline

```
.beam files → normalize → emit facts → Souffle rules → results
```

**Layer 1** walks every BEAM instruction and emits base facts about instructions, registers, control flow, and calls. **Layer 2** (domain extractors) produces higher-level semantic facts by interpreting OTP patterns, supervision trees, ETS usage, and other BEAM-specific constructs. Both layers feed into Souffle, which evaluates Datalog rules and returns derived relations.

## Quick start

```bash
mix deps.get
mix compile

# List available analyses.
mix argus --list

# Run an analysis against all project modules.
mix argus cfg
mix argus callgraph
mix argus supervision

# Scope to specific modules.
mix argus callgraph --modules Enum,:lists

# Render a call graph as SVG.
mix argus callgraph --format dot | dot -Tsvg -o graph.svg

# Fail CI if anti-patterns are found.
mix argus supervision --fail-above 0

# Run ad-hoc Datalog rules.
mix argus custom path/to/rules.dl
```

## Programmatic API

```elixir
# Analyze a single module's control flow graph.
Argus.analyze([:lists], :cfg)

# Analyze call graph across modules.
Argus.analyze([Enum, :lists], :callgraph)

# Run custom Datalog rules.
Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})
```

## License

MIT
