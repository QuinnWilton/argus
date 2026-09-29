# Monitor lifetimes

[Bug-class catalog](../bug-classes.md) · [Mailbox findings](../analyses/mailbox.md)

`monitor_leak` reports evidence that a process can add another monitor of a target
while a previous monitor remains live. A discarded reference alone does not prove
that the target will be monitored again.

## Conditions shared by all variants

For monitor site s in function f, held by P on target T:

1. The site is reachable in [repeated execution](runs.md) and is not once-only.
2. T is not proven freshly started by this run on every path.
3. Some returning path leaves the monitor live.
4. One of the witnesses below explains how another monitor can be added.

Freshness follows returned-call origins through supported wrappers. A reused PID,
parameter, lookup, or already_started result is not a fresh start. An unknown return
path prevents the all-path freshness claim.

A release consumes the matching DOWN or demonitors the reference, directly, through
a helper that releases it on every path, or through callers that all release it
after the call. Demonitor without flush releases a live monitor; an already queued
DOWN is a separate mailbox problem.

## Witnesses

### Wait returns before release

`how=wait` · **warning**

The run waits for DOWN, but a timeout, reply or alternate return path leaves the
monitor active. A later run can monitor the same target again. A raising timeout
also needs care: a caller may catch it and keep the monitoring process alive.

### Bookkeeping removed before release

`how=ended` · **warning**

The run records the reference or target PID in state or ETS. A later callback drops
that record while the target may still live, without releasing the monitor or
stopping the target. Another registration can then add a monitor.

The record must derive from the monitor reference or target, not merely be another
field updated by the same clause. If registration first checks a store for that
specific PID, only removal from the checked store permits reacquisition. Removing
an unrelated index does not.

Recognized removals include entry deletion, clearing a field, and resetting a field
to nil/undefined/false. A scalar reset counts only when it loses the last usable
reference, or loses the PID record after the reference was discarded. DOWN-clause
removal normally reflects the target's actual death; bulk clearing can still lose
other live monitors.

### Reference discarded in repeated work

`how=dropped` · **info**

Repeated work throws the reference away without a recognized state-dependent guard.
Only target or owner termination releases the monitor. Whether the same target is
actually supplied again is a protocol assumption, so this has weaker severity.

## Precision and coverage limits

- Store matching is primarily by field or table, not a complete key/value protocol.
  A removal can be associated with several monitors stored there.
- A helper's guarded caller is not necessarily the helper's only caller. Unsupported
  nested fields, record updates and returns can hide retention or release.
- Clearing another monitor's bookkeeping from a DOWN clause is not fully distinguished
  from clearing this monitor's record.
- Freshness requires all return origins to be recognized. Custom get-or-start or
  library APIs can therefore look like reused targets.
- Repetition inferred from external entry points does not prove the caller repeats
  the relationship. Short-lived request processes can safely own monitors until exit.
- Protocol-only once semantics and state updates outside supported callback returns
  are not fully modeled.

Do not suppress a leak because some demonitor exists nearby. It must release the
relevant reference on all paths used to justify the suppression. Keep counterexamples
for the wrong reference, one-branch release, unrelated store deletion and a reused
start result. They are covered by `test/soundness/monitors_test.exs` and
`test/analyses/mailbox_monitor_test.exs`.
