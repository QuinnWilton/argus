# Argus Autoresearch

This document is the LLM-maintained narrative for the argus
autoresearch loop. Tools (`mix argus.autoresearch ...`) own the
structured event log in `session/autoresearch.jsonl`; this file
captures the higher-level context that survives across sessions.

The LLM (driven by the `argus-autoresearch` skill) reads this file
at the start of every session and updates it after every iteration.
Keep entries concrete and dated.

## Objective

<!--
A rough, measurable goal. Example:

    Halve the fast-tier imprecision_event row count over the next
    10 iterations. Focus on categories with a clear dataflow
    recovery path — skip anything requiring new Datalog rules or
    cross-module analysis.
-->

## Current focus

(none)

## Open hypotheses

- [x] `ignored_result_unknown_api`: detect tail calls (call_ext_only/last) as "result used" — tail-called APIs return their result to the caller, not ignored (2026-04-10)

## Wins

- 2026-04-10 — `gen_server_start_name`: -5 (5→0, fully eliminated) via tail-call suppression in maybe_named_start/maybe_named_start_erlang. [commit 0b0b6b7]
- 2026-04-10 — `ignored_result_unknown_api`: -4 (4→0, fully eliminated) via result_used? heuristic recognizing x0-consumed patterns (save-to-y, test, destructure, pass-forward). [commit da3102c]
- 2026-04-10 — `ignored_result_unknown_api`: -18 (22→4) via tail-call detection in result_ignored? heuristic. Also eliminated 3 categories and reduced net imprecision by 48 (95→47). [commit 81655cf]

## Dead ends

- `coverage_supervisor_no_children` (closure scanning): tried 2026-04-10, reverted. Scanning all `make_fun3` closures in init/1 for child specs is unsound — closures may be used for non-child-spec purposes (telemetry handlers, filter predicates, config builders) and any `{Module, args}` tuple in them would be incorrectly classified as a supervised child. A sound fix would need to trace the closure's return value to confirm it flows into `Supervisor.init/2`'s children argument. REVISIT IF argus gains dataflow tracking for closure return values.

## Parking lot

- Measurement variance: consecutive measure runs can produce different counts (e.g. 47 vs 73 vs 146 for the same code). Root cause appears to be subprocess cold-start effects — counts stabilize after 1-2 runs. Consider adding a warm-up run or taking the median of N runs for reliable diffing.
