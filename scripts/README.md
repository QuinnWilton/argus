# Argus scripts

Tooling for running Argus against external BEAM projects. None of these are
compiled into the library — they're standalone Mix scripts and a shell wrapper.

## `analyze_project.exs`

Analyzes a single external Mix or Rebar3 project. The project must already be
compiled.

```bash
# Run all correctness analyses on Oban.
mix run scripts/analyze_project.exs /path/to/oban

# Run a single analysis.
mix run scripts/analyze_project.exs /path/to/oban supervision

# Run every available analysis (not just correctness).
mix run scripts/analyze_project.exs /path/to/oban all

# Write structured JSON to disk instead of pretty-printing.
mix run scripts/analyze_project.exs /path/to/oban --json /tmp/oban.json
```

What it does:

1. Adds the project's `_build/{env}/lib/*/ebin` directories to the BEAM code path.
2. Discovers project modules from the project's own ebin directories
   (umbrella apps under `apps/` are detected automatically).
3. Runs the requested analyses via `Argus.analyze/2` and either pretty-prints
   the results or writes them as JSON.

## `harness.exs`

Parallel batch harness for running Argus against many projects at once. Each
project runs in its own OS process (because `Code.prepend_path/1` mutates
global VM state, so we can't safely analyze multiple projects from the same
shell). Project-level parallelism is via `Task.async_stream/3`.

```bash
mix run scripts/harness.exs /path/to/projects/dir /path/to/output \
  --concurrency 4 \
  --analyses supervision,ets,unsafe_task \
  --timeout 900
```

Output layout:

```
output/
├── manifest.json     # run metadata, per-project status
├── triage.json       # cross-project index by finding type
├── phoenix/
│   ├── results.json  # full Argus results
│   └── compile.log   # captured compile output
└── ...
```

Use `--resume` to skip projects that already have a `results.json`.

## `analyze_all.sh`

Thin shell wrapper that walks a directory of projects, compiles each one,
and runs `analyze_project.exs` against it. Useful for quick spot checks
when you don't need the harness's parallelism or JSON output.

```bash
scripts/analyze_all.sh /path/to/projects             # default analysis
scripts/analyze_all.sh /path/to/projects supervision # specific analysis
```

Both Elixir (`mix.exs`) and Erlang (`rebar.config`) projects are supported.
The script `set -e`s and Ctrl-C kills the entire process group.
