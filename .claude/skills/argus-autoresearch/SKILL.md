---
name: argus-autoresearch
description: Iterative coverage improvement loop for the argus extractor pipeline. Use when improving coverage, reducing imprecision, or working on extractor targets.
---

# Argus Autoresearch

Iterative coverage improvement loop for the argus extractor pipeline.

## When to use

Use this skill when the user says "autoresearch", "improve coverage",
"reduce imprecision", or invokes `/argus-autoresearch`. Also use it
when asked to "work on the next biggest coverage gap" or "iterate on
extractor precision".

## Pre-flight

1. Run `mix argus.autoresearch status` to see the current state.
2. If `.autoresearch/` doesn't exist, offer to run `mix argus.autoresearch init`.
3. If there's no baseline, offer to run `mix argus.autoresearch measure` followed by `mix argus.autoresearch accept --initial`.
4. Read `.autoresearch/notes.md` in full — it has the objective, current focus, open hypotheses, wins, and dead ends.

## Iteration loop

Each iteration follows this 9-step flow. Steps between the two **confirmation gates** are mechanical and run automatically.

### 1. Resume
Run `mix argus.autoresearch status`. Note the top-ranked targets and the current focus from notes.md. Check dead ends — never retry a dead-end target within the same session.

### 2. Propose
Pick the highest-scoring non-dead-end target (or the "Current focus" if resuming an in-progress attempt). Formulate a one-sentence hypothesis. Show the user:
- The target category and its score
- The suggested extractor file path
- 2-3 example `sample_funcs` from the ranking
- Your proposed approach (one sentence)

### 3. Gate 1: proceed?
Ask the user to confirm. On yes, run:
```
mix argus.autoresearch note "attempt_start target=<category> hypothesis=<one-liner>"
```
Update `.autoresearch/notes.md` under `## Current focus` with the category name.

### 4. Edit
Edit the extractor file(s) to implement the improvement. Keep changes minimal and focused on the target category. Update `## Open hypotheses` in notes.md.

### 5. Checks
Run `mix argus.autoresearch checks`. If it fails:
- Revert the edit with `git checkout .`
- Log the failure: `mix argus.autoresearch note "checks failed: <reason>"`
- Return to step 2 with a new idea
If it passes, continue.

### 6. Remeasure
Run `mix argus.autoresearch measure`.

### 7. Diff
Run `mix argus.autoresearch diff`. Report to the user:
- Per-category deltas (improvements and regressions)
- Net total change
- Any new or removed categories

### 8. Gate 2: accept or revert?
Show the user the diff summary and ask for confirmation.

**If accept:**
1. Run `mix argus.autoresearch accept`
2. Commit the extractor change: `[extractors] <description>`
3. Update `## Wins` and clear `## Current focus` in notes.md
4. Commit the baseline + notes update: `[autoresearch] rebaseline after <description>`

**If revert:**
1. Run `mix argus.autoresearch revert`
2. Run `git checkout .` to discard working tree changes
3. Move the hypothesis to `## Dead ends` in notes.md with a reason
4. Commit notes.md: `[autoresearch] mark <category> as dead end`

### 9. Loop or stop
Return to step 1 until the user stops or after 3 consecutive reverted attempts on different targets (report to the user and suggest pausing — there may be a systemic issue).

## Commit protocol

Use two separate commits per accepted iteration:
1. **Extractor change**: `[extractors] <description of what changed>`
2. **Baseline update**: `[autoresearch] rebaseline after <description>`

Both via the existing `/commit` skill or manual `git add` + `git commit`.

## Safety rules

- Never run `accept` if `checks` hasn't passed for the current working tree.
- Never skip confirmation gates.
- Never retry a dead-end target within the same session.
- Always read notes.md before proposing a target.
- Always update notes.md after accepting or reverting.
- Keep the extractor change atomic — one category per iteration. Don't bundle unrelated fixes.
