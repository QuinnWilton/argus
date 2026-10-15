# Unsafe input

[Bug-class catalog](../bug-classes.md)

This analysis connects external entry points to operations that can exhaust resources,
execute code, run subprocesses, alter SQL or HTML syntax, or use upload filenames as
filesystem paths.
It also checks whether cryptographic verification results are enforced. A call path is weaker evidence than tracked data flow. Inspect the
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

Code execution and subprocesses stay at least warning regardless of distance. Optional
value-source priors can lower some severities and mark the evidence heuristic; they do
not prove that a value is trusted. Missing flow facts are not evidence of safety.
Wrappers, returned values, higher-order calls and unsupported propagators can reduce a
flow to a path. A route frame does not establish whether authentication protects it.

## Unbounded atom creation

`sink=atom`

Converting arbitrary strings or lists to atoms can exhaust the node's atom table.
Recognized finite sets, literal membership checks, integer ranges and bounded
combinations can suppress the finding. Existing-atom conversions are not creation
sinks. Prefer an explicit mapping when the accepted names are finite.

Bounds must cover every relevant path. Fixed table lookups retain their finite
vocabulary, including every possible fallback. Guard alternatives can retain
correlations between token characters, with deterministic limits that discard a
proof when exhausted. Private helpers inherit finite arguments only when every
direct caller establishes the bound and the helper cannot escape as a function.
Finite return summaries cover every returning branch; unknown returns remain
unbounded. Numeric equality counts integer and float alternatives separately;
composite numeric equality remains conservative. Cardinalities account for
combinations, and feeding generated atoms
back into the same conversion can defeat an apparent existing-atom bound.
Constructed finite proper lists retain their vocabulary through `Enum.reverse/1`;
cardinality and list-size budgets bound that proof. Protocol dispatch requires
builtin input evidence: a finite custom struct does not make its `Enumerable` or
`String.Chars` implementation independent of external state.

A separate sequence proof carries character alphabets through recursive private
helpers and tuple fields. A later length guard can establish a finite vocabulary
at `list_to_atom/1`. This proof concerns successful character conversion only:
numeric guards alone do not establish a finite set of floating-point values.
Unknown callers, unsupported control flow, and exhausted proof budgets retain
the warning.

Request call paths do not by themselves make configured atoms request-selected.
The existing-atom check follows the argument's provenance; mutable LiveView socket
data remains conservative. Generated parser state, separate fields of configuration
objects, and relationships between grammar actions and token buffers can require
facts beyond these bounds and may still produce warnings.

Without a request path, caller-derived input through a public API is reported at
warning. Runtime callbacks and known internal values are treated differently from
library entry points. Priors may lower this fallback to info.

The name of an atom that exists, read back into an atom
(`String.to_atom(Atom.to_string(a))`, `list_to_atom(atom_to_list(a))`), is that atom:
the conversion makes none, whoever chose `a`, so it is no sink. A private helper
inherits this from callers that each hand it such a name. A name written as Latin-1
and read as UTF-8 can name another atom and keeps the weaker existing-atom bound
above. Names that reach the conversion as text from elsewhere, such as a function
name parsed out of an ID string, are not recognized.

## Unbounded decompression

`sink=decompression`

Supported zlib APIs can allocate the expanded output before code checks its size.
A small compressed input can therefore consume excessive memory. Bound expansion
while streaming, rather than checking the size only after full decompression.

The detector excludes bounded-chunk APIs, but does not prove that a loop using them
enforces a total output limit. Zip/tar extraction and unmodeled wrappers are outside
this sink list. With no request path, caller-derived data is a warning whether it
comes from a network response or another external source.

An exported decoder is judged by the calls the program makes to it, where it makes
some: when every one hands the decoded parameter a literal (a module attribute built
at compile time, such as an embedded tree's gzipped payload), the bytes are the
program's own and neither decompression nor deserialization is reported. One call with
other bytes, a fun of the decoder handed on, or no call in the program at all keeps
the finding. What the decoded argument is made of is Dependence's answer; a value it
does not see beside the parameter, such as a received message, is a known limit.

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
non-executable/safe decoders are excluded from the term-safety finding. They remain
subject to the separate compressed-allocation check below.

Local recursive validators can clear this warning when their bytecode proves that
only inert scalars, recursively checked list heads and tails, every tuple element,
and map keys and values can be accepted. The accepted verdict must protect the
exact decoded result on every accepted path. Rejected error envelopes can be
forwarded unchanged, but projecting or consuming their rejected payload is not
certified. Unknown exception paths fail the proof. Unsupported validation remains
unknown. A `[:safe]` warning therefore does not
establish that validation is absent or that a decoded function reaches execution.
Review the accepted success payload and the treatment of rejected values separately.

Unlike atom creation, the fallback reports deserialization even without caller-input
evidence. Trusted files and internally stored terms can therefore be reported. The
program's own literals are not (see decompression above).
Request-path severity still follows proximity, so a distant request path can have
lower severity than the no-request fallback. This is the current grading behaviour,
not a statement that adding a request path makes decoding safer.

## Compressed ETF allocation

`compressed_etf_from_input` · **warning**

ETF decoders can expand compressed input before checking the decoded term.
Neither `[:safe]` nor an executable-term rejection wrapper bounds this allocation.
The finding follows caller-derived bytes to a decoder, including supported local
delegates. A cap on compressed input length alone does not establish safety.
Captured and exported delegates retain their own entry points even when their
direct callers reject compressed input.

A check must reject the compressed ETF prefix `<<131, 80, _::binary>>` for the
same bytes before decoding on every path. Supported local predicates can establish
that proof when compressed input cannot produce the result the caller accepts.
Checks after decoding, on another binary, or on only one incoming path do not clear
the finding. Uncompressed input should also have a size cap; this rule specifically
checks the compressed allocation risk.

## Unenforced cryptographic verification

`unchecked_crypto_verification` · **error**

JOSE returns a verification boolean alongside the payload, including when the
signature is invalid. Matching the tuple shape and using the payload does not
enforce that boolean. The detector requires a successful verdict from the same
invocation before the particular payload use on every path.

It distinguishes payload consumption from forwarding a complete result, passing
the verdict and payload together, and raising with the payload. A later use without
the verdict is still checked. Supported OTP boolean-returning verification APIs
are also reported when their results are provably discarded. Unknown result fate
is not treated as proof of discard, and validation inside unknown helpers remains
outside this local result-use model.

## Dynamic code execution

`sink=code`

The sink list includes supported Code and EEx evaluation/compilation APIs.
Request-controlled input can execute with the node's privileges. This check
intentionally requires no proven input flow. Literal EEx sources are excluded. Other
reachable code evaluation can still be reported without evidence that a caller
chooses the source.

Without a request path, reachability from an export is an error before optional
re-tiering. Code execution never falls below warning through distance, priors or
tooling classification. An administrative endpoint still needs an explicit trust
boundary; the analysis does not model its authorization policy.

## Subprocess execution

`sink=command`

`System.cmd/2,3`, `:os.cmd/1,2` and `System.shell/1,2` run a program on the host,
not code in the node. A call is a finding where data reaches what runs: the program
`System.cmd` runs and the arguments it hands a shell or interpreter, or the whole
command line `:os.cmd` and `System.shell` hand a shell. A literal program that runs
none of its arguments, a fully literal command line, and a shell or interpreter handed
literal arguments on every path (`mix` handed a task that runs no code included) are
no sink.

A shell handed `-c` and a literal script runs nothing the arguments after the script
say, where the script uses them only as double-quoted arguments of programs that do not
run their arguments: `sh -c 'kill -0 "$1"' sh pid` runs `kill`, whatever `pid` holds.
A positional parameter as a command word (`"$@" &`), unquoted, handed to `eval`,
`exec`, `trap`, a shell, an interpreter or a wrapper such as `env` or `xargs`, or a
script with command substitution, a here-document, an alias or a change of `PATH` or
directory, leaves the arguments code.

Without a request path, the finding requires that an exported function's caller hands
in what runs (or a function the program makes a fun of, which runs with whatever its
holder hands it), and is an error: it is a flow, not reachability. A program found on
the PATH or named by configuration, run with literal arguments, is no finding. A
request's flow is an error; a request's path to a subprocess is a warning where
anything reaches what it runs, and no finding where the program and script are made of
literals, the environment and configuration alone.

Option injection into an otherwise literal command (`git "$@"` or `System.cmd("tar",
args)` handed `--to-command`), and `env:` entries such as `LD_PRELOAD`, are not
covered. Port spawns are outside the list.

## Runtime template sources

`runtime_template_evaluation` · **warning**

Content returned by a runtime callback can reach EEx evaluation through supported
same-module helpers. This finding identifies a template trust boundary even without
a modeled web entry. Callback-produced content is not necessarily attacker-controlled.
Literal template source and dynamic binding values are distinct: bindings alone do
not create this finding.

The rules carry literal branch requirements through call arguments. A call passing
`false` to an evaluation flag can therefore exclude a sink guarded by that flag;
an unknown flag cannot. Unknown callback results remain runtime sources, while a
resolved callback returning only literal content does not. Unsupported external
helper returns, nested higher-order evaluation paths and more complex branch
conditions limit coverage.

## SQL construction

`sql_injection` · **error**

The statement argument is separate from bound parameters at known SQL APIs. The
analysis tracks binary and iodata construction, supported same-module returns and
mapping callbacks, retaining each interpolated value's lexical context. Quoted
identifiers, SQL string literals, dollar-quoted blocks and comments have separate
findings and safety requirements.

Generated Ecto Repo `query` and `query!` implementations are recognized as API
boundaries only when they forward the statement unchanged to the adapter.
The analysis checks SQL construction at calls to those wrappers, including
their generated default-argument shims. A similarly named function alone is
not an SQL sink, and a generated function that constructs SQL remains reportable.

Doubling double quotes only protects a surrounding PostgreSQL identifier, and only
at a recognized PostgreSQL boundary. It cannot protect the enclosing dollar delimiter.
A supported generated delimiter is safe only when its selected candidate is absent
from the same wrapped body; the body still needs correct inner identifier quoting.
Query-comment validation must reject both null bytes and `*/` for the same comment
before execution or persistence in supported Postgrex stream options. Merely calling
a predicate, checking another value, or rescuing a rejecting exception and continuing
does not establish this proof.

The symbolic construction walk is bounded and is not a complete SQL parser. Arbitrary
external helper returns, unmodeled database APIs and dynamic query builders can hide
flows. Unknown database dialects do not inherit PostgreSQL-specific escaping proofs.

## Raw HTML

`unescaped_html_from_input` · **warning**

Caller-derived text reaches a supported raw HTML output without a matching escaping
proof. Render assigns include stored user-authored labels as well as request values.
The finding does not establish that every caller supplies attacker-controlled text.

Escaping must apply to the actual emitted bytes. Regex escaping is unrelated to HTML
escaping. Known HTML escaping can protect text content, including supported static
highlighting around escaped text, but does not establish safety in script or attribute
contexts. Phoenix's `html_escape` passes existing `{:safe, value}` tuples through;
its name alone is therefore not a proof that arbitrary input was escaped.

Supported same-module returns and every direct caller of a private helper can
establish a proof for the whole output. A JavaScript string inside a script needs
its exact quote, backslash and newline escaping in the correct order, plus closing
script-tag protection. Separately escaped fragments cannot establish this proof
if their concatenation introduces a closing tag. External renderer names, including
QR/SVG libraries, do not establish safety without a proof of their returned bytes.
Replacing bytes in existing markup can change its parser context, so highlighting
proofs require escaped plain text before adding markup. A custom `String.Chars`
implementation can return a safe tuple despite its specification; only a proven
binary value establishes the binary protocol implementation's identity behavior.

An exported render function can receive arbitrary assigns. One safe event handler
or a default value does not protect a field that caller-provided assigns can
override. Neither configuration field names nor developer-documentation labels
establish a trust boundary.

Computed content types and response bodies returned through unsupported helpers,
as well as collection results from another module, currently limit this rule.
The AshAdmin advisory is covered; the Oaskit and Hexpm XSS advisory shapes are not
claimed covered by this implementation.

## Upload filenames in filesystem paths

`upload_filename_path_traversal` · **error**

The browser supplies an upload entry's `client_name`, independently of the temporary
path created by the server. The analysis follows that exact field from a supported
LiveView upload callback into filesystem paths. Joining it to a trusted directory does
not prevent `..` or embedded separators from selecting another path.

Using `Path.basename` as the final component can clear supported file-leaf operations.
It is not a general containment proof: directory operations, later components or suffixes,
unknown alternatives and symlink behavior require separate reasoning. Server-generated
names avoid trusting the client's filename. Unmodeled upload APIs and forwarding a
callback value to sinks in unsupported helpers limit coverage.

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
