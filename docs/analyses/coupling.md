# Restart coupling

[Bug-class catalog](../bug-classes.md)

These findings compare supervision policy with dependencies between processes.
The important question is what survives when one process restarts alone.

## Restart isolation

`sibling_dependency` with `reason=restart_isolation` · **warning**; **info** for inferred retention

Under `one_for_one`, one child's [startup phase](../design/analysis-model.md#startup-and-repeated-execution)
registers something in another branch's process. If the receiver restarts alone,
that registration disappears while the caller continues running. If the caller
restarts alone, it can leave the old incarnation's registration behind.

`holds_in` records what the receiver retains:

| Kind | Retained state |
|---|---|
| `table` | An ETS row. |
| `monitor` | A monitor or link. |
| `dict` | A process-dictionary entry. |
| `state` | A state change beyond the value initialization establishes. |
| `handed` | A request passed to unknown external code that may retain it; inferred evidence. |

Read-only requests and resets to initial field values do not establish retention.
Recognized links and dependencies exclusively on privately started instances are
excluded. The finding identifies the tree, startup request and retaining operation.
Cached PIDs are the reverse dependency: the caller retains the receiver's identity.

Inspect whether the receiver restores its state or the caller re-registers through
a recovery protocol; the analysis cannot prove either. If their lifetimes must be
coupled, use an appropriate restart strategy.

Unknown request tags can match unrelated writing clauses, and module-based matching
can conflate instances. Registrations made only by repeated handlers, sends to
handle_info, gen_statem requests, direct writes to another process's table, detached
registrations and some library registries are outside this model. This finding
covers `one_for_one` isolation; other restart policies can have analogous defects.

## A dependency with a shorter restart policy

`sibling_dependency` with `reason=restart_policy` · **warning**, or **info** for doubtful target evidence

A permanent child depends on a temporary or transient sibling. The dependency can
stop without being restarted, leaving the permanent child alive with no service.
Private instances are excluded. The check uses process dependencies and visible
child policies; it does not know whether the caller intentionally tolerates absence.

## Cached sibling PIDs

`sibling_dependency` with `reason=cached_pid` · **warning**

A child under `one_for_one` looks up a sibling during initialization and later uses
a PID instead of resolving its name again. Restarting the sibling leaves a stale
reference. Re-resolve the name when appropriate, or update the reference through an
explicit lifecycle protocol.

The lookup must be visible directly in `init/1`, and siblings are direct children.
Points-to information associates later uses; unresolved PID traffic can serve as
weaker fallback evidence.

## Dynamic children surviving their owner

`rest_for_one_orphaned_children` · **warning** for resolved targets; **info** for inferred targets

A later child starts work under an earlier sibling supervisor. `rest_for_one`
restarts the later owner without restarting that earlier supervisor, so the old work
survives and can be started again. A literal registered target is resolved evidence;
a uniquely matching earlier supervisor can provide inferred evidence.
A start that takes `{:error, {:already_started, pid}}` as success is excluded: its
child is registered under a name, and the restarted owner adopts the surviving one.

Place the work under the intended lifecycle owner or explicitly stop it when that
owner ends. The analysis cannot establish all application-specific cleanup protocols.

## Two restart authorities

`dual_restart_authority` · **warning**

A process monitors a dynamically supervised child and starts it again from its DOWN
handler, while the child's supervisor also has a non-temporary restart policy.
Both parties can restart the same work. Choose one restart owner and make the other
observe or request that owner's actions.

The start, monitor and later start must resolve to the modeled child and supervisor.
Helpers and returned start results are followed where their origins are known;
unknown child identities and task children can be missed.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/coupling.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/coupling.ex).
