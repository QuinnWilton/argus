# How a rule reads

A rule is read by people who know the bug and not Argus. Each analysis
states every bug it finds as one short rule in the words of the bug, and
keeps how each word is computed out of that rule.

## Three layers

1. **The report** (`.output`): the relation `lib/argus/analyses/*.ex`
   reads. It joins a detection relation with what a finding needs to be
   shown: the module, a function to anchor on, a table's kind. Its name
   and columns are an ABI (scry, planchette, the findings builder, the
   corpus), so a refactor never changes them. It holds no detection
   logic: every row of the detection relation is reported, and nothing
   else is.

2. **The detection rule**: named for the bug, as a noun
   (`missing_row_race`, `lock_during_init`). Its body is the bug, one
   idea per line, in the order you would say it:

   ```prolog
   // A check decides a row is there, a use that fails when the row is
   // missing relies on it, and another process can remove the row in
   // between.
   missing_row_race(func, check, use, remove, row) :-
     checks_row_exists(check),
     decides(func, check, use, row),
     fails_if_row_missing(use, func),
     on_shared_table(use),
     removes_row(remove, row),
     runs_in_another_process(remove, func).
   ```

   - Three to seven lines. More means an idea is split across lines or
     the rule is two bugs.
   - Every atom is a word of the bug's domain, defined below the rule or
     in `clientlib/`. No extractor facts (`ets_op`, `call_instr`,
     `remote_call`), no component internals (`missing.meets`), no
     arithmetic, no string comparisons on kinds.
   - A negation reads as a sentence too (`!server_traps(mod)`,
     `!rescued(use, func)`), never an implementation detail.
   - Variables are named for what they are (`check`, `use`, `remove`,
     `row`), not `a`, `d`, `w2`. A variable the detection needs but a
     reader might not expect (the `func` where two sites meet) keeps a
     comment saying why it is there.
   - One comment above the rule: the bug in a sentence. The same
     sentence can go on a slide.

3. **The words**: each atom of the detection rule is a relation with a
   comment saying what it means in one sentence, then its assumptions and
   soundness limits. This is where extractor facts, components, key
   comparisons and precision filters live. A word used by two analyses
   moves to `clientlib/` under one name.

## Naming

- Predicates read as verb phrases with their subject first:
  `fails_if_row_missing(use, func)`, `runs_in_another_process(remove, func)`,
  `retries_until_locked(lock)`.
- Kinds of thing are nouns: `removal(write)`, `EtsRow`.
- One word per concept across the analyses (docs/bug-classes.md's
  vocabulary). If two analyses mean the same thing by different words,
  pick one.
- Soufflé has no overloading: a new word may not reuse a name at another
  arity. Rename the older relation to what it means instead.

## A refactor changes no finding

Moving a rule into this shape is a refactor, and must leave every finding
identical, field for field:

- `mix test` passes (fixtures and corpus);
- the identity harness (`/Users/quinn/dev/wt/rulestyle/identity.exs` over
  the corpus, `identity_live.exs` over the live projects) shows no diff
  against main.

When the clearer rule is also more precise (a condition that was asked of
the whole function can now be asked of the one row), say so in the commit
message. If the harness still shows no diff, the tightening can land with
the refactor. If it moves findings, it is its own commit after the
refactor, with the findings it moves listed and argued.
