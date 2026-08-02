# Corpus findings, August 2026

Results from two new analyses — `request_surface` and `callback_receive` —
run over the sample corpus. Every finding below was read against source
before being written down, and the ones that did not survive that reading
are recorded too, because they are what calibrated the analyses.

Severity here is what the evidence supports, not what the analysis emitted.

---

## 1. Livebook — unvalidated `String.to_atom` on websocket payload

**Where** `lib/livebook_web/live/session_live.ex:397, 411, 428`
**Analysis** `request_surface` / `remote_atom_exhaustion`, proximity `direct`
**Severity** Low-to-moderate. Real bug, cheap fix, does not cross a
privilege boundary in the default deployment.

Three `handle_event/3` clauses take `"tag"` straight out of the client
payload and convert it:

```elixir
def handle_event("apply_cell_delta", %{"cell_id" => _, "tag" => tag, ...}, socket) do
  tag = String.to_atom(tag)
```

`tag` is whatever the browser's JavaScript pushed over the websocket. There
is no guard, no changeset, and no `to_existing_atom`. The domain it is
checked against downstream is exactly two values — `source_access/2` in
`lib/livebook/session/data.ex:2192` has clauses for `:primary` and
`:secondary` and nothing else.

The BEAM atom table is fixed-size (default 1,048,576) and never garbage
collected. A client that pushes `report_cell_revision` with a fresh random
`tag` each time permanently consumes one slot per message; when the table
fills, the VM aborts and takes every session on the node with it.

**Why the severity is not higher.** `SessionLive`'s routes sit behind the
`:auth` pipeline, and an authenticated Livebook user can already evaluate
arbitrary code — including `:erlang.halt/0`. So this is not an escalation
in the standard single-user deployment. It matters as defence in depth, and
it matters more wherever session access is broader than code-execution
trust: shared collaborative sessions, or any deployment fronting Livebook
with its own authorization.

**Fix** `String.to_existing_atom/1`, or match `"primary"`/`"secondary"`
explicitly and reject the rest.

---

## 2. Supabase Realtime — unvalidated `String.to_atom` on URL query parameters

**Where** `lib/realtime/api.ex:65,68` reached from
`lib/realtime_web/live/tenants_live/index.ex:53`
**Analysis** `request_surface` / `remote_atom_exhaustion`, proximity `adjacent`
**Severity** Moderate. Post-authentication denial of service.

```elixir
def list_tenants(opts) when is_list(opts) do
  field = Keyword.get(opts, :order_by, "inserted_at") |> String.to_atom()
  order = Keyword.get(opts, :order, "desc") |> String.to_atom()
```

`handle_params/3` feeds it directly from the URL:

```elixir
def handle_params(params, _url, socket) do
  changeset = Filter.changeset(socket.assigns.filter_changeset, params)
  form = Filter.apply_changes_form(changeset)
  ... Api.list_tenants(order_by: form.order_by, order: form.order, ...)
```

and the changeset does not constrain either field:

```elixir
def changeset(form, params \\ %{}) do
  form |> cast(params, [:order_by, :search, :limit, :order])
end
```

`cast/3` coerces types; it does not validate membership. So `order_by` is
an arbitrary attacker-supplied string that becomes a permanent atom. Roughly
a million requests with distinct values aborts the node, and the node is
holding every tenant's websocket connections.

`/admin/tenants` is behind the `:dashboard_admin` pipeline, so this is
post-auth — an admin should nonetheless not be able to kill the node by
editing a URL.

**Fix** `validate_inclusion(:order_by, ~w(inserted_at name ...))` on the
changeset, and `String.to_existing_atom` at the boundary.

---

## 3. TeslaMate — leaked monitor and unhandled `:DOWN` on the reconnect path

**Where** `lib/teslamate/vehicles/vehicle.ex:572-588`
**Analysis** `callback_receive` / `receive_in_callback`, proximity `direct`
**Severity** Moderate-to-high. Crash on an error path, in a supervised
process, exactly when the system is already degraded.

The analysis flagged the selective receive:

```elixir
def handle_event(:info, {:stream, msg}, _state, data)
    when msg in [:too_many_disconnects, :tokens_expired] do
  ref = Process.monitor(data.stream_pid)
  :ok = disconnect_stream(data)

  receive do
    {:DOWN, ^ref, :process, _object, _reason} -> :ok
  after
    1000 -> :continue
  end
  ...
```

That alone is a warning: it runs on the `gen_statem`'s own stack, so the
vehicle state machine handles nothing else for up to a second, and because
the pattern is specific the VM re-scans the mailbox for it.

Reading it surfaced a second, worse bug. On the `after 1000` branch the
monitor is never released — there is no `demonitor` anywhere in the file —
so a `{:DOWN, ref, :process, pid, reason}` arrives later. The module has two
`:DOWN` handlers (lines 615 and 620) and **both match `reason` `:normal`
only**; across 59 `handle_event` clauses there is no catch-all for `:info`.

An abnormal reason is the likely one here, since the process was just
force-disconnected. When it arrives, no clause matches, `gen_statem`
terminates with a bad-event error, and the vehicle process crashes — on the
`:too_many_disconnects` / `:tokens_expired` path, i.e. precisely when the
connection is already misbehaving.

**Fix** `Process.demonitor(ref, [:flush])` after the receive, and a
catch-all `handle_event(:info, {:DOWN, _, _, _, _}, _, _)`.

---

## What did not survive reading

These calibrated the analyses and are the reason the severities above are
worth anything.

| Reported | Verdict |
|---|---|
| sequin — 36 `transitive` atom paths | Not request-tainted. `Sequin.JSON.decode_struct_with_type/1` takes `_kind` from a JSON map, but both callers source it from **storage** (a Postgres JSON column via `Ecto.Type.load/1`, and Redis via `AcknowledgedMessage.decode/1`). A LiveView merely loads those records. |
| teslamate — `Vehicle.busy?/1` (`adjacent`) | `:"#{car_id}"` where `car_id` is a database primary key. Domain is the size of the user's garage. |
| livebook — 2 blocking receives | The documented `cancel_timer` flush idiom. `cancel_timer/1` returning false means the message was already sent, so the receive is guaranteed to match. |
| oban — `binary_to_term` in a worker | `test/support/worker.ex`. Test-only; an artifact of sweeping test-env beams. |
| livebook — `AttachedRuntimeComponent` node/cookie | Node names and cookies genuinely must be atoms for `Node.connect`, and a changeset runs first. Inherent, not a defect. |

The lesson that shaped both analyses: **reachability is not taint**. A path
from a request handler to a sink proves a path exists, not that attacker
data travels it. Every `transitive` finding examined turned out to carry
data from storage or configuration. That is why `request_surface` reports a
proximity and scales severity by it, rather than reporting every path as if
it were the same thing.

## Analysis hygiene notes

- Sweeps pick up `test/support` modules when the project was compiled in
  test env. Worth filtering, or at least labelling.
- Both analyses key findings on the sink site, not the (site, entry) pair.
  A sink reachable from forty controllers is one bug in one place, and
  reporting it forty times buries it.

---

# Contracts imposed by context, August 2026

`@pure` is a contract someone writes down. The more productive observation
is that **some contracts are imposed by context and nobody writes them
down** — the obligation comes from where the code sits, so there is nothing
to annotate and nothing to forget.

The clearest instance is a database transaction. Passing a closure to
`Repo.transaction/1` silently accepts that whatever it does is something
the database can take back, because the database is going to decide whether
it happened. Three ways that fails, none visible in review:

1. **Rollback leaves the effect behind.** Rows vanish, the webhook already
   fired, and the system is in a state its own database says never existed.
2. **Retry repeats it.** Serialization failures are retried by design, so
   one logical operation sends two emails.
3. **The connection is held throughout.** A pooled connection stays checked
   out for the whole closure, so an external call inside a transaction
   couples database capacity to a third party's latency.

The third is what takes systems down, and it is the least obvious: the code
is correct, it just holds a scarce resource while waiting on something it
does not control. Every finding below is an instance of it.

## 4. TeslaMate — a language change holds a connection through 20 geocoder calls

**Where** `lib/teslamate/settings.ex:32` → `lib/teslamate/locations.ex:50`
**Severity** Moderate-to-high. Connection-pool exhaustion on a user action.

`update_global_settings/2` opens `Repo.transaction(..., timeout: 60_000)`.
On a language change it calls `Locations.refresh_addresses/1`, which loads
**every** address, chunks by 50, and per chunk sleeps 1500 ms then calls an
external geocoding API.

A thousand addresses is twenty chunks: roughly 28 seconds of deliberate
sleeping plus twenty third-party HTTP round trips, all holding one pooled
Postgres connection. The 60-second timeout is itself an admission of how
long this runs.

Note what the analysis could *not* see: `@geocoder` is a configured module
attribute, so the HTTP call is behind a dynamic dispatch. It found the
`Process.sleep`, which was enough to lead to the geocoder by reading.

## 5. Sequin — a user-controlled wait inside a 90-second transaction

**Where** `lib/sequin/yaml_loader.ex:59` → `:404`
**Severity** Moderate-to-high, and partly attacker-influenced.

`apply_from_yml/3` opens `Repo.transaction(..., timeout: to_timeout(second: 90))`.
Inside, `await_database/3` retries connecting to an **external customer
database**, sleeping between attempts — 3 s intervals up to 30 s by default.

The wait is configurable *from the YAML being applied*
(`await_database["timeout_ms"]`), so the duration a pooled connection is
held is chosen by the submitted config.

The same transaction also runs `DynamicSupervisor.start_child/2` and
`terminate_child/2`, `GenServer.call/2`, `GenServer.stop/1`, and
`Task.async`/`await`. Supervisor lifecycle changes are not rolled back when
the transaction aborts.

Worth saying: this codebase already separates `perform_actions/1` to run
*after* the transaction, so the authors clearly knew some things belong
outside. `await_database` simply did not get the same treatment.

## 6. Keila — a CSV import runs entirely inside one transaction

**Where** `lib/keila/contacts/import.ex:26`
**Severity** Moderate.

`import_csv/3` wraps the whole import in a transaction: `File.open!`,
`File.stream!` and `IO.read` all execute with a connection checked out, so
the hold time scales with the uploaded file. Progress is reported with
`send/2` from inside, so a rollback leaves a UI that has already been told
about contacts that no longer exist.

Separately, `Mailings.ScheduleWorker.perform/1` makes a blocking
`GenServer.call/2` to `Mailings.RateLimiter` inside a transaction — a
connection held for the duration of another process's mailbox, and a
deadlock risk if that process ever needs the pool itself.

## 7. Supabase Realtime — a send inside a subscription transaction

**Where** `lib/extensions/postgres_cdc_rls/subscriptions.ex`
**Severity** Low-to-moderate. `Subscriptions.create/5` sends a message from
inside its transaction; on rollback the recipient has still been told.

## What the design needed to make this usable

The first run reported 37 findings on one project, and most were noise:
`Process.get/2`, `Application.get_env/2`, `GenServer.whereis/1`. All are
impure — they break referential transparency, so purity is right to reject
them — but a **read has nothing to roll back**.

That forced a second dimension into the effect model. Every impure call now
carries a `mode` of `:read` or `:write`, defaulting to `:write` for
anything unclassified, because a false "irreversible" costs a look while a
false "harmless" costs the bug. Purity ignores the dimension entirely;
transaction safety looks only at writes. One model, two contracts, opposite
questions.

Logging needed the same treatment for the opposite reason: it was
classified `:io` alongside file writes, which would have reported every
`Logger.info` in a transaction. It is now its own category, so a contract
can forbid file writes without forbidding logging.

Neither refinement was foreseeable from the armchair. Both came from
running the thing and reading what it said.

---

# Cleanup that never runs, August 2026

The third context-imposed contract, and the one with the sharpest teaching
case. `terminate/2` looks like "run this on the way out". OTP's rule is
narrower: it runs when a callback returns `{:stop, ...}` or raises. On a
**supervisor shutdown** — the normal way processes stop — the parent sends
an exit signal and a process that is not trapping exits simply dies.

The gap is invisible twice over. The code reads correctly, and a test that
calls `GenServer.stop/1` exercises the path that *does* run `terminate`, so
the one path that matters in production is the one never exercised.

## 8. Sequin — a distributed mutex whose release is both skipped and unsafe

**Where** `lib/sequin/mutex_owner.ex:109-113`, `lib/sequin/mutexed_supervisor.ex:49-53`
**Analysis** `shutdown_safety` / `cleanup_unclear`
**Severity** Low as written. The interesting part is what happens if you
fix it the obvious way.

`MutexOwner` is a `GenStateMachine` implementing singleton election: it
acquires a Redis mutex, and `on_acquired` boots `Sequin.Runtime.Supervisor`
— the entire CDC runtime — underneath a sibling `ChildrenSupervisor`.

```elixir
def terminate(_reason, :has_mutex, %State{} = data) do
  Logger.info("MutexOwner terminating, releasing mutex")
  Mutex.release(data.mutex_key, data.mutex_token)
end
```

`init/1` never calls `Process.flag(:trap_exit, true)`. On any supervisor
shutdown — a deploy, a restart — the process dies without releasing, and
the mutex sits in Redis until `lock_expiry` (default 5 s) expires. The next
node backs off `lock_expiry / 2` and retries, so a rolling deploy pays a
few seconds of runtime downtime that this code was written to avoid.

**The log line is the tell.** `"MutexOwner terminating, releasing mutex"`
would appear on every clean stop. It does not appear during deploys, and
has not, and nothing noticed.

On its own that is minor: the mutex is TTL-based precisely so a hard crash
cannot wedge it, so the missing `trap_exit` means always paying the TTL
rather than sometimes paying zero. A latent optimization that never fires.

**What makes it worth writing down is that the obvious fix is worse than
the bug.** `MutexedSupervisor` starts its children in this order:

```elixir
[
  {ChildrenSupervisor, name: child_supervisor},
  {MutexOwner, on_acquired: fn -> start_children(child_specs, child_supervisor) end, ...}
]
```

The order is forced — `on_acquired` starts children *into* `ChildrenSupervisor`,
so it must already exist. And a supervisor terminates children in **reversed
start order** (`otp/lib/stdlib/src/supervisor.erl:54`), so `MutexOwner` is
always shut down **first**, while the runtime it guards is still fully
running.

So adding `trap_exit` makes `terminate/2` run, and it releases the mutex
while `Sequin.Runtime.Supervisor` is still processing the change stream.
Another node is then free to acquire it and start a second runtime against
the same stream. **That trades a few seconds of downtime for a split-brain
window** — in a component whose entire purpose is to guarantee one runtime
at a time.

The release is not merely skipped; it is positioned where running it would
be unsafe. The TTL is doing the real work, and `terminate/2` is vestigial.

**Fix** Either delete the `terminate/2` clause and document that the TTL is
the mechanism, or move the release to after the children are down — which
means it does not belong in this process at all. Note also that
`Mutex.release/2` is a Redis round trip inside a 5000 ms default shutdown
timeout, so a trapping version would trip the analysis's second outcome as
well.

## 9. Livebook — two temp-directory cleanups skipped on shutdown

**Where** `lib/livebook/session.ex:2111`, `lib/livebook/app.ex:298`
**Severity** Low. Disk hygiene, not correctness.

Neither `Livebook.Session` nor `Livebook.App` traps exits, and both delete
a temp directory in `terminate/2` (`cleanup_tmp_dir/1`, which reaches
`File.rm_rf/1` through a `FileSystem` dispatch, and `cleanup_notebook_files_dir/1`).

User-initiated close goes through `{:stop, :shutdown, state}` and does run
`terminate`, so the common path is fine. Application shutdown and any
supervisor restart leak the directory. Bounded by the OS clearing `/tmp`.

## 10. Keila — an import's temp file is skipped on shutdown

**Where** `lib/keila/contacts/import.ex` → `KeilaWeb.ContactImportLive`
**Severity** Low, same shape: `File.rm/1` in a LiveView `terminate/2`,
no `trap_exit`. LiveView processes are killed on channel shutdown.

## Calibration

Every finding above was read against source, and so was every silence.

| project | `terminate/2` defs | do real cleanup | trap exits | reported |
|---|---|---|---|---|
| oban | 9 | 4 | **all 4** | 0 |
| sequin | 7 | 2 | 1 | 1 |
| livebook | 4 | 4 | 2 | 2 |
| keila | 1 | 1 | 0 | 1 |

**Oban is the reason the silences are worth anything.** It defines the most
`terminate/2` callbacks of anything swept — including `Watchman`, which
drains a producer and waits for executing jobs, and both `Peers` modules,
which delete a leadership row and notify peers — and every one of them
traps. Five of the nine are `Process.cancel_timer` on a process that is
about to die anyway, which the analysis correctly ignores as a
non-durable process operation.

Sequin's other five `terminate/2` callbacks are all
`_new_state = State.invalidate_all(state)` — a pure computation assigned to
an underscore and discarded. Genuinely nothing to skip.

## What the third outcome bought, and what it cost

The first version of this analysis found `MutexOwner` **for the wrong
reason**: through `:timer.tc/2`, which the effect model classified as a
process write on `:timer`'s behalf. The real cleanup — `Mutex.release/2`, a
Redis call behind a `Sequin.Redis` closure — was invisible. Right module,
accidental witness, and indistinguishable from luck until read.

Two changes followed. Dispatchers now outrank their module, so `:timer.tc`
reports as opaque rather than as a clock read. And a third, deliberately
weaker outcome reports work the effect model *cannot* classify, because
that is where most real cleanup lives — a call into your own code looks the
same whether it releases a lease or does nothing.

The fear was noise. Measured, it is **about one module per project**, and
in this sweep it caught `MutexOwner` and `Livebook.Session`, both real. The
suppression that makes it work is one line: a module already reported with
a classified write is not also reported as unclear, so the vague finding
never restates the precise one.

That the cost was measured rather than assumed is the whole reason it
shipped; the armchair estimate was "far too noisy to be useful."

---

# The reply contract, August 2026

The contracts so far came from where code sits — inside a transaction,
inside `terminate/2`. This one comes from what a function *returned*.

`handle_call/3` may answer immediately with `{:reply, value, state}`, or
defer: return `{:noreply, state}` and call `GenServer.reply/2` later.
Deferring is a promise, and the only thing that can discharge it is the
`from` term the callback was handed — an opaque `{pid, tag}` that exists
nowhere else in the system. A clause that defers without keeping `from` has
promised something it cannot deliver, and no later event fixes it.

**Why it needs an analysis** is not that the mistake is subtle. It is where
it surfaces. The process that got it wrong is fine — it returned a valid
value and went back to its loop. The failure appears five seconds later, in
a different process, in a different module:

    ** (exit) exited in: GenServer.call(pid, :thing, 5000)
         ** (EXIT) time out

Nothing there names the clause that failed to reply. Under load it is
indistinguishable from overload, which sends people to tune pool sizes and
mailbox depths for a bug that has nothing to do with either.

## 11. RabbitMQ Erlang client — a flush that answers nobody

**Where** `amqp_client/src/amqp_channel.erl:388`
**Severity** Latent. Unreachable today; a hang for anyone who writes the
obvious thing.

```erlang
handle_call(flush, _From, State) ->
    flush_writer(State),
    {noreply, State};
```

`amqp_channel` exports no `flush/1`, and nothing in the tree sends `flush`
to a channel, so the clause is dead. What makes it worth reporting is the
company it keeps: `rabbit_common/src/rabbit_writer.erl` has a clause with
**the same message name** that gets it right —

```erlang
handle_call(flush, _From, State) ->
    try
        State1 = internal_flush(State),
        {reply, ok, State1, 0}
```

— and exports `flush(W) -> call(W, flush).` for it. So the working protocol
exists one module away, `amqp_channel:flush_writer/1` calls it, and the
channel's own version mirrors it with the wrong return tag. Anyone adding
`gen_server:call(Channel, flush)` — the natural thing, given the neighbour
— hangs for `amqp_util:call_timeout()`.

## 12–13. Two catch-alls that hang instead of failing

**Where** `dogstatsd/src/dogstatsd_vm_stats.erl:96`,
`ranch/src/ranch_server_proxy.erl:40`
**Severity** Low, and deliberate in at least one case.

Both are `handle_call(_, _, State) -> {noreply, State}` in processes that
accept no calls; `ranch_server_proxy` even has a `-spec` documenting the
return. Neither is reachable in normal operation.

Worth naming anyway, because refusing a call by hanging the caller for a
full timeout is strictly worse than replying `{:error, :not_supported}` or
crashing. `ranch_server_proxy` appears in three of the projects swept —
ranch is under Cowboy, which is under Phoenix — so it is the single most
widely deployed instance of the shape.

## Precision

Three distinct modules across roughly fourteen thousand compiled modules,
every one read against source, no false positives. All three are Erlang.

## What did not survive the build

Two things, recorded because they are the more useful half.

**The first version silently exempted every Erlang dependency.** It reused
`clientlib/callbacks.dl`, which matches `implements_behaviour(mod,
"GenServer")` — the Elixir spelling only. Erlang modules declare
`-behaviour(gen_server)`. Since all three findings are Erlang, the analysis
reported nothing at all, and reported it in a way indistinguishable from
"this corpus is clean." The zero was believable, which is what made it
dangerous; it took comparing the Datalog output against the raw extractor
output to notice they disagreed.

**A second finding was written, measured, and deleted.** "Module keeps
`from`, calls `GenServer.reply/2` nowhere" is the same hang by another
route, and `StoresAndForgets` in the fixtures is exactly that shape. But
stating it precisely needs escape analysis this does not have: `from`
leaves through a send, a spawned closure, an ETS write, or any call that
happens to take it as an argument, and whoever receives it can reply.
Suppressing on the routes one can enumerate leaves the rest as false
positives. It found nothing across the corpus, so it was removed rather
than shipped as a heuristic. The fixture stays, pinned as a non-finding.

## Two things the bytecode taught

Neither was foreseeable from the armchair; both were found by running it
and reading what came out.

**A register can be read without being mentioned.** Calls take arguments
positionally, so

```erlang
handle_call({call, Payload}, From, State) ->
    NewState = publish(Payload, From, State),
```

compiles to a bare `{:call, 3, ...}` with no moves at all — the arguments
are already in `{x,0}`, `{x,1}`, `{x,2}`. A search for `{x,1}` finds
nothing, and `amqp_rpc_client` looked like it had dropped `from` when it
had passed it on. Any call of arity two or more now counts as a read.

**The question is per clause, and clauses interleave with dispatch.**
`handle_call/3` compiles every clause into one function, so asking
function-wide lets a clause that defers correctly vouch for one that does
not. That is not a rounding error — `amqp_channel` has ten clauses and was
invisible until the question became per return site.

Block granularity was not enough either. Elixir inlines the first clause
into the entry block, so that block holds both the dispatch test for the
*other* clauses and a body that stores `from`; at block granularity the
store poisons the entry and nothing downstream is ever reported. The
working version walks the control-flow graph instruction by instruction,
refusing to pass any instruction that reads `from`, and asks which
`{:noreply, _}` sites remain reachable.

---

# The analysis that was wrong about itself, August 2026

The most consequential finding of this round was not in anyone's code. It
was in argus.

`reply_contract` returned zero on every project swept. That was believable
— mature codebases, a narrow bug class — and it is exactly what a working
analysis finding nothing looks like. It was only caught because the raw
extractor output had been dumped separately during development and said
there were three.

The cause: `implements_behaviour` stores what a module *declared*, rendered
with `inspect/1`. `@behaviour GenServer` becomes `"GenServer"`;
`-behaviour(gen_server)` becomes `":gen_server"`, colon and all. Nineteen of
twenty-two analyses matched the Elixir spelling only.

On sequin that is 100 modules seen and **42 unseen** — thirty percent of the
gen_servers in the tree, every one of them in a dependency. Which is
precisely the population that matters: nobody reads those modules, so a bug
there survives longest, and all three `reply_contract` findings turned out
to be Erlang.

## What it cost, measured

Same corpus, same rules, only the behaviour predicate changed:

| | before | after |
|---|---|---|
| `shutdown_safety` cleanup_never_runs | 13 | **18** |
| `shutdown_safety` cleanup_unclear | 0 | **6** |
| `error_handling` exit_in_callback | 3 | **13** |
| `timeout_chain` blocking_cast_handler | 1 | **10** |
| `timeout_chain` timeout_chain_risk | 1 | **9** |
| `process_bottleneck` bottleneck_caller | 341 | **1698** |
| `process_bottleneck` sync_call_fan_in | 7 | **13** |

Spot-checked against source: `amqp_rpc_client:terminate/2` calls
`amqp_channel:close/1` — a `gen_server:call` — and the module never traps
exits, so the AMQP channel is not closed on any supervisor shutdown.

## The shape of the mistake

Under-reporting is the failure mode static analysis is worst at noticing,
because **the output of a broken analysis and a clean codebase are the same
artifact**. Every gate in this repo checks that findings are *right*. None
checked that they were *all there*, and no amount of reading the rules would
have shown it: each rule is locally correct, and `"GenServer"` is what the
rule means.

Three things follow, and all three are now in the tests.

**Ask the canonical question, not the declared one.** `behaves_as/2` in
`clientlib/behaviours.dl` maps spellings to one name, and a static test
fails any rule that matches a declared string.

**An indirection that normalises can lose things too.** `behaves_as` passes
unaliased names through unchanged — without that, adding it would silently
drop every behaviour the table omits. And two rules asked for
`":gen_statem"`, a spelling the table *rewrites*, so they matched nothing
from the moment the indirection landed. That regression is invisible at
runtime, so it is checked statically.

**A believable zero deserves the same scrutiny as a surprising finding.**
The only reason this was caught is that two views of the same question
existed and disagreed. That is worth building on purpose, not by accident.

---

# A negative result: unmatched messages, August 2026

Built, tightened three times, and reverted. Recorded because the technique
is worth keeping and the reason it failed is more instructive than the
findings would have been.

## The idea

`handle_info/2` is the only callback whose input the module does not
choose. `handle_call` and `handle_cast` receive what the module's own API
sends; `handle_info` receives whatever anyone puts in the mailbox, plus
what the runtime puts there on the module's behalf — `{:EXIT, pid, reason}`
under `trap_exit`, a late `{:DOWN, ref, ...}`, a `Task` reply that outlived
its `await`, a timer message that raced its cancel. None appear at a call
site, so a `handle_info` matching two specific messages looks complete and
is not. The result is `FunctionClauseError`, so the process dies, at the
moment the system is already degraded.

Finding #3 in this document — TeslaMate's leaked monitor — is exactly this
bug, and was found by reading. The goal was to find it mechanically.

## The technique, which works

Totality is legible in bytecode and exactly decidable. A multi-clause
function raises `FunctionClauseError` by jumping to its own `func_info`
label, which BEAM emits at the top of every function. So **a callback
accepts every input exactly when nothing branches to that label**.

```
{:label, 10}
{:func_info, {:atom, M}, {:atom, :handle_info}, 2}
{:label, 11}
{:select_val, {:x, 0}, {:f, 10}, ...}   <- branches to 10: partial
```

This gets guards right for free, which is the part worth keeping.
`handle_info(msg, s) when is_atom(msg)` reads as a catch-all in source and
is not one; the guard compiles to a test whose failure branch is the
`func_info` label, so it registers as partial exactly as it should.

## Why it was reverted

Three rounds of tightening, each removing a class of false positive, ending
at zero true positives.

**Round 1 — partiality is not rejection.** The first rule paired "traps
exits" with "partial `handle_info`". 17 findings on one project, and
`DBConnection.Watcher` was among them — which handles `{:EXIT, _, _}` on
line 53 and merely has no catch-all. Partiality says *some* input crashes,
never *which*. Same conflation that killed `reply_never_sent`.

The fix was a second fact: which atoms the callback discriminates on,
collected from every equality test. It has to over-approximate — an atom
compared for an unrelated reason counts as accepted — because every
consumer asks whether a message is *not* accepted, so over-approximating
suppresses findings rather than inventing them. 17 → 8, and 37 timer
findings → 1.

**Round 2 — a `start_link` wrapper links the caller, not the server.** The
remaining eight were all one shape: a module's own `start_link/1` calling
`GenServer.start_link`, which runs in the *caller* and says nothing about
what the server links to. Sequin's `PosthogReporter` is the clean example —
traps exits, one `handle_info` clause, no links beyond its parent, whose
exit `gen_server` handles itself. Requiring the link to be established from
a callback took it to zero.

**Round 3 — the last timer finding was a selective receive.**
`Phoenix.LiveReloader.Channel` schedules `:debounced` to itself and consumes
it in a `receive` inside a helper, so it never reaches `handle_info`.

**And the known-real case is invisible by construction.** TeslaMate's
`Vehicle` monitors a process and has two `{:DOWN, ...}` clauses, **both
matching reason `:normal`**, with no catch-all across 59 clauses. The atom
`:DOWN` *is* compared — so `callback_accepts` sees it and suppresses. The
over-approximation chosen in round 1 to avoid false positives is precisely
what hides this. Finding it needs the reason field modelled, not just the
tag, which is a different and much deeper analysis.

## What the negative result is worth

An analysis has to earn its place by finding something true, and this one
did not. Shipping it would have meant three schema relations and two
version bumps — each forcing a pin review in gloss, lowdown and planchette
— to support rules with no demonstrated finding.

The generalisable part: **the safe direction for an over-approximation is
chosen per-consumer, and here it is the same choice in both directions.**
Over-approximating "accepts" avoids false positives and creates false
negatives; the only bug I could point at in advance sits exactly in that
gap. When the conservative choice and the target case collide, the analysis
has no useful operating point, and that is worth discovering before
shipping rather than after.

The totality technique is retained here, and is cheap to rebuild if a
consumer appears that can use it — most likely one that models a clause's
full pattern rather than its head atom.

---

# Two candidates declined, and one analysis re-verified, August 2026

After the negative result above, three more things were measured. Two were
declined before being built, which is the cheaper place to decline them.

## Declined: cleanup under `shutdown: :brutal_kill`

A child spec saying `shutdown: :brutal_kill` never runs `terminate/2`, even
when the module traps exits — so `shutdown_safety`'s advice ("add
`Process.flag(:trap_exit, true)`") would be wrong for those children. That
looked like a real hole.

Grepping the corpus first killed it. Every `brutal_kill` occurrence is a
type spec (`shutdown() :: brutal_kill | timeout()`), a supervisor
*implementation* handling the case (`ranch_conns_sup`,
`consumer_supervisor`, `supervisor2`), or `Process.exit(pid, :brutal_kill)`,
which is a different thing. The handful of genuine child specs are for
children with nothing to clean up.

**That is the point, and it generalises.** `shutdown: :brutal_kill` is a
deliberate declaration that this child has no cleanup — a *commission*.
`trap_exit` is absent by default — an *omission*. Bugs live in defaults, and
the analyses in this document that found real bugs all key on something
absent-by-default: no `trap_exit`, no thought given to what a transaction
body can take back, no one keeping `from`. An analysis looking for a
contradiction someone would have to write on purpose will find that nobody
did.

## Declined: LiveView `mount/3` without a `connected?/1` guard

`mount/3` runs twice, so unguarded data loading doubles the work. Measured:
14 LiveViews in Livebook with none unguarded, 8 in Keila with 3. A thin
population, and a 2× load issue rather than a correctness one.

## Re-verified: `shutdown_safety`'s own findings

More useful than a twenty-third analysis. `shutdown_safety` shipped after
verifying its first-party findings; the full dependency tree had sixteen,
unread. Most had a **right verdict and wrong evidence** — the same failure
the analysis had already been corrected for once.

| | before | after |
|---|---|---|
| `cleanup_never_runs` on sequin | 16 | **5** |

Three exact defects, none of them in the rule's logic:

**Reads misclassified as writes.** `:application.get_env/2,3` and
`:os.timestamp/0` reported as durable cleanup. The Elixir spellings were
fixed when the `mode` dimension landed; the Erlang ones were not — the
**third** two-spelling gap in this sweep. `:error_logger`, which most Erlang
libraries still call, was a fourth, so a library logging "shutting down"
read as unclassified cleanup.

**Unbounded transitive reach.** `call_reachable` walked out of the module,
through a client library, into that library's connection pool. MutexOwner
was credited with `:ets.insert/2 via :wpool_pool:store_wpool/1` — five hops
down `Mutex.release → Redis → wpool`. Bounded to three hops, which is
`terminate → your cleanup function → the API it calls`.

**Structural calls as unclassified work.** `Kernel` is deliberately not in
the pure list, because purity found a soundness hole there — so its calls
arrive as unknown, and `DBConnection.Connection` was reported for
`Kernel.struct!/2` inside an exception constructor. **A soundness choice
made for one contract became noise in another**, which is a hazard worth
naming for any shared effect model.

Every survivor is now a plausible cleanup call: `:amqp_channel:close/3`,
`Gnat:unsub/3`, an `:erlang.send/2` directly in `terminate/2`. And
MutexOwner finally reads `Sequin.Redis.command/1 via Sequin.Mutex:release/2`
— the actual release path, and the evidence the writeup above claimed all
along.

## The pattern worth carrying forward

Four separate two-spelling gaps in one sweep — behaviour names, terminate
callback lists, environment reads, logging modules. Every one silent, every
one found only by reading output against source. Any table of names in a
BEAM analysis should be assumed to be half-written until proven otherwise,
because Elixir and Erlang spell everything twice and `inspect/1` keeps the
colon.

---

# TLS that encrypts without authenticating, August 2026

Generated by taking the previous section's conclusion seriously rather than
treating it as a stopping point. *Bugs live in defaults* is a generator: it
says to enumerate BEAM defaults that are silently wrong. The highest-severity
one is not structural at all — Erlang's `:ssl` client verified nothing
before OTP 26, and wrappers passing options through inherit that.

A connection that does not verify the peer is confidential against a passive
observer and wide open to anyone who can answer for the host. It is silent
by construction: the connection succeeds, the bytes are encrypted, and
nothing at runtime distinguishes a verified session from an unverified one.

## 14–18. Sequin — five modules where enabling TLS disables verification

**Where** `lib/sequin/consumers/redis_string_sink.ex:85`,
`redis_stream_sink.ex:101`, `sinks/nats/connection_cache.ex:172`,
`sinks/rabbitmq/connection_cache.ex:196`,
`databases/postgres_database.ex:206`
**Severity** High. Encryption without authentication, on connections
carrying customer data and credentials.

```elixir
defp maybe_put_tls(opts, %RedisStringSink{tls: true}),
  do: Keyword.put(opts, :tls, verify: :verify_none)
```

The user turns TLS **on** — in the UI, deliberately, because they want a
secure channel — and gets one that authenticates nobody. `:verify_peer`
appears nowhere in any of these modules, so there is no configuration that
changes it. Anyone able to answer for the host terminates the session with a
certificate they minted themselves and both ends report success.

`PostgresDatabase` carries the authors' own acknowledgement:

```elixir
# TODO: Remove this when we have CA certs for the cloud providers
# We likely need a bundle that covers many different database providers
# PLUS a path for users to provide their own certs if needed
```

which is useful evidence about precision: the analysis surfaced something
the authors had already identified as wrong.

**Fix** `verify: :verify_peer` with `cacerts` from
`:public_key.cacerts_get/0` or castore, and a per-connection setting for
users who genuinely need to opt out.

## Why this is an analysis and not a grep

`verify_none` greps fine. The finding is the **module-scope** question a
search cannot ask: *does this module offer any way to get a verified
connection?*

Sequin contains both shapes, and they are three lines apart in spirit:

| | shape | verdict |
|---|---|---|
| `ConfigParser` | maps `REDIS_TLS_VERIFY=verify-none` to `:verify_none`, and sets `:verify_peer` when certs are configured | a configuration surface — **not reported** |
| `RedisStringSink` | `tls: true` → `:verify_none`, `:verify_peer` nowhere in the module | no way out — **reported** |

Adding that filter took sequin from 9 findings to 7 and dropped
`Cldr.Http`, `WebSockex.Conn`, `TeslaMate.Mqtt` and `Kubereq.Step.TLS` —
every one of which supports verification and would have been noise. A module
naming `:verify_peer` anywhere is credited with offering the choice, which
is deliberately generous: arguing about which branch is reachable buys
little, and a false "this is insecure" against code that configures itself
properly is the finding that gets an analysis switched off.

## The half that did not pay

The second finding covers what a search genuinely cannot look for: a connect
whose literal option list never mentions `verify`, taking the library
default. That shape is the reason the analysis was justified in advance.

It found **nothing** on the corpus, because most code reaches TLS through
Mint or hackney rather than a literal `:ssl.connect`. It is kept — exact,
cheap, and correct — but it is not what earns the analysis its place, and
saying so matters: the justification and the value came from different
halves, and only the sweep could tell them apart.

---

# Three more defaults, one shipped, August 2026

Continuing to run *bugs live in defaults* as a generator. Each candidate was
measured before being built, or reverted after being verified.

## Declined: `active: true` sockets

`:gen_tcp.connect/3` defaults to `{active, true}`, which floods the owning
process's mailbox with no flow control — unbounded memory against a fast
peer. A genuinely dangerous default.

Measured: 2 sites in sequin, 0 in Livebook, 2 in TeslaMate, 0 in Bandit,
against 13–20 uses of `active: :once` or `{active, N}` per project. The
ecosystem overwhelmingly does the right thing and the stragglers are small
controlled peers. Thin population, same verdict as `brutal_kill`.

## Built and reverted: network I/O in `init/1`

The best-motivated candidate of the three, and the one that failed most
informatively.

`Supervisor.init/2` defaults to `max_restarts: 3` within `max_seconds: 5`,
and almost nobody changes it — **16 supervisor modules in Livebook, zero set
it**. So a child whose `init/1` connects to something outside the node fails
three times in about five seconds when that service is down, exhausts the
budget, and takes its supervisor's whole subtree with it. That is the shape
behind "the database blipped and the node went down": the service was gone
for seconds and the node stayed down until something restarted it.

Not covered by `sync_call_in_init`, which matches `sync_call` — one process
waiting on a *sibling*, not on a remote host.

It was reverted because neither operating point produces a trustworthy
finding:

- **Restricted to statically-listed supervisor children: zero.** Mature
  projects do not do this, and the ones that connect are started under
  `DynamicSupervisor`s the rule could not see.
- **Unrestricted: eight on sequin, none of them bugs.** `:eredis_client`,
  `Gnat`, `Postgrex.ReplicationConnection` — connection modules where
  connecting in `init/1` is the entire design, and which carry their own
  reconnect logic. Two were outright misattributions:
  `:inet.format_error/1` is classified as network I/O when it formats an
  error string, and `Postgrex.Protocol:cancel_request/3` is a transitive
  artifact of the unbounded reach.

**One thing it caught on the way through is worth keeping.** The first run
returned zero on every project, and the zero was a lie: the rule reads
`impure_call`, and `sync_call_in_init` does not declare the Purity
extractor, so the fact was never emitted. A rule matching nothing reports
exactly what a clean corpus reports. That is the third time in this document
the same failure mode appears — behaviour names, environment reads, and now
a missing extractor — and it is the argument for the fixture discipline used
throughout: **a positive fixture with a negative twin is what distinguishes
"found nothing" from "asked nothing".** Without the fixture the zero would
have been believed and shipped.

## Shipped: `tls_verification`

Covered above. The one of the three that found real bugs — five first-party
Sequin modules where enabling TLS disables verification.

## Scoreboard for the generator

Six candidates from "enumerate the defaults": `trap_exit` (shipped earlier
as `shutdown_safety`), TLS verification (shipped), `brutal_kill` (declined
on measurement), LiveView `mount` (declined on measurement), `active: true`
(declined on measurement), network-in-`init` (built, verified, reverted).

One in three shipped, and the declines cost a grep each. That ratio is the
argument for measuring populations before building, which is the cheapest
step in the whole loop and the one that was skipped for `unmatched_message`.

## Measured and not built: unbounded `DynamicSupervisor` children

Recorded with the measurement done so it can be picked up directly.

`DynamicSupervisor` defaults to `max_children: :infinity`, and the default
is universal: **8 DynamicSupervisors across sequin and Livebook, zero set
`max_children`.** `Task.await/1`'s default 5000 ms timeout (4 sites) and
`hibernate_after` (0 sites) were measured at the same time and are too thin
to pursue.

Relying on the default is not itself a bug — most dynamic supervisors are
driven by trusted callers. The finding is the pairing, and it is the same
shape that made `tls_verification` worth building: a module-scope question a
search cannot ask.

> Is `start_child` reachable from a request handler?

If it is, an unauthenticated request creates a process, and nothing bounds
how many. That is a memory-exhaustion vector reachable from outside, and
`request_surface` already has the entry-point machinery to answer the
reachability half.

**What it needs**: `max_children` is not extracted today. It is a literal in
`DynamicSupervisor.init/1`'s option list, so the extraction is the same
shape as the TLS option reading — cheap, but it means a schema bump and a
pin review in gloss, lowdown and planchette.

**Built after all**, and the findings below were read against source like
every other in this document.

## 19. Phoenix — the long-poll transport starts a process per unauthenticated request

**Where** `phoenix/lib/phoenix.ex:28`, `phoenix/lib/phoenix/transports/long_poll.ex:143`
**Analysis** `unbounded_dynamic_children`
**Severity** Moderate, and conditional.

```elixir
{DynamicSupervisor, name: Phoenix.Transports.LongPoll.Supervisor,
 strategy: :one_for_one}                                    # phoenix.ex:28
```

No `max_children`, so the default `:infinity` applies. And `long_poll.ex`
dispatches a `GET` through `resume_session`, which falls through to
`new_session` when no valid token is present:

```elixir
:error -> new_session(conn, endpoint, handler, opts)        # :57
...
case DynamicSupervisor.start_child(Phoenix.Transports.LongPoll.Supervisor, spec) do   # :143
```

So an unauthenticated GET starts a `LongPoll.Server`, and nothing caps how
many. It appeared in every project swept, because it is Phoenix itself.

**Why the severity is not higher.** The long-poll transport must be enabled
explicitly in the socket config, sessions carry a signed token with a
max_age, and servers time out. This is a missing ceiling on a
pre-authentication path, not an open door.

## 20. Livebook — session creation from a LiveView, uncapped

`Livebook.SessionSupervisor` starts `Livebook.Session` from
`Livebook.Sessions.create_session/1`, reachable from a LiveView event, with
no `max_children`. Each session is heavy — runtime, evaluator, temp dir.
Low severity in the single-user default deployment, and it matters wherever
an instance is shared.

## Why this one needed an analysis

Neither half is a finding. Uncapped dynamic supervisors are everywhere —
**8 of 8** in the corpus set no cap — and `start_child` from a request
handler is ordinary. Only the conjunction is a resource bound an outside
party controls, and it spans two files that each read correctly on their
own. This is the same module-scope shape as `tls_verification`, one level
up: the question is about the call graph, so no line-oriented tool can be
pointed at it.

The suppressions carry the claim, and both are in the fixtures: a cap
discharges it, and so does being unreachable from outside. Most dynamic
supervisors are internally driven, and reporting those would bury the ones
that are not.

---

# A second generator, and a second negative result, August 2026

When "enumerate the defaults" ran dry, a different generator: **two things
that must agree, where nothing checks the agreement.**

The sharpest BEAM instance is that a GenServer is one contract written in
two places. The client half is an ordinary function —

```elixir
def get(pid, k), do: GenServer.call(pid, {:get, k})
```

— and the server half is a `handle_call/3` clause. Nothing checks they
agree. Rename the tag on one side and it compiles clean. `call` then raises
`FunctionClauseError` in the server and the caller exits with it; `cast` is
worse, because the caller is told nothing at all — the server dies, the
supervisor restarts it, the state is gone, and the only trace is a crash
report nobody connected to the wrapper.

Both halves are literal atoms in bytecode, and both extracted cleanly:

```
client_message: [["MsgProbe:put/3#6", "MsgProbe:put/3", "cast", ":put"]]
server_message: [["MsgProbe:handle_cast/2", "handle_cast", ":store"]]
```

on a probe seeded with exactly that mismatch.

**It was reverted.** Two findings across roughly eight thousand modules, and
both were false:

| reported | reality |
|---|---|
| `:amqp_channel` casts `:ok` | `do_rpc/1` contains `gen_server:reply(From, ok)` — the `ok` is a reply value |
| `:syn_gen_scope` calls `:"3.0"` | a version atom, not a message tag |

Same root cause. The client tag is read by walking backwards from the call
to the first write of `{x,1}`, and that write is not always the message: a
tail call whose arguments were set up across a call boundary, or an
unrelated earlier write, gets attributed to the send. The scan stops at any
other write to the register, which is not enough — it needs to know that the
write it found is the one feeding *this* call, and that is dataflow, not a
backwards scan.

## What the two negative results have in common

`unmatched_message` and `message_contract` failed the same way, one level
apart. Both needed to know something about a **value** — which reason a
`:DOWN` clause matches, which message a `cast` is actually sending — and
both were built on a positional proxy for it. The proxy was right on
fixtures and wrong on real code, in both cases quietly.

The three analyses that shipped never asked about a value. `shutdown_safety`
asks whether an attribute is set. `tls_verification` asks whether an atom
appears in a module. `unbounded_dynamic_children` asks whether one function
reaches another. Those are questions the fact model answers exactly, and
none of them can be subtly wrong.

**That is the boundary worth writing down**: this fact model supports
questions about *structure* — what exists, what is set, what reaches what —
and does not yet support questions about *which value flows where*.
Analyses of the second kind can be built and will pass their fixtures. They
fail on the corpus, and they fail quietly enough that only reading every
finding against source catches it.

Building the value-flow layer is a real project, and `Argus.Dataflow`
exists as a starting point. Until then, a candidate that needs to know
*which* value is a candidate to decline — measured in advance, not after
the build.

---

# A third generator, and a defect it found in our own facts

The boundary from the previous section is itself a generator: *enumerate the
structural questions not yet asked* — what exists, what is set, what reaches
what.

One is nearly free. `handle_continue_clause(mod, tag, func)` and
`init_continues_to(mod, tag)` are both already emitted, and nothing checks
they line up. A `{:continue, tag}` with no matching clause crashes at
startup; a clause no `init` ever triggers is dead code.

## Declined, and the reason is now a rule

**`missing_clause` is zero on every project measured.** Exactly what the
loud-versus-silent principle predicts: that bug kills the process at boot,
in development, on the first run. Loud bugs have no population, and this is
the second time that has decided a candidate — the first being the
`brutal_kill` contradiction nobody writes.

Worth stating as a filter, since it is cheap to apply before building
anything: **a static analysis earns nothing by finding what the first `mix
test` already finds.** Every analysis in this document that shipped targets
something that survives to production — a skipped `terminate/2`, a reply
that never comes, TLS that encrypts without authenticating, a supervisor
with no ceiling.

## What the other column found

The `dead_clause` side was not zero — 14 on sequin, 12 on Livebook — but the
tags are not tags:

```
DEAD  Sequin.Runtime.SlotMessageStore  :ok
DEAD  Sequin.Runtime.SlotMessageStore  nil
DEAD  Sequin.Runtime.SlotMessageStore  false
DEAD  Livebook.Runtime.Fly             nil
```

`:ok`, `nil` and `false` are not `handle_continue` tags. **The
`handle_continue_clause` extractor is recording atoms from clause bodies as
though they were continue tags**, so roughly half the rows in that relation
are wrong.

That relation is not unused. `deferred_startup_deadlock` reads it, which
means its findings are computed partly from noise — and nobody would notice,
because a spurious tag simply fails to match anything downstream and
produces silence rather than an error. The same shape as every other quiet
defect in this document.

**Fixed.** The scan matched only `{:x, 0}`, which looks right — that is
where the tag arrives. But `{x,0}` is also the BEAM's first scratch
register, so once a clause body starts it holds whatever that body is
working on, and an `is_eq_exact {x,0} :ok` checking a call result is
indistinguishable from a clause head matching `:ok`.

Stopping at the first write to `{x,0}` is exact: until then the register
still holds the tag, and after it never does. Calls count as writes, since
they return into `{x,0}`.

| | before | after |
|---|---|---|
| clause rows, sequin | 27 | **20** |
| tags matching no `init` continue | 14 | **6** |

and the six that remain are real tags — `:send_next_tcp`,
`:handle_connection`, `:resubscribe` — continued to from `handle_info`
rather than from `init`, which `init_continues_to` does not record. That is
a limit of the ad-hoc measurement, not of the relation.

`deferred_startup_deadlock` reports zero on these projects before and after,
so there is no finding delta to review — the defect was corrupting an input
that happened not to reach an output here. It would not have stayed that
way.

**No unit test guards it, and that is deliberate.** One was written, and it
passed with the fix disabled: the fixture's `case check() do :ok -> ...`
compiles to a comparison on a register other than `{x,0}`, so it never
exercised the bug. Constructing a fixture that reproduces the shape the
corpus produces needs experimentation that was not done here, and **a test
that looks like a guard without being one is worse than none** — it is the
same false assurance as a rule that matches nothing and reports a clean
zero, which is the failure this document keeps returning to. The evidence
for the fix is the corpus measurement above, which is stronger than a
fixture would have been anyway, and the gap is recorded rather than papered
over.

---

# Turning the whole suite on ourselves

Three separate times this sweep, pointing an analysis at argus found more
than pointing it at a corpus. That is a generator too, so all 23 analyses
were run over argus itself.

**No new defects.** Two observations worth keeping.

## Test fixtures drown self-analysis

Most rows are `Argus.Test.Fixtures.*` — the deliberately-broken modules that
exist to make these analyses fire. `call_cycle` reports three cycles, all
fixtures. `deferred_startup_deadlock` reports five, all fixtures.

The hygiene note near the top of this document — *sweeps pick up
`test/support` when the project was compiled in test env* — was written as a
minor annoyance. On a project whose test fixtures are **purpose-built
positives**, it is not minor: it is most of the output, and it would make
argus useless on itself without filtering. Analyzer projects are the extreme
case, but any project with realistic fixtures has a weaker version of it.

## The real findings are all decisions someone already made

Strip the fixtures and what remains is three sites, and every one is
deliberate and documented:

- `Argus.Findings` converts names back to atoms with `String.to_atom/1`, and
  the moduledoc already says why: *"Those names come from BEAM files the
  caller asked Argus to disassemble, so the atoms already exist in this
  node's atom table — parsing does not grow it. Do not feed findings from
  untrusted `.beam` files into a long-lived node."*
- `Argus.Souffle` and `Argus.Autoresearch` call `System.cmd/3`. Shelling out
  to `souffle` is the architecture.

So `atom_safety` is right, and the author was right, and both can be true.
That is the same distinction `tls_verification` had to make — Sequin's
`ConfigParser` offers `verify_none` as a documented option while
`RedisStringSink` forces it — and there it was worth a module-scope filter
that dropped four findings.

**The generalisation is not built here, and it is the most interesting thing
this sweep surfaced**: a finding is worth much less when the code already
carries the reasoning for why it is acceptable. `tls_verification` gets at
this structurally, by asking whether the module offers an alternative. A
general version would ask whether the *decision* is recorded — and the
places that record it are exactly the places a fact model does not look:
moduledocs, comments, a `# TODO` like the one in Sequin's
`PostgresDatabase` that turned out to be the strongest corroboration any
finding in this document received.

## Checking that this document's own findings are clean

If purpose-built fixtures dominate self-analysis, the obvious question is
whether they contaminated anything reported here. Checked mechanically
rather than assumed, by reading each module's `:source` out of its
`compile_info` chunk:

| analysis | modules reported | from a test path |
|---|---|---|
| `tls_verification` | 6 | **0** |
| `shutdown_safety` | 5 | **0** |
| `reply_contract` | 3 | **0** |
| `unbounded_dynamic_children` | 2 | **0** |

Every finding in this document comes from `lib/` or `deps/`. That is partly
luck of which sweeps filtered to first-party beams and which did not, so it
was worth confirming rather than asserting.

**The check is also the fix.** `:beam_lib.chunks(beam, [:compile_info])`
yields `:source`, the absolute path the module was compiled from — so
whether a module is test scaffolding is exactly knowable, not a guess from
its name. A `module_origin(mod, kind)` fact would let every analysis drop
or label fixtures instead of each sweep re-inventing a filter, and it needs
no new disassembly: the pipeline already reads `compile_info`.

Not built here, for the same reason as the rest: an unconsumed relation is
dead weight, and wiring it through 23 analyses is a change whose finding
deltas want reading. But it is a small change with a clear shape, and it is
the difference between argus being usable on analyzer-shaped projects and
not.
