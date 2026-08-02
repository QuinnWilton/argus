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
