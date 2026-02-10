#!/usr/bin/env bash
#
# Runs analyze_project.exs against every project in a directory.
#
# Usage:
#   scripts/analyze_all.sh /path/to/projects [analysis]
#
# Supports both Elixir (mix.exs) and Erlang (rebar.config) projects.
# Projects are compiled before analysis. The analysis defaults to
# one_for_one_coupling.

set -euo pipefail

# Ctrl-C kills the entire process group (this script + all children).
trap 'kill 0' INT TERM

if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/projects [analysis]" >&2
  exit 1
fi

dir="$1"
analysis="${2:-}"

if [ ! -d "$dir" ]; then
  echo "Error: not a directory: $dir" >&2
  exit 1
fi

failed=0
analyzed=0
skipped=0

for project in "$dir"/*/; do
  if [ -f "$project/rebar.config" ]; then
    build="rebar3"
  elif [ -f "$project/mix.exs" ]; then
    build="mix"
  else
    skipped=$((skipped + 1))
    continue
  fi

  echo "════════════════════════════════════════════════════════════"
  echo "  $project ($build)"
  echo "════════════════════════════════════════════════════════════"
  echo

  compile_log=$(mktemp)
  echo "Compiling $project..."
  case "$build" in
    mix)
      if ! (cd "$project" && mix deps.get --quiet && mix compile --quiet) >"$compile_log" 2>&1; then
        echo "FAILED to compile: $project" >&2
        cat "$compile_log" >&2
        rm -f "$compile_log"
        failed=$((failed + 1))
        echo
        continue
      fi
      ;;
    rebar3)
      if ! (cd "$project" && rebar3 compile) >"$compile_log" 2>&1; then
        echo "FAILED to compile: $project" >&2
        cat "$compile_log" >&2
        rm -f "$compile_log"
        failed=$((failed + 1))
        echo
        continue
      fi
      ;;
  esac
  rm -f "$compile_log"
  echo

  if mix run scripts/analyze_project.exs "$project" $analysis; then
    analyzed=$((analyzed + 1))
  else
    echo "FAILED: $project" >&2
    failed=$((failed + 1))
  fi

  echo
done

echo "Done: $analyzed analyzed, $failed failed, $skipped skipped."

if [ "$failed" -gt 0 ]; then
  exit 1
fi
