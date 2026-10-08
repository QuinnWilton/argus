# Failure handling

[Bug-class catalog](../bug-classes.md)

These findings concern lost error information, unchecked results and process or
resource lifecycles. Several are heuristics: a reported inconsistency is evidence
of a local convention, not proof that every call needs the same handler.

## Swallowed exceptions

`unhandled_failure` with `kind=rescue` · **warning**

A catch-all discards the caught class, reason and stacktrace without re-raising or
classifying them. Failures become an ordinary return value and surface later without
their cause. Recognized boundary operations and generated code may be excluded.
The analysis does not infer whether a particular fallback is an intentional contract.

## Incomplete erpc handling

`unhandled_failure` with `kind=erpc_transport` · **warning**

The handler understands a remote exception but not erpc transport errors such as
no connection or timeout. Its own case can then fail while handling the original
failure. Cover transport errors separately from exceptions raised by remote code.
Detection depends on the handler shapes visible in bytecode.

## RPC results treated only as success

`unhandled_failure` with `shape=case` · **warning**

An RPC result enters a shape test or match that can fail, without recognized badrpc
handling. Node failure and remote exceptions can produce `{:badrpc, reason}`.
Result-forwarding wrappers are followed where their summaries are known.

Handling is partly function-wide: unrelated badrpc comparisons or failing matches
can affect the result. Multicall returns result and failed-node collections, so its
failure protocol needs separate inspection rather than a single top-level tuple case.

## RPC results used as booleans

`unhandled_failure` with `shape=boolean` · **warning**

A badrpc tuple is truthy, so a failed remote predicate can appear successful. erpc
raises instead; the finding identifies an escaping failure from a boolean context.
Predicate names ending in `?` also count as evidence of boolean use. Match explicit
success and failure results before using the value as a decision.

## Discarded child-start failures

`unchecked_result` with `api=Task.Supervisor.start_child` · **warning**

A task start may fail because of a child cap, but its result is discarded. The
request appears successful without the task. A known uncapped supervisor is excluded;
a missing supervisor exits instead of returning an error. Result-use detection is
local and can miss more indirect ways of dropping a result.

## Unchecked process lookups

`unchecked_result` with `api=Process.whereis` · **warning**

Code uses a literal-name lookup without a recognized nil/undefined check or handler
for the failure. The process may be absent. A successful lookup also does not keep
the target alive until its use. Bytecode value flow and straight-line tests limit
which checks are recognized. A lookup a private function returns is judged where its
callers use it; a cast, which drops a message to nil as it would to a dead server, and
a comparison with a value that is never nil (`self()`, the group leader) are no
failing use.

## Unobserved spawned processes

`orphan_process` with `kind=spawn` · **warning**

A spawn has neither a link nor a monitor, and no later watch is visible through
points-to analysis. Failure can go unnoticed. A spawn that is later linked or
monitored is excluded; detached work with intentional fire-and-forget semantics
may still be reported.

## Exit signals bypassing lifecycle ownership

`orphan_process` with `kind=exit_supervised` · **warning**; `kind=exit` · **info**

A GenServer callback sends an exit to a process it is not known to own. A resolved
supervised target gives stronger evidence; an unresolved target needs inspection.
The signal can conflict with restart policy or the target's stop protocol.
Known self-owned targets and detached caller paths are excluded.

## Deviating from result-handling conventions

`inconsistent_handling` with `belief=result_checked` · **warning** or **info**

Most comparable calls to an API on the same target inspect its result, but this one
discards it. Require at least three agreeing sites and at most one quarter deviating.
The finding includes examples of the prevailing convention; stronger statistical
support raises severity. Known non-failing results and dedicated start-result
findings are excluded.

The population is based on recognized APIs and target identity. Different call
contracts can look similar, and macro expansion or unresolved targets limit coverage.

## Deviating from exception-handling conventions

`inconsistent_handling` with `belief=exception_guarded` · **warning** or **info**

Comparable callers catch the callee's failure class, but this site has an unguarded
path. `cover` distinguishes no try, an incompatible local try, and incomplete caller
coverage. A try that only re-raises does not handle the failure. The same population
thresholds apply as for result handling.

Check whether this caller intentionally lets the failure terminate it. Handling a
different class is not equivalent: exits from process calls and errors from ETS/BIF
operations need different catches.

## Local-only operations on possibly remote PIDs

`remote_pid_probe` · **warning** for `lookup`; **error** for `resolver`

A local-only BIF receives a PID from a distributed registry, group or related origin,
without a recognized node guard or exception handler. It can raise badarg. A
conflict resolver receives holders on two nodes, so one is necessarily remote.
Supported wrappers and collection traversal are followed; arbitrary PID flow is not.

## RPC to an unavailable function

`rpc_undefined` with `why=missing` or `private` · **error**

A literal RPC MFA identifies a function absent from the analyzed module's exports.
Calling it remotely fails with undef. Supported wrappers can forward the module,
function and argument list from callers. Dynamic MFAs and remote nodes running a
different code version remain outside what the local program proves.

## Dropped file, socket or port handles

`resource_dropped` · **warning**

An opened handle is lost on a returning path without being closed, returned, stored
or transferred. A long-lived process can accumulate resources each time it takes
that path. Related evidence points to where the handle is lost.

The analysis treats transfer to an unknown call or data structure conservatively;
it does not prove that a recipient later closes the handle. Paths that end the
owning process have different lifetime semantics from returning paths.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/failure.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/failure.ex).
