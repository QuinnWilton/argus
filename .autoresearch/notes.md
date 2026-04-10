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

- 2026-04-10 — `ignored_result_unknown_api`: -4 (4→0, fully eliminated) via result_used? heuristic recognizing x0-consumed patterns (save-to-y, test, destructure, pass-forward). [commit da3102c]
- 2026-04-10 — `ignored_result_unknown_api`: -18 (22→4) via tail-call detection in result_ignored? heuristic. Also eliminated 3 categories and reduced net imprecision by 48 (95→47). [commit 81655cf]

## Dead ends

## Parking lot

- Measurement variance: consecutive measure runs can produce different counts (e.g. 47 vs 73 vs 146 for the same code). Root cause appears to be subprocess cold-start effects — counts stabilize after 1-2 runs. Consider adding a warm-up run or taking the median of N runs for reliable diffing.
