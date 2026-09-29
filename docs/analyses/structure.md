# Supervision and registration structure

[Bug-class catalog](../bug-classes.md)

These findings identify defects visible in child specs or registration names,
without needing a complete request or failure path.

## Supervisors declared as workers

`supervisor_registered_as_worker` · **error**

A child starts a supervisor but its spec says worker, explicitly or by default.
The wrong type gives it worker shutdown semantics and can cut off teardown of its
subtree. Specify the supervisor type in the actual child spec, including a custom
child_spec used through shorthand starts.

The extractor must recognize the started module and spec. Dynamic specs, wrappers
and path-dependent child_spec results can limit coverage.

## Permanent ConsumerSupervisor workers

`consumer_supervisor_permanent_child` · **warning**

A ConsumerSupervisor starts a worker for an event, but its permanent restart policy
restarts the worker after normal completion. This can repeat work and exhaust the
restart budget. Use a policy that matches one event's lifetime. The policy comes
from the explicit spec or the child's own shorthand spec; unknown policy is not
proof that a child is permanent.

## Duplicate registered names

`duplicate_process_name` · **error**

Two modules register the same literal name. Only one registration can succeed.
Local and global names are distinguished. The analysis does not prove that both
modules run in the same deployment, so mutually exclusive implementations can be
reported. Computed names and multiple instances hidden behind one module can be missed.

## Global names without a conflict resolver

`global_register_risk` · **warning**

A call to `:global.register_name/2` uses default conflict resolution. After a
partition heals, one holder can be killed and its state lost. Decide how conflicting
owners should be reconciled and use an explicit protocol or resolver when required.
This check recognizes the registration form; it does not model partition recovery
or prove that conflicts will occur.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/structure.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/structure.ex).
