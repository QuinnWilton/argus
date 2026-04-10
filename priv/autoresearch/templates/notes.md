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

<!--
The category the LLM is actively working on right now. "(none)"
if between attempts.
-->
(none)

## Open hypotheses

<!--
Ideas currently being explored. One bullet per hypothesis. Move to
Wins when accepted, to Dead ends when abandoned.

- [ ] <category>: <one-line hypothesis> (last tried: YYYY-MM-DD)
-->

## Wins

<!--
Accepted improvements, most recent first. Include the commit SHA
so the baseline commit can be found quickly.

- YYYY-MM-DD — `<category>`: -N via <brief description> [commit XXX]
-->

## Dead ends

<!--
Categories that have been attempted and abandoned. Document *why*
so future sessions don't retry them. Include a "REVISIT IF" condition
when a future change could unblock the idea.

- `<category>`: tried YYYY-MM-DD ×N, <reason>. REVISIT IF <condition>.
-->

## Parking lot

<!--
Ideas worth trying eventually but not now — lower priority or
blocked on something else. No format requirements; just notes.
-->
