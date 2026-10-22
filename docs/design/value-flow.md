# Intraprocedural value flow

[Shared analysis model](analysis-model.md) · [Comparison with Doop, Soot and Gigahorse](value-flow-comparison.md) ·
[Glossary](../glossary.md)

`Argus.Extractors.TermFlow` summarizes provenance within each BEAM function.
It follows parameters, project-call results, containers, replies, ETS tables
and dictionary values as well as PIDs. Its summaries name values as *variables*
(a kind and a key, [glossary](../glossary.md#value-flow)): general provenance
uses `call_arg_var`, `return_var`, `call_result_var` and the term relations, and
process operations expose `process_*_var` relations.

## Model

A register definition holds a set of source tokens, each a variable the
register may hold. A read joins the sets of
all definitions reaching that register, using `Argus.Dataflow`'s register and
control-flow semantics. Parameter definitions contribute their position, and a
literal operand (an atom, a binary, an integer) contributes itself, spelled as
`Argus.Extractor.Terms.spell/1` spells it. Moves,
swaps and frame trims transport these sets; a send returns its message; unsupported writes contribute no
modeled provenance. The empty set is **missing evidence**, not proof of safety.

Containers are objects identified by their construction instruction. Nested
objects synthesized by a call have distinct suffixes at that site. Each object
has a shape, a map from selectors to source sets, inherited `base` sources, and
selectors it definitely overwrites. For a literal selector `s`, a local read is:

```
fields[o, s] ∪ unknown_key_fields[o, s]
  ∪ (if s is not overwritten: read(base[o], s))
```

Unknown-key fields apply to literal map reads. A constant overwrite can shadow
an old source even though the replacement's source set is empty. A write under
an unknown key cannot shadow a particular base field. Reads of external
containers (including dictionary contents) become deferred `load` sources for Datalog to resolve.

Tuple selectors are zero-based `{i}`; map selectors use the common literal
spelling; `[]` merges list elements. Cons cells retain their tails as bases.
Reading a list tail preserves the collection abstraction, so reading its head
can also include earlier elements. Spawn argument positions are recovered only
from a single chain of locally constructed cons cells with a literal empty tail.
Unknown, ambiguous or cyclic chains have no positional summary.

## Solving

`ValueFlow` starts register outputs at bottom and runs a sparse worklist.
Changes to a definition reschedule its register users. `TermFlow.Heap` separately
records every object visited by a field read, including missing or empty
objects, and reschedules those readers when the object changes. Object identity
can stay fixed while its fields grow: register dependencies alone are insufficient.

For fixed instructions and selectors, the token universe is finite. Transfers
join sources, with overwrite sets fixed by the instruction rather than by the
sources discovered so far. These monotone equations converge to the least
fixpoint of the **modeled** operations, independent of schedule. Local reads
visit each object once along a base path; source-free heap cycles stay empty.
TermFlow has no evaluation cutoff. An explicit `ValueFlow` budget raises when
exhausted instead of exposing an incomplete result as a solved function.

Emission occurs after convergence. Objects are emitted only if they transitively
contain a non-closure source; source-free cycles emit no objects. Rows are sorted
and deduplicated. Shared Datalog resolves calls, callback state, messages,
registries, replies and dictionary contents across these function summaries.

## Variable kinds and relation families

| Kind | Meaning |
|---|---|
| `param`, `result`, `reply` | Parameter position, project invocation result, synchronous server reply. |
| `term`, `load` | Local allocation site, deferred external field read. |
| `process`, `self`, `name` | Started process, running process, literal registry reference. |
| `literal` | A literal atom, binary or integer, spelled; not booleans or `nil`. |
| `table`, `dictionary`, `remote` | ETS allocation, literal dictionary key, possibly remote PID origin. |

`call_arg_var`, `return_var` and `call_result_var` connect parameters and returns.
`term_allocation`, `field_store`, `term_update_base`, `term_update_overwrites` and `field_load` describe containers.
A tuple element load runs only once its match has passed: `field_load_match`
gives the arity and, when tested, the tag that every path to it matched, and
points-to reads such a load from the tuples that fit it alone. A tuple whose
tag or arity is not known fits any match. A read of a register past such a
match, any instruction's, skips the tuples the function built that the match
does not fit: `{:error, e} -> {:error, e}` hands back the term it matched,
and that is not the `{:ok, pid}` the same register held on the other path.
`process_start` and `process_{call,message,send,signal,register}_var`
describe process operations. Table, dictionary and remote-PID
relations expose their respective operations. Exact columns and consumers are
specified in `lib/argus/schema/` and `priv/dl/clientlib/`.

## Library calls

`Argus.Extractors.TermFlow.Library` says what each collection call of `Enum`,
`Stream`, `List`, `Map`, `Keyword`, `MapSet`, `Tuple`, `:lists`, `:maps` and the
container BIFs answers, as a spec over its arguments: an element of one, a new
list of another's elements, a tuple, a map built from pairs, and so on. Value
flow follows a value through a modeled call by that spec, and a call that only
inspects (`Enum.count/1`, `Map.has_key?/2`) answers nothing and keeps nothing.

Enumeration is uniform: a list yields its `[]` field, a map its `{key, value}`
pairs, and a MapSet — modeled as the list of its members — its members. A map
holds a key that is not a literal under the pseudo-field `@key`, so a pair's
key is what was put there. A lookup in a keyword list under a literal key
(`Keyword.get/2`, `opts[:key]`) reads the pairs tagged with that key alone,
as a match of `{^key, value}` would. A pair is allocated at the call for a map built in
the function, and for a map from elsewhere points-to stands one for it
(`pair <map>`, `clientlib/processes.dl`). `**` reads any field
(`Tuple.to_list/1`). A stream is the list it would enumerate.

A call running a fun on each element (`Enum.map/2`, `Enum.reduce/3`,
`Map.new/2`, `:maps.fold/3`, ...) names the program's fun it runs in
`element_fun`: the fun's parameters receive the elements, pairs or accumulator
as `element` `call_arg_var`s, and when the call's answer holds what the fun
answers, a `call_result_var` names the fun as the callee — `Enum.map/2`'s answer
is a list of those answers, a fold's the answer itself. A library function
captured as the fun (`&Task.await/1`, `&List.wrap/1`) is applied by its own
model. `task_operation_var` records what each Task operation is handed.

Any other call outside the program — an unmodeled library call, a send, a
dynamic `fun.(...)` or `apply`, a call running a fun the table does not know —
records what it is handed in `unmodeled_use`. A rule needing to know a value's
every use treats an escape as a use it cannot see (`clientlib/task_handles.dl`).
`test/analyses/task_library_flow_test.exs` carries a task through every modeled
call, both collected and dropped, and fails for a modeled call without an
entry.

## Precision and coverage limits

- Branches join alternatives without path predicates. Repeated allocations at
  one site share an object, including across loop iterations. Correlations
  between fields or branches are lost; a modeled source need not be feasible.
- A literal tuple, list, map or float carries no source, and neither do
  `true`, `false` and `nil`. A literal alone does not make a term worth
  emitting: a term holding only literals and unmodeled values is not emitted, and
  `unmodeled_use` leaves literals out. Empty sets cannot distinguish an
  unsupported result from a not-yet-discovered source during solving.
- Only explicit structural instructions and recognized library operations
  preserve provenance. Unresolved calls, dynamic apply and unmodeled runtime
  results can lose it; `unmodeled_use` records where a library call or a
  dynamic call is handed a value, so a consumer can tell a lost value from a
  dropped one. Closure tokens identify spawned functions but are not emitted
  as general values: a fun is followed only where a modeled library call runs
  it in the calling process. This is not complete higher-order value flow.
- Library models over-approximate what an answer holds: `Enum.take/2` holds
  every element, a map update every field its base held, a MapSet is a list.
- A map read with an unknown key reads only the unknown-key field `*`, rather
  than every literal field. This intentionally sacrifices coverage. Unknown
  writes can alias every literal read. Literal map keys are spelled as terms,
  so the string `"*"` is distinct from the reserved selector `*`.
- Default-valued map/access reads conservatively include the default even when
  the key might be present. `Access.get` models map-style selectors, not every
  custom Access implementation. Tuple/list reads do not prove shape validity.
- Dictionary and registry identities describe possible shared contents, not a
  time-ordered simulation of mutations. External containers and call results
  depend on the coverage and abstraction of the consuming Datalog stage.

These summaries must not justify safety from absent provenance. The
whole-program points-to stage has its own guarantees; its field-insensitive
fallbacks do not make this extractor a sound model of all BEAM executions.

## Verification

`value_flow_test.exs` compares generated cyclic dependency graphs with an
independent full-pass solver and varies scheduling and duplicated edges.
`term_flow/heap_test.exs` compares generated update chains with a concrete map
interpreter, checks source monotonicity and invariance under site/key renaming,
and exercises empty dependencies, shadowing and cycles. `term_flow_test.exs`
checks compiled BEAM summaries, including default values and nearby field
isolation/overwrite counterexamples. Process and table analysis tests exercise
the downstream interpretation of those summaries.
