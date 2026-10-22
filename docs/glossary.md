# Glossary

[Shared analysis model](design/analysis-model.md) · [Value flow](design/value-flow.md) ·
[Writing rules](design/rule-style.md) · [Bug-class catalog](bug-classes.md)

The terms Argus's code, rules and documentation use, with the standard term from
the program-analysis literature where one exists. Names in the code follow these
definitions: a relation is named for what it holds, in these words, so this page
says what a word means rather than translating a name.

## Program representation

**Module, function, instruction.** The units of BEAM code. A function is named by
its *function ID*, `Mod:name/arity` (`MyApp.Cache:put/2`), and an instruction by
its *instruction ID*, the function ID with the instruction's index,
`Mod:name/arity#idx` (`Argus.InstrId`). The index is an offset into the function's
instruction list, so an edit to a function renumbers its instructions.
Columns named `func` hold a function ID and `mod` a module as `inspect/1`
prints it; `id` and `site` hold an instruction ID.

**Site.** The instruction an operation happens at: a call site, a send site, an
allocation site. A relation names its operation by the site's instruction ID.

**Call site, callee, caller.** A call instruction, the function it calls and the
function it is in.

**Call graph** (`call_edge`, stage 0). Which function may call which. It
over-approximates execution: it includes closure ownership and functions handed
to calls, and resolved `apply` targets; an unresolved `apply` can also omit an edge.

**Entry.** A function the runtime or another program can start running: a
callback a behaviour calls (`process_entry`), an export a caller outside the
program can call, a request handler.

**Program.** The modules Argus analyzes, as opposed to code *outside the program*
(OTP, dependencies left out), which Argus sees only through models.

**Build callback** (tooling). Code that runs while a project is built rather
than when it runs: Mix tasks, compilers, compile-time hooks. Argus treats
build-time modules as tooling, not as entries of the product.

## Facts and rules

**Fact, relation, column.** A fact is a row of a relation; a relation has named,
typed columns. Datalog columns are positional, so a column's name documents it.
A relation's schema (`lib/argus/schema/`) gives its name, columns and meaning.

**Layer 1, layer 2.** Layer 1 relations describe bytecode as it is
(`instruction`, `call_site`, def/use and control flow, `priv/dl/base.dl`).
Layer 2 relations are what extractors derive from it (`priv/dl/layer2.dl`).

**Extractor.** An Elixir module that reads a module's disassembly and emits
layer 2 facts about it (`Argus.Extractor`). Extractors are intraprocedural or
module-local; whole-program questions are answered in Datalog.

**Stage.** A Datalog program whose outputs every analysis that needs them reads as
facts, derived once per run: stage 0 (the call graph), the points-to stage and
the values stage.

**Analysis.** A Datalog program (`priv/dl/analyses/`) and the Elixir module that
turns its output rows into findings (`lib/argus/analyses/`).

**Clientlib.** Shared Datalog components analyses include (`priv/dl/clientlib/`):
reachability, process identity, callbacks, value flow. The name follows
Gigahorse's client libraries.

**Report, detection and supporting relations.** The three layers of an analysis's
rules ([rule style](design/rule-style.md#three-layers)): what a finding displays,
the defect stated in domain terms, and the joins that implement those terms.

**Demand.** A rule that derives rows only for the values some consumer asks about
(*demand-driven* or *client-driven* evaluation). The points-to stage stages
`var_process` and `var_table` only for the variables analyses ask about.

**Budget, overflow.** A row limit a stage's fixpoint is held to. A relation that
reaches it overflows (`points_to_overflow`), and the stage runs a less precise
program instead. Which program runs is a function of the facts, not of time.

## Value flow

**Value flow** (`Argus.Extractors.TermFlow`). Where a value comes from within one
function, summarized per function; two stages read the summaries across
functions: points-to, for the objects a variable holds, and the values stage, for
the literals. The literature calls the local part *intraprocedural dataflow* or
*def-use analysis* and its output *function summaries*.

**Variable.** A value value flow names, by a kind and a key (`var_kind`, `var`):

| Kind | The value |
|---|---|
| `param` | A parameter, by position. |
| `result` | What a call to a program function answers, by call site. |
| `reply` | A synchronous server call's reply, by call site. |
| `term` | A term the function builds, by allocation site. |
| `load` | A field read of a term from elsewhere, deferred to points-to. |
| `process` | A process the function starts, by start site. |
| `self` | The running process. |
| `name` | A registry reference no literal spells (a lookup's answer, `{:global, n}`, `{:via, m, k}`), read as the process it names. |
| `literal` | A literal atom, binary or integer, as the program spells it; points-to reads one as the process registered under it, if any. |
| `table` | An ETS table the function creates. |
| `dictionary` | A process dictionary entry, by literal key. |
| `remote` | A pid that may belong to another node. |

These are the *variables* of the points-to literature: a BEAM register is
reassigned, so Argus names a value by where it comes from rather than by register.

**Term, allocation site.** A term is a compound value the program builds: a tuple,
a map, a list, a struct. It is identified by its *allocation site*, the
instruction building it (`term_allocation`), as an *abstract object* is in
Andersen-style analyses. Terms built at one site share an identity, loop
iterations included.

**Field, field selector.** A term's parts, each named by a selector: `{i}` for a
tuple element (zero-based), the literal key for a map (`:pid`, `"id"`), `[]` for
any list element, `*` for a map field under a key not known, `@key` for a map's
keys that are not literals, `**` for any field. A *field store*
(`field_store`) puts a variable's value in a term's field; a *field load*
(`field_load`) reads one.

**Term update.** A map update or record update builds a new term from a base
(`term_update_base`), keeping the fields it does not overwrite
(`term_update_overwrites`). BEAM terms are immutable, so an update is a new
allocation, not a store into the old one.

**Unmodeled use** (`unmodeled_use`). A value handed to code value flow does not
follow (a library call with no model, a send, a dynamic call). A rule that needs a
value's every use treats one as a use it cannot see.

**Model.** What Argus knows of code outside the program: which argument of
`Enum.map/2` the answer's elements come from, which call starts a process, which
call is a sink. `Argus.Extractors.TermFlow.Library` holds the collection models.

## Points-to

**Points-to analysis** (`priv/dl/points_to.dl`, `clientlib/processes.dl`). Which
objects a variable may hold, across functions. Argus's is *inclusion-based*
(Andersen-style), *field-sensitive* (a term's fields are kept apart) and
*flow-insensitive* across functions.

**Object.** What points-to tracks: a process (by start site, or an *instance* of
one), an ETS table (by allocation site), or a term holding one of them.
`var_points_to(func, var_kind, var, object)` says a variable may hold an object;
`field_points_to(term, field, object)` that a term's field may.

**Client-driven pruning** (`holds_object`). Points-to follows only the terms that
hold a process or table, directly or through another term: no client asks about
the others, and they are most of a program's terms.

**Instance, heap cloning.** A process started by a factory function, or a term a
helper builds from its parameter, is given a separate identity at each call
site that keeps it (`instance`, `built <call> <term>`). This is one level of
*call-site sensitivity* for those objects (*heap cloning*): two callers of one
start helper get two processes. Parameters themselves are *context-insensitive*:
a parameter holds what every caller passes, except where a function hands a
parameter straight back, which each caller reads from its own argument.

**Full, selective and field-insensitive stages.** The points-to stage's three
programs. The *full* stage is field-sensitive throughout. When it outgrows its
budget, the *selective* stage resolves the *hub objects* field-insensitively and
every other object field-sensitively; when that outgrows it too, the
*field-insensitive* stage resolves every object field-insensitively.
`points_to_mode` says which ran, and a notice reports it. Choosing which objects
lose precision by a measure of the program is *introspective* analysis in the
literature.

**Hub object** (`hub_object`). An object a large share of the program's variables
hold (over 1% of them, and over 1,000). Hubs are where a field-sensitive fixpoint
grows with the square of the terms that merge them.

**Approximated** (`approximated_process`, `approximated_table`). A process or table
a selective or field-insensitive stage resolved field-insensitively: a target
naming it is one a call *may* reach, not one it does.

**May, must.** A *may* fact holds on some execution the model admits (a target a
send may reach); a *must* fact holds on every one (a guard every path to a use
passes). Rules keep the two apart: a may fact never proves safety.

## Values

**Values stage** (`priv/dl/values.dl`). Which literals each of the program's
parameters may hold: *interprocedural constant propagation* over sets of
constants, on value flow's variables. Each variable kind a call hands a parameter
is a *jump function*: a `literal` is itself, a caller's `param` passes its own
values through unchanged, a callee's `result` is what that callee returns at that
call. The closure is transitive, so a value reaches a parameter through any number
of wrappers, and a start hands its argument to the entry it runs.

**Parameter value, argument value** (`param_value`, `arg_value`). A literal a
parameter may hold from any caller, and a literal one caller hands a callee (its
own, or one its forwarded parameter may hold). A rule that attributes a value to
the function supplying it reads the second, so callers' values do not mix.

**Origin** (`param_origin`). The call that spells a literal a parameter may hold,
before any chain of callers hands it on unchanged: the caller a rule credits the
value to, as a call's target is that caller's dependency, not its wrappers'.

**Complete** (`param_complete`, `arg_complete`). Every value a parameter may hold
is a known literal: every caller is seen and passes a literal or a complete
parameter. An export, a function captured as a fun, an `apply`, a computed
argument, or a callee's result handed on makes a set incomplete. A rule that
claims a set is the whole story (a module's every timer message) reads
completeness; one that names what may happen reads the values alone.

## Processes and OTP

**Process identity** (`process`, `server_process`). A process Argus can name: by
its start site, by a supervisor's child spec, or by a registered name. A *server
process* runs a behaviour module's callbacks.

**Call, cast, send, signal.** A synchronous request (`GenServer.call`), an
asynchronous one (`GenServer.cast`), a plain message (`send`), and an exit, link
or monitor. `call_site_target` resolves which process each may reach.

**Phase.** When code runs relative to a process's lifetime: during `init/1`
(startup), once after it, or again and again (`once_code`, `again_code`).

## Findings and reporting

**Finding.** A defect an analysis reports: a row of a report relation, with a
title, a message, a location and evidence. Rows agreeing on the relation's key
columns are one finding.

**Anchor.** Where a finding points, parsed from the IDs its row carries
(`Argus.Findings.Anchor`).

**Basis.** How a finding's key fact was established: `resolved` (Argus followed
it to a known target), `inferred` (from module-level structure) or `doubted`
(inferred, and a prior gives it a low probability). A doubted finding is
reported at a lower severity.

**Prior.** Classifier evidence about the program that the bytecode cannot settle
(`prior_*` facts), with a probability in permille. Rules read priors positively:
a missing prior is not evidence against.

**Source, sink, sanitizer, validator** (`unsafe_input`). Taint-analysis terms: a
*source* is where outside input enters, a *sink* an operation input must not
reach unchecked, a *sanitizer* a transformation that makes it safe and a
*validator* a check that rejects unsafe input before the sink.

**Bounded value** (`Argus.Extractors.ParamFlow.Bounded`). A value known to be one
of a finite set the program wrote down, by a guard, a `case` arm or a
membership test on every path: not unbounded input, whatever its origin.

**Notice.** A message about the run rather than the code (`Argus.Report.Notice`):
a stage ran selective, a module failed to extract, an ignore entry matched nothing.

**Degraded.** An analysis that could not run (its engine failed, a stage it reads
failed) and so reported nothing, which the run says rather than reporting a clean
zero.

**Ignore entry.** A configured `ignore: [findings: ...]` entry leaving one
analysis's findings out of one module or function.

## Development

**Corpus.** Open-source projects with closed issues, each a pair of checkouts
before and after a fix (`test/corpus/pairs.exs`), that Argus is measured on.
`mix argus.corpus` fetches them and tallies or compares findings across them.

**Pins** (`test/argus/analysis_inputs.exs`). The relations each analysis reads,
regenerated by `mix argus.pins`, so a change to what an analysis reads is a
reviewed change.

**Fixture.** A small module compiled only in tests, written to exhibit one shape
of a defect or its nearest safe variant (`test/fixtures/`).
