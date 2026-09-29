# Bug-class catalog

Argus reports defects in process protocols, supervision, shared state and external
input handling. This catalog explains what each finding means, the evidence behind
it and the limits to consider when reviewing it.

## Analyses

| Analysis | What to inspect |
|---|---|
| [Startup](analyses/startup.md) | Dependencies that block or race initialization. |
| [Shutdown](analyses/shutdown.md) | Cleanup and peer lifetimes during teardown. |
| [Blocking](analyses/blocking.md) | Call chains, cycles and unbounded waits. |
| [Restart coupling](analyses/coupling.md) | State or work left inconsistent by independent restarts. |
| [Mailbox](analyses/mailbox.md) | Unhandled messages, missing replies and repeated acquisitions. |
| [Failure handling](analyses/failure.md) | Lost errors, unchecked results and dropped resources. |
| [Structure](analyses/structure.md) | Child specs and conflicting registrations. |
| [Races](analyses/races.md) | Harmful interleavings on names, ETS rows and Mnesia records. |
| [State machines](analyses/state-machine.md) | Unreachable states and states with no exit. |
| [ETS](analyses/ets.md) | Table ownership, restart windows and access patterns. |
| [Effects](analyses/effects.md) | Purity contracts and effects that transactions cannot undo. |
| [Unsafe input](analyses/unsafe-input.md) | Resource exhaustion and code execution reachable from external input. |
| [Exposure](analyses/exposure.md) | Inspect-visible secrets and TLS verification settings. |
| [Coverage](analyses/coverage.md) | Facts the analysis could not recover; opt-in and informational. |

Each entry names its output relation and relevant discriminator, such as kind,
phase or source. Related frames are evidence for that finding, not additional bug
classes. The implementation links on each page lead to the rules and finding builder.

## Interpreting severity

Severity combines the consequence with the strength of the available evidence:

| Level | Typical interpretation |
|---|---|
| **error** | Strong structural or data-flow evidence: a broken callback contract, conflicting registration, self-call or explicitly disabled control. |
| **warning** | A crash, hang, leak or lost update under a plausible failure, repeated operation or timing window. |
| **info** | A performance hint, uncertain lifetime or intent, weaker evidence, coverage gap or successful verification. |

These are review priorities, not proofs that a particular execution will fail.
Some findings use explicit assumptions even at error severity. Read the entry's
limits and the finding's evidence rather than treating a level as a probability.

Inferred targets and optional priors can lower severity. Findings identify heuristic
provenance when applicable. Code classified as tooling or test support can also step
down a level. Unsafe-input findings have their own proximity-based grading; code
execution retains a warning floor. The finding builder is the authority for exact
variant-specific grading.

## Reviewing a finding

Start at the reported operation, then follow the related frames. Establish which
process runs it, what value or message reaches it, and which other process can fail,
restart or interfere. A helper's module is not necessarily its executing process.

Check the limits relevant to that evidence. An unresolved target can miss a real
dependency; a broad tag or module-level match can include an impossible one. A
missing handler or guard in the extracted facts is not always absent from the
program. [Coverage findings](analyses/coverage.md) can explain missing information.

A suppression should have a concrete reason: the reference is released, the table
exists on every relevant path, the peer is known ready, or the operation is serialized.
An unrelated guard elsewhere in the module is not enough.

## Design reference

| Guide | Purpose |
|---|---|
| [Shared analysis model](design/analysis-model.md) | Facts, call/process reachability, identity and uncertainty. |
| [Startup and repeated execution](design/runs.md) | Once-only clauses, repeated work and state gates. |
| [State across restarts](design/restart-state.md) | Retained registrations and readers that outlive table owners. |
| [Monitor lifetimes](design/monitor-leaks.md) | Repeated live monitors and release proofs. |
| [Race detection](design/races.md) | Check/act pairs, rivals, harm and ordering. |
| [Suppressions](design/exclusions.md) | Assumptions and counterexamples behind exclusions. |
| [Rule style](design/rule-style.md) | Naming, comments and the separation of detection from reporting. |

Keep this reference about current behaviour. Regression fixtures and corpus pairs
remain in the test tree; historical audits, precision tallies, retired rules and
completed investigations remain in Git history. When a rule changes, update the
affected entry's meaning and limits instead of appending another review log.
