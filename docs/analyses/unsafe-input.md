# Unsafe input

[Bug-class catalog](../bug-classes.md)

This analysis connects external entry points to operations that can exhaust resources
or execute code. A call path is weaker evidence than tracked data flow. Inspect the
proximity and value evidence before interpreting a finding as exploitable input flow.

Recognized entries include Plug/controller requests, selected LiveView and channel
callbacks, Oban jobs, Broadway messages, ThousandIsland socket data and WebSock frames.
Only designated parameters carry external data. Callback names and behaviours determine
coverage; not every public endpoint, hook or authentication boundary is understood.

## Evidence and severity

`sink_reachable` identifies a request path. `sink_without_request_path` uses the
sink-specific fallback described below.

| Proximity | Evidence | Usual severity |
|---|---|---|
| `flow` | A request parameter contributes to the sink argument. | error |
| `direct` | The sink is in the entry function. | error |
| `rendered` | Template assigns contribute to the converted value. | warning |
| `adjacent` | The entry calls the sink function. | warning |
| `transitive` | A longer call path reaches it. | info |

Code execution stays at least warning regardless of distance. Optional value-source
priors can lower some severities and mark the evidence heuristic; they do not prove
that a value is trusted. Missing flow facts are not evidence of safety. Wrappers,
returned values, higher-order calls and unsupported propagators can reduce a flow
to a path. A route frame does not establish whether authentication protects it.

## Unbounded atom creation

`sink=atom`

Converting arbitrary strings or lists to atoms can exhaust the node's atom table.
Recognized finite sets, literal membership checks, integer ranges and bounded
combinations can suppress the finding. Existing-atom conversions are not creation
sinks. Prefer an explicit mapping when the accepted names are finite.

Bounds must cover every relevant path. Most checks are local to the sink function;
a few literal-list forwarding patterns cross calls. Cardinalities must account for
combinations, and feeding generated atoms back into the same conversion can defeat
an apparent existing-atom bound.

Without a request path, caller-derived input through a public API is reported at
warning. Runtime callbacks and known internal values are treated differently from
library entry points. Priors may lower this fallback to info.

## Unbounded decompression

`sink=decompression`

Supported zlib APIs can allocate the expanded output before code checks its size.
A small compressed input can therefore consume excessive memory. Bound expansion
while streaming, rather than checking the size only after full decompression.

The detector excludes bounded-chunk APIs, but does not prove that a loop using them
enforces a total output limit. Zip/tar extraction and unmodeled wrappers are outside
this sink list. With no request path, caller-derived data is a warning whether it
comes from a network response or another external source.

## Deserialization

`sink=deserialization`

binary_to_term is classified by its options:

| Safety | Meaning | Severity without a request path |
|---|---|---|
| `unsafe` | No literal safe option. | error |
| `atoms_only` | A literal option list contains safe. | warning |
| `dynamic` | The options cannot be read. | error |

The safe option does not validate an application's expected term shape or exclude
all executable terms. Validate the decoded representation and use a suitable
non-executable decoder when handling untrusted terms. Recognized Plug.Crypto
non-executable/safe decoders are not sinks in this model.

Unlike atom creation, the fallback reports deserialization even without caller-input
evidence. Trusted files and internally stored terms can therefore be reported.
Request-path severity still follows proximity, so a distant request path can have
lower severity than the no-request fallback. This is the current grading behaviour,
not a statement that adding a request path makes decoding safer.

## Dynamic code execution

`sink=code`

The sink list includes supported Code evaluation/compilation APIs, shell commands
and dynamic command execution. Request-controlled input can execute with the node's
privileges. This check intentionally requires no proven input flow: reachable literal
evaluation and shell commands can also be reported.

For System.cmd, a literal non-interpreter executable is excluded; a dynamic executable
or shell/interpreter with non-literal arguments remains a sink. This does not cover
option injection into otherwise literal commands. Some evaluation and port-spawn APIs
are outside the list.

Without a request path, reachability from an export is an error before optional
re-tiering. Code execution never falls below warning through distance, priors or
tooling classification. An administrative endpoint still needs an explicit trust
boundary; the analysis does not model its authorization policy.

## Children that outlive requests

`unbounded_children_from_request` · **error**

A request can start children under a supervisor with no recognized finite cap and
without waiting for them to finish. Repeated requests can accumulate processes.
Use an explicit concurrency/lifetime bound appropriate to the service.

Task streams enumerated by the request's own process and starts followed by a
recognized wait for child exit are excluded. Detached enumeration, a timeout or an
early reply can break that lifetime bound. The analysis recognizes selected cap
locations; unread cap options are unknown, not evidence of no cap. Dynamic supervisor
identities and deployment-specific admission control can limit the finding.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/unsafe_input.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/unsafe_input.ex).

Regression cases live in [test/analyses](https://github.com/QuinnWilton/argus/blob/main/test/analyses) and [test/soundness](https://github.com/QuinnWilton/argus/blob/main/test/soundness).
