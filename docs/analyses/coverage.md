# Analysis coverage

[Bug-class catalog](../bug-classes.md)

Coverage is an opt-in analysis of what Argus could resolve. All findings here are
**info**. They are not program defects, and a missing finding elsewhere is less
informative when the relevant facts were not recovered.

## Extractor fallbacks

`imprecision_event`

| Reason | What happened |
|---|---|
| `dynamic` | A fact contains an unknown-value placeholder. |
| `unresolvable` | A whole argument or structure could not be read. |
| `skipped` | The extractor omitted a fact it could not recover. |
| `missing` | A required callback or definition could not be resolved. |

Only instrumented fallbacks appear. Events describe extraction, before later
points-to resolution; a dynamic target may subsequently become known. Use the named
relation and category to locate the coverage gap.

## Supervisors without recovered children

`coverage_supervisor_no_children`

A recognized supervisor has no recovered static or dynamic children. Runtime-built
specs or unattributed starts may explain this. Tree-based analyses have little
information about its subtree; the finding does not prove the supervisor is empty.

## GenServers without observed traffic

`coverage_genserver_isolated`

No resolved call, cast or send reaches the server, and no recognized supervisor starts
it. The server may be unused, called only outside the analyzed program, or hidden by
unresolved target flow. Recognized supervised modules are excluded from this check.

## ETS tables without observed operations

`coverage_ets_unused`

A table with a literal creation name has no identified accesses. Reference-based or
dynamic access can be harder to connect to the allocation; unresolved operations in
the creating module may suppress the report. Inspect table identity resolution
before interpreting it as dead storage.

## Registered names without traffic

`coverage_named_process_unreachable`

No resolved traffic reaches a literal registered name or a PID associated with it.
Other nodes and external callers may be its intended users. Computed names are not
covered. This is a prompt to inspect analysis scope and target resolution, not a
reason by itself to delete the registration.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/coverage.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/coverage.ex).
