# Suppressions and their assumptions

[Bug-class catalog](../bug-classes.md) · [Rule style](rule-style.md)

An exclusion is a condition that prevents a finding. It can express the defect's
definition, remove duplicate evidence, or compensate for an approximation. Those
roles need different justification.

## Classify the condition

| Kind | Meaning | Review question |
|---|---|---|
| Definitional | The defect cannot hold without the excluded condition's absence. | Does the relation actually establish that condition? |
| Heuristic | A recognized pattern is usually intentional or safe. | What assumption makes it safe, and what real bug looks similar? |
| Redundant | Other premises or rules already imply the same result. | Can removing it change any observable output? |

A negated atom is not inherently a heuristic. "No competing process," "no path lacks
a release," and "no stronger evidence already reports this site" are different uses
of negation. Name the underlying concept rather than calling all three exceptions.

## Prefer evidence over broad exceptions

An exclusion should establish the relevant property at the relevant site:

- A demonitor releases this reference on every required path, not merely somewhere
  in the module.
- A table guard refers to this table and precedes the read or creation.
- A caller waits for this child's exit, not any reply from the child or any DOWN.
- A field test tracks the acquisition it suppresses; an unrelated state branch is
  not a proof of once-only execution.
- A handler covers the actual exception class and continues; a try around other
  code or one that only re-raises does not handle the failure.
- A known child policy or option is distinct from an unread value. Unknown is not
  automatically an OTP default.

Use the shared lifetime, execution-phase and identity models before introducing a
new per-analysis approximation. Existing broad filters still have limits; their
presence is not a reason to copy them.

## Keep the nearest counterexample

For each new suppression, retain a safe example and a nearby defect it must not hide.
Useful mutations include changing the target, using the wrong reference, moving a
check after the operation, guarding only one branch, returning an unknown value,
adding another writer, or making a supposedly fresh start return an existing PID.

The tests in `test/exclusions/` preserve cases from the original exclusion audit.
`test/soundness/` checks adversarial variants of suppression assumptions. These
suites complement the ordinary positive and non-reporting analysis fixtures.

## Evaluate changes at the output

A helper relation gaining rows does not necessarily change findings: another filter
may remove them, another rule may already derive them, or the changed relation may
only supply evidence. Compare the analysis outputs and the resulting finding fields,
including severity, anchors and related frames.

One useful diagnostic is to remove a candidate condition in isolation and inspect
new rows. That reveals where the condition matters in the chosen datasets; no new
rows do not prove redundancy on all programs. Priors, bounded points-to mode and
opt-in analyses need representative inputs if the condition depends on them.

Keep experimental counts with the run or change that produced them. The old census
mixed historical measurements, completed work and proposals; those records remain
in Git history rather than serving as a current suppression inventory.

## Known assumptions worth checking

| Area | Assumption that can fail |
|---|---|
| Logging and telemetry | Modeled side paths do not call application handlers relevant to the finding. |
| Process identity | One known owner is the only owner; a shared helper can run in other processes too. |
| Startup ordering | A startup-only writer cannot overlap normal work or a later incarnation. |
| Locking | Every participating writer uses the same lock, not merely some lock API. |
| Field and table identity | Similar source fields or names denote the same runtime resource. |
| External APIs | Visible call sites describe all callers and relevant argument values. |
| Tooling | No production path reaches a module classified as development-only. |

Specific limits belong beside their model or [finding class](../bug-classes.md),
where a reader can assess their effect. Do not use an old precision percentage as
proof that an individual exclusion is sound.
