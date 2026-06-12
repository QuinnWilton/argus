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

- 2026-06-12 — **measurement variance ROOT-CAUSED AND FIXED** (parking-lot item):
  work/output dirs were named with System.unique_integer alone, which is
  VM-local — concurrent measure subprocesses all picked the same /tmp/argus_<N>
  and clobbered each other's facts (3 of 5 projects could return byte-identical
  reports for the wrong codebase). Names now include :os.getpid(). Three
  consecutive measures agree exactly (69 events / 12 shape-gap rows). All
  pre-fix corpus diffs were untrustworthy. [commit 440233f]
- 2026-06-12 — placeholder-atom leak: resolve_register could surface the
  :dynamic marker inside {:ok, _} and inspect/1 forged ":dynamic" fact fields
  that evade every dynamic filter. Fixed at the resolve_register boundary +
  nested keyword/tuple consumers. coverage_named_process_unreachable -2 (3→1,
  the PG2Worker/Tracker.Shard ghosts), gen_server_start_name +2 (honest
  imprecision for what was previously emitted as fact). [commit 76ae89a]
- 2026-04-10 — interprocedural constant propagation: new call_arg fact + Datalog resolved_arg rules derive additional sync_call/async_cast rows by tracing literals through wrapper call chains. All correctness analyses benefit via enriched call graph. Oban baseline preserved (7 findings unchanged). [commits 9dd8434, 522edd5, c08d3e8]
- 2026-04-10 — shape-gap rules: -6 rows (20→14) via 3 Datalog fixes: exclude supervised GenServers from isolated, exclude same-module-ops tables from unused, filter dynamic names from unreachable. [commit fd23c33]
- 2026-04-10 — `gen_server_start_name`: -5 (5→0, fully eliminated) via tail-call suppression in maybe_named_start/maybe_named_start_erlang. [commit 0b0b6b7]
- 2026-04-10 — `ignored_result_unknown_api`: -4 (4→0, fully eliminated) via result_used? heuristic recognizing x0-consumed patterns (save-to-y, test, destructure, pass-forward). [commit da3102c]
- 2026-04-10 — `ignored_result_unknown_api`: -18 (22→4) via tail-call detection in result_ignored? heuristic. Also eliminated 3 categories and reduced net imprecision by 48 (95→47). [commit 81655cf]

- 2026-06-12 — `ets_table_ref_op` (in-function slice): ops on a table ref now
  inherit the same-function :ets.new site's name via Helpers.call_result_origin
  (move-chain walk with sound x/y register lifetimes). Corpus-NEUTRAL on both
  fast and medium tiers — every remaining event there is a state-held table
  created in another function. Pinned by EtsRefOps fixture. REVISIT the
  remaining 30 events IF argus gains cross-function value tracking (same
  condition as the coverage_supervisor_no_children dead end). [commit 9b8f6c7]

## Dead ends

- `coverage_supervisor_no_children` (closure scanning): tried 2026-04-10, reverted. Scanning all `make_fun3` closures in init/1 for child specs is unsound — closures may be used for non-child-spec purposes (telemetry handlers, filter predicates, config builders) and any `{Module, args}` tuple in them would be incorrectly classified as a supervised child. A sound fix would need to trace the closure's return value to confirm it flows into `Supervisor.init/2`'s children argument. REVISIT IF argus gains dataflow tracking for closure return values.

## Parking lot

- ~~Measurement variance~~ RESOLVED 2026-06-12: not cold-start effects — concurrent
  subprocess VMs shared the same VM-local-unique temp dir names and raced on the
  facts directories. Fixed by adding :os.getpid() to the names (commit 440233f).
  Measures are now exactly reproducible.
