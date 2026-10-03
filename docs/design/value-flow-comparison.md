# Value-flow design comparison

[TermFlow model](value-flow.md) · [Shared analysis model](analysis-model.md)

This compares representations and abstraction choices, not measured precision or
performance. Doop is a declarative whole-program pointer-analysis framework;
Soot supplies intermediate representations and several analyses; Gigahorse lifts
EVM bytecode and supplies client-analysis libraries. TermFlow is one extractor
inside Argus, so compare it with their fact-generation and local-flow layers,
and compare Argus's shared Datalog stages with their interprocedural solvers.

Sources were inspected on 2026-10-02. Source links below pin the inspected revisions.

## Facts versus solved summaries

Doop's [instruction schema](https://github.com/plast-lab/doop/blob/7882d20bf594db14614f4a5765def763b31019f6/souffle-logic/facts/flow-sensitive-schema.dl)
identifies variables, instructions, allocation values, fields, methods and
invocations separately. It records formal parameters, actual parameters,
return-value assignments, loads and stores. Its
[flow-insensitive projection](https://github.com/plast-lab/doop/blob/7882d20bf594db14614f4a5765def763b31019f6/souffle-logic/facts/flow-insensitive-facts.dl)
exposes relations such as `AssignLocal`, `AssignHeapAllocation`,
`LoadInstanceField`, `StoreInstanceField` and `ReturnVar`. Those describe
operations; subsequent analysis decides their points-to consequences.

Soot's [Spark pointer-assignment graph](https://github.com/soot-oss/soot/blob/a25593e12b7f7cbcc9eb4414e1532e557796dfed/src/main/java/soot/jimple/spark/pag/PAG.java)
likewise distinguishes allocation, assignment, load and store edges. A
[field-reference node](https://github.com/soot-oss/soot/blob/a25593e12b7f7cbcc9eb4414e1532e557796dfed/src/main/java/soot/jimple/spark/pag/FieldRefNode.java)
retains a base variable and a field. These are Java objects and graph APIs,
not a single exported Datalog schema comparable to Doop's.

Gigahorse's [client IR interface](https://github.com/nevillegrech/gigahorse-toolchain/blob/1b06cef82f0a29790e87f576eba6d6d793170d70/clientlib/decompiler_imports.dl)
separates `Variable`, `Statement`, `Block` and `Function`. Clients can read
`Statement_Uses`, `Statement_Defines`, block edges, actual/formal arguments,
returns, constants, and mappings from lifted statements to original bytecode.

Argus already has instruction, def/use, CFG and reaching-definition facts in its
bytecode layer. TermFlow then partially solves them in Elixir: `value_arg` and
`value_return` contain source sets; `value_field` describes object contents;
`value_load` is a deferred projection. These are analysis summaries, not a
complete normalized IR. A local load may disappear into its resolved sources.
That reduces downstream joins, but consumers cannot recover an operation that
TermFlow omitted. Renaming `pid_*` to `value_*` clarifies this contract without
turning the summaries into raw instruction facts.

## Abstraction choices

| Question | Established representations | Argus / TermFlow |
|---|---|---|
| What identifies a local value? | Doop/Spark variables; Gigahorse lifted variables and definitions. | A reaching definition `(instruction, register)` internally; source pairs externally. |
| What identifies a container? | Doop/Spark allocation objects; Gigahorse memory/storage models build on IR operations. | Construction site, with separate nested objects synthesized at calls. |
| What identifies a field? | Java field identities; Gigahorse address/data-structure models. | Spelled map key, tuple position, or merged list-element selector. |
| Where is flow solved? | Doop rules, Soot graph solvers, Gigahorse configurable Datalog components. | Sparse Elixir register/heap solver, then shared Datalog composition. |
| Are call contexts represented? | Doop has independent method/heap context configuration. | No general context dimension in extracted sources; downstream process-specific refinements are separate. |
| How are unknown operations exposed? | Explicit unsupported/opaque instruction concepts and runtime models in Doop; recoverable IR operations in Gigahorse. | Some symbolic external sources survive; other unsupported results become empty provenance. |

Doop's [context-insensitive configuration](https://github.com/plast-lab/doop/blob/7882d20bf594db14614f4a5765def763b31019f6/souffle-logic/analyses/context-insensitive/analysis.dl)
implements method and heap contexts with singleton values, rather than removing
those concepts from the analysis interface. Its
[opaque-method layer](https://github.com/plast-lab/doop/blob/7882d20bf594db14614f4a5765def763b31019f6/souffle-logic/facts/opaque-methods.dl)
marks selected operations and supports explicit modeling. Neither mechanism
makes arbitrary missing library behavior automatically sound.

Soot's [Shimple documentation](https://sable.mcgill.ca/soot/tutorial/shimple/index.html)
explains SSA conversion and phi expressions. An explicit definition identity
simplifies scalar flow; it does not by itself make heap analysis flow-sensitive.
Argus's reaching definitions provide a similar local identity benefit without
materializing a new SSA instruction stream. Its register analysis is sensitive
to overwrites, while emitted object and interprocedural summaries still merge
alternatives. Calling the entire system simply “flow-sensitive” would conceal
that distinction.

## What should transfer to BEAM

These are design conclusions from the comparison, not claims made by the other
projects.

**Keep immutable updates explicit.** A BEAM map update makes a new value. TermFlow's
`value_base` plus `value_sets` describes that version and its inherited fields.
Importing Java's accumulating mutable-field stores directly would lose useful
precision. An empty replacement source set must still shadow the old field.
ETS, registries and process dictionaries are mutable resources and need separate
effect/lifetime models; a term heap should not simulate their update ordering.

**Separate reusable mechanics from transfer policy.** Gigahorse's
[flow components](https://github.com/nevillegrech/gigahorse-toolchain/blob/1b06cef82f0a29790e87f576eba6d6d793170d70/clientlib/flows.dl)
let clients choose transfer statements and boundaries, and use actual/formal
return summaries. TermFlow's shared worklist and separate heap now make the same
separation practical in Elixir. Source-preserving operations should remain
explicit: “every argument flows to every result” confuses dependency with value
identity and incorrectly propagates through helpers that return constants.

**Make partiality observable before claiming completeness.** The most important
remaining gap is the conflation of unsupported provenance with empty provenance.
An explicit unknown/coverage relation tied to a definition or invocation would
be more useful than silently treating missing sources as safety. Its consumers
must preserve uncertainty; merely adding an `unknown` token to today's points-to
rules would not establish a sound top element.

**Add typed identity where it pays for itself.** Separate source-kind enums and
selector domains would prevent malformed joins and clarify map versus tuple/list
projection. A normalized operation view with definition IDs would let future
clients implement different transfer policies without repeating BEAM decoding.
It should reuse `Instr`, CFG and reaching definitions, and remain optional so
ordinary analyses retain small cached summaries.

**Introduce context sensitivity for a measured problem.** Call/heap contexts can
separate repeated helper calls and allocations, but enlarge facts and cache
identities. Start with a counterexample that current summaries merge, preserve
its nearest safe/unsafe pair, and compare findings and row budgets. Doop's
configuration separation is a useful pattern; reproducing all Java analyses or
Gigahorse's EVM memory reconstruction is not a BEAM requirement.

The immediate changes follow these conclusions: general relation names, a
separate finite heap model, explicit solver failure instead of partial fixpoints,
and differential/metamorphic tests of transfers and scheduling. Explicit unknown
facts, a normalized client IR and configurable contexts remain future work.
