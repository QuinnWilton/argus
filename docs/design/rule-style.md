# Writing and changing rules

[Bug-class catalog](../bug-classes.md) · [Shared model](analysis-model.md) ·
[Runnable debugging and extension workflows](../../CONTRIBUTING.md)

A detection rule should explain the defect to someone who understands the bug but
has not learned Argus's extractor internals. Keep reporting, detection and supporting
mechanics separate.

## Three layers

1. **Report relation.** The `.output` consumed by `lib/argus/analyses/*.ex`. It adds
   names, locations and evidence needed to display a detected defect. Its name,
   columns and identity are an interface to builders and downstream consumers.
2. **Detection relation.** A short statement of the defect, using domain concepts.
3. **Supporting relations.** Extractor joins, value identity, reachability,
   comparisons and precision filters that implement those concepts.

For example, a missing-row race can read:

```prolog
// Another process can remove the row between the presence check and a use
// that raises when the row is absent.
missing_row_race(func, check, use, remove, row) :-
  checks_row_exists(check),
  decides(func, check, use, row),
  fails_if_row_missing(use, func),
  on_shared_table(use),
  removes_row(remove, row),
  runs_in_another_process(remove, func).
```

Each line contributes one part of the argument. If a detection rule needs many
extractor details or unrelated conditions, give those concepts supporting relations.
Do not add an abstraction solely to meet a line-count target.

## The dialect

The rules are written in [FlowLog](https://github.com/flowlog-rs/flowlog)'s
dialect of Soufflé's language: declarations, components, `#include` and the
usual operators and functors, with these differences.

- An input's declaration ends in `mutable` (`.decl edge(a: symbol, b: symbol)
  mutable`), so that an engine kept between solves can retract its rows as well
  as add them. `mix argus.gen.dl` writes the
  schema's declarations this way.
- There are no ADTs, records, `inline` relations or subsumption. A tagged value
  is a tuple whose first field is the tag, such as `("top", field)`, and a
  "keep only the best row" rule is a head aggregate.
- Aggregates appear only in a rule's head: `count_of(x, count(y)) :- ...`. To
  aggregate inside a body, give the aggregate its own relation and join it.
- An atom's arguments are variables, constants or `_`. Bind an expression first,
  as in `next = n + 1, reaches(next)`.
- A negated atom's variables are bound by the rule's positive atoms, not taken
  apart from a tuple. When a negation needs part of a value, give that part a
  relation of its own and negate that.
- A rule needs at least one positive atom; restate a body made only of
  negations or constraints with the atom that ranges over its variables.
- There is no `.limitsize` or `.plan`. An engine plans its own joins; a budget is
  a relation the caller reads once the fixpoint is done, as `points_to_budget`
  is.

`mix argus.flowlog solve PROGRAM FACTS_DIR` runs a program over a directory of
`<relation>.facts` files and reports a compile error with the rule it is in.

## Names and comments

- Use names that state the property: fails_if_row_missing, runs_in_another_process.
  Put the subject first and name variables for their role.
- Use nouns for entities and detected defects, such as EtsRow or missing_row_race.
- Reuse a shared concept from clientlib when it means the same thing. Keep distinct
  concepts separate, especially possible versus guaranteed properties.
- Relation names cannot be overloaded by arity; choose an unambiguous name.
- Start a comment with what the relation means. Add only the assumptions, unknown
  cases or implementation reason a reader needs to use it correctly.
- Put historical examples, measurements and discarded approaches in the change
  record. Do not make readers reconstruct current behaviour from a sequence of fixes.

A useful comment explains why a condition exists or what a result guarantees. It
does not narrate each join, repeat the identifier, or promise more precision than
the rules provide. Keep an example when it distinguishes easily confused shapes,
such as nested exit reasons or timer-message tuples.

## Suppressions

Distinguish a condition required by the defect's definition, a heuristic that a
pattern is safe, and a filter that removes duplicate evidence. A negated atom can
serve any of these purposes. State what the condition establishes and which
assumptions it relies on.

Require evidence for the operation being suppressed: release this reference, guard
this table before use, wait for this child's exit, or handle this exception on the
required paths. A similar operation elsewhere in the module is insufficient.
Unknown options, owners and callers are not evidence of safe defaults or exclusivity.

Keep a safe case and the nearest defect each suppression must still report. Useful
counterexamples use the wrong reference, check after use, protect only one branch,
add a writer, reopen a gate or return an existing PID from a supposed fresh start.
`test/exclusions/` and `test/soundness/` retain these cases.

Evaluate changes at the output: added helper rows can be removed by another filter
or affect only evidence. Removing one condition can show where it matters in a
dataset; no changed rows do not prove it redundant for every program. Exercise the
priors, points-to modes and optional analyses the condition depends on. Keep measured
counts with the change that produced them, and document specific assumptions beside
the affected finding or shared model.

## Refactors and behaviour changes

A rule refactor preserves every finding field, including identity, severity, source
anchors and evidence. Use the relevant fixture, soundness and corpus comparisons
for the code being changed; do not rely on a machine-specific scratch harness path.

If a rewrite intentionally changes which programs are reported, describe the changed
condition and its counterexamples. Keep that behaviour change distinguishable from
mechanical restructuring. Update the affected catalog entry and shared model, and
keep a counterexample for any new suppression.

Documentation-only edits need no rule changes. When schema documentation changes,
refresh its generated declarations so the source and generated comments agree.
