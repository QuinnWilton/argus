# scry

[![CI](https://github.com/QuinnWilton/scry/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/scry/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/scry.svg)](https://hex.pm/packages/scry)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/scry)

Analysis-only Mix compiler for BEAM projects: incremental [argus](https://github.com/QuinnWilton/argus)
analyses via [roux](https://github.com/QuinnWilton/roux), reported as rich compiler diagnostics.

Scry runs **after** the Elixir compiler, reads the `.beam` files it produced, and
runs argus's Datalog analyses over them — supervision-tree anti-patterns, leaked
tasks, deadlock-prone call cycles, unsafe deserialization, and more. Findings
flow through the standard Mix compiler diagnostics infrastructure (editors and
CI see them like any compiler warning) and render as
[pentiment](https://github.com/QuinnWilton/pentiment) frames that show the
responsible lines, connected evidence in other files, and how to fix the issue:

```
warning[scry.coupling]: Coupled children under one_for_one
   ╭─[lib/depot/application.ex:19:5]
   │
17 │
18 │     opts = [strategy: :one_for_one, name: Depot.Supervisor]
19 │     Supervisor.start_link(children, opts)
   •     ──────────────────┬──────────────────
   •                       ╰── supervision tree defined here
20 │   end
21 │ end
   │
   ├─[lib/depot/queue.ex:76:5]
   │
74 │
75 │   defp broadcast(state, payload) do
76 │     Notifier.notify(state.notifier, @channel, payload)
   •     ────────────────────────┬─────────────────────────
   •                             ╰── coupling call
77 │   end
78 │ end
   │
   ├─[lib/depot/notifier.ex:1:1]
   │
 1 │ defmodule Depot.Notifier do
   • ─────────────┬─────────────
   •              ╰── called sibling
 2 │   @moduledoc """
 3 │   In-process pub/sub for job lifecycle events. Listener registrations
   │
   ╰─────
     note: Depot.Queue calls Depot.Notifier, but both are children of the
           one_for_one supervisor Depot.Application. When Depot.Notifier
           crashes and restarts, Depot.Queue is not restarted with it and
           keeps any stale pid, monitor, or cached state it held.
     help: restart-coupled siblings belong under `rest_for_one`, with
           `Depot.Notifier` started before `Depot.Queue` — a `Depot.Notifier`
           restart then restarts `Depot.Queue` too
     help: alternatively, have `Depot.Queue` monitor `Depot.Notifier` and
           re-resolve it on every use instead of caching state across crashes
```

(Real output over the test fixture in `test/fixtures/depot`; note/help
prose re-wrapped for README width.)

Fact extraction and Datalog solving are incremental: results are memoized in a
roux database persisted across `mix compile` runs, so a warm `mix compile`
re-analyzes nothing and a comment-only edit re-extracts one module and re-runs
zero analyses.

## Installation

Add scry in **all** environments with `runtime: false` (an `only:` dep breaks
`MIX_ENV=prod mix compile`, because `compilers:` would reference a missing
task; `runtime: false` keeps scry out of releases):

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers() ++ [:scry]
  ]
end

def deps do
  [
    {:scry, "~> 0.1.0", runtime: false}
  ]
end
```

For syntax-highlighted terminal frames, also add `{:makeup_elixir, "~> 1.0"}`
and `{:makeup_erlang, "~> 1.0"}` (they are optional; without them frames
render plain).

Projects that declare an explicit `applications:` list in `application/0`
(rather than `extra_applications`) must also set `prune_code_paths: false`
in `project/0`, or Mix prunes scry off the code path before the `:scry`
compiler can run.

Solving requires a [Souffle](https://souffle-lang.github.io/) binary on
`PATH`. Without one, scry skips analyses and emits a single notice (set
`scry: [souffle: :require]` to make it a hard error instead).

## Usage

`mix compile` now reports findings. Configuration lives under the `:scry`
project key:

```elixir
def project do
  [
    # ...
    scry: [
      analyses: [:coupling, :mailbox],         # default: argus's :default set; sets like :security work too
      severity: [mailbox: :error],             # per-analysis override
      ignore: [modules: [~r/^MyApp\.Gen/], files: ["lib/legacy/**"]],
      include_deps: false,
      fail_on: :error,                         # :warning promotes findings to build failures
      souffle: :warn,                          # | :require
      priors: :off                             # | :cached_only | :live | [mode: ..., cassette: "priors.jsonl"]
    ]
  ]
end
```

`priors:` turns on argus's heuristic facts: a classifier's answers about
names (is `totp_seed` a secret; does this helper read storage; does that
module front a process) that add findings marked `heuristic` or move a
severity, never remove one. `:live` asks the model for what the cache
does not hold and needs `TYPESAFE_API_KEY`; `:cached_only` is offline and
deterministic, and a committed cassette (`mix argus.priors export`,
named under `cassette:`) makes a CI run match a developer's. The rows
ride the manifest, so a warm run repeats no request.

A standalone task drives the same incremental core for one-shot and CI use:

```bash
mix scry                     # all configured analyses
mix scry coupling            # a specific analysis
mix scry security            # a named set
mix scry --list              # available analyses and sets
mix scry --format json       # machine-readable findings
mix scry --fail-above 0      # exit 1 on any finding
```

## Limitations

- **Umbrellas are per-app**: each child app analyzes its own beams with its
  own manifest, so cross-app analyses (call cycles, supervision across apps)
  under-report. `include_deps: true` on the app owning the supervision root
  pulls sibling ebins into the call graph as an escape hatch.
- **Line-granular anchors**: BEAM Line chunks carry no columns, so a label
  spans the anchored line's code, never a sub-expression.
- **Not yet on Hex**: roux and argus are pinned to tagged GitHub releases
  (argus's name is taken on hex; roux pins a GitHub fork of gen_lsp), so
  scry itself is consumed as a GitHub dependency:

  ```elixir
  {:scry, github: "QuinnWilton/scry", tag: "v0.1.4", runtime: false}
  ```

## License

MIT
