#!/bin/sh
# Mock LLM script for testing Argus LLM integration.
# Reads stdin and returns canned responses based on keywords.
# Exit 0 on success, 1 on failure keywords.

input=$(cat)

# Check for failure triggers.
case "$input" in
  *"FORCE_ERROR"*)
    echo "mock error: forced failure" >&2
    exit 1
    ;;
  *"FORCE_TIMEOUT"*)
    sleep 30
    exit 1
    ;;
esac

# Explain mode: return a canned explanation.
case "$input" in
  *"static analysis expert explaining"*)
    echo "## Finding 1"
    echo "The analysis found a potential issue in the analyzed modules."
    echo "This means the code has a pattern that could lead to problems."
    echo "Consider refactoring to address this finding."
    exit 0
    ;;
esac

# Query synthesis mode: return a simple Datalog program.
case "$input" in
  *"Souffle Datalog expert"*)
    # Check if this is a retry with error feedback.
    case "$input" in
      *"Previous attempt (failed)"*)
        cat <<'DL'
.include "../clientlib/imports.dl"

.decl query_result(func: symbol, mod: symbol)
.output query_result

query_result(func, mod) :-
  function_def(func, mod, _, _, _, 1).
DL
        exit 0
        ;;
    esac
    cat <<'DL'
.include "../clientlib/imports.dl"

.decl query_result(func: symbol, mod: symbol)
.output query_result

query_result(func, mod) :-
  function_def(func, mod, _, _, _, 1).
DL
    exit 0
    ;;
esac

# Enrichment mode: return JSON responses.
case "$input" in
  *"Determine the BEAM register values"*)
    # Count the number of sites by looking for "## Site" headers.
    count=$(echo "$input" | grep -c "## Site")
    i=1
    while [ "$i" -le "$count" ]; do
      echo "{\"site\": $i, \"value\": \"MockModule\"}"
      i=$((i + 1))
    done
    exit 0
    ;;
esac

# Default: echo back a summary.
echo "Mock LLM response for: $(echo "$input" | head -1)"
exit 0
