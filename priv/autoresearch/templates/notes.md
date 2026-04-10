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

## Wins

## Dead ends

## Parking lot
