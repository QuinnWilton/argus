# Changelog

All notable changes to Argus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.20.0-dev — unreleased

What 0.20.0 will ship; the release dates this heading and drops the
`-dev` from `mix.exs`. Grouped by concern. Each entry opens with what it
does: **Added**, **Changed**, **Fixed** or **Removed**.

### Waits that end on their own

**Fixed.** `blocking.receive_in_callback` no longer reports a receive
that waits for its own monitor's `:DOWN` as "Blocking receive inside a
GenServer callback" (error). The runtime sends that `:DOWN` once the
process exits, or at once if it was already gone, so the wait cannot
outlast the monitored process. Such a receive (`recv_down`, below) is
`bounded` "down" and reported as "receive inside a GenServer callback"
(warning), whose detail says it holds the callback until that process
exits and whose help is Task.shutdown/2's shape: an `after` that kills
it and waits again. Broadway's `Topology.terminate/2` (stops its
supervisor and waits for it to go) and `Topology.Terminator`'s
terminate/2 (waits for each consumer's `{:done, pid}` or `:DOWN`) move
from the error to the warning. `blocking` runs `Argus.Extractors.Monitor`.

**Fixed.** `recv_start`'s `blocking` column read a timed receive as
blocking when a receive without `after` followed it in the same
function: the scan of the empty-mailbox block for `wait` or
`wait_timeout` passed over the timed one's `wait_timeout` and found the
later receive's `wait`. Phoenix's `Channel.Server.close/2` (a grace
period for the `:DOWN`, then a kill and a wait) had both of its
receives recorded as blocking.

**Fixed.** `mailbox.unconsumed_monitor` "timed_wait" ("leaves a monitor
live after its wait times out") leaves out a monitor whose `:DOWN` a
receive with no `after` in its own function takes (`recv_down`): it is
waited out there, as the rule already counts a blocking receive's.
Phoenix's `Channel.Server.close/2` and `Socket.shutdown_duplicate_channel/1`
give the channel a grace period, then kill it and wait for the `:DOWN`.
Read per function, as the timed wait is. `mailbox` reads `recv_down`.

**Added.** Schema 88. `recv_down(id, func, monitor)`
(`Argus.Extractors.Monitor`): a receive with a clause that takes the
`:DOWN` of a monitor its own function took. The clause heads are run on
that message, `{:DOWN, ref, type, object, reason}` with only the tag,
the ref and the type known; a pin on the object (a monitor by name
reports `{name, node}`), a reason or a guard is a test the message can
fail, and no row. The pinned ref must be, on every path, what an
`erlang:monitor/2,3` of a process or port (or `Process.monitor/1,2`)
returned, and no path from that call to the receive may demonitor. Its
other clauses do not matter: they can only end the receive sooner.

### A timer finding where the program cancels it

**Changed.** `mailbox.timer_cancel_without_flush` is still one finding
per module and state key, but it points at a cancel the program itself
runs over one only its tests reach, and then at an arm likewise; a key
whose cancels are all under test is reported as before. Plausible's
`Ingestion.WriteBuffer` cancels its `:tick` timer in `handle_cast`'s
buffer-full branch and in `handle_call(:flush)`, which only its test
helpers request; the finding pointed at `handle_call/3` because the
least row orders by function name, and now points at `handle_cast/2`
(write_buffer.ex:53). A cancel left out is a related frame of the
finding: **Added** `mailbox.timer_cancel_under_test(mod, key, site,
func)`, an evidence relation ("also cancelled here, on a path only the
tests take"). Which modules are reported does not change; corpus tally
unchanged.

**Added.** `clientlib/test_code.dl`: `test_module` (a module that calls
into ExUnit — test support compiled with the program), `test_code`,
`runs_outside_tests` (forward from the functions nothing calls, never
through test code), `reached_from_tests` and `runs_under_test`. For
choosing among sites, not for quieting a finding: a library's public
function that only its compiled test helpers call reads as under test
too.

### A monitor the caller collects

**Added.** Schema 87. `awaits_down_after(func, call)` (Monitor
extractor): every path in `func` from the call at `call` to its return
waits for a :DOWN — a receive with no `after` whose `{:DOWN, …}`
clause takes any monitor's (the ref not compared) or the one whose ref
the call returned, a `Process.demonitor(ref, [:flush])` of that ref, or
a call to a function of the module that holds such a receive or calls
one. A path that raises is not asked; a wait in a closure or in another
module is not seen. Read by `mailbox`.

**Fixed.** `mailbox.unconsumed_monitor`'s `timed_wait` ("… leaves a
monitor live after its wait times out", an error) no longer reports a
monitor its callers go on to collect: every way the program has into
the monitoring function passes a call that `awaits_down_after` names,
and none comes from an exported function, one nothing calls, or what a
spawn runs. That is OTP's old supervisor shutdown, whose
`monitor_child/1` looks once with `after 0` and returns the monitor to
`wait_children`: GenStage's `ConsumerSupervisor.monitor_child/1` and
Horde's `ProcessesSupervisor.monitor_child/1` were false positives
(corpus: gen_stage ×2, horde ×3 checkouts gone; no other title moved).
A caller that waits on only some paths, one caller that waits beside
one that does not, and a wait pinned to another monitor's ref still
report it.

### A run redoes only what an edit invalidates

**Added.** `Argus.Pipeline.run_shards/3` extracts into a directory per
producer — `:base` (the emitter's facts, `def_use`, `conditional_call`
and the extraction errors of the steps they come from) or one
extractor — and reports the modules it lost to a timeout or a crashed
worker and the modules whose specs it read from the code path.
`Argus.Pipeline.Shards` joins such directories into a facts directory.
A producer's rows do not depend on which other producers run, so one
can be extracted again on its own.

**Added.** `Argus.Cache`: a store of results on disk, keyed by
content — its entries' layout, their retention (`Argus.Cache.stale/2`,
`prune/2`: within each group the three most recent and anything
touched within the hour are spared) and `ARGUS_NO_CACHE`, which turns
every store off.

**Added.** `Argus.Cache.Facts`: facts extracted through a store, each
producer's rows kept as a shard keyed by the beams, the code that
producer runs (`Argus.Cache.Code`: its import-table closure and the
base's, from its roots through this project and its dependencies), the
runtime and the options that shape rows — and, for the specs extractor,
the environment it reads, with each module it read from argus's own
application or found absent recorded and checked on every hit. Only
missing shards are extracted, and a run that lost a module to a timeout
keeps none. A run's facts are each relation file's digest and source,
materialized on demand as hard links byte-identical to
`Argus.Pipeline.run/3`'s directory; `solve/3` keys a solve on the
digests of exactly what it reads, and a stage's outputs join the facts
by content. `Argus.Cache.CodeTest` runs every producer with call
counting on and checks that nothing it executes lies outside its
closure.

**Added.** `cache:` on `Argus.run_analyses/2`, `Argus.analyze/3` and
`Argus.Analysis.extract_facts/3` names a store: the facts are read from
its shards or extracted into them, stage 0, the points-to stage and
every analysis are solved through it, and after an edit only the
producers and solves the edit invalidated run again. A run whose solves
are all kept makes no facts directory; `extract_facts/3` returns
read-only links byte-identical to a fresh extraction. The findings are
the ones a run without a store returns, every field but the durations.
Priors are asked every run, as without a store, and the solves that
read them are keyed on what the model said. Ignored with `facts_dir:`
and under `ARGUS_NO_CACHE`.

**Changed.** `Argus.Corpus.analyze/2` runs through each checkout's
store (`Argus.Corpus.store/1`, `<checkout>/.argus-facts`) in place of
the whole-facts entries keyed on the engine digest: an edit to one
extractor re-extracts that extractor's shard over each checkout, an
edit to a rule re-solves what reads it, and an edit that leaves the
facts byte-identical (a refactor of `Argus.Instr`) re-extracts and
solves nothing again. `Argus.Corpus.stale_facts/2` and `prune_facts/2`
(and `mix argus.corpus prune`) prune the store per producer and per
program, and the older whole-facts entries by the same policy; nothing
reads those any more. The specs extractor's shard records what it read
of argus's own application: in `MIX_ENV=test` that holds the fixtures'
stubs of `Oban.Worker`, `Phoenix.LiveView` and the like, which a
corpus checkout's calls resolve to — the engine digest left them out.

**Changed.** `Argus.Pipeline.run/3` writes a relation's rows grouped
by producer — the base's first, then each extractor's in the order
`extractors:` names them, each group in module order — where it
interleaved them module by module. Three relations have more than one
producer (`extraction_error`, `imprecision`, `dynamic_call`); every
other file is byte-identical to before. `Argus.Findings.extraction_errors/1`
lists the errors in that order. An extractor named twice in
`extractors:` runs once.

### What the program's other sites believe

**Changed.** Schema 86. `failure.inconsistent_handling` gains `raises`,
`cover` and `caught`: for an `exception_guarded` deviant, the class the
call raises, and how the site stands — `none` (no try around it, here or
on some way in), `try` (inside a try whose handler takes `caught`, other
classes or nothing) or `callers` (every way in passes a try, not always
one that takes the class). Empty for `result_checked`. Only the finding
builder reads them.

**Fixed.** The `exception_guarded` finding says what is true of its
site. It said "outside a try" of a call inside a try that lets its class
through (an `after`, `catch :exit` around a badarg); that site now reads
"called in a try that lets its error through", with "inside a try that
catches only :exit; the call raises an error" (or "catches nothing").
A bare site's title says what the other sites do in the class-aware
sense: "called bare where every other call site catches its error" (was
"guards it"), and the detail "N of the M call sites in this program
catch its error" (was "wrap in one"). The label names the site's
standing ("called outside any try", "in a try that catches only :exit")
in place of "the one site that disagrees", and the fix says which class
to catch.

**Changed.** Schema 76. `call_result(id, func, callee, fate, raises,
target)`: `guard` and `guard_end` are gone, and `raises` names the class a
failing call raises (`exit` for a call into a process, `error` for a BIF
or an ETS operation, `*` for either). `catch_class(id, func, class,
span_end)` says which classes a try's handler takes on a path that
returns (none for an `after` or a rescue that only re-raises; `*` with
no class test, and for Erlang's `catch Expr`), and
`try_covers_closure(id, func, closure)` which closures a try's region
builds. Only `failure` read the dropped columns.

**Fixed.** `failure.inconsistent_handling` counts a call as guarded only
when a try covering it (`try_covers`) takes the class the call raises.
Any enclosing `try` used to count: an `after`, a `catch :exit` around an
ETS badarg, and a rescue that re-raises made a belief out of sites that
handle nothing, and hid a deviant in the same shapes. Erlang's `catch
Expr` now counts as a guard; a program that keeps
`case catch ets:update_counter(...)` as its convention was all bare,
and its one truly bare site was not reported.

**Fixed.** `catch_class` counts a class a handler takes only on a path
that ends in a return: a clause that re-raises in tail position
(`reraise e, __STACKTRACE__`, `:erlang.raise(kind, reason, stack)`,
unwrapping `e.original` included) keeps nothing from propagating, and
`CatchClauses` reports what its paths return from as `handled`. finch's
`HTTP2.Pool.request/5`, whose `catch kind, error` logs and raises again,
no longer makes a belief out of the calls it wraps.

**Fixed.** `failure.inconsistent_handling` counts a call as guarded
when its callers guard it: a private helper called only inside a try
that takes the class, and a closure whose value only calls inside such
a try read (`Enum.each(ks, fn k -> ... end)`), run under its handler.
The call graph is walked from the exported functions down every call
site no such try covers; what is not reached that way is guarded. A
closure built in a function that starts a process may run in that
process, and is not. A tail call takes part in the exception belief as
any site does, guarded by its callers' tries. db_connection's
`Holder.hash_holder/2`, reached only from inside `maybe_disconnect/3`'s
rescue, is no longer the deviant. The evidence frame of a site its
callers guard says so.

**Changed.** `failure.inconsistent_handling`'s population no longer
depends on how the target is spelled for a callee that fails on a
missing row (`:ets.update_counter`, `:ets.lookup_element`). A site on a
literal table was judged only by that table's sites, and one on a
variable by every site of the callee: sequin's logger was a deviant with
`table_name` and would not have been with `@table`. A site on a known
target none of whose sites agree is now judged by every site of such a
callee when the agreeing sites span two tables or more. A target that
has an agreeing site of its own is judged by its own sites, whatever
the callee (postgrex's SCRAM cache reads its table guarded once and
bare once, where it knows the row is there), and a callee that fails
when the table or the server is missing keeps a belief per target.
mnesia's one bare read of its stats table is still not a deviant from
gvar's 120 guarded ones.

**Changed.** `failure.inconsistent_handling`'s title says "every other
call site" only when the reported site is the population's one deviant,
and "most call sites" when there are more: `clear_majority` lets up to a
quarter of the sites deviate, and nine guarded against three bare
reported three sites, each titled as though it were the only one.

### A remote call that never answers

**Changed.** Schema 72. `rpc_call` records `:rpc.block_call/4,5`,
`:rpc.yield/1`, `:rpc.nb_yield/2` and `:erpc.receive_response/1,2,3`
(variants `block_call`, `yield`, `nb_yield`, `erpc_receive`): each
waits for an answer, forever where the arity leaves the timeout out.
`nb_yield/1` and `wait_response` do not wait and stay out. Two
relations beside it: `rpc_target(id, target)`, the remote function as
`Mod.fun` from the M and F arguments (`"fun"` for the forms that take
a fun, `"dynamic"` where the site does not name it), and
`rpc_timeout_param(id, param)`, when the timeout is one of the
function's parameters on every path. `infinity_arg(caller, callee,
arg_pos)` (`Argus.Extractors.CallArgs`) records a literal `:infinity`
argument at any position; `call_arg` stops at the fourth, and a
wrapper's `timeout \\ :infinity` passes it fifth.

**Fixed.** `failure`'s `{:badrpc, _}` rules (an rpc result matched by
shape with no badrpc clause, or used as a boolean) read `:rpc.block_call`
and `:rpc.yield/1` as well as `:rpc.call` and `:rpc.multicall`: each
answers a gone node with the tuple itself. `rpc_result` records
`:rpc.yield/1` (part of schema 76). `:rpc.nb_yield` wraps the answer in
`{:value, _}` and stays out.

**Changed.** `startup.blocks_on_peer` "remote" follows an rpc as it
follows a `:global` lock: one in `init/1`, or in anything `init/1` calls
on its own stack, holds the supervisor's start (`func` is the init/1;
the anchor is the rpc). It read only an rpc written in init/1 itself, so
a helper's rpc was reported by blocking as a generic unbounded wait. An
rpc in a process init/1 starts is not followed.

**Changed.** `blocking.unbounded_wait` "rpc" leaves out an rpc init/1
reaches on its own stack, not only one written in init/1: startup
reports it (above). A helper init/1 shares with handle_call/3 is then
reported only as startup's, as a `:global` lock already was.

**Fixed.** `blocking.unbounded_wait` "rpc" ("RPC without a bounded
timeout") no longer fires on a remote function that answers without
waiting on anything: a process or ETS lookup, a clock,
`:persistent_term.get`, `:code.is_loaded` (`quick_remote` in
blocking.dl, read against `rpc_target`). On a connected peer such a
call returns, and a peer that goes away is noticed within net_ticktime;
what can keep the caller forever is a callee that never answers, and
these do not wait. Horde's `Registry.process_alive?/1`
(`Process.alive?`), nerves_hub's `CLISessionCache` (`:ets.tab2list`)
and phoenix_live_dashboard's `SystemInfo.node_capabilities/2`
(`:code.is_loaded`) are no longer reported.

**Fixed.** "RPC without a bounded timeout" said a partitioned or
restarting peer blocks the caller indefinitely. It does not: erpc,
under `:rpc.call` since OTP 23, monitors the peer, and once
net_ticktime notices it gone (about a minute by default) the call
returns `{:badrpc, :nodedown}` or raises `{:erpc, :noconnection}`. The
detail now says a peer that stays connected but never answers holds the
caller forever, and a node that goes away is noticed after net_ticktime.

**Fixed.** "RPC without a bounded timeout" helps each API by what its
timeout does: `:rpc.call` and `block_call` answer `{:badrpc,
:timeout}`, `:erpc.call` and `receive_response/2` raise `{:erpc,
:timeout}` (the help said to match `{:badrpc, :timeout}`, a value that
never arrives), a multicall names the node that did not answer, and a
yield has `nb_yield/2`. `Argus.Findings.rpc_api/1` names every variant;
`erpc_multicall` read as its raw name.

**Added.** "RPC without a bounded timeout" follows a timeout the
function takes as a parameter to the callers that pass `:infinity`
there: a wrapper's `timeout \\ :infinity` compiles to a lower arity
that does, and every call through it waits forever. The site's timeout
read as unknown and was never reported. `unbounded_wait`'s `detail` is
`caller` for such a row, and `blocking.rpc_infinity_caller(func, site,
caller)` gives each caller as a related frame ("passes :infinity as
the timeout"). Only a literal `:infinity` at the call is followed, not
one forwarded through a further wrapper's parameter.
### Check-then-act, read closer

What a precision audit of `ets_missing_row`, `ets_check_act` and
`mnesia_check_act` found, one entry per finding.

**Fixed.** `ets_missing_row` follows the check across function calls.
CheckThenAct lifted only literals, `any`, parameters and their elements
across a call, and the rule names tables as `clientlib/tables.dl` does
(a named table, an `:ets.new/2` site, a module's field), so a check and
an act in different functions never met: a count in a helper the
found-row branch calls, a check in a helper that returns it, or a count
in another module. A named table and an `:ets.new/2` site now cross
every call unchanged (`global_identity`), and a table a module keeps
under a field of its own crosses calls within the module
(`module_identity`). The other instances name their resources by
literals and parameters, and are unchanged.

**Fixed.** `ets_missing_row` asks whether the act's ArgumentError is
rescued of the act and the calls that lead to it, not of whole
functions. A `rescue` anywhere in the meeting function or the act's
function silenced it, even one around unrelated code after the act;
now the act is rescued when a handler that takes the error (class
error, `ArgumentError`, `:badarg`, or Erlang's `catch`) covers it, or
covers a call on every path from the meeting function down to it
(`clientlib/exceptions.dl`'s `site_rescues_argument_error`, over
`try_covers`). A private function whose every call is so covered, and
that nothing outside the program can call, is rescued by its callers.
One unguarded caller keeps the finding.

**Fixed.** A composite key written out at each call —
`:ets.lookup(t, {mod, fun})`, then `:ets.update_counter(t, {mod, fun},
...)` — is one key: the check and the act meet on it, as they did when
the key was bound to a variable first (schema 77, below).

**Fixed.** `ets_missing_row` asks the remover's key when it can rule
the remover out. A remover of the calling process's own row
(`:ets.delete(t, self())`) takes only its own process's row, so it does
not race a pair keyed by `self()` (schema 78, below); a remover of a
literal row takes that row alone, not another literal's nor the rows
kept beside it under parameters (a `:__total__` next to the keyed
counts). A remover whose key the facts cannot equate to the pair's — a
flush keyed by what a timer was handed — still counts.

**Fixed.** `ets_missing_row` takes a named table the program does not
show being made — made by a dependency, or under a name that arrives at
runtime — to be shared. `shared_table` held only when an `:ets.new/2`
in view named the table and was not private, so a table named from
config was never reported.

**Fixed.** `ets_check_act`'s trip exemption — a write that carries
nothing of the read, on a table nothing writes back, whose decision
stays inside — no longer covers a guard on what the row holds, nor a
marker whose decision also sends. A guard (`[{^k, cur}] when cur >=
serial -> :ok`, then `insert({k, serial})`: a field of the row compared
with the value the write stores, schema 80's `field_compared`) was
exempt whenever the function returned `:ok` on both branches or its
caller ignored the result, though the older serial still lands last. A
marker whose decision sends or makes another write (`[] -> insert({id,
true}); send(mailer, ...)`, schema 79's `effect_decided`) was exempt
though both racers send. A check of the row against a clock (`blocked >
now`) is an expiry, not a guard, and a send in a helper the decision
calls is not counted: supavisor's `CircuitBreaker.record_failures/3`
trips its block when the stored one has expired and has a helper tell
the other nodes, and both racers write the same block and send the same
news.

**Fixed.** `ets_check_act`'s delete exemption holds only for a delete
decided by whether the row is there. "Deleting twice is deleting once"
covers a delete racing a delete, not a delete racing a fresh insert: a
release that checks the row's owner and then deletes by key can delete
the next owner's lock. A delete decided by what the row holds is
reported, unless every row the table is written is a refill: then the
row a delete can lose is a cached copy, and losing one is a miss (an
expired cache row deleted on read; blockster's settings caches,
invalidated after a caller decides on a setting's value). An
invalidation (`[{^key, _}] -> delete`) and a `delete_object`, which
deletes only the object it names, are not reported.

**Fixed.** `ets_check_act`'s refill exemption — both racers compute the
same value, so either write is right — no longer covers a value the
call mints (a random API, a unique integer, a ref, or a project function
that makes or returns one) when the writing function hands it out: each
racer returns its own token, and only one is stored. `races` reads
`impure_call` (`Argus.Extractors.Purity`) for it. The `CacheRefill`
fixture pinned as quiet a loader that stamped `System.unique_integer/0`
into its value and returned it; that is this shape, and its loader is
now a pure function of the key.

**Fixed.** When `ets_check_act`'s pair runs in one process, the other
writer it counts must be able to land on the pair's row after that
process starts. A write of a literal key other than the pair's, or of a
literal row beside rows keyed by what callers pass (a seeded
`{:schema_version, 1}` beside the counts), is not the pair's row; and a
write reached from other processes only through an `init/1` or an
Application's `start/2` — a table seeded by its creator — runs before
an ordered supervisor start reaches the serialized process's siblings.
`ets_missing_row`'s removers take the same view of a literal row kept
beside keys callers pass, whatever the source of those keys.

**Fixed.** `ets_check_act`'s write-back test is asked of the pair's key,
not the whole table. One `update_counter` of a separate literal row —
a `:__hits__` count beside a cache's rows — turned off the delete,
refill and trip exemptions for every pair on the table. A write-back
now counts against a pair only where it can land on the pair's row:
not at a literal key other than the pair's, nor at a literal row
beside keys callers pass. Where either key is not known, the table-wide
answer stands.

**Fixed.** An insert into a table made with `keypos: N` is keyed by
element N of its object, not the first. On a table of Erlang or Elixir
records the first element is the record's tag, so a lookup by id and
the insert of the updated record never agreed on a key, and the classic
read-modify-write of a record table went unreported by
`ets_check_act` and `ets_missing_row` alike.

**Fixed.** A match on the key — `:ets.match_object(t, {k, :_})`, or
`:ets.match/2` — decides as a lookup does: it is a check for
`ets_check_act` and `ets_missing_row` (schema 82). A pattern whose key
is a wildcard names no key, and a `select` match spec, whose head sits
in a list, is left out, as a dynamic key is.

**Fixed.** `mnesia_check_act` finds the read-modify-write that updates
the record it read in place: `[rec] = dirty_read(t, k)` and then
`dirty_write(put_elem(rec, 2, n + 1))`, an Elixir record's update, or
a helper's `put_elem` pipeline (schema 83). The write's table and key
were `dynamic`, so only a program that rebuilt the whole tuple was
seen: blockster's `update_user_betting_stats/5` was reported only
through the fresh record written in its `[] ->` branch, and the lost
update of the stats it read went unseen.

**Fixed.** `mnesia_check_act` finds the other writer and the write-back
where they are. When the pair runs in its table's one owning process,
another writer counted only if it spelled the table: one handed the
record by a helper (`defp save(rec), do: :mnesia.dirty_write(rec)`,
the table the record's first element), or the table as a parameter,
was not seen, nor was a transaction's write or `dirty_update_counter`,
though a dirty read-modify-write takes no lock against either (schema
79). The same helpers and counters now write a table back, so a
dirty delete on it is reported, as it is on a table written back in
place. Both resolve the table through `mnesia_write_table`; the acts
stay the dirty writes.

**Fixed.** `mnesia_check_act` reads a dirty activity as dirty: a
read-modify-write with `:mnesia.read` and `:mnesia.write` inside
`:mnesia.async_dirty(fn -> ... end)`, or `activity(:sync_dirty, ...)`,
takes no lock and is reported as the `dirty_*` spelling is (schema 85).
Only the closure's own calls: a helper it calls is not known to run in
the activity.

**Fixed.** `mnesia_check_act` takes a cluster lock as serializing: a
pair in a closure `:global.trans/2` runs, on a table every writer writes
under such a closure (or in a private function only such closures
call), is not reported. Dirty operations skip Mnesia's locks, not an
external mutex. The lock's identity is not compared, so writers under
different locks are taken as serialized; one writer outside a lock
keeps the finding. `races` now runs `Argus.Extractors.ApiCalls` for
`global_op`.

**Changed.** `mnesia_check_act`'s one-writer excuse says what it
assumes, in `races.dl` and the analysis's doc: one process per node. A
locally registered owner runs on every node, and a replicated table is
written by each node's owner, which the excuse does not see; whether a
table is replicated is `create_table`'s copies lists, which the facts do
not show.

**Changed.** `mnesia_check_act` leaves out the ETS rule's trip as well
as a delete (`harmless_record_race`): a dirty write of a value made of
neither the read nor a call, not guarded by what the record holds, with
no send or other write under the decision and a decision that stays in
the program — `[] -> dirty_write({:prefs, user, defaults})`, then
`:ok`. Both racers write the same record. A claim that tells its caller
it won, and a guard on the record's contents (ztlp's serial check),
stay reported, as does anything on a table the program writes back or
counts in.

### Solves kept across corpus runs

**Added.** `Argus.run_analyses/2` and `Argus.Souffle.run/3` take
`solve_cache:`, a directory of kept solves (`Argus.Souffle.Cache`), or
`{dir, group}` to name the entries' group for retention. A solve is
keyed on its program with its transitive includes, the solver's
version, and the content of exactly the relation files the program
reads (`Argus.Souffle.input_files/2`): one whose inputs have not moved
since it was kept is read back rather than run, the stages among them,
and a stage's outputs key the solves after it by their content. So a
change that leaves a program's inputs byte-identical — an edit
upstream whose stage came out the same — solves nothing again. One
directory serves any facts. A kept solve's files are read-only, beside
a manifest of their digests. Off by default, and ignored under
`ARGUS_NO_CACHE` (`Argus.Cache.enabled?/0`).

**Changed.** `Argus.Corpus.analyze/2` keeps each checkout's solves.
A warm corpus run with no rule edited solves nothing (72 checkouts:
1,016 solves and 191 s of solver time before, none now); a rule edit
re-solves only the programs that include it and those whose inputs it
changed. The findings are identical, every field, to solving afresh.
`Argus.Corpus.stale_solves/2`, `prune_solves/2` and `solve_caches/1`
apply the facts cache's prune policy to each program's solves, and
`mix argus.corpus prune` prunes them in the entries it keeps.

**Changed.** `Argus.Souffle.input_relations/2` is memoized for any
program, keyed by its content with its includes and the solver, and
`programs:` keeps the answer in a store's directory across VMs, so a
warm run asks no solver. A program argus ships is read at most once a
second; one elsewhere on every call. `Argus.Souffle.executable/0`
looks `souffle` up once per value of `PATH`. On a busy disk the reads
were most of a warm corpus run's system time.

### Priors asked side by side

**Fixed.** `Argus.Priors.Jev` sends its requests over an httpc profile
of its own, `:argus_priors`, that gives each request an idle connection
or opens a new one (`max_keep_alive_length: 0`, up to 64 kept alive).
On httpc's default profile a request waits in the queue of a busy
keep-alive connection rather than open another, so requests in flight
shared however many connections the first burst had opened: at 32 in
flight over Plausible, 11, and each request took three times as long.

**Changed.** `Argus.Priors.rows/2` and `derive/2` ask every question's
requests from one pool (`Argus.Priors.Driver.derive_all/3`) instead of
one question after another, each with its own rounds and tail; the
questions' subjects are computed side by side and a question's requests
go out as soon as its subjects are ready. The default `:concurrency` is
16, up from 8: over Plausible's 115 requests 32 in flight nearly
doubled each request's time with nothing gained, and no rate-limit
response came back at any setting. Requests and cache keys are
unchanged, and replaying the same answers gives the same rows. Over
Plausible the requests now take about 1.5 s where they took 3; what
remains of the priors phase is reading the facts and computing the
subjects.

### Process points-to, derived once

**Changed.** Process points-to (`clientlib/processes.dl`) is a stage of
its own, `priv/dl/points_to.dl`, derived once per run after stage 0,
into the same facts directory, instead of inside every solve that asks
which process a pid can be. The fixpoint was most of each of those
solves on a large program — over ssl, public_key and kernel, four of
the ~4.5 s blocking, coupling, coverage, failure, mailbox, shutdown and
startup each took, and races as well — and it was the same fixpoint in
each. The analyses read what the stage writes
(`Argus.Analysis.points_to_relations/0`: the processes, the resolved
targets, and of what each source points to, the processes and ETS
tables) through `clientlib/staged_processes.dl`, which `otp.dl` now
includes in place of `processes.dl`. Over the four benchmark sets
(Phoenix's stack, mnesia+inets+ssh, ssl+public_key+kernel, logflare)
every analysis's output rows are identical; those solves drop to
0.2–0.7 s each, plus one points-to solve of 0.5–4.2 s.

The stage follows a gen_statem's data, exit signals, monitors and links,
and ETS tables for every analysis alike (before, only an analysis that
included `process_statem.dl`, `signals.dl` or `tables.dl` did). None of
them changes what another analysis sees: signal kinds are not call
kinds, so they are staged apart (`process_signal`, which `signals.dl`
joins back into `process_call` and `pid_use`), and a table is a leaf no
field or process is read out of. `runs_elsewhere` moved to
`clientlib/runs_elsewhere.dl` and is still derived per analysis (it
needs no points-to, so an analysis that only walks a process's own calls
does not read the stage); `call_instr` moved to `imports.dl`,
`statem_process` to `behaviours.dl`.

`extract_facts/3` derives the stage when a selected analysis reads it
(`points_to: :deferred` leaves it to the caller), `run_rules/3` when it
is missing, and `Argus.Findings.run/2` stages it once before the solves
fan out; a points-to failure degrades only the analyses that read it
(`{:points_to, reason}`). New: `Argus.Analysis.derive_points_to/2`,
`points_to_rules_path/0`, `points_to_relations/0`,
`stage0_relations/0`; `Extraction.ensure_points_to/3` and
`reads_points_to?/1`. `stage0: :provided` covers both stages. The
corpus cache keeps stage 0 but not the stage, which is rules: each run
derives it into a directory of hard links beside the entry. The pinned
input sets moved accordingly (`test/argus/analysis_inputs.exs`): the
analyses that read points-to no longer read the `pid_*` summaries, and
coverage no longer reads the call graph at all.

### Check-then-act without the copies

**Changed.** `clientlib/check_then_act.dl` tests how two identities'
sources agree with two relations (`either_any`, `may_agree`) instead of
a disjunction in each rule that asks, and walks from a value to the acts
it decides once for all the checks it carries (`decides`). Souffle
expands a rule with k alternatives into k rules, each with the whole
body: races.dl compiled to 1,593 clauses (685 now), spent ~2.8 s
compiling before reading a fact (0.7 s now; it was 260 of the 359 s of
solver CPU in the test suite without the corpus), and repeated
`joined`'s five-atom join per alternative — 26 of the 28 s races took
over mnesia+inets+ssh (2.2 s now). The rows are identical.

### Rules that read as their sentence

**Changed.** The top-level rules of the findings people read most —
`blocking.unbounded_wait` (rpc and :global), `startup.blocks_on_peer`
(a cluster-wide lock in init/1), `shutdown.teardown_touches_sibling`
(through `sibling_call`), `mailbox.timer_cancel_without_flush`,
`failure.inconsistent_handling`, and `races.ets_check_act`,
`ets_missing_row`, `ets_publish_order` and `mnesia_check_act` — are
written in named concepts (`makes_rpc`, `no_timeout`, `during_init`,
`retrying_lock`, `waits_on`, `catches_exit`, `cancels_under`,
`rearms_under`, `clear_majority`, `reads_then_writes`, `public_table`,
`another_process_writes`, ...) with the plumbing underneath, so each
reads aloud as what it checks. Terms shared between analyses live in
`priv/dl/clientlib/vocabulary.dl`; single-use terms stay beside their
rule. The concepts are Soufflé `inline` relations where they are
non-recursive, so naming one materializes nothing. Output relations,
their columns and every finding are unchanged (the corpus's 1,213
findings compared whole, before and after, are identical); no
input set moved.

**Fixed.** `blocking.receive_in_callback` no longer reports the bounded
flush — `Process.cancel_timer(ref)` followed by `receive :tick -> :ok
after 0 -> :ok end`, the form the cancel_timer docs give — as a receive
in a callback. The blocking form of the flush was already exempt; the
bounded one now is too, on the same terms (the function cancels a timer
and the receive can take its message), at any bound, since the facts
carry whether a receive can block but not its timeout. Found by a talk's
worked example; the corpus change is one row, sequin's
`ReorderBuffer.maybe_cancel_flush_batch_timer/1`, which is that idiom.

### Frames that point where the path starts

**Changed.** A related frame that names the entry a site is reached
from now points at the call in that entry that starts the path, not at
the entry's head: `startup.blocks_on_peer`'s "init/1 reaches it from
here" (a cluster-wide lock in a helper) and
`startup.unbounded_effect_in_init`'s "reached from Mod.init/1" (a
receive or recv in a helper) anchor at the call in init/1 whose callee
continues the path, and `shutdown.teardown_touches_sibling` gains a
"terminate/2 reaches it from here" frame at the call in terminate/2
when a helper makes the sibling call. When several calls start a path,
the earliest in the function is kept: an output relation may now
declare `earliest: column`, and `Argus.Findings.Rows.dedupe/2` keeps
that group's earliest instruction instead of its least row (instruction
IDs do not sort by position as strings). A path that leaves the entry
through no call instruction — a closure it hands to a call — keeps
pointing at the entry, unless the site is in an anonymous function
written inside the entry, whose line the finding's anchor already is. New evidence relations `init_lock_path` and `terminate_path`;
`init_reaches_recv` gains a `call` column. The findings are unchanged;
only these frames move or appear. `unsafe_input.sink_export` ("reachable
from X, which is exported") still points at the export: it names
entries rather than a path, and the call would add the instruction-level
`call_site` to that analysis's input set, re-solving it on every body
edit.

### A call on the way out, audited

`shutdown.teardown_touches_sibling`'s terminate half ("terminate/2 calls
a sibling that may already be down"), after a precision audit.

**Fixed.** The caller must trap exits (`traps_exits`, the same file's
condition for `cleanup_defect`). A supervisor stops a child with
`exit(pid, :shutdown)`, and a child that does not trap is killed without
running terminate/2; its terminate/2 then runs only after a
`{:stop, ...}` or a crash, while the sibling is up. The cleanup such a
module loses is `cleanup_defect` "never_runs". All three kinds (`call`,
`call_restart`, `call_unordered`) check it. The `SiblingGuard` test
fixtures, which never trapped and were reported only by that accident,
now trap exits.

**Fixed.** The order is the branches', not the direct children's
(`starts_before`, `child_subtree`): a supervisor stops a whole later
child, a nested supervisor and everything under it, before an earlier
one. A caller nested in an earlier branch (`[WorkerSup, Directory]`,
Writer under WorkerSup) and a sibling nested in a later branch are now
reported, with `sup` the supervisor where the two branches meet. A
restart (`call_restart`) still needs the sibling to be that
supervisor's own child: one nested in an earlier branch is restarted by
its own supervisor, and the caller is left alone. The prose says both
"run under" the supervisor rather than being its children.

**Fixed.** A try guards the sibling call by name only with
`catch :exit, {:noproc, _}` (`catch_tuple_tag`, schema 74). A bare
`catch :exit, :noproc` is `GenServer.stop`'s reason and never matches
a call's `{:noproc, {GenServer, :call, _}}`: such a call is reported.

**Fixed.** A sibling call terminate/2 makes only for reasons other than
`:shutdown` — the reason a supervisor stopping the process passes — is
not reported: `terminate(:shutdown, s)` followed by
`terminate(reason, s)` makes the second clause's call only after a
`{:stop, ...}` or a crash, while the sibling is up (`skipped_on_shutdown`,
schema 75; the analysis now runs `Argus.Extractors.ClauseCall`). A
clause for `:normal` ahead of the call's does not spare it.

**Changed.** The finding says the call itself fails ("what it was for
never happens") and that terminate/2 then skips anything after it: a
call in tail position (Horde's shutdown signal) loses its own effect,
not later cleanup. The rule's comment lists its known limits: a
`shutdown: :brutal_kill` child is still reported (the spec's shutdown
value is not extracted), a restart escalating from a nested branch is
not followed, and a helper dispatching on the reason is taken to run.

**Fixed.** A path from terminate/2 through a closure or a function
reference is guarded by the call that runs the fun, not by any
exit-catching try in the function: a try around an unrelated
`GenServer.stop` no longer silences `Enum.each(peers, fn p -> ...
GenServer.call ... end)` after its `end`, and a sibling API handed as
`&Directory.unregister/1` is waited on at the `Enum.each` that runs it
(`fun_handed`, schema 73; `resolved_apply` for an apply).
`ForwardGuardedCallReach` gains a `handed(func, callee, call)` input;
only a fun no call is handed keeps the function-wide `sealed` reading.

**Fixed.** The path from terminate/2 stops at a fun handed to a spawn
or a task's start (`Task.start(fn -> Directory.unregister(...) end)`):
its `:noproc` ends that process, not terminate/2. `ForwardGuardedCallReach`
does not follow an edge `runs_elsewhere` sets aside, and gains an
`elsewhere(call)` input for a handing call that starts a process.

### A sibling the supervisor has already stopped

**Changed.** `shutdown.teardown_touches_sibling` ("terminate/2 calls a
sibling that may already be down") fires only for a sibling the
supervisor itself has stopped before it terminates the caller. Two of
its sequences do: its shutdown, which stops children in reverse start
order, so a sibling started *after* the caller is gone (kind `call`,
any strategy); and its rest_for_one or one_for_all restart, where a
sibling started *before* the caller crashing is why the caller is
terminated (kind `call_restart`; oban#21's Producer and Watchman,
Horde's SignalShutdown). A sibling started before the caller under
one_for_one is still up while the caller terminates, and is no longer
reported. When the child list or the strategy does not settle which
applies — the same module listed on both sides of the caller, or a
strategy chosen at runtime — the row is kept as `call_unordered` and
reported at `:info`, its label saying the order is unknown. Order
comes from `supervisor_child`'s positions; the prose and help now say
which sequence stops the sibling, and the reorder suggestion no longer
points at a start order the rule would flag.

### A lock on the local node alone

**Fixed.** `startup.blocks_on_peer` called every retrying `:global`
lock init/1 reaches "Cluster-wide lock during init", including one over
`[node()]`, where only this node's global server takes part: that lock
still waits forever on a local holder, but no other node, so the
cluster cannot stall it. The lock's node list now decides: a list
holding the connected nodes (`[node() | Node.list()]`, `Node.list()`)
or no list at all (`set_lock/1`, `trans/2`, which mean every known
node) stays "Cluster-wide lock during init" at `:error`; `[node()]` is
"Lock during init" at `:warning`, its label and help saying it waits on
this node's holders and pointing at `set_lock/3`'s retries as well as
handle_continue/2. A list the bytecode does not show — a parameter, a
call's result — stays cluster-wide, the stronger claim, and its prose
and label say the list could not be read and is assumed to hold the
cluster. `blocks_on_peer`'s `dep` holds the node list for a "global"
row (`cluster`, `local` or `unknown`; it was empty), and a global row
dedupes on (mod, dep, op), so a local and a cluster-wide lock init/1
both reach are two findings. `blocking.unbounded_wait` gains a `nodes`
column (empty for its other kinds) and reads it the same way: its
"global" row over `[node()]` is "Local :global lock without a retry
bound", still `:info`, and an unread list keeps the cluster-wide title
with the same caveat. The vocabulary's `cluster_lock` is
`retrying_lock`, with the node list as a fifth column. The talk's
worked example (`[node() | Node.list()]`) and nebulex's
Replicated.Bootstrap (a node list from `Cluster.get_nodes/1`, unread)
both stay cluster-wide.

### A lock during init, as OTP runs it

**Fixed.** `startup.blocks_on_peer`'s "global" row called any lock with a
positive retry count one that "retries until it gets its way", though
`:global.set_lock/3` with N retries gives up after N backoff sleeps
(1/4 s doubling to 8 s) and returns false; following the "Lock during
init" help (bound the retries) did not clear it. A lock init/1 holds is
now reported by what its retries say (`lock_until_granted` and
`bounded_lock` in `clientlib/vocabulary.dl`): `:infinity` stays "global";
a count the bytecode does not show (a parameter, an option — Nebulex's
`transaction/3` forwards `Keyword.get(opts, :retries, :infinity)`) is
the new kind "global_assumed", reported with the same title and
severity and saying it assumes `:infinity`, where it was dropped; a
positive count over other nodes is "global_bounded", "Bounded
cluster-wide lock during init" at `:warning` (each try still waits on
every node in the list); a positive count over `[node()]` is quiet, as
the help promises.

**Fixed.** The walk from a lock back to init/1 is `global_path`
(`clientlib/global_reach.dl`), read by startup and by blocking's
`during_init` alike, so a lock is one of the two analyses' finding. It
enters only the clauses a literal first argument matches
(`clause_call`): `sync(:boot, s)` in init/1 no longer reaches the lock
in `sync(:locked, s)` that only handle_continue/2 enters. It steps into
a task init/1 starts with `Task.async` (or `Task.Supervisor.async`) and
waits for with `Task.await`, `await_many`, `yield` or `yield_many`
(`awaits_task` in `clientlib/runs_elsewhere.dl`, function-level), where
the task's lock holds init. startup now runs
`Argus.Extractors.ClauseCall`, and stage 0's `call_site` keeps the
`Task` async, await and yield calls.

### Funs that leave the caller's stack

**Fixed.** `runs_elsewhere` (`clientlib/runs_elsewhere.dl`) says which
edges leave the caller's stack, for every same-process walk and for
process points-to. A fun the caller only registers or keeps is one
now: handed only to a callback registrar (`:telemetry.attach` and
`attach_many`, `:persistent_term.put`, the process dictionary, the
application env) or to no call at all (built into the state init/1
returns, a message, a child spec), and not called by the caller. A
`:telemetry` handler that takes a lock was "Cluster-wide lock during
init". A closure the caller hands to a call is no longer set aside
because an unrelated start of an unknown fun (`Supervisor.start_child`
of a spec, `Task.start_link(opts[:warmup])`) sits beside it: the "only
closure" rule counts only the closures built into a term, and a fun
handed to a helper that starts a process on it is set aside by that
call. Stage 0 stages `fun_handed_to(caller, fun, callee)`, the function
each call in `fun_handed` calls, for it to read. On the corpus, sequin's MutexedSupervisor no
longer reports "init/1 makes a synchronous supervisor call" from the
`on_acquired` callback its init builds into a child's options (its
MutexOwner runs it later); nothing else moved.

### Analysis names

**Removed.** The alias table for the analysis names retired in 0.17
(`supervision`, `error_handling`, `sync_call_in_init`, `unsafe_task`,
...), promised for two minor versions: `Argus.Analysis.aliases/0`,
`Argus.Analysis.alias/1` and the `alias_entry` type are gone, and
`Argus.Findings.run/2` answers a retired name with
`{:error, {:unknown_analysis, name}}` like any other unknown one. A
finding's `analysis` is always its concern now; `concern`, which said so
while the two could differ, stays and equals it. `Argus.Migrate` and
`mix argus.migrate encore`, which re-keyed encore manifests through the
table, are removed with it: a count pinned under a retired name has
no mechanical home without the table, and the manifests it existed for
are re-keyed. To upgrade from 0.16 or earlier, go through 0.19 first,
or rename by the 0.17 entry below.

### Module layout

**Changed.** `Argus.Analysis` and `Argus.Findings` are split into
cohesive modules; every function they exported still works, delegating
where the code moved. `Argus.Analysis.Catalog` discovers the built-in
analyses, looks one up and resolves its rules path.
`Argus.Analysis.Sets` holds the concerns, the named sets and how a
selection (`run/2`'s `:analyses`) resolves to modules.
`Argus.Analysis.Extraction` builds the facts directory (pipeline,
stage 0, priors); its `ensure_stage0/2` is public.
`Argus.Findings.Anchor` parses anchors (`Argus.Findings.at_site/2` and
the other `at_*` helpers delegate to it) and adds `from_row/1` and
`empty/0`. `Argus.Findings.Names` writes names as a reader does
(`call_name/1`, `elsewhere/2`, `rpc_api/1`, and `render/1`, which
`build/2` applies to every finding's prose). `Argus.Findings.Build`
turns a solve's rows into findings, `Argus.Findings.Rows` deduplicates
them (`Argus.Findings.dedupe_rows/2` delegates to its `dedupe/2`) and
`Argus.Findings.Evidence` joins evidence rows to their findings. The
`Argus.Analysis.evidence` type names the `:limit` key the analyses
already use. `Argus.Findings.Runner` runs a selection (`run/2` and
`extraction_errors/1` delegate to it); `Argus.Findings` keeps the
struct, the types, the constructors analysis modules build with, and
its moduledoc says which submodule holds what.

### Fact schema and extraction

**Changed.** Schema 85, no shape change. `mnesia_op` has the plain
`read`, `write`, `delete`, `delete_object`, `match_object`, `select`
and `index_read` of a closure handed to a dirty activity
(`:mnesia.async_dirty/1`, `sync_dirty/1`, `ets/1`, or `activity/2` with
one of those contexts), spelled as their dirty twins (`dirty_read`,
`dirty_write`, ...): they take no lock. `Mnesia.site?/1` names the
plain operations.

**Changed.** Schema 84, no shape change. `mnesia_op` has rows of kind
`write` for a transaction's `:mnesia.write/1,3`, `delete/1,3` and
`delete_object/1,3`, and for `dirty_update_counter/2,3`: not dirty
acts, but writes of the table a dirty read-modify-write takes no lock
against. `Argus.Extractors.Mnesia.site?/1` names them too.

**Changed.** Schema 83, no shape change. `Identity.tuple_element_identity/5`
follows a record updated in place — `put_elem/3` (`setelement/3`),
`R#r{f = V}` and an Elixir record's update (`update_record`), and a
local helper whose every exit returns a parameter's tuple with the
element unchanged (`Identity.returned_elements/2`, passed as the third
element of `origins`) — to the element it keeps, and the head of what
`:mnesia.dirty_read` or `:ets.lookup` returned to the table and key the
read was asked for. `mnesia_op`'s table and key and `ets_key`'s key
for an insert name them where they were `dynamic`.

**Changed.** Schema 82, no shape change. `ets_key` has a row for
`:ets.match/2` and `:ets.match_object/2`: the pattern's first element,
the key it matches, unless that is `:_` or a pattern variable, which
match every key.

**Changed.** Schema 81, no shape change. `ets_option` has a `keypos`
row, the key's element in an object from 1, for an `:ets.new/2` given
`keypos: N`. `races` reads it to key an inserted record by its key
rather than by its tag (below).

**Added.** Schema 80. `field_compared(func, kind, source, pos,
other_kind, other_source)` (`Argus.Extractors.Dependence`): what a
deciding test compares element `pos` of the source's tuple with, by data
alone — `[{^k, cur}] when cur >= serial` compares element 1 of the
lookup's row with parameter 1. A comparison with a value the facts do
not name (a clock read) has no row. `races` reads it (below).

**Added.** Schema 79. Two `Argus.Extractors.Dependence` relations.
`field_decides(func, kind, source, pos)`: a test in the function
decides on element `pos` of a tuple the source holds (a
`get_tuple_element`, or `element/2` with a literal index), or on a value
made from one — `[{^k, cur}] when cur >= serial` tests element 0 (the
key) and element 1 of the lookup's row; a test of whether a lookup found
a row tests none. An `:ets.lookup_element` answer is element 1 of its
row. `effect_decided(func, kind, source)`: a send, or a runtime call
that changes something outside the function (a process, a port, a
file, the network, a node, by `Argus.Purity.Effects`; not logging,
clocks, randomness or the process dictionary), runs only because of a
test on the source; the runtime's calls are otherwise not in the
dependence relations. `races` reads both (below).

**Changed.** Schema 78, no shape change. A value `self()` made is
`{"self", ""}` in `Argus.Extractor.Identity`'s vocabulary, the calling
process, where it was the `local` of whichever `self()` call made it:
two calls of `self()` in one function are one key. It names something
only within one function, and crosses no call.

**Changed.** Schema 77, no shape change. A key a tuple is built of
values that each have an identity is named by them, in order:
`{"tuple", "{param 0, param 1}"}` (`Argus.Extractor.Identity`), where it
was `{"local", instr_id}`, the one instruction that built it. So a
composite key spelled out at a lookup and again at the write, `{mod,
fun}` twice, is one key, as it was when bound to a variable once; each
spelling was its own `local`. `ets_key`, `ets_value`, `ets_call_arg`,
`mnesia_op` and `name_lookup`/`creating_op` read it. Like a `local`, it
names something only within one function.

**Added.** Schema 75. `skipped_on_shutdown(id, func)`: the call at `id`,
in a `terminate/2` or `terminate/3` that chooses its clause by the
reason, does not run when the reason is `:shutdown`
(`Argus.Extractors.ClauseCall`). New `Argus.Extractor.Dispatch.
reached_with/3`: the instructions reached when an argument is a given
atom, each test on it taking only the edge that atom takes.

**Added.** Schema 74. `catch_tuple_tag(id, func, class, tag)`: the
`catch_tag` atoms a clause compares as a tuple's first element — an
`is_tagged_tuple`, or a comparison on a register holding element 0 —
rather than the reason itself. `catch :exit, {:noproc, _}` has a row;
`catch :exit, :noproc` has only its `catch_tag`. A `GenServer.call` to
a dead process exits with `{:noproc, {GenServer, :call, _}}`, a
`GenServer.stop` with bare `:noproc`, so the two catch different exits.
`CatchClauses.analyse/2`'s summary gains `tuple_tags`.

**Added.** Schema 73. `fun_handed(id, caller, callee)`: the call at
`id` is handed, as a fun value, a function that runs `callee` — a
closure the caller builds, or a literal external fun — in an argument
position the call's result does not carry (`Argus.Pipeline.Emit.
FunRefs.handed_rows/2`). The call graph's edge into a closure or a fun
reference has no call instruction; this names the call it runs inside,
so a rule asking whether a `try` covers the edge asks it of that call.
**Changed.** Schema 71. `schema_field(mod, field)` gains a third
column, `type`: the field's Ecto type from `__schema__(:type, field)`,
which `Argus.Extractors.EctoSchema` reads from `__schema__/2`'s
dispatch the way it reads `__schema__/1`'s. It is spelled for a reader
— `string`, a custom type by its module (`Sequin.Encrypted.Field`), an
embed as `embeds_one Sequin.Sinks.Gcp.Credentials`, a collection as
`array of string` — and `dynamic` when the dispatch or the type has
another shape. No rule reads it; it is there for `Sensitivity` to show the
model. A rule reading `schema_field` adds a column; `exposure`'s do.
`prior_sensitive`'s `detail` gains `secret_reference` and `public_key`,
both details of `none` (Sensitivity v2, under exposure).

**Changed.** Schema 70. `global_op` gains `nodes`, the shape of the
call's node list: `"local"` for a list of only the local node
(`[node()]`, `[Node.self()]`, `Node.list(:this)`), `"cluster"` for one
holding the connected nodes (`:erlang.nodes/0,1` or `Node.list/0,1`,
alone, consed onto or appended with `++`) and for a call that omits the
list (`set_lock/1`, `del_lock/1`, `trans/2`), `"unknown"` for anything
else, and empty for `whereis_name` and `send`, which take none. New
`Argus.Extractor.Resolve.node_list/3` reads it: a `Resolve.trace/5`
walk over the list's cells, where the `node/0` BIF (or `Node.self/0`)
is the local node, a call to `nodes/0,1` is the connected nodes, and
paths that disagree are unknown. An unknown list records a
`global_op_nodes` imprecision. `:global.set_lock/1`, not extracted
before, is now.

**Fixed.** `Argus.Symbols.ETS.intern/2` wrote an id into `forward`
before writing its `reverse` row, so another process could find the id
and have `resolve/2` raise `ArgumentError` on it in the window between
(thousands of times in a 20,000-key run with four readers). The reverse
row goes in first now, and a binary that loses the `insert_new` race
deletes the row it wrote. `races.ets_publish_order` found it.

**Added.** Schema 69. `try_covers(id, func, call, kind)` — the try
(`kind` "try") or Erlang `catch Expr` ("catch") at `id` covers the call
at `call`: the call is on a path from the try that has not passed its
`try_end` (`catch_end` for a catch), walked on the function's graph
with `Argus.Cfg.Walk`, so a call after the try's `end` is not covered,
a call inside nested tries is covered by each, and one in a nested
try's handler by the outer try alone. What the handler takes stays in
`catch_total` and `catch_tag` at the same `id`; `clientlib/exceptions.dl`
joins the two as `covered_by_catch(call, func, try_site, class)` (a
`catch` takes every class). From `Argus.Extractors.ErrorHandling`; read
by `shutdown` (below).

**Changed.** Schema 68. `prior_sensitive` gains `detail_permille`
before `permille`, and `permille` is now the probability of `kind` — the
sum over its details — where it was the chosen detail's. `kind` is the
class with the most mass (the chosen detail's on a tie) and `detail` the
likeliest detail within it. A rule reading the relation positionally
adds a column. The cached answers already hold the whole distribution,
so no request changed and `Sensitivity`'s prompt version stays 1:
recorded answers replay into the new rows.

**Added.** Schema 67. `inspect_derived(mod)` — the struct's `Inspect`
is derived — and `inspect_shows(mod, field)` — a field it prints, after
`except:` and `only:`. `Argus.Extractors.DerivedInspect` reads them from
the `Inspect.<Struct>` implementation module: its `inspect/2` calls
`Struct.__info__(:struct)` and hands the kept fields to `Inspect.Any` or
`Inspect.Map`, and the fields kept are the atoms the comprehension's
filter compares the field against (Elixir 1.18 and 1.19 compile both
options to that one guard). A hand-written `defimpl Inspect` has no row.
`redacted_field`'s doc says what it is now: a field declared
`redact: true`, which Ecto honours only when the schema derives no
`Inspect` itself. Read by `exposure` (below).

**Added.** Schema 66. `callback_drops(func, callback)` — the callback's
catch-all does nothing with the message but log or ignore it (a forward
walk from its body: the message reaches only Logger, `:logger`, IO or
`inspect/2`); `callback_open(func, callback, shape)` — a clause other
than a catch-all takes the message by its shape alone (`any`: `msg when
is_atom(msg)`; `tuple`: `{ref, result}`); `statem_info_tag(mod, func,
tag)` and `statem_info_open(mod, func, shape)`, the same two questions
of a gen_statem's content. `Argus.Extractors.CallbackTag.MessageClauses`
reads them; `Argus.Extractor.Dispatch.clause_start?/3` is public.

**Added.** Schema 65. `call_arg_element(caller, callee, arg_pos,
param_pos, index)` — the argument is element `index` of the caller's
parameter — and `call_arg_tuple(caller, callee, arg_pos, index, source,
value)` — element 0 or 1 of a tuple the caller builds as the argument,
as `key_identity/4` names it. `Identity.key_identity/4` names an
element of a parameter `{"element N", "P"}` (through `get_tuple_element`
or the `element/2` BIF), and `tuple_element_identity/5` names an
element of a tuple that is still a parameter the same way; both said
`{"dynamic", ""}`. `mnesia_op` rows now include the dirty reads by
pattern, match spec and index (races, below).

**Changed.** Schema 64, no shape change. `ets_op` has two rows for
`:ets.take/2`, a `read` and a `write`: it reads the row and deletes it,
and was `unknown`. `process_start` has a row for each
`:timer.apply_after/4`, `apply_interval/4` and `apply_repeatedly/4`
(Process points-to, below). Corpus: `ets.ets_read_outside_owner` gains
bb's `BB.Command.ResultCache.fetch_and_delete/1`, a take of the table its
GenServer creates in `init/1` with no heir, from the caller's process —
real, the class of the lookups it already reports; nothing else moves.

**Changed.** Schema 63. `ets_write_order` is replaced by
`ets_effect_order(func, first, then)`: two effects of one function in
order, each an `insert`/`insert_new` or a call into project code (so an
insert a callee makes is ordered where the call is), at least one an
insert or a call to a function of the module that inserts. Order is
reachability without a loop's back edge (an edge into a block that
dominates its source), where it was reachability: a pair in a loop body
was ordered both ways. **Added:** `ets_call_arg(id, callee, pos, source,
value)`, what identifies each argument of those calls, in `ets_key`'s
vocabulary, so a callee's key reads in its caller's terms;
`table_alloc(id, func, table)` and `table_use(id, func, src_kind, src)`,
PidFlow's (below). `ets_table_path` keeps every arm of a join, so
`cfg.table || @default` has a row for the field and one for the literal
(`Resolve.access_paths/4`, where it kept one only when the arms agreed), and has rows
for `:ets.new/2`'s name operand too.

**Added.** Schema 62. Three ETS relations, all `Argus.Extractors.ETS`'s
and read by `races`. `ets_table_path(id, source, root, path)` says where
an operation's table operand was read from: a literal name, a parameter
or a local value (the instruction that made it), and the map keys read
on the way down from it (`Resolve.access_paths/4`, `":tables.:forward"`).
`ets_op` knows an unnamed table by the name `:ets.new/2` gave it, so two
tables created with one name and handed around in one map
(`%{forward: f, reverse: r}`) were one table to every rule; their paths
tell them apart, in one function and, from a parameter, across a
module's functions. A join whose arms disagree has no row today; the
relation is many-valued so a table named `cfg.table || @default` can
have one per arm. `ets_value(id, pos, source, value)` identifies the
elements past the key of the object an `insert`/`insert_new` writes, in
`ets_key`'s vocabulary. `ets_write_order(func, first, then)` orders two
ETS writes in one function by its control-flow graph, computed where the
graph is, as `call_followed_by_branch` is.

**Changed.** The pipeline decodes only the relations the in-process passes
read (`Argus.Pipeline.typed_relations/0`) into `module_data.typed`, and
`Helpers.typed/1` builds the same: decoding every relation was 23% of
extraction on sequin (531 beams, 12.8 s of 56 s serial), the subset is
8.5 s. An extractor that reads another relation from `typed` adds it to
the list; `Argus.Pipeline.TypedRelationsTest` fails until it does.

**Changed.** Extraction solves each function's reaching definitions once.
The pipeline's `module_data.reaching` is read off the per-function
solutions `Argus.Instr.Reaching` keeps (**Added**: `Reaching.uses/2`, the
same set `Argus.Dataflow.reaching_uses/2` computes from the facts), which
the emitter's and the extractors' register walks share; it was solved
again from the decoded facts, and once more for each of the two
instruction lists. The solver itself visits blocks in reverse postorder
and keeps what reaches a point per register, which took a function of
many wide joins from quadratic to linear (Ecto.UUID 20.7 s to 0.4 s).

**Changed.** A run reads each installed module's specs once: the pipeline
hands its extractors an ETS memo for the run (`module_data.installed_specs`,
**Added**: `Argus.Specs.installed/2`, `of_beam/2`), which also resolves the
remote types a spec names. `installed/1` stamps its answer with the
module's file on every call, which for a module that is not loaded walks
the code path through the code server that every worker waits on.

**Changed.** `Argus.Cfg` finds dominators and post-dominators with
Lengauer–Tarjan and loop headers by numbering the dominator tree once.
Cooper–Harvey–Kennedy walked the tree from every predecessor to where
the paths meet, and a function whose clauses all fail to one landing
pad is a tree as deep as the function with that pad under every clause:
idna_mapping's graphs took 1.7 s, Cldr.Validity.Subdivision's 1.1 s;
each is under 0.1 s now. The graphs are the same.

**Changed.** `Argus.Cfg.Function.block_at/2` is a binary search over the
blocks, which are numbered in instruction order, rather than a scan of
them; `Argus.Cfg.Walk.explore/4` asks it at each block's end instead of
indexing every instruction of the function on each call.

**Added.** `Argus.Extractor.ValueFlow`: a value per register write,
solved to a fixpoint over one function's reaching definitions by a
worklist that evaluates an instruction again only when a write it reads
changes: PidFlow's solver, moved out. ParamFlow and Dependence solve on
it, one function at a time, where they passed over every instruction
(ParamFlow's of the whole module) until nothing changed.

**Changed.** `Argus.Facts.decode/1` parses each instruction ID once per
call: a module's IDs recur across its relations, and every row naming
one shares the struct. Decoding a module takes 35 to 50% less time
(Timex.Gettext 509 ms to 320 ms). The rows are the same.

**Changed.** A module's debug-info chunk is read once for the
extractors that read it (`Generated`, `Specs`), where each inflated and
decoded it on its own: `module_data.debug_info` (**Added**:
`Argus.Extractor.Helpers.debug_info/1`, `Argus.Specs.of_debug_info/3`).
A run with neither reads it not at all.

**Changed.** `Argus.Pipeline.run/3` encodes each module's rows as the
lines of their files in the worker that extracted them, and the caller
only writes them (**Added**: `Argus.Pipeline.Writer.encode/2`,
`append_encoded/2`). Encoding every row in the caller was serial, and on
the Phoenix stack took longer than extracting it at eight workers: the
run takes 5.7 s where it took 9.3 s. The files are the same.

**Changed.** `Argus.Pipeline.extract/2` with `format: :typed` decodes
each module's rows in the worker that extracted them, where it decoded
the merged facts in the caller afterwards: the Phoenix stack's typed
facts take 3.8 s where they took 14 s. The rows are the same.

**Changed.** `Argus.Extractor.Helpers` is split by concern, each
concern its own module (**Added**): `Argus.Extractor.Facts` (the rows
an extractor emits and the imprecision it records),
`Argus.Extractor.Resolve` (what a register holds, read back through the
writes that reach it, `trace/5` included), `Argus.Extractor.Identity`
(what names that value), `Argus.Extractor.Terms` (spelling and walking a
literal) and `Argus.Extractor.Shapes` (the tuples a function returns).
Helpers keeps what every extractor reads a module through: the call
sites and scans, the call matchers, the attributes, and the module
data's accessors. The moved functions still answer in Helpers, and are
deprecated there.

**Changed.** Each relation of the fact schema is declared once, in the
module of its concern (`Argus.Schema.Bytecode`, `Supervision`, `Otp`,
`ErrorHandling`, `Processes`, `Priors` and twelve more), with its
`in_process` flag beside it; `Argus.Schema` reads them in order. It was
declared three times in one 2,800-line file: as an attribute, in its
layer's list and, for the in-process ones, in `@in_process_only`. The
API, `all/0`'s order, the generated `.dl` files and the schema version
are unchanged; `in_process_only/0` lists its relations in schema order.

**Added.** Schema 61. `clause_call(id, func, tag)`, from the new
`Argus.Extractors.ClauseCall`: for a function that chooses its clause by
its first argument — a `handle_call/3` by its request, a guarded
dispatcher like `route(:local, n)` / `route(:remote, n)` — the calls each
clause makes, with the tag (the atom, or the first element of the tuple)
every path to the call established; one row per tag, none for a call
some path reaches with no tag established. From
`Argus.Extractor.Dispatch.argument_tags/2`, a walk over every path through
the function, so a `case` on the argument in the body refines as a clause
head does. Read by `blocking`'s call chains.

**Removed.** Schema 60. `move`, `allocate`, `deallocate`, `try_end` and
`module_attribute`: no Datalog rule and no in-process pass read them (the
walks read the instructions; the extractors that need an attribute read
the chunk). `literal_value` still records what a move writes. A consumer
reading one of them from the facts directory must read the disassembly.

**Fixed.** `call_arg` records a literal binary or integer argument, spelled
as `Helpers.key_identity/4` spells it (`"\"users\""`, `"42"`), where it
said `"dynamic"`: a key handed to a helper now joins the key identities
the check-then-act rules lift through `call_arg`.

**Fixed.** A `start_child` whose supervisor comes from another module's
function (`Other.via_for(conf)`) is `"dynamic"`, not the via name of a
local function that happens to share the name and arity.

**Fixed.** A module that `use`s the GenStateMachine library is a gen_statem to
the extractor: its `@behaviour GenStateMachine` was not `:gen_statem`, so
it had no `statem_*` facts at all (swarm's tracker among them), though
the Datalog side already read the two names as one.

**Changed.** Schema 59. `resolved_apply` is a layer-1 relation the emitter
writes (`Argus.Pipeline.Emit.Applies`), and it has rows. It resolved only
`erlang:apply/3` with a literal module and function, which the compiler
already turns into a direct call whenever it can see the argument list —
so it was never populated. It now also resolves the `apply` instruction
(module and function from `x(N)` and `x(N+1)` through the writes that
reach them) and `erlang:apply/2` of a closure or a literal external fun.
The call graph follows a resolved apply (`call_edge`), and the effect
model classifies its target: `apply(&File.read/1, args)` is a file read,
not an opaque call. The `Purity` extractor no longer lists the relation.

**Added.** Schema 58. `fun_ref(caller, callee)`: a function hands `callee`, as a
fun value, to a call that may invoke it and does not call it itself — a
literal external fun (`&URI.parse/1`) or `erlang:make_fun/3` of literals
in an argument position whose data the call's result does not carry
(`Keyword.get(opts, :on_fail, &M.f/2)` hands its default back to be
stored; a callback stored in state is not run by the function storing
it). The call graph follows it (`call_edge`), so `Enum.map(list,
&URI.parse/1)` reaches `URI.parse/1`; it stopped at `Enum.map` before.
The same-process walks (`reach.dl`'s SameProcess variants, `blocking`'s
same-process edge, `processes.dl`'s `same_process_call`) set it aside as
they do a closure: a fun may run in
another process. Local captures were already `closure_def` rows.
`blocking` and `mailbox` read `fun_ref` (pins). `Helpers.fun_origin/3`
also reads `erlang:make_fun/3` of literals.

**Changed.** Schema 57. `spawn_call` records every call that starts a process
running a function its arguments name, and says how far they resolve.
New: `erlang:spawn_opt/2..5`, `proc_lib:spawn/1..4`, `spawn_link/1..4`,
`spawn_opt/2..5`, `start/3..5`, `start_link/3..5` and `start_monitor/3..5`,
and `Process.spawn/2,4` (all were missing, so `failure`'s bare-spawn rule
and `effects` did not see them). Four columns: `api`, the spawning
function (`:proc_lib.start_link/3`); `source` — `closure`, `fun` (a
literal external fun: `spawn(&Mod.f/0)` was "dynamic" though the fun was
in the literal), `param` (the fun is the caller's parameter, in the new
`param` column, for rules to follow to the callers' closures), `mfa` or
`dynamic`; and `args`, the register of the argument list. `spawn(M, :f,
args)` with an argument list of unknown length keeps `M` and `f` (arity
-1), and a literal `f` beside an unknown `M` is kept. `variant` reads a
literal options list (`:link`, `:monitor`, `{:monitor, _}`) and is
`spawn_opt` when the options are not literal. `Helpers.fun_origin/3` says
where a fun comes from; `Helpers.fun_target/3` also reads a literal
external fun.

**Fixed.** `catch_total`/`catch_tag` follow the reason through the
handler as `Argus.Instr` reads it: a call destroys every `x` register
(the walk forgot only the call's arguments, so a copy of the reason in a
higher register still counted as the reason), an instruction outside the
walk's table that overwrites the reason's register ends the alias, and a
`swap` or `trim` carries it.

**Fixed.** `statem_timeout` finds an action built on one arm of a
branch: the walk from the action tuple to the callback's return follows
the jump to the shared return block and steps every other instruction
with `Argus.Instr.carry/2`, where its own table stopped at the first
label and kept a register an unknown instruction overwrote.

**Fixed.** `handle_continue_clause` finds every tag a
`handle_continue/2` dispatches on: a comparison counts where the
parameter itself reaches `x0`, not until the first instruction a private
seven-shape list said writes `x0`. A clause whose tag test followed
another clause's body — `handle_continue(:load, s) when is_map(s)` after
a tuple clause — was recorded as `"dynamic"`.

**Fixed.** `Argus.Cfg` reads fall-through from the `next` facts, which
are `Argus.Instr.falls_through?/1`, instead of its own op lists: the
`raise` BIF (every Elixir re-raise) and `badrecord` end their block
rather than falling into the code after them, `raw_raise` falls through
as erts runs it (an invalid class returns `badarg`), and `apply_last` is
a tail call. `Argus.Cfg.build/1` raises when handed instructions without
`next`. `Argus.Instr.tail_call_op?/1` answers for an op name.

**Fixed.** The extractors spell a literal value the way `literal_value` does,
through the new `Argus.Extractor.Helpers.spell/1`: key identities
(`key_identity/4`, `tuple_element_identity/5`, map fields), timer
messages and keys, via-registry keys and route `plug_opts` were
`inspect/1`ed, which ran a struct's own `Inspect` implementation when its
module was loaded (so scry, with the analyzed code loaded, could spell a
key differently from a batch run) and cut long values short (so two ETS
keys differing past 4096 bytes were one key). Atoms spell as before.

**Fixed.** No literal crashes an extractor. A beam's literals can be improper lists
(`[a | :b]`; Elixir's own `Logger.Translator` holds improper iolists;
Erlang's `-my_attr([a|b]).` stores one as the attribute), and `Enum`,
`length/1`, `++`, `Keyword` and `in` all raise on them: the TLS extractor,
which reads every instruction, raised on `Logger.Translator`, as did the
reply, supervision, gen_statem, monitor, ETS, router, endpoint, Ecto
schema and error-handling extractors, `Argus.Pipeline.Emit`'s attribute
rows and `Argus.Purity.declared/1`, each on some odd literal; a
supervisor flag, restart or type that is not an atom raised in
`to_string/1`. The fixes share `Argus.Extractor.Helpers`:
`proper_list?/1`, `list_elements/1`, `attribute_values/2`, and
`mentions?/2`, the one improper-safe walk over an instruction's
operands — which does not enter a `{:literal, _}` operand, so a literal
`{:x, 1}` no longer counts as a read of the register (the reply
extractor took one for a read of `from`), nor a literal `{:f, 3}` as a
branch target (`Argus.Extractor.Dispatch.branch_targets/1`); and
`value_contains?/2` for searching a literal's value. `resolve_register/3`
answers `:dynamic` for an improper list, and for `length/1` or `++` of
one. `Argus.Pipeline.Normalize` no longer rewrites inside a literal (a
literal `{:tr, a, b}` was stripped to `a`, as though a typed register).
`test/extractors/odd_literals_test.exs` feeds generated odd literals —
improper and nested lists, maps, binaries, terms past inspect's bounds —
through every extractor and the full pipeline.

**Added.** Schema 55. A failure while extracting one module no longer takes the
caller down, and is never dropped silently. The pipeline's workers are
linked to the caller, so an extractor that raised exited scry's compiler
(or the test process) before anything could be reported, and a module
that outlived the 120 s per-module timeout aborted the whole run
(ex_cldr_numbers' `rbnf_lexer.beam`). Now every step is caught in its
worker: an extractor, or a derived-facts stage (`decode`, `cfg`,
`reaching`, `conditional_call`), that fails costs only its own rows for
that module, and a module whose disassembly or bytecode facts raise, or
that times out (killed on its own, `on_timeout: :kill_task`), loses its
facts alone. Each failure is an `extraction_error(mod, step, reason)`
row — in `Argus.Pipeline.extract/2`'s facts, in the directory
`Argus.Pipeline.run/3` writes, and as `extraction_errors` on
`%Argus.Findings{}` (`Argus.Findings.extraction_errors/1` reads them from
a facts directory). A consumer reports them beside the findings: the
analyses still ran, over what was extracted. An input that cannot be
read at all is still `{:error, reason}`.

**Fixed.** `resolved_apply` named the wrong arity for `apply(M, f, [x | rest])`:
the argument list, as `resolve_register/3` rebuilds it, reads an unknown
tail as one more element, so the call resolved to `M.f/2` whatever
`rest` held, and an improper literal list raised. The arity now comes
from `Argus.Extractor.Helpers.list_length/3`, the cons-cell walk
`spawn_call` already uses.

**Fixed.** Literals that differ past `inspect/2`'s bounds (50 elements, 4096 bytes
of a string) no longer spell the same: a spelling inspect cuts short
ends in ` #` and a digest of the whole term, so `literal_value`,
`module_attribute` and operand columns tell such literals apart. Spelling
every literal in full was measured and rejected (it doubles the bytes of
literal spellings over ecto, absinthe and hexpm, nearly all of it
embedded asset binaries); the digest adds 0.4% and changes 995 of 91,640
spellings there, every other spelling is as before.

**Fixed.** Fact files are escaped. Souffle reads a field as the bytes between two
tabs and a row as the bytes up to a newline, with no escapes of its own,
so a name holding either (`def unquote(:"a\tb")()`) wrote a row with a
column too many and Souffle refused the program's whole fact directory.
`Argus.Tsv` is the format now: a backslash, tab, newline or carriage
return in a field is written `\\`, `\t`, `\n`, `\r`, and every
reader in argus (`Argus.Souffle`'s outputs, `Argus.Lines.from_facts_dir/1`,
`Argus.Priors.read_facts/2`) undoes it, so values round-trip exactly
through Souffle. A consumer that writes or reads `.facts` itself uses
`Argus.Tsv.encode/1` and `decode/1`. The file bytes change only for a
field that holds one of the four characters.

**Fixed.** The same beams extract to the same facts in any VM. A VM
iterates a small map whose keys hold atoms in atom-table order, which
depends on the atoms it happened to create first, so `literal_value` and
`move` spelled a literal map (a struct's `__info__/1` field list,
`Inspect.Opts`' defaults) with its keys in a different order in two runs,
and `def_use` listed its rows in a different order: every cache keyed on
the facts missed. `Helpers.spell/1` sorts a map's keys, and `def_use`
rows are sorted.

**Fixed.** `Helpers.resolve_register/3` read a field of a call's field
(`{:ok, {pid, _ref}} = GenServer.start_monitor(...)`) as an element of
the `{:call_field, mfa, n}` marker naming the outer field, so `pid`
resolved to the atom `:call_field`; it is unknown now.

**Added.** Schema 50. Typespecs inform the analyses. `Argus.Specs` reduces what a
function's `@spec` claims it returns to a few shapes — `can_fail` (the
return type names `{:error, _}`, `:error`, `nil`, `false`, `:undefined` or
`{:EXIT, _}`), `total` (known, and names none of them), `no_return`,
`returns_pid` — resolving local and remote types four levels deep.
`Argus.Extractors.Specs` emits them as `spec_return(func, shape, origin)`:
`analyzed` rows from each analyzed beam's own specs, `installed` rows for
the remote functions it calls, read off the code path and memoized per
module. `clientlib/specs.dl`'s `callee_returns` prefers the analyzed
program's specs for a function it defines. A function with no row —
no spec, a `term()` return, a module shipped without specs like
`:mnesia` — is unknown, never "cannot fail", and a spec is an
unverified claim: rules use it only to stay quiet or to confirm. The
installed rows depend on the applications on the code path;
`Argus.Specs.environment_digest/1` names them — by version, and each
application outside the OTP and Elixir installations also by the
contents of its beams, since a path dependency or an umbrella sibling
changes its specs without moving its version (`exclude:` leaves out the
applications a caller tracks itself) — and the corpus facts cache folds
it in, excluding argus's own beams (a downstream cache keyed on
extraction output should too). The pipeline's module data carries the disassembled `:beam`.

**Added.** `failure.inconsistent_handling`'s `result_checked` belief skips a callee
whose spec names no failure value: `:ets.new/2` returns a table or
raises and `:ets.delete/2` returns `true`, so a site discarding either
misses nothing.

**Changed.** Schema 45. `spawn_call` names what the new process runs instead of
recording "dynamic": `spawn(M, F, args)` and the node-qualified form run
M.F/length(args) when the module, function and the argument list's length
are literal, and `spawn(fun)` runs the function the closure was lifted
to. `arity` is now that function's arity (it held the spawn BIF's own,
contrary to the schema doc), and -1 when unknown. The length is read from
the cons cells that build the list, so `[x | rest]` stays unknown. Both
readers (`failure`'s bare spawn, `effects`) ignore these columns;
scry/planchette memos keyed on the schema version invalidate.

**Added.** Schema 44. A new extractor, `Argus.Extractors.Dependence`,
emits what each call, shared-state operation and return value depends on
— the function's parameters, the results of the calls it makes, the
results of shared-state operations — through data and through control,
so a value merged after a `case` depends on what the `case` tested:
`site_depends(site, func, kind, source)`, and the per-function
`call_decided(caller, callee, kind, source)`, `call_arg_depends(caller,
callee, arg_pos, kind, source)` and `returns_depends(func, kind,
source)`. Calls into erts, kernel, stdlib, elixir and logger are not
named as callees or sources.

**Changed.** Schema 43. `try_call` gains `call`, the guarded call's own instruction:
the `try` instruction carries the line of whatever preceded it (the
previous clause's body, or the function head), so "catches :noproc but
not :shutdown" and the erpc rescue finding anchored one clause off. Both
now anchor at the call. `statem_call_unreplied` anchors at the clause's
last pattern test rather than the return — the compiler shares one
`:keep_state_and_data` block between clauses — and gains `tag`, the
literal that test compares against, which the finding passes as
`at_source` so a consumer with the source lands on the clause head
(pattern tests carry the previous clause's line in the Line chunk).

**Changed.** The pipeline computes reaching definitions once per module
(`module_data.reaching`, `Helpers.reaching/1`) and shares them: `ParamFlow`
read them from its own `Dataflow.reaching_uses/2` call, and `def_use` from
another. `def_use` is derived from the shared set and is unchanged.

**Changed.** `Helpers.tuple_element_identity/4` identifies element `n` of a tuple built
on the way to a call (through moves) or folded into one literal: an ETS
object's key, and the reader the ETS extractor used inline before.

**Changed.** The register walks behind `resolve_register/3`, `arg_position/3` and
`map_field_of/3` no longer stop at a branch boundary. They walk the
instruction stream backwards and treated a `return` as the end of the
path, so a value read in the second arm of a `case`, or in the second
clause of a function, resolved to nothing: the first arm's `return` was
in the way. A label reached going backwards now resumes from the branch
that targets it when that is the only way in, and at a real join —
fall-through into the label, or predecessors in separate blocks — walks
every way in and keeps only an answer they all give. The compiler's
fast-and-slow-path diamond for `map.key` agrees at its join once the
slow path's `no_parens_remote` call is read as the field read it is.
Per query the joins are budgeted and the labels memoised, and the
branch-target counts are cached per function. Every extractor that
resolves an argument sees more: the ETS key written in a `case`'s last
arm, the name a later clause looks up.

**Changed.** A named `Agent.start_link/2,4` or `Agent.start/2,4` is a registration
like a named GenServer start: `process_register`, a `creating_op` for the
lookup-then-start race (tesla#768's shape spelled with an Agent), and
`named_process` owned by the module that starts it, since an Agent has
no module of its own.

**Fixed.** A literal operand was spelled with `inspect/1`, which runs a struct's
own `Inspect` implementation when its module is loaded — so the same
beam yielded different `literal_value` rows in a VM that had the
analyzed code loaded (scry's compiler) than in one that had not, and an
implementation that raises on the struct's defaults (sequin's
`CircularBuffer`) rendered a multi-line `#Inspect.Error<...>` that broke
the fact file. Literals are now inspected with `structs: false`, the
plain `%Mod{...}` form whatever implementation is loaded — a row change
for memoising consumers only where a struct had its own.

**Fixed.** `Argus.Instr` is the one reading of the instruction set: what each OTP 28
instruction reads (`uses/1`), writes (`defs/1`), where control may go
(`targets/1`) and whether it falls through (`falls_through?/1`), for
raw and normalized instructions alike, with `known?/1` false for an
opcode it cannot read. The emitter's `def`, `use` and `next` rows come
from it, which fixes rows that were missing or wrong: `try_case` writes
the exception class, reason and stacktrace into `x0`–`x2`, `catch_end`
writes `x0` and `build_stacktrace` rewrites it (a handler's read of the
reason had resolved to the function's parameter 1); `trim` renumbers the
stack frame, writing `y0..y(R-1)` from the slots above the trimmed ones
(a read after a trim had resolved to the old slot's value); the
`bs_get_utf8`/`16`/`32` tests write their last operand instead of
reading it; `recv_marker_reserve` writes its marker; map keys held in
registers, the operand of `badmatch`/`case_end`/`try_case_end`/
`badrecord`, `raw_raise`'s `x0`–`x2`, `bs_init_writable`'s `x0` and
`wait_timeout`'s timeout register are read; `catch_end` reads the
protected expression's value from `x0` as well as writing it; `raw_raise`
(inline `erlang:raise/3`) writes `badarg` into `x0` and falls through, as
the emulator does for an invalid class; and literal operands are no
longer recorded as reads. No `next` row follows an instruction control
cannot pass — a `select_val`, `func_info`, a raise, `wait`,
`loop_rec_end` — which had joined a raising path's writes into the next
clause. A `bs_create_bin` with a fail label records it as a `branch`,
like the map instructions. The test suite asserts that every instruction
in OTP, Elixir and the dependencies is known, and that the emitter's
rows are exactly `Argus.Instr`'s.

**Fixed.** `Argus.Dataflow.reaching_uses/2` with `params: true` seeds the
parameters at the function's entry only (the `function_entry` label,
else the instruction after `func_info`). It had seeded every block with
no predecessor, and an exception handler is one: in `handler(a, b)` a
rescue's reads resolved to `{:param, 0}` and `{:param, 1}`, feeding
false flows into `call_arg_derived`, `site_depends`/`call_arg_depends`
and process points-to. The successor relation now also follows a guard
BIF's and a binary match's fail label and the edge from a `try`/`catch`
to its handler, the same graph as `Argus.Cfg`, so a value bound before
the `try` reaches the handler's reads and a clause reached only through
a failing guard sees the writes before it.

**Fixed.** `call_arg_derived`, the Dependence relations and process points-to
derive a copy's write from the one register it copied (`Helpers.copies/1`,
`Helpers.copy_read/2`): a `trim` writes each kept stack slot from one
renumbered slot and a `swap` each register from the other, and deriving
every write from every read mixed them — a slot kept by a trim took the
parameters of every other kept slot.

**Fixed.** The extractors' register walks (`Helpers.resolve_register/3`,
`arg_position/3`, `map_field_of/3`, `call_result_origin/3`,
`recent_writer/3`, `tuple_element_identity/5`, and through them
`key_identity/4`, `value_at/3`, `module_target/3`, `timeout_ms/3`) follow
reaching definitions over the function's real control flow
(`Argus.Instr.Reaching`) instead of stepping backwards through the
instruction stream. The stream walk read the instruction laid out before
a label as its predecessor and missed writes it had no clause for, so it
answered with another path's value: in `receive do pid ->
GenServer.call(pid, :x) end` the received message was parameter 0; in
`def f([h | t])`, `t` was parameter 0; in a `case` arm reached through
the previous arm's map-match fail edge, the previous arm's literal; after
a call, an `x` register the call destroyed kept its old value. A join
resolves only when every path agrees — a record whose arms all build it
with the same table and key keeps its identity. `nil` operands read as
the empty list, which is what BEAM assembly means by them, not the atom
`nil`. New: `Helpers.fun_target/3` and `Helpers.list_length/3` (what the
spawn resolution walked for itself). Corpus: eight new read-then-write
races in blockster_v2 (a Mnesia record written by a helper after a
missed `dirty_read` of the same key, a settings key checked and then
reset), all real; BB.Command.Server's "init/1 can block on a synchronous
call" is no longer reported, because the dynamic child its runtime
starts it as is now recognised and the rule exempts a callee under a
different supervisor.

**Fixed.** The extractors' remaining private readings of the instruction set are
`Argus.Instr`'s. `Helpers.trace/5` (a backward walk over the writes that
reach, for questions the other walks do not ask) and `Argus.Instr.carry/2`
(the registers holding a value after an instruction, for forward walks)
are new. Monitor's pid origin follows the writes that reach instead of
the stream (a pid started on one path and a parameter on the other was a
`started_child`), its ref-liveness table is `Argus.Instr`'s reads and
writes (a ref a receive wrote over was taken as kept), and its clause-head
walk drops a register written over. ErrorHandling's timer destination
follows copies (`me = self()` stored with `Process.put` first was
"other"), its timer-ref and rpc-result walks stop at a tail call, a jump
or a raise and drop registers every writer overwrites (the "last element
is the destination" rule missed `put_tuple2`, `get_list`, `make_fun3`),
and its, ProcessRegistry's and Reply's tail-call and positional-read
tests are `Argus.Instr`'s. A `trim` or `deallocate` ends the `y`
registers it does not keep.

### Process points-to

**Added.** An ETS table is an object of the same analysis:
`table_alloc(id, func, table)` is the `:ets.new/2` that makes `"table
<id>"` — the reference an unnamed table is, or the name a named one is
answered with — and `table_use(id, func, src_kind, src)` says which
source an ETS operation's table operand is. The table goes wherever a
pid would: through parameters, returns, map and tuple fields, a
server's state, a closure's environment, a spawned function's
arguments. `:timer.apply_after/4`, `apply_interval/4` and
`apply_repeatedly/4` are starts: the MFA runs in a process of its own,
with the argument list, and nothing the caller holds names it.

**Fixed.** `PidFlow` spells a literal `{:global, name}` or `{:via, mod,
key}` name, and a literal map key it selects on, with `Helpers.spell/1`,
as `ProcessRegistry` spells the names it registers: a name past
`inspect/2`'s bounds carried a digest on the registry side and not on the
lookup side, so the two never joined.

**Changed.** `coupling` reads the points-to analysis where the extractor's
target column says `"dynamic"`: a `Process.link/1` whose pid resolves to
a server (`signals.dl`'s `signal_target`) links the two modules, so a
coupled pair linked that way is not reported; and a `Process.monitor/1`
of a pid followed back to a `DynamicSupervisor.start_child` is a monitor
of a started child, for `dual_restart_authority`. Synchronous calls and
casts already resolved through `process_call` (`calls.dl`). `coupling`
reads `pid_signal` (pins).

**Fixed.** `PidFlow` reads what `spawn_call` now says of each spawn: the
argument list's register (`args`; it guessed x2, or x3 after a node,
which is wrong for `spawn_opt/4,5`, `proc_lib:start/4,5` and
`Process.spawn/4`) and the result's shape — `{:ok, pid}` from a
`proc_lib` start, `{pid, ref}` from a monitoring `spawn_opt` — where every
resolved spawn returned a bare pid. A spawn whose target did not resolve,
or of unknown arity, is left to the closure-following starts table
rather than named `M:f/-1`; `proc_lib:start_monitor`'s `{result, ref}`
is not modelled.

**Changed.** A wait is the waiting process's: `calls.dl`'s
`reaches_sync_dep`, `reaches_tag_dep` and `reaches_sync_dep_timeout` no
longer carry a dependency over the edge into what a spawn, task or agent
runs (`runs_elsewhere`). init/1 starting a task that calls a sibling the
supervisor starts later is no deadlock (`startup.blocks_on_peer`), nor
is a handler's task a hop of a call chain. The closure is a function of
the same module and keeps the dependency, so module-level relations
(cycles, fan-in, coupling) are unchanged. Corpus, realtime, logflare
and hexpm unchanged; OTP kernel's `logger_server:init/1`, whose simple
handler's loop runs in a process it spawns, no longer "can block on a
synchronous call" (4 rows).

**Changed.** Every analysis that reads process points-to includes
`process_statem.dl` and extracts `GenStatem`: blocking, coupling,
failure and coverage did not, so a gen_statem's state functions were no
process entries there, and a pid kept in its data did not resolve (a
cycle through a statem's data was found only when a message tag guessed
the hop). Corpus, realtime, logflare, hexpm and OTP findings unchanged.

**Fixed.** A wrapper that forwards its target to `:gen_statem.call/2,3`
or `GenStateMachine.call/2,3` (or the casts) is a peer call as a
`GenServer` one is: `calls.dl`'s forwarding rules read `peer_call` and
the new `peer_cast` rather than their own GenServer-only lists, so
`defp do_call(s, m), do: :gen_statem.call(s, m)` called with a literal
module is a dependency on it. `stage0.dl`'s `anchor_api` gains
`:gen_server.cast` and the gen_statem calls and casts, and coupling's
anchor for a witness's own peer call takes any of them, not only an
Elixir-spelled `GenServer` one.

**Fixed.** A GenServer module's public function that calls or casts to
another module's server — resolved by process points-to — is no longer
that module's client API (`genserver_sync_api`, `genserver_async_api`,
`reaches_sync_caller_in` in `calls.dl`): its callers wait on the other
server, and `ProxyApi.ask/0` calling `Answerer` made every caller of it
depend on ProxyApi's process instead. Corpus, realtime, logflare, hexpm
and OTP findings unchanged.

**Fixed.** A call process points-to resolves is no longer also attributed
by its message tag (`calls.dl`'s `tag_resolved_site`): the tag's guess
could name a different server than the one the pid is (a `:reindex`
only a decoy's `handle_call` names, sent to the catch-all server the
caller started), and a hop points-to proves was marked "tag", inferred,
in `blocking.call_chain` and `call_cycle_path`.

**Changed.** `calls.dl`'s `reaches_module` closes only over modules a
supervisor starts (`child_subtree`), the only targets
`stateful_module_dep`'s one consumer, coupling, asks about, and that
relation's module-level clause reads a precomputed `module_client_call`
rather than joining every function of the target. Output identical;
coupling's solve of this clause over a deps tree 0.49s to 0.05s.

**Changed.** Points-to (`clientlib/processes.dl`) solves the same rows in
about half the time: its recursive rules carry `.plan`s that start each
semi-naive version from its new tuples, where the source order scanned
all of `pid_arg`, `pid_load` or `pid_return` on every iteration to probe
a few new `source_pts` rows, and a load's or an update's base term is
named once (`load_base`, `update_base`). Every analysis that includes
`otp.dl` pays for it: over a 751-module deps tree blocking 21.9s to
10.7s and mailbox 21.9s to 9.9s; over OTP's ssl, public_key and kernel
6.2s to 4.5s and 6.7s to 4.2s. Output identical over the corpus and
four large programs.

**Changed.** A closure runs in the process that runs its caller unless a
start runs it. The same-process walks (reach.dl's `SameProcessReach` and
`SameProcessReachSet`, `self_pid`, blocking's callback reach) dropped
every closure edge, so a receive, a monitor's wait or a `self()` inside
a closure handed to `Enum.each` or `:lists.foldl` was not the caller's;
they now drop only the edge into what a spawn, a task or an agent runs
(`runs_elsewhere`, processes.dl), and a function's one closure when it
starts a process on a fun it did not build or builds a child spec (with
several, which is handed off is not known, and they stay the caller's;
a closure handed to `Task.async_stream` is the caller's too, since the
caller waits for it). A closure the function also calls itself
(`work.()` beside `Task.Supervisor.start_child(sup, work)`) stays the
caller's. mailbox's late-message and async_nolink reaches take the
same walk, so a source inside a task a server starts writes to the
task's mailbox, not the server's. `stage0.dl`'s `anchor_api` gains
`Supervisor.start_child`, the call that hands a child spec's fun off.
`mailbox.unconsumed_monitor` ("timed_wait") no longer reports a monitor
whose function ends the process that runs it (the last call of a task,
not called otherwise, not recursing): the monitor ends with the task.
On OTP's kernel, `:global`'s `handle_call(disconnect)` waits for
`nodedown` in a `lists:foldl` closure and is reported as a blocking
receive in a callback; mnesia_loader's `finish_copy/6`, whose monitor
the receive's `:DOWN` clause consumes, is no longer a monitor leak.

**Changed.** A start inside a function that returns what it starts is a
factory: each call that keeps its `{:ok, pid}` (or bare pid) is its own
process, `"start <call site>"`, and a child spec's child is `"child
<sup>#<pos>"`, the process its module's `start_link/1` returns. A
module's private `{:ok, conn} = Conn.start_link()` and the `Conn` its
supervisor starts were one process (the start site in
`Conn.start_link/1`), so a call to the private one looked like a call to
the supervised sibling. `clientlib/processes.dl` adds `instance(proc,
base)` (every process and its start site), `supervised_process(proc,
sup, pos)` and `private_process(proc, func, site)`; `server_process`
stays the module-level view, a start's name names all its instances, and
`self()` in a spawned function is every instance of its spawn.

**Added.** A pid a server replies with reaches its caller: a
`GenServer.call`'s result is a `reply` source, the second field of the
`{:reply, reply, state}` tuples the target's `handle_call/3` returns
(every clause's: the message is not matched to one). `pid =
Directory.lookup(id)` then `GenServer.call(pid, ...)` depends on the
worker the directory hands out. A map read by a key not known reads what
was written under keys not known (`Map.put(workers, id, pid)`), so a
registry map keyed at run time hands out what it holds; it does not read
every field, or `Map.get(socket, key)` would be the socket's transport
pid (phoenix_live_view's test client looked like a peer its channel
calls back).

**Added.** Schema 56. `pid_signal(id, func, signal, src_kind, src)`:
an exit signal (`Process.exit/2`, `:erlang.exit/2`), a monitor
(`Process.monitor/1,2`, `:erlang.monitor/2,3`), a link or an unlink, with
its target resolved like a call's (`clientlib/signals.dl`, apart from
processes.dl as sends.dl is: a helper that kills or monitors its
parameter is resolved at each caller). It provides `signal_target(id,
func, signal, proc)`, `watched_process(proc, how)` and
`exit_to_own_process(id, func)` (every resolved target was started by
the sending module), and processes.dl `started_by_module(proc, mod)` and
`self_call(func, site)` — a call to `self()`, or to a name only the
caller's module's processes hold from that module's own process, which
gen exits with `calling_self`. No analysis reads them yet.

**Changed.** `self()` resolves in a function a process's own code
calls — a callback's helper, a client API a callback calls — not only
in the callbacks and spawned functions themselves (closures are not
followed: one may be a task's). A gen_statem's data carries pids from
init/1 and state to state the way a GenServer's state does
(`process_statem.dl`: `{:ok, state, data}`, `{:next_state, state,
data}`, `{:keep_state, data}`, ...), and a call, cast or send to one
reaches its state functions' content. `process_statem.dl` is included by
every analysis that extracts with GenStatem (mailbox and startup now
too), so `self()` in a state function resolves the same in each. Only a
process behaviour's module is a process (`process_module`,
`init_function`, via `process_behaviour_module`): a Plug's,
Ecto.Type's or a storage callback's `init/1` ran as a process's before
(supavisor's and realtime's Peep storage modules held an "unnamed table
held by a process": corpus tally 21 → 17). mailbox's "Task.async in
library code" keeps exempting any behaviour module (`behaviour_module`).

**Fixed.** ProcessRegistry recorded a `{:global, n}` start name as the
local `n`, so a local `whereis(:n)` and a global start of `n` looked like
one name to the registry race; it is spelled `{:global, :n}` now
(`PidFlow.name_of/1`), and an Elixir start's `name: {:global, n}`, which
it skipped, is recorded the same way. Named starts it missed:
`:gen_statem.start*/4`, `GenStateMachine.start*/3`,
`Supervisor.start_link/2,3`, `:supervisor.start_link/3` and
`:gen_event.start*/1,2` (the last two kinds name no module's process).

**Added.** Process points-to knows more starts and every registry.
Allocation sites: `:gen_server`/`:gen_statem` `start_monitor`
(`{:ok, {pid, ref}}`), `GenStateMachine`, `Supervisor.start_link/3` and
`:supervisor.start_link/2,3`, `:proc_lib` spawns, `Task.start*`,
`Task.async` (a `%Task{}` whose `:pid` is the process and `:owner` the
caller) and `Task.Supervisor`'s, which run their closure (closures are
tracked as values for this), and `Agent` starts (kind `agent`). A start
with a literal `name:` (or `{:local, n}`, `{:global, n}`, `{:via, m,
k}`) registers its process (`pid_register` at the start site), as do
`:global.register_name/2,3` and `Registry.register/3` (the caller);
`GenServer.whereis/1`, `:global.whereis_name/1`,
`Registry.whereis_name/1` and `Registry.lookup/2` (`[{pid, value}]`) look
them up. The local, global and via registries are three namespaces
(`PidFlow.name_of/1` spells a name once for every relation). A child
spec's `name:` names its child, and ProcessRegistry's module-level guess
(`named_process`, which takes `Process.register(pid, n)` for the
caller's own process) is used only for a name nothing resolves
precisely. A call's arguments are followed at every position (the four
it stopped at dropped what redix's `Cluster.Manager.restart_connection/6` is
handed in its fifth and sixth).

**Added.** Schema 49. A call through a helper is the caller's dependency. A
parameter is context-insensitive, so `def safe_call(pid, msg), do:
GenServer.call(pid, msg)` called by two servers with two different peers
used to call both peers, and every caller of it reached both (a false
cycle when one peer called the other server back). A call whose target
is a parameter, or a field of one, is now a summary lifted to each
caller, where the pid is known: `clientlib/processes.dl`'s
`process_call(func, anchor, site, api_kind, proc)` says `func` waits on
(`call`), casts to (`cast`) or sends to (`info`) `proc` through the call
at `site`, in `func` itself or in a helper `func` hands the pid to at
`anchor`. The lifting follows any depth of helpers (the summaries are
finite); a callback's state and message, a spawned function's and
init/1's argument and a closure's environment are resolved where they
are (`entry_pts`). `sync_dep`, `async_dep`, `sync_site` and
`call_target` read it, so the dependency and its anchor are the
caller's.

`sync_call_site(id, caller_func, callee_mod, timeout_ms)` (ApiCalls):
each synchronous call's target and timeout at its site. Rules that paired
a function's calls with its timeouts or tags pair them by site now:
`sync_dep_timeout` took the 5000 of a `GenServer.call(self(), ...)` for
the `:infinity` call beside it, a tag attributed at one call resolved
every unresolved call of the function (`tag_resolved_site`), startup's
"unconditional" verdict took any unconditional GenServer.call in init/1
for the one behind a branch, a blocking handler was anchored at every
GenServer.call of a handler with one `:infinity` call, and coupling
anchored a points-to dependency at the witness's first GenServer call.

**Added.** Schema 48. Process points-to is field-sensitive: the terms that hold
pids are objects too. `PidFlow` names each term by the instruction that
built it (`put_map_*`, `put_tuple2`, `put_list`, `update_record`, a
start's `{:ok, pid}`, `Map.put/3`) and gives it a field per map key,
tuple position (`{i}`) or list element (`[]`, one field for all of
them); a read of `state.conn`, `elem(msg, 1)`, a clause head's
`{:subscribe, pid}` or `Map.get(state, :conn)` is a load of that one
field. A map update keeps the fields it does not set. Before, every read
of a structure took everything in it, so every pid in a GenServer's
state reached every handler use of any state field, and every pid in a
message of one kind reached that kind's handler: a server that kept two
private workers and called one "called" both (a false synchronous call
cycle and a call chain of depth 10 on the audit fixture), and a send to
the first subscriber "reached" the worker kept beside the subscribers
(a false unreceived message). The state is now the field of the
returned tuple its tag puts it in (`{:ok, s}`, `{:reply, r, s}`,
`{:noreply, s}`, `{:stop, reason, s}`, ...).

New relations: `pid_object(func, obj, shape, tag, arity)`,
`pid_field(func, obj, sel, src_kind, src)`, `pid_base(func, obj,
src_kind, src)`, `pid_sets(obj, sel)`, `pid_load(func, load, sel,
src_kind, src)` and `pid_result(id, func, callee)`; sources gain `obj`
and `load` kinds, and a `result` source is now the call site (so two
calls of one wrapper are two results). Every relation is keyed by site:
`process_start(id, func, proc, kind, runs)`, `pid_arg(id, caller,
callee, arg_pos, via, src_kind, src)` (`via`: `call`, `init`, `spawn`,
`child` or `closure`), `pid_call(id, ...)`, `pid_message(id, ...)`,
`pid_register(id, ...)`. Processes are named by their start site
(`"server Mod:start_link/1#6"`) or by the child spec naming them
(`"child Sup#0"`). A spawned function's parameters are the positional
elements of its argument list. `clientlib/processes.dl` provides
`source_pts`, `param_pts`, `returns_pts`, `field_pts`, `state_pts`,
`call_site_target(id, func, api_kind, proc)` and keeps `call_target`,
`named_pid`, `self_pid` and `server_process`; a call's message reaches
the handler of the server the same call site targets, and `sync_site`
anchors a points-to dependency at the call that makes it instead of at
every GenServer call in the function.

**Changed.** `Argus.Extractors.PidFlow` is six times faster (23.8s to 3.8s over the
385 Phoenix-stack beams): it reuses the module's reaching definitions
instead of recomputing them, converges each function on its own instead
of revisiting the whole module every pass, and asks one compile-time set
(`Argus.Extractor.Runtime`, which `Dependence` now shares) whether a
callee is the runtime instead of asking the code server at every call
site. Calls into OTP applications outside ERTS, Kernel, STDLIB, Elixir
and Logger are now followed like project calls; the corpus tally is
unchanged.

**Added.** Schema 46. Process points-to: which process a pid can be. A pid is a
reference and the call that started the process is its allocation site —
a spawn, named by what it runs (`spawn_call`), or a GenServer,
`:gen_server` or `:gen_statem` start with a literal callback module; the
process registry is a field that `register/2` stores into and a send to a
name reads. `Argus.Extractors.PidFlow` summarises each function with the
same union fixpoint over reaching definitions as `ParamFlow`, with
processes, parameters, project calls' results, registered names and
`self()` as sources:

- `process_start(func, proc, kind, runs)` — `func` starts `proc`
  (`"spawn Mod:fun/n"` or `"server Mod"`, function-level ids).
- `pid_arg(caller, callee, arg_pos, src_kind, src)` — an argument may be
  a pid from the source; also a server start's init argument, a
  one-argument spawn's argument and a closure's captured variables.
- `pid_return(func, src_kind, src)`, `pid_call(func, api_kind, src_kind,
  src)` (the `sync_call`/`async_cast` table's calls and casts),
  `pid_register(func, name, src_kind, src)`.
- `pid_send(id, func, message, src_kind, src)` — keyed on the site; the
  message is a literal atom, `{:tag, …}`, or `dynamic`.

`clientlib/processes.dl` chains them (context-insensitive, like
Andersen's analysis): `param_pid`, `returns_pid`, `named_pid`,
`self_pid` (a server's callbacks run in that server, a spawned function
in its spawn), a GenServer's state (what `init/1` and the handlers return
is the next handler's state parameter) and `call_target`;
`clientlib/sends.dl` adds `send_target`, apart, so the analyses that ask
only about calls do not read every send. `sync_dep` and `async_dep` gain
a clause for a call whose `"dynamic"` target resolves to a server —
rows added, none removed, since `cached_pid` and the tag rules key on
`"dynamic"` — and `sync_site` one for its site. blocking, coupling,
shutdown and startup list the extractor (and `ProcessRegistry`, for
`named_process`, where they did not); their pinned inputs gain the
function-level relations only. Only project code is followed: a call into
OTP or Elixir's own modules yields nothing. scry/planchette memos keyed
on the schema version invalidate.

**Added.** Schema 47. Process points-to follows pids carried in messages.
`pid_message(func, api_kind, src_kind, src)` records the pids a call's,
cast's or send's message may carry, and they reach the handler of the
server the target resolves to (`handle_call/3`, `handle_cast/2`,
`handle_info/2`) as its message parameter, and from there the server's
state: how `Hub.subscribe(self())` puts a subscriber's pid where the hub
later calls it. `pid_call` gains `info` rows for sends (a message to a
server lands in `handle_info/2`) and `name` sources for literal targets,
which resolve through the registry. Messages are not taken apart, and a
function's messages of one kind reach every server its calls of that
kind do.

**Added.** Process points-to counts a supervisor's children as processes: a child
started on request (`DynamicSupervisor.start_child/2`,
`Supervisor.start_child/2`) is a start site whose `{:ok, pid}` the
caller holds, named by its child spec's module, with the spec's
argument flowing into `Mod.start_link/1`; and a GenServer named in a
static supervisor's child spec is a server process
(`clientlib/processes.dl`'s `server_process`) even when no start call in
the program names it, so `self()` in its callbacks resolves. blocking
and mailbox list the Supervision extractor for it.

### Findings: anchors, frames and prose

**Fixed.** Anchors no longer invent modules. Several builders passed a function ID
where `Findings.at_site/2` takes a module string, so a row whose site
was empty or `"dynamic"` anchored at a module named after the function
(`:"Elixir.Foo.Bar:baz/1"`); `failure`'s inconsistent-handling finding
and its frames lost the module on Erlang code (`":lists:foo/1"` split to
`""`). `Findings.at_site_in_func/2,3` anchors a site inside a known
function and falls back to that function (then, given one, a module);
`module_atom/1` returns `nil` for anything `inspect/1` would not print
for a module, function IDs included. The two private `site_or_func/3`
copies in blocking and shutdown are that function now.

**Fixed.** Findings that knew only a function now point at the instruction, and
carry the frames a reader wants next. Stage 0's `call_site` gains the
callee's function and arity, covers local calls, and stages the few
library calls findings anchor at (`GenServer.call`,
`DynamicSupervisor.start_child`, `Supervisor.start_link`, `:gen_tcp.recv`,
`:ssl.recv`), so the supervision family still reads neither `remote_call`
nor `local_call`; `sync_site` and `call_instr` in the clientlib are
derived from it. `teardown_touches_sibling` anchors at the call into the
sibling (or, for a handler, at the callback) with the supervisor's child
spec as a frame; `foreign_dynamic_children` at the `start_child` call;
`dual_restart_authority` at the `start_child`, with the monitor and the
`:DOWN` handler as frames; `timer_cancel_without_flush` at the
`cancel_timer`, with the `send_after` as a frame; the cluster-wide lock at
the `:global` call, with the reaching `init/1` as a frame when it is
elsewhere; the unbounded receive at the `recv`; the post-start write with
the `Supervisor.start_link` as a frame; the table read outside its owner
with the `:ets.new` as a frame; a call cycle at the calls in its
witnesses. Evidence relations attach a sample (at most three, `limit:` on
the evidence spec) of the sites that follow a convention
(`handling_site`), the exported functions that reach a sink no request
reaches (`sink_export`, three calls deep), the entry removals of a server
that never demonitors (`monitored_entry_removal`) and the `Task.yield` of
a linked task (`task_yield_site`).

**Fixed.** A finding can close a span. `Findings.new/4` takes `to:`, an anchor whose
instruction ends the primary span, and `Findings.related/3` takes `to:`
for a frame; `to_instr` rides on both. A consumer with the source draws
the lines from the anchor to it as one bracket. `try_call` and
`call_result` gain `guard_end`, the handler's last instruction (the
`CatchClauses` walk already visits every instruction of a handler), so
"catches :noproc but not :shutdown", the erpc rescue finding and the
"guarded by this catch" frames of a consistency finding cover the call
through its catch — the guard Elixir's body-level `catch` has no `try`
keyword for.

**Fixed.** A finding can name the source block its anchor sits in: `to_block:` on
`Findings.new/4` and `Findings.related/3` (`:guard`, `:receive`,
`:clause`, `:function`), for a consumer with the source to close the
span by when the bytecode gives no end — a catch whose bodies are
literals has no line of its own. Bytecode cannot tell a `rescue` from a
`catch`, so prose about a guard says `{guard}` where the keyword goes
and a consumer with the source fills it in (`handler` without one):
the bare-rescue finding, the erpc finding and the "guarded by this
{guard}" frames. The noproc, erpc and bare-rescue
findings and the "guarded by this {guard}" frames name `:guard`; the
receive-in-callback findings `:receive`; the unreplied gen_statem call
and the dropped `from` `:clause`; the handle_info catch-all `:function`.
`bare_rescue` gains `guard_end` and the finding anchors at the try,
spanning the rescue.

**Fixed.** `Argus.Findings.new/4` takes `at_source:`, a source fragment a consumer
holding the source uses to move the anchor to the first line at or after
the bytecode anchor that contains it as a whole token. `exposure`'s
`unredacted_secret` anchors at the schema's `__schema__/1` — every
function Ecto generates carries the `schema do` line — with the field's
name as the fragment, so scry lands on `field :api_key` rather than
`defmodule`; its `at_label` is "declared without redact: true".

**Changed.** Related frames take `at_source:` as findings do (`Findings.related/3`;
the `related` map gains an `at_source` key): a source fragment that
carries the frame's line the last step. `unreceived_message`'s "the
receive it never matches" frame says `"receive"` and `to_block:
:receive` — a receive's `loop_rec` has no line, so the bytecode alone
put the frame on `def loop do`. Consumers refine a frame's line with the
fragment as they do a finding's (scry resolves frame lines from the
bytecode only, today).

**Fixed.** Every finding says what its anchored line is and what to do about it:
the builders that had no `at_label` or `help` (blocking, effects, ets,
exposure's TLS pair, failure's rescue/exit/whereis, mailbox's reply
defects, shutdown's cleanup defects, startup's init effects,
state_machine, structure, unsafe_input's reachable sinks) now carry
both, and remediation sentences moved out of `detail` into `help`,
where scry renders them as trailers. Prose fixes on the way: the
read-then-write race no longer prints the key's source index as the key
(`reads 1 from …`); the badrpc findings name `:rpc.call`, `:rpc.multicall`
or `:erpc.call` (`Findings.rpc_api/1`) instead of `:rpc.rpc`; callees
read `GenServer.call/2` and `:gen_statem.call/3` (`Findings.call_name/1`)
rather than the facts' `GenServer:call/2`; compiler-generated closure
names (`-ensure_connections/2-fun-0-/2`) render as "an anonymous
function in ensure_connections/2" in every piece of prose a finding
carries, done once in `Argus.Findings.build/2`; a witness that is the
callback itself is no longer named "(through …)"; a sink reached by its
own function is described once; `String.to_atom` is named beside its
compiled form; the timer-flush finding says nothing flushes the message
rather than that no receive takes it; the exposure detail lost a double
space. `unbounded_effect_in_init`'s recv rows dedupe per receiving
function, with the `init/1` callbacks that reach it as evidence frames
(`init_reaches_recv`) instead of one identical finding per init.

**Changed.** Prose spells functions one way. Builders interpolated the facts' raw
function IDs (`Madrigal.Wait:await_downfall/2 leaves a monitor live...`)
beside names already spelled with `call_name/1` (`GenServer.call/2`);
every finding's title, detail, anchor label, help and frame labels now
render a function ID as `Mod.fun/2` (`:gen_server.call/3` for Erlang),
and a closure as "an anonymous function in Mod.fun/2", in the one place
`build/2` already rewrote closure names. Instruction IDs and a generic
finding's raw columns are left as they are. Titles that named a
function change with it.

**Changed.** Two titles change. failure's inconsistent-handling title names the
callee with its module (`:gen_statem.call/3 called bare where every
other call site guards it`, was `call/3 called bare ...` — a title that
could not tell `GenServer.call/3` from `:gen_statem.call/3`); exposure's
unredacted-secret title reads `MyApp.User.password_hash is printed by
inspect/1` (was `MyApp.User.:password_hash`). Consumers matching titles
re-key: the corpus pairs are, encore's goldens are not yet.

**Changed.** `Findings.heuristic/3` is the one way a finding rests on a prior: one
severity step down, `provenance: :heuristic`, `confidence`, and a help
line — `heuristic: <what the prior said> (p=0.87)`. The coupling,
exposure and unsafe-input builders each carried a copy of the demotion
and rewrote `at_label` with the note; `at_label` now keeps saying what
the anchor line is ("supervision tree defined here"), and the note moved
to the last help line.

**Changed.** Four analysis descriptions (what `mix scry --list` prints) had drifted
from the README's table, and the table from the analyses: `structure`
now names its lookup-then-start race, `ets` Mnesia, `blocking` receives
in callbacks, `startup` handle_continue/2 by its arity, `coverage` that
it is opt-in. `Argus.ReadmeTest` keeps the two equal. `Findings.run/2`'s
docs name the sets and the retired names `:analyses` accepts.

### Findings: building and degradation

**Fixed.** A Souffle solve never outlives its caller. `Argus.Souffle.run/3`
ran the solver under `System.cmd/3` in a task and `Task.shutdown/1`ed it
at the deadline, which closed the port and left the solver running to
completion — a core and hundreds of megabytes per timed-out analysis —
and a caller that died, or a VM that halted (an interrupted `mix
compile`), left it running the same way. The solver now runs under a
`/bin/sh` reaper that holds the port's stdin and kills the solver when
stdin closes, which is when the port does: at the deadline, when the
calling process dies, and when the VM exits by any means.

**Fixed.** One row a finding builder did not expect degraded its whole concern:
`run/2` rescued the concern's build as a unit, so a single raising row
dropped every finding in it. The rescue is per row now — that row is
reported with its raw columns (a generic finding, or a generic frame
for an evidence row) and a help line saying so, the concern still
reports everything else, and it gets a `degraded` note as well as its
`ran` entry. `test/finding_heads_test.exs` reads every rule head of every
output relation from the `.dl` sources and checks each literal
combination reaches a builder clause that renders it, so a new head no
clause matches fails in the suite.

**Fixed.** A custom (non-builtin) analysis's evidence relations joined nothing:
the join columns were looked up among the builtin analyses only, so every
frame silently vanished. `Findings.build/2` reads the joins off the
analysis's own relations, once per build (the lookup ran per row, over
every loaded module), and raises when two evidence relations name the
same finding relation or one names a relation the analysis does not
declare. Collecting a finding's frames is linear in its rows (it
appended one frame at a time).

**Fixed.** `Findings.build/2` raised `KeyError` on a solve's raw result — any
relation the analysis does not declare as an output (stage 0's
`call_reachable`, a rule's intermediates) — and its spec said it
returned `[Findings.t()]`. It ignores undeclared relations and is
specced `[finding()]`.

**Fixed.** A retired name's row filter resolved each alias column per row, over
every loaded module; it resolves once per alias entry, against the
concern that runs it.

### mailbox

**Added.** `mailbox.unhandled_info(mod, func, site, message, source,
server, handler, fallback)` — the GenServer half of what
`unreceived_message` asks of a spawned process: a message a server is
sent (`source`: a `send` process points-to follows to it, a `timer` it
arms for itself, the `{:DOWN, …}` of a `monitor` it takes in its own
callbacks) that no clause of its handle_info/2 takes. `fallback` is what
takes it instead: nothing (`crash`, "No handle_info/2 clause for a
message the server is sent", a FunctionClauseError), a catch-all that
only logs or ignores it (`catch_all`, "A message the server is sent
reaches only its catch-all handle_info/2" — a warning for a monitor's
:DOWN, a monitor that does nothing; info for a message the program
sends, which a catch-all may be meant to take), or GenServer's own
handle_info/2 (`default`). Sent to a gen_statem that no callback of
takes it, a state function with no :info catch-all is `state_crash`
("No clause for a message a gen_statem is sent"). Not judged: a catch-all
that hands the message on, a clause that takes it by shape
(`callback_open`), a message a receive in the server's callbacks could
take, a monitor its function waits on or flushes. partial_handler's
"runtime" and "late_message" catch-all findings step aside for a module
a `crash` names, and "statem_info" for a state a `state_crash` names.
Corpus: three fix pairs — oban@5518653 (Notifiers.PG dropped each
listener's :DOWN in its catch-all and leaked the listener),
sequin@6693949 (SlotMessageStore armed :max_memory_check with no clause
and no catch-all), astarte@f3edb85 (AMQPEventsProducer re-armed :init
after a refactor removed its clause). Those are the rule's only rows
over the corpus, realtime, logflare, hexpm and OTP's kernel, stdlib,
mnesia, ssl, inets and ssh; no other finding moved. The ~120-repo scan
that found no pair for `unreceived_message` found every real "message
never received" fix in a handle_info/2, which is why the rule is here.
teslamate@91f6a8f (:repair armed by `:timer.send_interval/3`, handled in
handle_cast, dropped by a logging catch-all) is the same shape and is
caught by the fixtures, but its 2020 tree does not build on any
installed toolchain.

**Fixed.** An armed timer's ref handed to a function of the module
(`{:noreply, put_timer(state, ref)}`) goes where that function puts its
parameter: `timer_ref` says `stored` under the helper's key, or follows
the helper's result when the helper returns it. It said `"dynamic"`, so
the cancel-without-flush rule could not pair the arm with its cancel.

**Changed.** `mailbox.reply_defect`'s "self_call"/"self_cast" (a tag the
module sends and its own handler cannot take) treats a function whose
call or cast process points-to follows to another module's server as a
proxy, as it did one with a literal other target: a server calling the
catch-all server it started, with a tag its own `handle_call` lacks, is
that server's business. The rule still fires on calls whose target it
cannot resolve (a client function's pid parameter is the usual shape of
a real mismatch), so requiring points-to to prove the target the
module's own was not done: it would silence those.

**Changed.** `mailbox.unreceived_message` judges every receive the
spawned process runs — the spawned function's and those of what it
calls in its own process (`ForwardSameProcessReach`, reach.dl) — rather
than the spawned function's alone. A process whose first receive takes
`:go` and whose loop then takes `:work` was reported for `:work`; one
whose spawned function only calls its loop was never judged, which on
OTP's kernel was 50 of 56 sends to a spawned process. A process that
runs a call through a fun or an apply, a gen_server/gen_statem
`enter_loop` or a hibernate is not judged: its receives are not the
program's to read. The rule stays quiet on the corpus, realtime,
logflare, hexpm and OTP's kernel, mnesia, inets, ssh and ssl, now for
reasons it can state: on kernel, of 71 literal sends to a spawned
process 35 meet a receive clause that takes anything, 27 a process that
runs code through a fun, 7 a clause for the message, and 2 a process
with no receive.

**Changed.** `mailbox.partial_handler`'s "late_message" source no longer
counts a timer the process arms for itself with a literal message its
own `handle_info/2` has a clause for (a janitor's `:purge`), nor a
`cancel_timer`: the late message is one the process takes, and a cancel
writes nothing. A partial `handle_info/2` in such a process is no
FunctionClauseError waiting to happen.

**Changed.** `mailbox.partial_handler`'s "runtime" source counts only a monitor the
server takes on its own stack (a callback, or what one reaches in the
module), as `unconsumed_monitor` already did: a client function of the
same module (`def await_up, do: Process.monitor(whereis(__MODULE__))`)
runs in the caller, and its `:DOWN` never reaches the server.

**Fixed.** `mailbox.timer_cancel_without_flush` takes a receive for the
timer's message as its flush only where the cancel is: in the function
holding the cancel, a caller that handed the ref down to a cancel
helper, or a function one of those calls in the same process. A receive
for the message anywhere in the module used to silence the finding, so
a `receive :heartbeat` that handle_cast/2 waits in hid the missing flush
after the cancel in handle_call/3. Whether the receive comes after the
cancel inside the function is not asked. Over the corpus the two
flushes the rule ever saw are in the cancelling function, and no
finding moves. No schema change.

**Changed.** Schema 53. `mailbox.timer_cancel_without_flush` leaves out two cancels
that cannot leave a stale message behind. One in the `handle_info/2`
clause of the very message the timer sends (`def
handle_info(:heartbeat, s)` cancelling the heartbeat ref): that timer has
already fired. `cancel_clause(id, func, message)` records the clause
head a cancel sits under, from the head test that dominates it in the
control-flow graph. And one in a helper only `terminate/2` calls,
directly or through one more such helper. A module whose own-clause
cancel was the anchor now reports its other cancel, the one with the
window (supavisor's `Manager`: the `:DOWN` clause, not the
`:check_subscribers` one).

**Changed.** `unreceived_message` gains a `spawn` column, the start site
process points-to now records, and its "the process is spawned here" frame
points at the spawn instead of the spawning function's head.

**Added.** `mailbox.unreceived_message`: a message sent to a spawned process whose
receive has no clause for it. The message is not dropped; it stays in
the mailbox for the life of the process and every later receive scans
past it. The destination comes from process points-to (the send may
reach the process through parameters, results, `self()` or a registered
name, so the sending function need not name it), the message is a
literal atom or a tuple's literal tag, and only a receive held by the
spawned function itself is judged, never one with a clause that could
take anything. Anchored at the send, with the receive and the spawn as
related frames. No corpus pair: the corpus trees, OTP's and Elixir's own
applications and a search of public issues turned up no instance, so the
rule ships on its fixtures (`test/analyses/mailbox_unreceived_test.exs`)
and its quiet neighbour.

**Added.** `mailbox`'s `timer_cancel_without_flush` also catches a timer whose ref
never leaves the function: `ref = Process.send_after(self(), :deadline,
t)`, work, `Process.cancel_timer(ref)` and no flush. A message the timer
delivered before the cancel is handled on a later call, as if it were
that call's. `timer_cancel` gains the source `local`, keyed by the
arming site, from the same local identity; such a row has an empty
`key` and is deduplicated by its arming site. The local identity now
follows `swap` as well as `move`.

**Fixed.** `timer_cancel_without_flush` follows the message through the calls that
store the ref rather than through every caller of the arming function:
nebulex's `start_timer(time, ref, event \\ :heartbeat)` keeps `:cleanup`
under one key and `:heartbeat` under another, and each finding now names
its own message (both said `:cleanup`).

**Fixed.** mailbox's timed-wait monitor leak was the one error-severity finding
with no `help`; it says to `Process.demonitor(ref, [:flush])` on the
timeout branch, and `FindingHeadsTest` requires help of every error.

### effects

**Changed.** effects findings point at the calls they are about. `effect_in_context`
gains `site` (the instruction performing the effect; empty for a
receive) and `opened` (the transaction call); `purity_unprovable` gains
`site`; `impure_closure_to_pure` gains `site` (the call handing the
closure to the pure function) and `effect_site`. A transaction finding
anchors at the `Repo.transaction` call its label names ("opens the
transaction here" sat on the function head), a closure finding at the
call that hands the closure over, and each carries the effect as a
related frame. Output-relation shapes only; the fact schema is
unchanged, and effects now reads stage 0's `call_site`.

**Fixed.** A transaction body was paired with every repo its function opened a
transaction on: `effects.dl` joined `transaction_body` and
`transaction_site` on the caller alone, so a function passing its one
closure to `FakeRepo.transaction/1` and an `Ecto.Multi` to
`AuditRepo.transaction/1` reported the effect inside both — and, once
deduplicated, named whichever repo sorted first. The body is keyed by
its transaction site, and a function whose transactions name two repos
has no body: nothing says whose the closure is.

### races

**Fixed.** A read-then-write that runs in one process is raced by a
writer only a caller outside the program runs when that caller can
exist. `ets_check_act` and `mnesia_check_act` counted every writer the
pair's process does not reach, so a function nothing in the program
calls always counted, as if a library's user called it.
`RunsConcurrently` (clientlib/concurrency.dl) now says which such
functions outside callers have (`open_entry`): an exported function
nothing in the program calls, in a module no other module of the
program calls into. A module the program is the client of has its
callers in view, and a function of it none of them calls is unused, not
an entry; one an open entry reaches still counts, and so does any
writer another entry's process runs. nerves_hub_web's CLISessionCache
serializes `get_and_update/2` in its own `handle_call/3`; the only
other writer the rule counted was `clear/0`, which only the tests call,
while `Accounts` calls the cache's other functions. The same cache in a
library nothing calls into is still reported, `clear/0` being API.
What this misses: a module a library both calls itself and hands its
users, through a function it never calls. Corpus: 10 ETS rows to 7.
nerves_hub_web's CLISessionCache goes at both checkouts, and ztlp's
`AdminApiRateLimiter.do_check/1`, the same shape: its token bucket is
serialized through `handle_call/3` (the moduledoc's fix for the
lookup-then-insert race), MetricsServer calls its `check/1`, and the
other writer was `reset/0`, documented as a test helper. ztlp's
unserialized `RateLimiter` and `RegistrationAuth`, hammer#94, postgrex
and blockster stay; Mnesia rows and every other title are unchanged.

**Changed.** A check and an act that name what they touch by different
parameters meet where a caller names both alike (`CheckThenAct`,
clientlib/check_then_act.dl). elvengard_ecs's `do_insert_new(type, key,
record)` dirty_read `{type, key}` and dirty_wrote `record` when the read
was empty; only `insert_new/1`, which handed it `elem(record, 0)`,
`elem(record, 1)` and `record`, and `create_entity/3`, which built the
record, say the two are one record. A pair whose identities differ only
in parameters (or in elements of parameters, against a literal) is
carried up the call graph, both sides renamed at each call, until the
two agree — it meets in that caller — or a side stops being a
parameter's. A table named as a record's first element resolves at the
callers that build the record (`table_at_record`). Mnesia's
`dirty_match_object` (by the pattern's key; `:_` reads every key),
`dirty_select`, `dirty_index_read` and `dirty_index_match_object`
(every key of the table) are reads. Corpus: elvengard_ecs@1118693 is a
fix pair; blockster_v2 gains four Mnesia rows — an idempotency check by
a secondary index before inserting a referral earning (twice, the live
and the backfill path), an X-account uniqueness check by
`dirty_match_object` before writing a connection, and a dev seeding
script's read-then-seed of a pool other processes write — and
nerves_hub_web one ETS row (`CLISessionCache.handle_call/3` reads a
session through `get/1` and writes it through `put/2`, keyed by an
element of the message; the cache serializes it in its own process,
and the other writer the rule counts is the exported `clear/0`, which
only the tests call). OTP's mnesia, kernel, stdlib, ssl and inets:
unchanged.

**Added.** `ets_missing_row`: a read decides a row is there
(`case :ets.lookup(t, k) do [_] -> ...`) and an operation that raises
when it is not acts on it (`:ets.update_counter/3`,
`:ets.lookup_element/3`), while a take or delete of the table's rows can
run in another process between the two. No update is lost; the act
crashes with `badarg` on the row the other process removed. Built on
CheckThenAct with the tables of clientlib/tables.dl; the remover's key
is not asked, since a flush keyed by the arguments a timer was handed is
no key the facts can equate to the check's. Quiet when the act has a
default (`update_counter/4`) or `ArgumentError` is rescued, when the
table is private, and when the remover cannot run while the pair's
function is between the two. Corpus: sequin's DebouncedLogger (46ce4e1,
live upstream), the count its timer's flush takes the row from under, is
a present-only pair; it was the consistency rule's `info` alone.

**Changed.** Which ETS tables an operation may touch is one relation,
`ets_table(id, kind, ident)` (clientlib/tables.dl): `named` and the name,
spelled at the operation, as one arm of a join, or passed by callers;
`new` and the `:ets.new/2` site of an unnamed table, followed by process
points-to; and, only where neither answers, `field`, the module and the
map path a parameter's table is read under. `ets_publish_order` matches
its tables on it, where it knew a table by name or by field within the
module: two unnamed tables in a tuple, or kept under one field name in
two maps, or handed to another module, are told apart by where each was
made. Its two writes may be the function's own or its callees' (a
function runs an insert at the call that leads to it, and reads the
callee's key in its own terms through `ets_call_arg`), ordered by
`ets_effect_order`. And the reader's key must be able to hold the value:
made from a read of the first table, through callers, returns and
parameters (`site_reads`, `call_arg_reads`, `returns_depends`), or from a
source whose origin the program does not show — a parameter of an
exported function or one taken as a fun, a call nothing summarises. A
reader only ever handed keys from elsewhere is quiet.

**Added.** `ets_publish_order`: a function writes a row of one ETS table
holding a value (`{name, id}`), and only then the row another table keys
by that value (`{id, name}`), while a reader elsewhere takes values out
of the first table and reads the second at them with a read that raises
on a missing row (`:ets.lookup_element/3`, `:ets.update_counter/3`).
Between the two writes the value can be found and its row cannot, and
the reader crashes with `badarg`. The fix is the order: the row first,
then the value, and a publish that can lose (`insert_new`) deletes the
row its loser wrote. The two writes join on the value's identity in
their function (`ets_value` against `ets_key`) and are ordered by
`ets_write_order`; the tables are matched to their readers by name for a
named table and by the map field it is kept under for an unnamed one
(`ets_table_path` from a parameter). Quiet when the reader takes a
default or rescues `ArgumentError`, when no table of the name is found
or one is private, when the two tables are one, and when the writer and
the reader run only in one and the same process. A `:warning` anchored
at the early write, with the completing write and the reader as related
frames. Corpus: no row, and the tally is otherwise unchanged (1,143
rows before and after); the rule has no fix pair in `pairs.exs` yet.

**Changed.** Whether two processes can run a function (`RunsConcurrently`,
clientlib/concurrency.dl) counts the processes a spawn, a task or an
agent starts as entries of their own, and walks from every entry in its
own process (`SameProcessReach`): a task's work was its starter's, so a
claim a GenServer hands a task per message ran in "one process", the
server. A started process has many instances when its start runs more
than once — reached from a request or a message handler, in a closure,
or in a function that calls itself — and is one process otherwise (a
worker `init/1` spawns). races extracts `PidFlow` for `process_start`.
Corpus: ztlp's name-registration rate limit, a lookup-then-insert run
in a task per UDP packet, is a read-then-write race. OTP's mnesia gains
four read-then-write rows on `mnesia_gvar` and the schema table, now
that its loader workers and transaction processes are processes of
their own (the same class as its 29 existing rows: mnesia orders these
writes with its own locks, which the rule does not see).

**Changed.** A new concern, `races`, owns the three check-then-act
relations, which move with their columns, titles and prose unchanged:
`registry_race` from `structure`, `ets_check_act` and `mnesia_check_act`
from `ets`. They were one shape on three stores, built on one component,
split across two concerns by store. The move is breaking, and no alias
covers it: code or configuration asking `structure` or `ets` for these
rows asks `races` now, and findings report under `races` (scry's
`[scry.races]`). `races` is in the `:default` set, as `registry_race`
was through `structure`: over the closed-issue corpus and four large
programs it reports one registry race, ETS races in five projects and
OTP's mnesia internals, and Mnesia races in two projects, each a read
deciding a write another process can interleave. `structure` and `ets`
keep their other relations and declare only the extractors those read.
One solve derives the three: `param_arg`, the same for every
`CheckThenAct` instance, is derived once outside the component instead
of once per instance (88k rows each on a deps tree), and one
`RunsConcurrently` instance, seeded with every meeting and write the
three ask about, replaces three. Rows are byte-identical over the corpus
and the four large programs. On argus's deps tree `races` solves in
1.1 s, and `structure` and `ets` drop from 0.7 s and 1.0 s to 0.2 s and
0.4 s.

**Fixed.** A Broadway pipeline's `handle_message/3` and `handle_batch/4` are
request entries for the races too: `clientlib/concurrency.dl` counts what
they reach as run by many processes at once, as unsafe_input always
did. The clauses were written in `unsafe_input.dl` alone, so a Broadway
module's read-then-write on an ETS key or a name was taken for one
process's and not reported. They live in `clientlib/request_entry.dl`
now. No finding over the corpus and the four large programs moved.

**Changed.** `structure.registry_race` leaves out two losers that are not a bug: a
`register/2` inside an Erlang `catch` (the loser handled, as in
`inet_gethost_native`), and a named start whose `{:error,
{:already_started, pid}}` — its spec says it can fail — nothing reads on
the way back to where the lookup decided (`ssh_dbg:switch/2`, which goes
on by the name the winner holds).

**Changed.** `clientlib/check_then_act.dl` solves the same rows faster: the loop rule
joins a callee's acts to its callers' parameter-fed arguments on
(callee, position) instead of scanning every argument, its recursive
rules carry `.plan`s that start each semi-naive version from its new
tuples, and `carried_through` is walked one call at a time from where a
pair meets rather than closed over itself. The ets analysis over OTP's
mnesia, inets and ssh: 3.9s to 1.6s, output byte-identical.

**Changed.** Schema 54. `ets.ets_check_act` and `ets.mnesia_check_act` tell a lost
update from a race both racers win. `Argus.Extractors.Dependence` also
emits `site_reads` and `call_arg_reads`, its dependence relations by data
alone — what a value is made of, not what it runs under. A pair is a
lost update when its write carries what a read said, or when the table
is written back from a read or counted into (`update_counter`) anywhere
in the program; on a table that is neither, three shapes are no longer
reported: a delete (deleting twice is deleting once), a refill whose
value a call or a read of another store makes (cache-aside: both racers
load the same thing), and
a trip whose decision stays inside the program (nothing a caller
branches on, no exported function handing it out; a spec returning one
literal atom, `:ok`, says the result carries no decision). A claim that
tells its caller it won (blockster's sync slot), Hammer's first insert
over an `update_counter` key and ztlp's token bucket are still reported;
blockster's cache refills (from functions and from Mnesia) and
invalidation, supavisor's circuit breaker,
sequin's havoc stop and blockster's expired OAuth-state deletes are not;
Postgrex's per-connection parameters row (the key a monitor ref only its
connection holds) is a known false positive the rule cannot see. A
Mnesia finding names a delete as a delete.
`Argus.Specs` gains the `constant` shape: a return type that is one
literal atom (also `total`).

**Added.** The check-then-act races follow the paper they come from (Christakis and
Sagonas, PADL 2010) across functions. `clientlib/check_then_act.dl`
composes the dependence relations in the `CheckThenAct` component: a
check's result meets the acts that depend on it where it is born or
returned to, through a lookup helper, a start helper, a multi-clause
helper handed the result, another module, or the next iteration of a
loop, with names and keys translated across each call by `call_arg`,
`call_arg_forward` and `call_arg_field`. An unknown higher-order call is
not followed, the paper's own evaluated setting. `guarded_create` and
`ets_guarded_write` are removed — an act decided in the same function is
the component's simplest case — and so is `Argus.Extractor.Guard`, which
nothing called once the rules read `Argus.Extractors.Dependence`.

**Added.** `registry_race` rows now name the function where the pair meets, and
cover `Process.registered/0` deciding a register (`name_lookup` api
`registered`, source `any`) and whereis-then-unregister (new
`name_release(id, func, api, source, key)`; the loser's outcome is an
`ArgumentError` or `badarg` rescued). `ets_check_act` follows a table
handed on as a parameter, by name or as the reference `:ets.new/2`
returned in a caller — new `ets_tid_arg(caller, callee, arg_pos, name)`,
closures' captured variables included. The paper's registry and ETS
examples, and Dialyzer's unregister warning, are Erlang fixtures under
`test/fixtures/erl/` pinned by `Padl2010RaceTest`.
`Argus.Findings.elsewhere/2` names the function a site sits in when it
is not where the pair meets.

**Added.** `ets` gains `mnesia_check_act(mod, func, table, key, read, write)` over a
new `Argus.Extractors.Mnesia` and its `mnesia_op(id, func, op, kind,
table_source, table, key_source, key)`: a dirty read that decides or
feeds a dirty write of the same record another process can write. With
it every example in the paper is pinned, and the check-then-act rules
cover all four of Dialyzer's `-Wrace_conditions` warnings.

**Added.** The race families' names, tables and keys gain a fifth source, `local`:
a value that is no literal, parameter or map field but has one defining
instruction (`Helpers.key_identity/4` with `Helpers.origins_index/1`,
through reaching definitions and moves, indexed once per module as
`module_data.origins_index`), keyed by that instruction's ID. Two
operands with the same origin hold the same value, so `key = {name,
type}` handed to a dirty read and then a dirty write is one key
(ztlp@39fa329); a value two definitions reach stays dynamic, and a local
identity never crosses a call.

**Added.** A check-then-act pair that meets in a helper is reported there, and not
again in each caller the helper returns the check to.

**Changed.** `structure.registry_race` gains `key_source` (literal, param, field,
local, dynamic or any) before `key`, and the finding says which name it
means: "asks whether the name in its first argument is registered" where
it said "asks whether 0 is registered" — a parameter's position, printed
as a number, in 11 of the 14 name-race findings across the corpus.

**Changed.** `ets_publish_order`'s labels fit beside the code they mark. The early
write's label is "this publishes the value before its row in :reverse
exists" (was "this write makes the value findable before its row in the
table held under :reverse exists", 90 columns after an indent of 40),
naming a field table by its path and a named table by its name; the
reader's frame is "a read that raises if the row is not there yet" (was
"a read that raises on the missing row"). The title, the detail and the
relation are unchanged.

### unsafe_input

**Fixed.** Request taint follows a propagator's data argument, not its key.
`Argus.Extractors.ParamFlow.Propagators` recorded `:maps.get(Key, Map)`
at position 0, so taint through a direct `:maps.get` was lost (and a
tainted key tainted the result); `:lists.nthtail(N, List)`,
`:lists.sort/2` and `usort/2` (the list follows a fun),
`Tuple.insert_at(tuple, index, value)`, `Enum.reduce/2` (the fun) and
`List.update_at/3` (the fun) were wrong the same way, and `:maps.get/3`,
`Map.get/3`, `Keyword.get/3` (the default), `:lists.reverse/2`,
`append/2`, `flatten/2`, `join/2`, `Enum.join` and `map_join` (the
separator) and `:binary`/`:string` `replace` (the replacement) missed
arguments that reach the result. BIFs follow their operand order too:
`map_get(Key, Map)` carried every register operand, key included
(`Propagators.bif_positions/2`; `bif?/1` is deprecated). A test checks
every entry against the documented signature's argument names.

**Changed.** `unsafe_input` finds the request entries that transitively
reach a sink walking back from the sinks' functions instead of forward
from every entry over everything it calls: the walk is 48 rows instead
of 12.1k on blockster. Output identical over the corpus and four large
programs.

**Fixed.** `unsafe_input`'s two sink relations gain a trailing `safety` column, the
deserialization's option class (`unsafe | atoms_only | dynamic`, empty
for the other sinks), and the deserialization finding says which. The
title "binary_to_term without :safe" was literally false for a call that
passes `[:safe]` — argus keeps that finding on purpose, as a downgrade
rather than a clear (Paginator CVE-2020-15150 was RCE through `[:safe]`),
but said the wrong thing about it. Now: `unsafe` keeps its title and
`:error`; `atoms_only` is "binary_to_term with [:safe] and no shape
check" at `:warning`, with the loaded-module fun risk and
`Plug.Crypto.non_executable_binary_to_term/2` in the text; `dynamic` is
"binary_to_term with options not known statically" at `:error`. A
request-reachable deserialization keeps its proximity severity and gains
the same wording.

### failure

**Changed.** `failure.orphan_process` reads process points-to
(signals.dl). An exit signal from a callback to a process the sending
module started itself — a helper kept in the state, a connection it
opened, a proxy it started a line above — is its own to stop and no
longer "Process.exit inside a GenServer callback"; one that resolves to
a supervisor's child names the child as `target`, and the new evidence
relation `exit_target_owner(func, target, sup, sup_site)` attaches the
supervisor as a related frame: the bypass the finding describes. The
callback reaches the exit only in its own process now: a kill inside a
closure it spawns is the spawned process's. A bare `spawn` whose process
the program then monitors or links to is watched, and no longer an
orphan. Corpus: phoenix's CodeReloader killing the IO proxy it started
and supavisor's SecretChecker, whose kill runs in a spawned closure on
a connection it opened, drop out; OTP kernel's rpc (a spawn race's kill
of its own process) and three spawns something monitors or links
(file_server, inet_gethost_native, user_sup) drop out.

**Changed.** `failure.inconsistent_handling` no longer reports a discarded start
result that `startup.ignored_start_result` already reports: one site,
one concern, one title.

**Added.** Schema 52. `macro_generated(func, by)`: a function another module's
macro wrote into the analyzed one, read from the `context:` Elixir keeps
in each definition's debug-info metadata (or its `generated: true`
marker) by `Argus.Extractors.Generated`. `failure.inconsistent_handling`
leaves those sites, and the closures inside them, out of the population:
`use Ecto.Repo` writes a bare `Supervisor.stop/3` into every repo, on the
`use` line, and that was the library's choice reported as the program's.

**Changed.** Schema 51. `call_result` gains a `target` column: the call's first
argument when it is a literal (the table, the server name).
`failure.inconsistent_handling` judges a site against its callee's sites
on the same target, and against every site of the callee only when its
own target is unknown; the finding and its `handling_site` evidence
carry the target. mnesia reads its gvar table under a catch 120 times
and its stats table bare once, on purpose (`mnesia_lib:read_counter/1`);
pooled per callee, the one read was a deviant. Postgrex's SCRAM cache
and its parameters table, blockster's dedup table and its caches, were
the same story in the corpus.

### blocking

**Fixed.** Call timeouts are read at the signatures' positions.
`:erpc.call/4` (`Node, M, F, A`) and `:erpc.multicall/4` read their
timeout from the argument list — so no erpc call without a timeout was
ever recorded as waiting forever; they wait forever, and `erpc`'s
`call/2,3` and `multicall/2,3` are recorded. `:rpc.multicall/4` is
`(Nodes, M, F, A)` or `(M, F, A, Timeout)`, told apart by its third
argument. `GenServer.multi_call/3,4` and the new `:gen_server.multi_call`
name their server second (the target read the node list) and `/4`'s
timeout fourth (it was always infinity). `Agent.get/update/
get_and_update` in their module-function forms (`/4` default, `/5`
timeout) are synchronous calls. A `:gen_statem.call/3` timeout of
`{:dirty_timeout, t}` or `{:clean_timeout, t}` is `t`.

**Added.** `blocking.call_cycle` "self": a synchronous call to the calling
process itself, "Synchronous call to the calling process itself" — to
`self()`, to `self()` handed to a helper that calls its parameter (new in
processes.dl's `self_call`), or from a callback to a name only the
module's own process holds. gen exits such a call with `:calling_self`;
the two-module cycle rule filters `mod != to` and never saw it. One
finding per call site. Nothing on the corpus, realtime, logflare, hexpm
or OTP.

**Changed.** `blocking.call_chain` ("chain") keeps only the shortest chain between two
servers (a Souffle subsumption), where it enumerated every path length up
to ten and reported one at random, and no longer passes through a
synchronous call cycle: the cycle is its own finding.

**Changed.** A chain is made of requests, not modules: a hop is the call a
handle_call/3 clause makes, with the tag it sends, into the clause of the
next server that tag enters (`clause_call`, schema 61), and a chain stops at a
clause on a cycle of requests rather than at every module in a call
cycle. By module, a cycle through one clause swallowed a chain through
another: encore's fugue seeds Countersubject -> Answer -> Subject beside
the Answer <-> Countersubject cycle Answer's `:echo` clause closes, and
the chain was lost when chains stopped at cycle members. A call into a
function with a literal first atom enters only that clause of it, so a
handler calling `Router.route(:local, n)` no longer waits on what the
`:remote` clause calls (fugue's Router tripwire). A clause the extractor
cannot tell (a helper that dispatches, a catch-all) serves every request,
and a request with no literal tag enters every clause, so where neither is
known the chain is the module-granular one. `call_cycle` stays by module:
a server busy in one clause cannot answer a call into another.
`clientlib/calls.dl` gains `sync_request_at`, `sync_request` and
`reaches_sync_request` (the synchronous dependencies with their request's
tag) and `site_request` / `site_clause`, the same per call site of the
functions a consumer seeds `site_demand` with.

**Changed.** One site, one concern: an rpc in `init/1`, and a blocking `:global` op
`init/1` reaches, are `startup.blocks_on_peer`'s findings ("remote",
"global") and no longer also `blocking.unbounded_wait`'s; a blocking
receive in `init/1` is `startup.unbounded_effect_in_init`'s ("receive") and
no longer also `blocking.receive_in_callback`'s.

**Changed.** `blocking.receive_in_callback` judges the cancel_timer flush idiom per
receive rather than per function: a blocking receive in a function that
cancels a timer is the flush only if it can take a timer's message — a
clause for a literal one of the module's timers carries, for `:timeout`,
or for anything. One whose every clause waits for some other literal, in
a module whose timers all carry known literals, is reported. When the
module arms no timer the program can see, the receive stays suppressed.

**Fixed.** A literal target handed to a wrapper is the dependency of the
call that hands it (`clientlib/calls.dl`). `def flush(server), do:
GenServer.call(server, :flush)` called as `flush(EventBuffer)` resolved
the literal in the wrapper, whose parameter is every target any caller
passes, and each caller of the wrapper then waited on every caller's
target. Plausible's Event and Session write buffers — two modules of
`def flush, do: WriteBuffer.flush(__MODULE__)` over one server module —
were three "Synchronous call cycle" errors: the wrappers called each
other, and the server module called both. The wrapper is now a summary
(`target_param`: a parameter that becomes a call's or cast's target,
through any depth of forwarding) lifted to each call passing a literal
(`named_target`), as `processes.dl` lifts a pid handed to a helper, and
the dependency is anchored at the call into the wrapper (`sync_site`,
`sync_request_at`). Every analysis reading `sync_dep` sees the change;
the corpus tally is unchanged.

**Fixed.** `blocking.call_cycle` ("call") is a cycle between processes:
each direction is a wait the module's own process makes, at a function
it runs — reached from one of its callbacks on its own stack, or in a
task it awaits. By module, any function counted, and a client function
of a server module closed a cycle no process can deadlock in: klife's
`Producer.produce/3` runs in its caller, and only `Batcher`'s process
calls `Producer`'s. A module that runs no process of its own is never a
side of one.

**Fixed.** A wait a process makes only while it starts — from `init/1`,
or from a Phoenix channel's `join/3` — closes a `blocking.call_cycle`
only when the process can be named during its start (a registered name,
or a call to it by name) or when the peer's `handle_call/3` clause for
that request calls it back. Otherwise the peer can reach it by the pid
it hands over alone, and answers before it can call back. Phoenix
LiveView's upload channel registers with the LiveView from `join/3`,
and `Phoenix.LiveView.Channel` <-> `UploadChannel` was reported on two
corpus checkouts; the LiveView replies at once and calls the channel
later, through the pid it kept. A peer that defers its reply to the
start's request and calls the starting process from another callback is
not seen (the reply is not followed).

### startup

**Fixed.** `startup.unbounded_effect_in_init` and `blocks_on_peer`'s
"sup", "global" and "blocking_server" rows follow only what `init/1`'s own
process runs. A loop, a connect, a `:global` lock or a supervisor call
inside a function `init/1` spawns, hands to a task or an agent (process
points-to's `process_start`) or builds into a child spec does not hold the
start, and was reported as though it did (`spawn_link(fn -> loop() end)`
read as "init/1 waits on a socket with no timeout"). The walk is the new
`ProcessReach` component over `runs_elsewhere` (processes.dl): every call
edge but the one into what a start runs, so a closure handed to
`Enum.each` still counts. On the corpus, supavisor's DbHandler no longer
waits on a Manager whose `Supervisor.stop` runs in a task; in OTP's
kernel, the loops `:global`, `:global_group`, `:rpc` and
`:logger_simple_h` spawn from init are no longer init's waits.
`blocking.unbounded_wait`'s "global" and "rpc" rows step aside for init's
by the same walk, so a lock in a task init starts is blocking's finding.

**Changed.** A `receive` with no `after` on init's path is its own kind,
`unbounded_effect_in_init` "receive", titled "init/1 waits on a message
with no timeout" and anchored at the receive; "recv" and "init/1 waits on
a socket with no timeout" are for a `:gen_tcp`/`:ssl` recv with
`:infinity`.

### exposure

**Changed.** `Argus.Priors.Questions.Sensitivity` is at prompt version 2,
so cached version-1 answers stop being hits and every field is asked
afresh. Version 1 asked what kind of data a field holds from its name
and its siblings' names, and its only secret-adjacent answers were
secrets: in a talk's priors hunt over 32 corpus checkouts, four of the
six warnings resting on it were not secrets — nerves_hub's
`OrgKey.key` (an Ed25519 public key, 0.97), `SharedSecretAuth.key` twice
(the key's public id beside its `secret`, 0.91 and 0.96) and blockster's
`PlatformAccount.credentials_ref` (a reference, 0.91). Version 2 shows
each field with its Ecto type (schema 69) and asks what the field holds,
with two more answers that are not secrets: `secret_reference` (a key's
id or name, a handle to credentials kept elsewhere) and `public_key`
(the public half of a pair). It drops the `must_redact` noul, which no
rule read. Re-run over the same 32 checkouts: the four warnings leave
(the ids and the reference are answered `secret_reference`, the public
key a secret at 0.83, under 0.9), `nkey_seed` (1.00), `NatsSink.jwt`
(1.00) and `GcpPubsubSink.credentials` (0.94, where its type
`embeds_one Sequin.Sinks.Gcp.Credentials` is what keeps it over 0.9:
the question without the types answers 0.87) stay, and two warnings
arrive, both secrets: blockster's `Airdrop.Round.server_seed` (a
provably-fair seed kept secret until the draw, 0.99) and
`XOauthState.code_verifier` (a PKCE verifier, a secret at 0.97 as
before, whose likeliest kind is now credential at 0.53 over token at
0.44, so a warning where it was an info-level token). One info-level row leaves: sequin's
`ApiToken.hashed_token` (a hash of the token, 0.66). Heuristic
findings go from 20 (6 warnings, 2 secrets) to 16 (4 warnings, 4
secrets). On the priors spike's labelled schema fields (26) coverage at
0.7 goes from 96% to 100% at 96% precision, every labelled secret still
fires, and one fixture field arrives at 0.95 (`body` in a module named
`...Secret.Ordinary`; the same schema under another name answers
`none` at 0.97); on its synthetic schemas (93 fields) from 87% to 95%
coverage and 94% to 98% precision, with 18 of 20 secrets over 0.9
where version 1 had 19, and no false one where version 1 had one. A
request costs about 30% more input tokens. The corpus runs without
priors and does not move.

**Fixed.** `exposure.unredacted_secret_inferred` gated on the chosen
kind's probability, so a field the model was sure is a secret but split
between kinds fell under 0.9: sequin's `NatsSink.jwt` (token 0.89,
credential 0.11), `github_token` (0.86 + 0.14), `api_token` (0.81 +
0.19), `totp_seed` (0.87 + 0.13). It gates on the probability that the
field is a secret of any kind now (schema 68), reports the likeliest
kind, and the help line says both ("names :jwt a secret, most likely a
token"). Replayed over the recorded answers of a talk's priors hunt (32
corpus trees), four info-level rows arrive — `NatsSink.jwt` (real, fixed
upstream in 035ee6f), blockster's `User.telegram_connect_token` and
`XOauthState.code_verifier` (bearer material), and blockster's
`Hub.token` (a currency ticker: wrong) — none leave, and the six
warnings are the same six. The corpus runs without priors and does not
move.

**Fixed.** `exposure.unredacted_secret` (and `unredacted_secret_inferred`)
knew only Ecto's `redact: true`, so a field kept out of `inspect/1` by
`@derive {Inspect, except: [...]}` or `only: [...]` was reported as
printed. The derived `Inspect`, when its module is in the run, is now the
answer (schema 67): a field it does not show is hidden, and one it shows
is printed even under `redact: true`, which Ecto ignores once a schema
derives `Inspect` itself. The relations gain a `via` column, `redact` or
`derive`, and a finding under the schema's own derive sends the fix to
its field list instead of to `redact: true`. Found by a talk's priors
hunt: sequin's `Gcp.Credentials.private_key` was reported although
excluded, and sequin 035ee6f's fix for `NatsSink` (a derive, no
`redact:`) would not have cleared it. New pair `sequin@035ee6f`.
Corpus: 23 `unredacted_secret` rows leave, all sequin and each a field
its schema's derive excludes (19 at 46ce4e1 — every sink's `password`,
`secret_access_key`, `api_key` and the like, and four of
`Gcp.Credentials`; `PostgresDatabase.password` and
`Gcp.Credentials.private_key` at 6693949 and 94fbd52); none arrive, and
no other analysis moves.

**Changed.** `exposure.unredacted_secret` no longer reports a field that names a
secret but holds a fact about it — `password_reset_sent_at`,
`access_token_expires_at`, `api_key_count`: a field ending in a
timestamp, date, count, expiry, TTL, length, version or "set" suffix.

### ets

**Fixed.** An ETS operation on a table held in the server's state
(`:ets.lookup(state.table, k)`, a `%{table: t}` head) names the table
the module stores under that field (`%{state | table: :ets.new(...)}`,
`%State{table: t}`, `Map.put(state, :table, t)`), where its `ets_op`
row said `"dynamic"` and joined no `ets_new`. A field that holds two
tables in the module names neither.

**Fixed.** `ets.ets_read_outside_owner` takes an Erlang `catch Expr` around the
read as the rescue it is (`catch` takes every class, a gone table's
badarg among them), as `structure.registry_race` already did for a
register's loser. The two analyses share one definition,
`rescues_argument_error` in `clientlib/exceptions.dl`. No finding over
the corpus and the four large programs moved.

**Changed.** `ets_missing_read_concurrency` and `ets_missing_write_concurrency` gain
`mod` and `site` columns and anchor at the table's `:ets.new/2`, as
`ets_ordered_set_contention` does; they were findings with no location.

**Changed.** `ets.ets_read_outside_owner` no longer counts `:ets.info/1,2` (it answers
`:undefined` for a table that is gone), takes `catch :error, :badarg` as
the rescue it is, and joins a table created under a computed name only
with reads whose table is also computed, not every read in the owner's
module.

### coupling

**Changed.** `coupling.dual_restart_authority` walks the intra-module call
graph back from the functions that start a dynamic child and the ones
that monitor it, instead of closing it over every function of the
program: 6.1M rows to 11 on a 751-module deps tree (the coupling solve
37s to 30s there). The call a coupling's witness makes into the sibling
is found walking back from the functions that call a coupled sibling
rather than forward from every witness (8.8k rows to 250 on blockster).
Output identical over the corpus and four large programs.

**Changed.** `coupling.sibling_dependency` "cached_pid" asks that a
handler use the cached pid: process points-to follows a handler's call,
cast or send to the process registered under the name init/1 looked up,
through anything but the name itself. It accepted any handler making
any call to a pid it could not follow, so a server that looked a sibling
up at boot and called whatever pid each caller handed it was reported.
Where the name resolves to no process points-to knows, the old test
stands in. Corpus, realtime, logflare, hexpm and OTP unchanged.

**Changed.** `coupling.sibling_dependency` ("restart_isolation",
"restart_policy") is not reported for a caller whose every call or cast
to the callee's module that process points-to resolves goes to an
instance the caller started for itself (`private_module_dep`, calls.dl):
a Pool's own `{:ok, conn} = Conn.start_link(...)` is not the Conn its
supervisor starts beside it. Corpus, realtime, logflare, hexpm and OTP
unchanged.

### shutdown

**Fixed.** `shutdown.teardown_touches_sibling` ("terminate/2 calls a
sibling that may already be down") asks whether the try that catches
the exit covers the sibling call, where it asked whether the function
had such a try anywhere. A terminate/2 that catches exits around one
call and makes the sibling call after the `end` was quiet, and is now
reported. The guard is the call's own: an exit-catching try (or one
naming `:noproc`) covering the sibling call, or any call on the path
from terminate/2 to the helper that makes it — terminate/2's call into
the helper, a call between helpers — within the rule's three calls. A
dependency with no call site to hold against a try, or a path through
a closure, keeps the function-wide reading, which errs quiet. The
finding's site is the unguarded call, and "terminate/2 reaches it from
here" the first call of an unguarded path. Erlang's `catch Expr` around
the call now guards it too. The path is a new `clientlib/reach.dl`
component, `ForwardGuardedCallReach`: bounded forward reach that stops
at a call its instance marks `guarded`, and reports each path's first
call.
The corpus tally is unchanged: oban#21's Watchman and Horde's
SignalShutdown (three checkouts) still fire, and no row arrives.

**Changed.** `shutdown.teardown_touches_sibling` does the same: a
`terminate/2` calling a connection the module started for itself
(`private_dep`), and a handler stopping one through the sibling's own
`stop/1` when every process it hands that function is such an instance,
no longer touch the supervised sibling. Corpus, realtime, logflare,
hexpm and OTP unchanged.

### coverage

**Changed.** `coverage_genserver_isolated` and
`coverage_named_process_unreachable` count traffic process points-to
follows to the module's process or the name's, through the pid a start
returned or a whereis found: a server called only that way was "a
GenServer with no observed traffic". coverage includes otp.dl (whose
forwarding wrappers also name targets) and extracts PidFlow and CallArgs. On
realtime, logflare, hexpm and OTP 20 such rows drop out (hexpm's
`Hexpm.Cache`, called through its server's pid; logflare's `Vault`).

### Corpus and tooling

**Added.** A corpus pair may name an `otp:` version beside `elixir:`:
the asdf installs of both lead the compile's `PATH`, with that Elixir's
own `MIX_HOME` (an archive built for one OTP does not load on another),
and the command is looked up on that `PATH`. A tree whose locked Erlang
dependency no longer builds on OTP 28 builds on the OTP it was written
for: sequin's rabbit_common on 27, astarte's (which uses `maybe` as an
atom) on 26. `Argus.Corpus.compile_env/1` is public. An OTP 26 install
needs hex and rebar3 placed by hand: its httpc rejects builds.hex.pm's
certificate.

**Added.** `Argus.Corpus` pairs take `subdir:` for a repository whose Mix project is
not at the root — `mix.exs` under `elixir/`, one app of an umbrella under
`apps/` — so a fix in such a tree can be a pair. The clone is still one
directory per `<repo>-<sha7>`; relaxing the Elixir requirement, building
and finding beams happen in the project, and an umbrella app's beams are
found in the umbrella's `_build`.

**Changed.** The closed-issue corpus keeps the facts of each checkout in
a store beside it (`.argus-facts`; see "A run redoes only what an edit
invalidates" for how it is keyed), so a warm run extracts nothing and
an edit re-extracts only what it reaches; `Argus.Corpus.analyze/2`
takes the pair and side and solves over the cache, and `analyze/1`, which
extracted a list of beams afresh, is removed (`Argus.run_analyses/2` does
that). Extraction was over
90% of a large tree's analysis and its inputs never move between runs.
`Argus.CorpusTest` analyzes each checkout once, `ARGUS_CORPUS_JOBS` (default
4) at a time, before checking the pairs. An entry under another digest is
pruned only once no run has touched it for an hour: a VM beside this one
may still be reading it. The suite's analysis tests run
`async: true`; the tests that set VM-wide state (`PATH`, `TYPESAFE_API_KEY`,
`ARGUS_PRIORS_DIR`) live in their own sync modules.

**Added.** `Argus.BeamDigest`: a compiled module's digest that names its
code, not the tree it was built in. It hashes every chunk but the
compile info, the docs and the Elixir checker's table (and the debug
info unless asked for), with the build root — the directory holding
the beam's `_build` — replaced by `$ROOT` in the literals, attributes,
debug info and line table, and the two fields derived from the bytes
(`FunT`'s `OldUniq`, a `vsn` attribute) cleared. A path outside the
build root still keys it.

**Fixed.** The corpus facts cache missed in every worktree but the one
that filled it: its key hashed the engine's beams byte for byte, and a
beam carries the absolute path it was compiled in. Code is keyed
through `Argus.BeamDigest` now (`Argus.Cache.Code`), so every worktree
of one commit shares the entries; a comment or `@doc` edit that moves
no line of the code a producer runs no longer re-extracts either. A second worktree at
the main checkout's commit tallies warm on its first run (184 s cold
before).

**Changed.** `Argus.Specs.environment_digest/1` hashes a dependency's
beams with `Argus.BeamDigest`, debug info included (it is where specs
are read from), so the same dependency built in two checkouts of one
project digests the same. The digest's value changes once: scry's
fingerprint, which folds it in, misses once on upgrade.

**Changed.** `mix argus.corpus tally` analyzes the checkouts
`ARGUS_CORPUS_JOBS` at a time (`Argus.Corpus.analyze_all/2`, which
`Argus.CorpusTest` uses too) instead of one after another, and each
checkout once: a tree two pairs share was counted twice. Its order no
longer depends on map iteration (count, then analysis and title). A
checkout that fails to build is reported on stderr instead of silently
dropped. `mix argus.corpus` runs in `MIX_ENV=test` by default, as the
gate does: the cache is keyed on the dependencies on the code path, and
a dev-environment tally extracted every checkout a second time.
`ARGUS_CORPUS_JOBS` that is not a positive integer raises.

**Changed.** Pruning a checkout's facts cache keeps the three most
recently used entries beside the one just installed and any touched
within the hour (`Argus.Corpus.stale_facts/2`), so the baseline of a
before-and-after tally survives the change it measures; a staging
directory a crashed run left is removed after a day. **Added.**
`mix argus.corpus prune [--keep N] [--dry-run]` applies the same policy
to every checkout and reports what it reclaimed.

**Fixed.** `Argus.Corpus.ensure/2` returned every beam twice when the
project is the repository root, and listed both a dev and a test build;
each beam once now, from one build.

**Changed.** `Argus.Souffle.input_relations/2` memoizes its answer for a program
shipped under `priv/dl`, versioned by a digest of every file there and
the solver binary's identity. The answer depends on nothing else, and
resolving it is a Souffle invocation per analysis (about 190ms each) that
scry paid six times on every cold compile and the suite paid on every
test that enumerates the analyses. A program outside `priv/dl` is still
read on every call.

**Changed.** `Argus.Facts.materialize/2` reads each id from the symbol
table once per call, through a call-local map as `decode/2` does,
instead of once per cell. Over the 650k rows of 300 logflare modules in
one call that halves it (1.2 s to 0.6 s); a caller that materializes
one relation at a time, as scry does, sees no difference either way.

**Changed.** `Argus.Tsv.escape/1` finds a field's special characters by
scanning its bytes instead of `:binary.match/2` over a four-pattern list,
which compiled the pattern on every call — every field of every fact row
argus or scry writes. Encoding the 652k fact rows of 300 logflare
modules drops from about 2.5 s to 0.4 s; the text is byte-identical.

## 0.19.0 — 2026-09-22

### Added

**Schema version 37.** Two Layer-2 relations from a new extractor,
`Argus.Extractors.ParamFlow`: `call_arg_derived(caller, callee, arg_pos,
param_pos)` — the argument is data-dependent on the caller's parameter,
a superset of `call_arg_forward` that follows destructuring, tuple and
binary construction, and the calls known to hand their argument's data
through (`ParamFlow.Propagators`); and `sink_arg_derived(id, func,
arg_pos, param_pos)`, the same at a sink site. Both come from
`Argus.Dataflow.reaching_uses/2`, reaching definitions with the
function's parameters as sources (`def_use_edges/1` is unchanged). Read
by `unsafe_input` only; scry and planchette memos keyed on the version
invalidate. Also public: `Argus.Extractor.Helpers.typed/1` (the decoded
facts the pipeline now attaches to `module_data`) and
`Argus.Extractors.ApiCalls.sink_mfas/0` / `sink?/1`.

`unsafe_input` gains a fourth proximity, `flow`: request data — one of
the entry's request-carrying parameters, as `request_param` in
`clientlib/request_entry.dl` spells them out — provably reaches the
sink's argument, chained backward from the sink by the `ParamReach`
component in `clientlib/reach.dl`. A flow is an error at any distance
and replaces the path rows for its site. A path the summaries cannot
confirm keeps its proximity: the summaries do not follow a local
helper's return or an element handed to a closure, so their silence is
not evidence that the data comes from elsewhere.

**Schema version 38.** `call_result(id, func, callee, fate, guard)` from
`Argus.Extractors.ErrorHandling`: one row per call to a process or OTP
API (or to anything that starts a process), with what became of its
result — `used`, `ignored`, `returned` for a tail call, `dynamic` — and
whether the site sits inside a `try`. Read by `failure` only.

`failure` gains `inconsistent_handling(func, site, callee, belief, agree,
deviate)`: a call site that breaks with the program's own convention for
its callee — every other site matches the result and this one discards
it (`result_checked`), or every other site wraps the call in a `try` and
this one does not (`exception_guarded`). No list says which results
must be checked; the other sites do (Engler et al., "Bugs as deviant
behavior", SOSP 2001). A belief needs three agreeing sites and the
deviants must be a quarter or fewer of the population; severity is the
z-score of the agreeing fraction against a coin flip, `:warning` from
about seven to one. Scoped to process APIs on purpose: a `File.write`
ignored once in twelve is not a BEAM bug class.

**Schema version 39.** Six Layer-2 relations for the check-then-act
races, and one removed. `name_lookup(id, func, api, scope, source, key,
checked)` replaces `whereis_call(id, func, name, checked)`: it also
covers `Registry.lookup/2`, and identifies the name the way
`Helpers.key_identity/3` does (a literal, a parameter, a map field), so
a create on the same name can be joined to it — `failure`'s
`unchecked_result` rows for `Process.whereis` are unchanged. New:
`creating_op(id, func, api, scope, source, key)` (a registration, a
named or via-registered start, `start_child`), `guarded_create(act,
check)` and `ets_guarded_write(write, read)` (the act runs only because
of a test on the check's result, from `Argus.Extractor.Guard` over the
control-dependence tree), `start_error_compared(func, atom)`, and
`ets_key(id, source, key)`. `clientlib/concurrency.dl` adds the
`RunsConcurrently` component: which seeded functions more than one
process can be running at once.

`structure` gains `registry_race(mod, func, lookup_api, create_api,
key, check, act)` and `ets` gains `ets_check_act(mod, func, name, key,
read, write)`: the read–decide–write races on the process registry and
on ETS that Christakis and Sagonas detected in 2010 and Dialyzer
reported until OTP 25 removed `-Wrace_conditions`. A lookup that decides
a start of the same name, where the loser's outcome is taken nowhere
and more than one process can run the function; a read that decides a
plain write of the same key on a public table another process can
write. `insert_new`, `update_counter` and `select_replace`, and matching
`{:error, {:already_started, pid}}`, are the fixes and stay quiet.
`ExUnit.Callbacks.start_supervised/1,2` and `start_supervised!/1,2`
count as a `start_child`: the shape is common in shared test helpers
(tesla#768, the corpus pair).

**Schema version 40.** A third layer of relations, priors: facts no
extractor emits. `Argus.Priors` asks a System-One model (typesafe.ai's
Jev, `Argus.Priors.Jev`) the questions bytecode cannot settle and writes
the answers into the facts directory after stage 0, each row ending in
`permille`, the model's probability in thousandths. The first relation is
`prior_sensitive(subject_kind, mod, name, kind, detail, permille)` — what
a schema field holds, `kind ∈ secret | personal | none` — filled by
`Argus.Priors.Questions.Sensitivity`, one request per schema with the
whole field list as state. `priv/dl/priors.dl` is generated beside
`base.dl` and `layer2.dl` and included by `clientlib/imports.dl`.

Off by default. `Argus.run_analyses/2` takes `priors: :off | :cached_only
| :live` and `priors_opts:` (`:oracle`, `:cache_dir`, `:model`,
`:batch_size`, ...). Every answer is kept in a content-addressed cache
under `ARGUS_PRIORS_DIR` (default `~/.cache/argus/priors`), keyed on the
model, the question and its prompt version as well as the request, so a
run in `:cached_only` mode is deterministic and offline; `mix argus.priors`
inspects, clears, exports and imports it as a cassette. `:live` without
`TYPESAFE_API_KEY` fails before extracting; an oracle error leaves the
relation empty and the run reports what it would have without priors.

The contract every rule that reads a prior keeps: a prior is a positive
premise only — it may add a finding or move a severity, never remove a
structural row — so findings with priors are a superset of findings
without, and priors off is byte-identical to before. Findings gain
`provenance` (`:structural | :heuristic`) and `confidence` (the prior's
permille, else `nil`); `Argus.Findings.new/4` takes both.

`exposure` reads it: `unredacted_secret_inferred(mod, field, kind, aware,
permille)` reports a field the substring table does not name but the
model does at 0.9 and above — `totp_seed`, `teams_key`, `secret_first` —
under the structural finding's title, a severity step down, labelled
heuristic with the probability. The calibration that set the threshold
(98% precision at 0.9 on fields read from beams and on public projects'
schema names; the other two families measured, and the tag-target family
parked as behaviour-polymorphic dispatch a rule should settle) is in
`spike/priors/FINDINGS.md`.

**Schema version 41.** `prior_reads(func, source, permille)`, the second
prior: which external source a function itself reads — `request`,
`storage`, `config`, `internal`, `passthrough` or `constant` — judged
from what it calls and its literals, its arguments not counting.
`Argus.Priors.Questions.Reads` asks it only about the functions that
hold a sink and are not request entries, the functions of one module in
one request. `unsafe_input`'s `sink_reachable` gains `source` and
`permille` columns (empty and 0 without a prior, and for a proven flow,
which needs none): a path row — adjacent or transitive — whose sink
function reads storage, configuration or the system's own state at 0.7
and above drops one severity step, labelled heuristic with what was read
and the probability. That is the sequin shape, a helper converting a
record loaded from Postgres, told apart from a helper converting whatever
it is handed; a `passthrough` answer changes nothing, and neither does
`request`, which the calibration did not measure. Sites, titles and
rows are the same with priors on or off.

**Schema version 42.** `prior_talks_to_process(mod, permille)`, the
third prior: the model's probability that calling a module's public
functions messages or waits on a long-lived process, asked by
`Argus.Priors.Questions.ProcessRole` about the modules with a call or
cast and no callback loop of their own. `coupling`'s `sibling_dependency`
gains `basis` and `permille`: `resolved` when a call or cast with a known
target connects the siblings, `inferred` when only the module-level
clause of `stateful_module_dep` does — the caller reaches some function
of the sibling and the sibling has a call somewhere — and `doubted` when
that inference is all there is and the prior puts the sibling at 0.3 or
below. A doubted row is the same finding one severity step down,
labelled heuristic: a helper with a call in its `start_link` reached for
a pure function, told apart from a facade reached through delegation,
which is the false-positive class the July corpus audit traced to that
clause. A resolved dependency is never doubted.

### Fixed

`def_use` had no edges through binary construction or binary matching:
`bs_create_bin` recorded no reads or writes, and the segment-extracting
commands of `bs_match` (`get_tail`, `integer`, `binary`, ...) recorded
no writes, so `"prefix" <> value` and `<<"pre_", rest::binary>> = value`
broke every chain that ran through them. Both now carry `def`/`use`
rows; gloss and planchette, which consume `def_use`, see the added
edges.

## 0.18.1 — 2026-09-21

### Fixed

Three compiler warnings in 0.18.0: the `evidence/2` clauses sat between
`finding/2` clauses in two analyses, and `finding_relations/1` took the
doc meant for `output_relations/1`.

## 0.18.0 — 2026-09-21

### Changed

The relations inside each concern merge the way the analyses did: a
mechanism is a column, not a relation, and a defect has one relation.
Titles, severities, anchors and finding counts are unchanged unless a
row below says otherwise; the retired analysis names keep resolving
through the alias table to the rows that were theirs (the alias table
itself is due to go in 0.19.0). Two mechanisms carry this: a relation's
`key` may be chosen by the value of a column (`{:kind, %{"unclear" =>
[:mod], default: [...]}}`), since the rows of a merged relation can
identify a finding differently per kind; and the Souffle output reader
keeps an empty first or last column, which a merged relation uses for a
column that does not apply. The output relations went from 97 to 59.

| Concern | Was | Now |
|---|---|---|
| `coupling` | `one_for_one_coupling`, `suspect_nonpermanent_dependency`, `cached_sibling_pid` | `sibling_dependency(sup, caller, callee, reason, detail, sup_site, witness, site)`, `reason` ∈ restart_isolation, restart_policy, cached_pid |
| `effects` | `purity_violated`, `effect_in_transaction` | `effect_in_context(func, context, scope, category, api, via)`, `context` ∈ pure_contract, transaction (`scope` is the repo) |
| `failure` | `swallowed_error`, `erpc_transport_unhandled`, `rpc_result_unhandled` | `unhandled_failure(func, site, kind, shape)`, `kind` ∈ rescue, erpc_transport, rpc, multicall, erpc |
| `failure` | `unchecked_start_child`, `whereis_race` | `unchecked_result(func, site, api, name)` |
| `failure` | `unlinked_spawn`, `exit_in_callback` | `orphan_process(func, site, kind, target)`, `kind` ∈ spawn, exit |
| `shutdown` | `cleanup_never_runs`, `cleanup_unclear`, `terminate_may_be_truncated` | `cleanup_defect(mod, behaviour, kind, category, api, via)`, `kind` ∈ never_runs, unclear, truncated |
| `shutdown` | `trap_exit_without_handler`, `trap_exit_without_exit_clause` | `unhandled_exit_signal(mod, kind, witness)`, `kind` ∈ no_handler, no_exit_clause |
| `shutdown` | `terminate_calls_sibling`, `callback_stops_sibling` | `teardown_touches_sibling(mod, sibling, phase, kind, via, sup)`, `phase` ∈ terminate, handler |
| `shutdown` | `deliberate_termination_while_monitored` | `kills_monitored_child(mod, site, kill_site)` (renamed) |
| `mailbox` | `handle_info_without_catchall`, `handle_info_partial`, `nolink_messages_unhandled`, `statem_timeout_unhandled`, `state_missing_info_catchall` | `partial_handler(mod, handler, source, missing, detail)`, `source` ∈ runtime, late_message, task_nolink, statem_timeout, statem_info |
| `mailbox` | `leaked_monitor`, `monitor_never_released`, `monitor_ref_discarded` | `unconsumed_monitor(mod, func, site, kind)`, `kind` ∈ timed_wait, never_released, ref_discarded |
| `mailbox` | `leaked_async_task`, `yield_on_linked_task`, `linked_task_in_library` | `task_result_defect(func, site, kind)`, `kind` ∈ never_awaited, yield_linked, linked_in_library |
| `mailbox` | `unhandled_self_message`, `never_replies`, `call_never_replied` | `reply_defect(mod, func, site, kind, tag)`, `kind` ∈ self_call, self_cast, dropped_from, statem_unreplied |
| `blocking` | `timeout_chain_risk`, `blocking_cast_handler`, `timeout_insufficient` | `call_chain(from, to, kind, depth, inferred, caller_ms, downstream_ms)`, `kind` ∈ chain, cast, budget |
| `blocking` | `infinity_timeout_in_chain`, `rpc_without_timeout`, `rpc_in_genserver_callback`, `global_blocking_op` | `unbounded_wait(func, site, kind, api, detail)`, `kind` ∈ infinity, rpc, rpc_in_callback, global |
| `blocking` | `blocking_receive_in_callback`, `receive_in_callback` | `receive_in_callback(id, func, callback, behaviour, proximity, bounded)` |
| `startup` | `sync_call_in_init`, `init_deadlock_risk`, `wrong_start_order`, `sup_call_in_init`, `init_waits_on_blocking_server`, `continue_to_later_sibling`, `continue_to_parent_supervisor`, `global_blocking_in_init`, `distributed_in_init` | `blocks_on_peer(mod, phase, dep, kind, ordering, sup, site, detail)`; `phase` ∈ init, continue; `kind` ∈ call, cast, sup, blocking_server, parent, global, remote. **One finding where there were two**: an init that calls a sibling starting later was both a deadlock (`init_deadlock_risk`) and a wrong start order (`wrong_start_order`); it is the deadlock now, with the tree definition as a related frame. |
| `startup` | `blocking_recv_in_init`, `connect_in_init_without_backoff` | `unbounded_effect_in_init(mod, kind, api)`, `kind` ∈ recv, connect |
| `startup` | `init_timeout_deferral`, `continue_crash_loop_risk` | `deferral_defect(mod, kind, site, detail)`, `kind` ∈ init_timeout, continue_catch |
| `startup` → `blocking` | `mutual_continue_deadlock` | `call_cycle(mod_a, mod_b, witness_a, witness_b, phase)` with `phase` = continue; `deferred_startup_deadlock` resolves to it |

### Removed as findings

Three relations were witness lists dressed as findings: the edges of a
call cycle (`call_cycle_path`, "Cycle edge: A → B"), the callers of a
high-fan-in server (`bottleneck_caller`, "Caller of a high fan-in
GenServer") and the endpoints that reach a sink (`sink_endpoint`, "GET
/path reaches …"). They are **evidence** now: an output relation may
declare `evidence: %{of: relation, on: join_columns}`, and its rows
become related frames of the finding they join through the analysis's
new `evidence/2` callback. The cycle, the fan-in and the sink are the
findings; their frames name the edges, the callers and the routes.
Consumers that build findings from solved rows themselves use
`Argus.Findings.build/2`, which applies this; `Argus.Analysis.finding_relations/1`
lists the output relations that are findings.

## 0.17.2 — 2026-09-21

### Fixed

`mix argus.migrate encore` sliced the manifest with `String.slice` on
byte offsets, which corrupted any file with a multi-byte character
before the block.

### Changed

`mix argus.migrate encore` rewrites only the pinned-count maps it
migrates (`--analyzer a,b` narrows them to the analyzers that already
report the concerns), so the comments in a manifest survive; a zero
pinned under a name that spans several concerns lands as a zero under
each of them instead of being listed for hand measurement.

## 0.17.1 — 2026-09-21

### Fixed

The `v0.17.0` tag left `mix argus.migrate` (`Argus.Migrate`) out of the
release; this tag carries it. Nothing else changes.

## 0.17.0 — 2026-09-21

### Changed

One analysis per concern. An analysis answers "what goes wrong";
mechanism, phase and proximity are columns on a relation, never
separate analyses, and a defect has one owner. The retired names keep
working for two minor versions: `Argus.run_analyses(analyses: [old])`
runs the concern the old name's findings live in, reports the rows that
were its under the old name, and sets the new `concern` field on every
finding to the analysis it belongs to today (`Argus.Analysis.aliases/0`
is the table). Named sets (`:all`, `:default`, `:security`, `:effects`,
`:otp`) can stand in for a list (`Argus.Analysis.sets/0`). `mix
argus.migrate encore MANIFEST` carries an encore manifest's pinned
counts over through the same table, and lists the ones that span
several concerns for measuring by hand.

| Retired | Now | Notes |
|---|---|---|
| `atom_safety` | `unsafe_input`, `sink_without_request_path` | a sink a request reaches is reported once, by proximity, not again as export-reachable |
| `request_surface` | `unsafe_input`, `sink_reachable` (+ `sink_endpoint`) | the three `remote_*` relations are one, with the sink as a column |
| `unbounded_dynamic_children` | `unsafe_input`, `unbounded_children_from_request` | unchanged |
| `secret_exposure` | `exposure`, `unredacted_secret` | unchanged |
| `tls_verification` | `exposure`, `disables_verification`, `relies_on_default_verification` | unchanged |
| `purity` | `effects`, `purity_*`, `impure_closure_to_pure` | unchanged |
| `transaction_safety` | `effects`, `effect_in_transaction` | unchanged |
| `timeout_chain` | `blocking`, all four relations | unchanged |
| `call_cycle` | `blocking`, `call_cycle`, `call_cycle_path` | unchanged |
| `process_bottleneck` | `blocking`, `sync_call_fan_in`, `bottleneck_caller` | unchanged |
| `callback_receive` | `blocking`, `blocking_receive_in_callback`, `receive_in_callback` | unchanged |
| `distributed` (part) | `blocking`, `rpc_without_timeout`, `rpc_in_genserver_callback`, `global_blocking_op` | unchanged |
| `error_handling` (part) | `blocking`, `partial_noproc_catch` | unchanged |
| `one_for_one_coupling` | `coupling`, `one_for_one_coupling` | unchanged |
| `supervision` (part) | `coupling`: `suspect_nonpermanent_dependency`, `cached_sibling_pid`, `rest_for_one_orphaned_children`, `dual_restart_authority`; `structure`: `supervisor_registered_as_worker`, `consumer_supervisor_permanent_child` | unchanged |
| `process_registry` (part) | `structure`, `duplicate_process_name` | unchanged |
| `distributed` (part) | `structure`, `global_register_risk` | unchanged |
| `sync_call_in_init` | `startup`, all six relations | unchanged |
| `deferred_startup_deadlock` | `startup`, all five relations | unchanged |
| `supervision` (part) | `startup`, `wrong_start_order`, `post_start_initialization` | unchanged |
| `distributed` (part) | `startup`, `global_blocking_in_init`, `distributed_in_init` | unchanged |
| `error_handling` (part) | `startup`, `ignored_start_result` | unchanged |
| `shutdown_safety` | `shutdown`, all six relations | unchanged |
| `supervision` (rest) | `shutdown`, `permanent_child_stops_normally` | supervision is retired; its alias spans coupling, structure, startup and shutdown |
| `error_handling` (part) | `shutdown`, `trap_exit_without_handler`, `trap_exit_without_exit_clause` | unchanged |
| `monitor_leak` (part) | `shutdown`, `deliberate_termination_while_monitored` | unchanged |
| `distributed` (rest) | `failure`, `erpc_transport_unhandled`, `rpc_result_unhandled` | distributed is retired; its alias spans blocking, structure, startup and failure |
| `error_handling` (part) | `failure`, `swallowed_error`, `exit_in_callback` | unchanged |
| `unsafe_task` (part) | `failure`, `unchecked_start_child` | unchanged |
| `unlinked_spawn` | `failure`, `unlinked_spawn` | unchanged |
| `process_registry` (rest) | `failure`, `whereis_race` | process_registry is retired |
| `error_handling` (rest) | `mailbox`, `handle_info_without_catchall`, `handle_info_partial`, `timer_cancel_without_flush` | error_handling is retired; its alias spans blocking, startup, shutdown, failure and mailbox |
| `unsafe_task` (rest) | `mailbox`, `nolink_messages_unhandled`, `leaked_async_task`, `yield_on_linked_task`, `linked_task_in_library` | unsafe_task is retired |
| `monitor_leak` (rest) | `mailbox`, `leaked_monitor`, `monitor_never_released`, `monitor_ref_discarded` | monitor_leak is retired |
| `message_contract` | `mailbox`, `unhandled_self_message` | unchanged |
| `reply_contract` | `mailbox`, `never_replies` | unchanged |
| `gen_statem` | `mailbox`: `state_missing_info_catchall`, `statem_timeout_unhandled`, `call_never_replied`; `state_machine`: `unreachable_state`, `terminal_without_stop` | the reply and timeout rows are mailbox defects that happen to be in a statem |

## 0.16.0 — 2026-09-21

### Changed

- Reachability over the call graph is one vocabulary: the components in
  `priv/dl/clientlib/reach.dl` (`CallReach`, `SameProcessReach`,
  `ClosureReach`, `IntraModuleReach`, their set forms, the forward forms
  and a depth-bounded one). The thirty closures the analyses used to
  write by hand are instances seeded with the sites each rule cares
  about; findings are unchanged on the corpus, the 14-tree sample and
  encore. A declarations test now refuses a rule in an analysis file
  that recurses over `call_edge` on its own head.
- Five more vocabulary files under `priv/dl/clientlib/`, each replacing
  spellings that several analyses kept of their own: `closures.dl`
  (`enclosing_function`, `sole_closure`), `receive.dl` (`receives`,
  `blocking_receive`, `timed_receive`, `receives_message`),
  `exceptions.dl` (`catches_class`, `site_catches_class`), `effects.dl`
  (`durable_effect`, the one list behind shutdown safety's cleanup and
  transaction safety's unrollbackable effects; `slow_effect`,
  `structural_call`, `config_writer`, `config_write_api`,
  `removal_api`) and `process.dl` (`process_module`, `statem_process`,
  `has_handle_info`, `mailbox_handler`, `partial_handle_info`; the
  gen_statem `process_entry` extension is `process_statem.dl`, included
  by the analyses that read `statem_event_clause`). `peer_call` moved to
  `calls.dl`. Findings unchanged. The recursion guard now covers
  `closure_def` too.
- The supervision, startup and entry vocabulary: `supervision.dl` gains
  `sibling`, `sup_management_call` (every `sup_call` but GenServer.stop,
  replacing eight `api != "GenServer"` guards) and the op tables
  `child_creating_op`, `unbounded_sup_op`, `stopping_sup_op`;
  `startup.dl` names `deferral_path(mod, kind)` (timer, self, continue,
  statem_timeout); `sinks.dl` the unsafe deserialization classes that
  atom_safety and request_surface each listed; `calls.dl`
  `module_sync_dep`; `entries.dl` `init_dep`, `handler_dep` and
  `continue_dep`, one relation per entry so a consumer reads only its
  own entry's facts. message_contract reads `call_tag`,
  `handle_call_function` and `handle_cast_function` instead of its own
  copies. Findings unchanged.

## 0.15.0 — 2026-09-16

### Changed

- `timer_cancel_without_flush` follows the timer through the state
  instead of pairing any cancel with any bare timer in the module. The
  ref an arm site produces is traced to the map key it is stored under
  (`timer_ref`, `returns_call`, `timer_store`, through arming helpers and
  default-argument wrappers), the ref a cancel site takes is traced to
  the key it was read from (`timer_cancel`, `call_arg_field`), and a
  cancel pairs with an arm only on the same key. The flush must be a
  receive that names the armed message or matches anything
  (`recv_pattern`). The finding names the key and the message, one per
  timer. A module with a heartbeat and a reconnect timer now gets two
  verdicts, and a receive that drains some other message no longer
  counts.
- Schema version 36: `timer_arm` gains a `literal` column;
  `timer_ref`, `timer_cancel`, `timer_store`, `returns_call`,
  `recv_pattern` and `call_arg_field` added.

## 0.14.1 — 2026-09-16

### Fixed

- `timer_cancel_without_flush` now treats any receive in the module as
  the flush, including the idiom from the `cancel_timer/1` docs: a
  blocking receive taken only when the cancel returned `false`. Before,
  only an `after 0` receive counted, and encore's ostinato tripwire was
  reported.

## 0.14.0 — 2026-09-16

### Added

Six rules for the bug classes hypothesized after the issue-mining pass
and validated against closed issues, each with a corpus pair or a live
instance:

- `distributed`'s `rpc_result_unhandled` (`:warning`): an `:rpc.call` /
  `:rpc.multicall` result matched by shape with no `{:badrpc, _}` clause
  (rabbitmq-cli#193, phoenix_live_dashboard#218, livebook#972), or used
  as a boolean, where the tuple is truthy — and an `:erpc.call` in a
  boolean context with no rescue for `{:erpc, :noconnection}` (horde
  30bb1a1). New fact `rpc_result(id, func, handling)`.
- `error_handling`'s `timer_cancel_without_flush` (`:warning`): a
  process cancels a timer and arms one whose message carries nothing
  that identifies it, with no flush (MongooseIM#3502, beam-bots/bb#214;
  nebulex's generation heartbeat, cachex's warmer). `mailbox_writer`
  gains the kinds `timer_bare` and `cancel`; the new fact
  `timer_arm(id, func, target, message)` says whether the timer targets
  `self()` and whether its message is a literal, a parameter the callers
  fill (resolved through `call_arg`), or computed. A helper module that
  arms and cancels timers for its caller counts as the owner (BB.Loop).
- `unsafe_task`'s `nolink_messages_unhandled` (`:warning`): an
  `async_nolink` task started from a callback and not collected there,
  whose `{ref, result}` or `{:DOWN, ...}` has no `handle_info/2` clause
  (archethic-node#1306, sentry-elixir#172, Engram#1552). New facts
  `callback_ref_head` and the `task_nolink` writer kind.
- `sync_call_in_init`'s `connect_in_init_without_backoff` (`:warning`):
  init/1 reaches a network connect and the module arms no timer and
  continues nowhere after init (tortoise#46, grpc-elixir#557,
  newrelic/elixir_agent#181).
- `shutdown_safety`'s `callback_stops_sibling` (`:warning`): a handler
  stops a sibling child the supervisor owns, through `GenServer.stop`
  or the sibling's own stop API (horde#154, #193). `GenServer.stop` is
  a `sup_call` now.
- `supervision`'s `cached_sibling_pid` (`:info`): init/1 looks a sibling
  up by name under a `:one_for_one` supervisor and the handlers call a
  pid held in state (k8s 99c05d6 is the shape; oban#1413/#1499 its
  inverse).

Two hypothesized classes were dropped on the evidence: a late
`GenServer.call` reply into a changed state cannot happen since OTP 24
(process aliases, erlang/otp#2735), and no caller-side crash on a
server's unexpected reply shape was found anywhere.

### Changed

- `gen_statem`'s `statem_timeout_unhandled` now reports a generic
  timeout (`{{:timeout, name}, ms, content}`) whose `{:timeout, name}`
  event has no clause, as kind `generic_timeout`; before, only literal
  action lists produced a `generic` fact and any 3-tuple action counted
  as one. Generic timeouts built at runtime, single literal actions, and
  clause heads comparing the event type to a literal tuple are now
  extracted, which also lets a gen_statem's backoff timer count as a
  reconnect path for `connect_in_init_without_backoff`
  (Postgrex.ReplicationConnection).

- Schema version 35: `rpc_result`, `callback_ref_head` and `timer_arm` added; no
  existing relation changed.

## 0.13.2 — 2026-09-16

### Fixed

- `gen_statem`'s `statem_timeout_unhandled` counted any 3-tuple headed
  `:timeout` as an armed event timeout — a `{:timeout, ref, payload}`
  built to send, or the `{:timeout, name}` inside a generic timeout
  action. An armed timeout is now one that flows into the callback's
  return (DBConnection.Connection and Finch.HTTP2.Pool were reported at
  error severity for timeouts they handle).
- `supervision`'s `dual_restart_authority` requires the monitor to be of
  the started child: `monitor_call`'s target is now `"started_child"`
  when the pid came from a supervisor start, directly or through a
  local wrapper (Oban.Queues monitors its notifier and restarts queues
  from a signal — two processes, not two authorities). `:erlang.monitor/2`
  resolves its second argument, not the `:process` type in its first.
- `System.monotonic_time/1` and its siblings are time effects, not port
  operations; `shutdown_safety`'s `cleanup_never_runs` no longer reports
  a terminate/2 that only timestamps and logs (Phoenix.LiveView.Channel).

### Added

- Three present-only corpus pairs for shapes found on the trees rather
  than in an issue: cachex's router `:rpc.call/4` without a timeout,
  horde's shutdown signaller calling a sibling unguarded from
  terminate/2, nebulex's bootstrap taking a `:global` lock in init.

## 0.13.1 — 2026-09-16

### Fixed

- `callback_total` is now a path walk over the clause heads
  (`Dispatch.total_on?/2`): a fail edge on the message opens the next
  clause, a fail edge on the state is the next clause only when its
  target begins with tests (a body's `state.field` fallback begins with
  a call), registers projected from the message carry across clauses,
  and a clause inherits the message tests its predecessor passed (two
  `{:DOWN, ref, _, _, _}` clauses share a prefix). A linear scan had
  read Redix.SocketOwner's handle_info/2 — every clause a message shape
  plus a state pattern — as a catch-all, and DBConnection.Watcher's and
  Postgrex.TypeServer's the same way.
- A message the process sends itself counts as a late-message source
  when it is Elixir's `send/2` (a call to `:erlang.send/2`), not only
  Erlang's `!` (the `send` opcode).

## 0.13.0 — 2026-09-16

### Added

- The closed-issue corpus is part of the test suite. `test/corpus/pairs.exs`
  lists sixteen issue pairs; `Argus.CorpusTest` clones and compiles each
  tree once into `ARGUS_CORPUS_DIR` and asserts the rule's finding is
  present before the fix and absent at it. `mix argus.corpus fetch|tally`
  warms the cache and tallies titles across the trees; `mix argus.pins`
  regenerates the per-analysis input pins, now a data file
  (`test/argus/analysis_inputs.exs`) rather than a map in the test.

### Changed

- Schema version 34. `catch_tag` gains a `class` column and is emitted
  per catching clause rather than per handler region, so a rule can ask
  "is there an `:exit` clause for `:shutdown`" instead of "does
  `:shutdown` appear anywhere". `rescue X` now counts as a tested clause
  with tag `X` (the `__struct__` read before `Exception.normalize/3` is
  a projection of the reason), so `ets_read_outside_owner` accepts only
  a rescue that would catch ArgumentError as a guard. `catch_handler` is
  dropped (no rule read it). `matches_down` now means a clause head, not
  any comparison in the body.
- `call_never_replied`'s walker keys revisits on the `from`/event alias
  sets too, so a block re-entered with `from` elsewhere is not pruned.
- `handle_info_partial` needs a late-message source in reach of the
  process's callbacks: a timed `GenServer.call` (its late reply), a
  `Task.async`, a timer (`send_after`, `send_interval`), a subscription,
  a message the process sends itself, or caller-supplied code run through
  a closure or `apply` (gen_stage#238's producer ran the user's stream).
  New fact `mailbox_writer(id, func, kind)`. A partial handle_info with
  nothing that writes the mailbox is a style note and stays quiet.
- `ets_read_outside_owner` follows a table name through parameters:
  `defp fetch(table, key), do: :ets.lookup(table, key)` called with a
  literal is a read of that table by the caller. New fact
  `ets_op_param(id, pos)`.
- `blocking_recv_in_init` also reports a `receive` with no `after` on
  init's path. `foreign_dynamic_children` also counts tasks started
  under another tree's Task.Supervisor (`dynamic_child` records the
  child as `"Task"`), and no longer reports a start function that lives
  in the supervisor's own module (`Postgrex.TypeSupervisor.start_server/2`):
  that tree is offering a shared service.
- `terminate_calls_sibling` no longer reports a call under a `catch`
  that takes the `:noproc` exit (oban's own fix), and a quiet-shapes
  fixture pins the nearest non-bug neighbour of every rule from the
  issue-mining pass.
- `callback_total` means a clause accepts every *message*, whatever it
  demands of the state: `handle_info(msg, {stack, continuation})` is a
  catch-all (gen_stage's fix for #238), where the old check required a
  clause that accepts every argument.
- Tag resolution of dynamic call targets is stricter and shows its
  work. A tag is no longer attributed by uniqueness when it is generic
  (`:get`, `:stop`, `:state`, ...) or when some `handle_info/2` also
  matches it; when several modules handle a tag, the one the caller's
  module refers to statically (its start_link, its API) wins. Cycle
  edges (`call_cycle_path`) and chains (`timeout_chain_risk`) carry a
  new column, `"tag"` or `"static"`, and their findings say when an
  edge is inferred from a tag. Both are positional output changes for
  readers of those relations.

## 0.12.1 — 2026-09-16

### Fixed

- `shutdown_safety`'s `foreign_dynamic_children` and `ets`'s
  `ets_read_outside_owner` attribute code to the process whose callbacks
  reach it, not to the module it sits in: a plain helper module that
  starts children for a GenServer in the same tree (encore's canon) is
  no longer reported. The closures run backwards from the start/table
  functions, so their size is bounded by those functions, not by every
  process's reach. New clientlib relation `process_entry(mod, func)`.
- `gen_statem`'s `call_never_replied` no longer reports a clause that
  parks `from` at the head of a tuple (`pending: {from, expected}`) or
  reads it from a register the event was saved to.

## 0.12.0 — 2026-09-16

### Added

- **Dynamic call targets resolved by message tag.** Most `GenServer.call`s
  target a pid or a name held in state, which the extractor reports as
  `dynamic`; on horde that hid a deadlock cycle whose every edge was such
  a call (elixir-horde/horde#217). Stage 0 now stages `call_tag` — the
  tuple tag or atom each call/cast sends — and the clientlib attributes a
  dynamic-target call to the one GenServer module whose handler
  discriminates on that tag (`tag_resolved_call`; ambiguity attributes
  nothing). `call_cycle`, `sync_call_in_init`, `timeout_chain`,
  `process_bottleneck`, `one_for_one_coupling` and `supervision` see the
  edges. Stage 0 writes a fourth file, `call_tag.facts`.

- `error_handling`'s `handle_info_partial` (`:info`): a GenServer or
  GenStage whose handle_info/2 matches specific messages and has no
  catch-all, even when nothing in the module invites runtime messages —
  a library's late reply crashed a Flow producer (gen_stage#238), a
  restart loop re-sent a start-up message (cachex#314), a stray message
  killed a process manager (commanded#332). The warning-grade
  `handle_info_without_catchall` now also covers GenStage.

- `shutdown_safety`'s `terminate_calls_sibling` (`:warning`): terminate/2
  synchronously calls a sibling child of the same supervisor, which the
  supervisor may already have stopped (oban#21: the Watchman pausing its
  Producer, `:noproc` inside terminate/2).
- `shutdown_safety`'s `foreign_dynamic_children` (`:warning`): a process
  starts children under a DynamicSupervisor in another tree and its
  terminate/2 does not stop them, so they outlive it (the shape behind
  postgrex#763; that instance passes the supervisor through a GenServer
  message and is not yet resolved).

- `supervision`'s `consumer_supervisor_permanent_child` (`:warning`): a
  ConsumerSupervisor child template with `restart: :permanent`, which
  restarts every child that finishes its event (gen_stage#195). The
  extractor now reads ConsumerSupervisor trees.
- `supervision`'s `dual_restart_authority` (`:warning`): a process starts
  a permanent child under a DynamicSupervisor, monitors it, and starts it
  again from its :DOWN handler, so a child that stops on a semantic error
  crash-loops under two restart authorities and takes the tree with it
  (redix#334). New fact `child_spec_restart(mod, restart)` records what a
  module's own child_spec/1 declares, so a `:temporary` child is exempt.
- `supervision`'s `post_start_initialization` (`:info`): shared state (a
  persistent_term, an ETS row, application env) written only after
  `Supervisor.start_link` returned, while the children are already running
  (phoenix#5981). New fact `post_start_call(func, site, callee)`.

- `error_handling`'s `partial_noproc_catch` (`:warning`): a peer call
  wrapped in `catch :exit, {:noproc, _}` with no clause for
  `{:shutdown, _}` — the peer stopping mid-call is the same condition
  and crashes the caller (phoenix_live_view#4359).
- `distributed`'s `erpc_transport_unhandled` (`:warning`): a rescue
  around `:erpc.call` that unwraps `{:exception, _, _}` in a `case` with
  no clause for `{:erpc, reason}`, so a node going away is a
  CaseClauseError (nebulex#140).
- `ets`'s `ets_read_outside_owner` (`:info`): a table created by a
  process's callbacks with no heir, read by a function its callbacks do
  not reach — the module's API, run in callers — with no rescue; during
  the owner's restart the read raises in the caller (redix#338).
- `sync_call_in_init`'s `blocking_recv_in_init` (`:warning`): init/1
  reaches a `:gen_tcp`/`:ssl` `recv` with `:infinity`, following the
  timeout through wrapper parameters (postgrex#746).
- New facts behind those: `catch_handler`, `catch_total`, `catch_tag`,
  `catch_falls_through` and `try_call` — what a `try` handler catches,
  from a path walk over its clauses (`Argus.Extractors.ErrorHandling.CatchClauses`).

- `gen_statem`'s `call_never_replied` (`:warning`): a `{:call, from}`
  clause that returns without a reply action, without postponing, and
  without keeping `from` — the caller of `:gen_statem.call/2` waits
  `:infinity` by default (sneako/finch#213: a cancel while disconnected
  blocked for days). Schema 32 adds `statem_call_unreplied`.

- `unsafe_task`'s `yield_on_linked_task` (`:warning`): a task started with
  `Task.async`/`Task.Supervisor.async` and collected with `Task.yield` or
  `yield_many` in a process that does not trap exits — the link delivers
  a crash before the `{:exit, _}` branch can run (whatyouhide/redix#317).
  And `linked_task_in_library` (`:info`): `Task.async` in a plain
  library function, linked to whichever process called it
  (elixir-ecto/ecto#2246).

### Changed

- Schema version 33: eight layer-2 relations added — `child_spec_restart`,
  `post_start_call`, `matches_down` (a function that compares something
  to `:DOWN`, emitted for every function so a gen_statem's private :info
  helpers count), `catch_handler`, `catch_total`, `catch_tag`,
  `catch_falls_through` and `try_call`; no existing relation changed.

- `call_cycle`, `process_bottleneck`, `timeout_chain`, `sync_call_in_init`
  and `message_contract` no longer read `def_use`, `tuple_literal` or
  `literal_value`: the tag comes staged. Those are positional relations,
  so a body edit no longer re-solves them.

### Fixed

- `message_contract` no longer reports a dynamic-target call whose tag
  another module's handler discriminates on as a message the caller
  sends itself.

## 0.11.0 — 2026-09-16

### Changed

- The package is `panoptes` (Argus Panoptes; `argus` is taken on Hex)
  and so is the OTP application: depend on `{:panoptes, "~> 0.11"}`. The
  modules keep the `Argus` namespace. Anything that named the application
  (`Application.spec(:argus, :vsn)`, `:code.priv_dir(:argus)`) names
  `:panoptes` now.

### Removed

- `mix argus` and `scripts/analyze_project.exs`, with `Argus.Report`.
  Scry's Mix compiler is the way to run the analyses over a project —
  incremental, and reporting through compiler diagnostics; this package
  is the engine and its in-VM API. `mix argus.gen.dl` stays: it is a
  maintainer task for this tree.

## 0.10.0 — 2026-09-16

### Added

- `Argus.Symbols`: an interning table for fact symbols, and
  `Argus.Pipeline.extract/2` with `format: :interned` — rows as tuples
  of symbol ids and integers, interned in the extracting worker against
  the `symbols:` table the caller owns. `Argus.Facts.intern/2`,
  `materialize/2` and `decode/2` convert between the raw, interned and
  typed forms. On a 226k-row module the rows take 9 MB of heap instead
  of 39 MB (3 MB instead of 24 MB serialized), an ETS round trip is 9 ms
  instead of 60 ms, and typed decoding — instruction IDs parsed once per
  symbol and cached on the table — takes 0.36 s instead of 1.2 s. The
  table is pluggable (`Argus.Symbols.Store`) so a consumer that persists
  rows can persist the ids' meaning with them; the default is ETS.

## 0.9.1 — 2026-09-16

Schema 31: `whereis_call` gains a `checked` column.

### Fixed

- `process_registry`'s `whereis_race` no longer flags every
  `Process.whereis/1`. The extractor reads the straight-line code after
  the call for a comparison against nil/`:undefined`, a type test or a
  `select` that lists nil, and records the result in the new `checked`
  column; only unchecked results are findings. `case Process.whereis(n)
  do nil -> ...` (nerves_hub_link's error-report collector) was a false
  positive.
- `atom_safety`'s `code_injection_risk` skips `System.cmd/2,3` with a
  literal command whatever its arguments: argv is never shell-parsed, so
  caller data in it is not code execution. A literal shell or
  interpreter (`sh`, `bash`, `python`, ...) with non-literal arguments
  still counts. `System.cmd("free", [])` was flagged because the empty
  argument list is the atom `nil` in bytecode, which the old guard did
  not accept as static.

## 0.9.0 — 2026-09-12

### Changed

- Fact extraction streams each module's rows to the `.facts` files as it
  completes instead of merging the whole program in memory first. On a
  2,400-module project the extracting VM peaked at 5.8 GB; the whole
  fact set never exists in memory at once now.
- `Argus.Analysis.extract_facts/3` stages only the relations a Souffle
  program reads. The sixteen layer-1 relations that exist for the
  in-process control-flow and dataflow passes (`instruction`, `next`,
  `def`, `use`, `move`, ... — `Argus.Schema.in_process_only/0`) are
  written as empty files; they were three quarters of the fact volume.
  `Argus.Pipeline.run/3` still writes everything unless given
  `relations:`.
- No built-in analysis reads `call_reachable` any more. The closure is
  quadratic in the call graph (17M rows from 100k edges on the same
  project, ~500 MB in every solve that touched it), and every question
  the analyses asked of it — which functions reach a sync dependency, a
  supervisor call, an exit, an effect, a sink — is answered by
  propagating over `call_edge` from the few functions that matter. The
  clientlib's `reaches_sync_dep`, `reaches_async_dep`,
  `reaches_sync_dep_timeout`, `module_reaches`, `stateful_module_dep`
  and `genserver_sync_api` are derived that way (new helpers
  `reaches_module`, `reaches_sync_caller_in`), and each analysis that
  joined the closure directly has its own root-driven relation. Same
  rows out; the eighteen solves that took 450-690 MB and 12-17 s each
  now take under 60 MB and under 2 s. `same_process_reaches` is gone
  (`monitor_leak` propagates over non-closure edges instead);
  `call_reachable` stays declared for custom programs.
- `Argus.Findings.run/2` caps concurrent Souffle solves at four by
  default (`:concurrency` overrides it). Every solve holds its own copy
  of the call graph's closure, so running one per scheduler multiplied
  a project-sized footprint by the core count.

### Fixed

- `mix argus` removes its work directory when it finishes. Each run left
  the staged facts (hundreds of megabytes on a large project) in the
  temp directory.

## 0.8.1 — 2026-09-12

### Changed

- `mix argus` and `scripts/analyze_project.exs` fail before extracting
  anything when the `souffle` binary is missing, with a message that says
  where to install it (`Argus.Souffle.not_found_message/0`).

## 0.8.0 — 2026-09-12

Schema version 29. A consolidation release: nothing an analysis reports
changes unless a section below says so.

### Changed

- Schema version 30: `tuple_literal` is a layer-1 fact emitted by
  `Argus.Pipeline.Emit` (it is generic bytecode; the extractor that
  produced it is gone), and `rpc_call`'s timeout column spells
  `:infinity` as `-1` and an unreadable value as `0`, as
  `sync_call_timeout` always has.
- One rule vocabulary. `priv/dl/clientlib/calls.dl` defines `sync_dep`,
  `reaches_sync_dep` (with async and timeout twins), `stateful_module_dep`
  and `same_process_reaches` once; `callbacks.dl` defines `otp_callback`,
  `init_function`, `handler_function` and `terminate_callback`;
  `behaviours.dl` carries `process_behaviour` with its `loop`,
  `gen_server_like` and `terminating` kinds; `supervision.dl` gains
  `starts_before`. `otp.dl` is the one prelude. Eleven analyses had each
  derived "this function waits on that module" by hand and no two agreed;
  the analyses shrink onto the shared definitions and every encore golden
  is byte-identical. `resolved_calls.dl` adds the self-directed rows to
  `sync_dep` for analyses that accept value flow; `sync_call_target` is gone.
- One extraction pass. The pipeline indexes every call site once per
  module (`Argus.Extractor.CallSites`) and attaches the per-function
  control-flow graphs; extractors filter the index
  (`Helpers.each_remote_call/3`) instead of each walking the instruction
  stream, and walk control flow through `Argus.Cfg.Walk` instead of three
  private copies of the loop. `Helpers.return_shapes/1` replaces six
  return-tuple scanners; `Argus.Extractor.Dispatch` reads clause heads.
- `Argus.Extractors.ApiCalls` is one table-driven extractor for every
  "call to a known API, with an argument read back" fact — the process
  calls (`sync_call`, `async_cast`, `sup_call`, `sync_call_timeout`),
  atom safety, ports and distribution. It replaces the AtomSafety, Ports,
  Distributed and GenEvent extractors and the call tables in OTP.
- `Argus.Extractor` gains `relations/0`; `Argus.ExtractorRelationsTest`
  holds every declaration to the schema and to the rules.
- `Argus.Analysis.run/3` filters its results to the analysis's declared
  outputs and removes its work directory; `Argus.Souffle.run/3` removes
  the output directory it created; `Argus.Findings.run/2` takes a
  `:facts_dir` to evaluate an existing extraction and cleans up its own.
  `scripts/analyze_project.exs` extracts once for every analysis instead
  of once per analysis plus twice more.

### Fixed

- `ets.dl` matched the declared behaviour string, so an Erlang
  `-behaviour(application)` module owning a table was reported as
  unprotected.
- Via-named call targets (`"via:Registry"`), which no rule can resolve to
  a module, no longer reach findings as if they were one.
- gen_statem state-function IDs were minted from `String.to_atom/1` of
  the module's inspected name and were unresolvable.

### Removed

- The autoresearch loop (`Argus.Autoresearch`, `mix argus.autoresearch`,
  `.autoresearch/`) and the batch scripts `scripts/harness.exs` and
  `scripts/analyze_all.sh`. `scripts/analyze_project.exs` remains.
- `Argus.Origins`, `Argus.Resolution` and `Report`'s `:facts` option,
  `Argus.Pipeline.read_facts/1`, `Argus.Facts.canonicalize/1`,
  `Argus.Schema.{fetch!,arity,field_names,souffle_decl}/1`: no callers
  anywhere in the workspace.
- `Argus.Souffle`'s `:fallback_rules` option and the `_argus_mode` result
  key: nothing passed the option, so every result was `"precise"`.
- `priv/dl/clientlib/cfg.dl`: no analysis read `cfg_edge`; the
  conditional-call question it existed for is answered by `Argus.Cfg` at
  extraction time.
- Twelve relations no rule read: `module_info`, `import_ref`,
  `recv_end`, `make_fun` (superseded by `closure_def`),
  `tuple_field_access`, `unhandled_op`, `deferred_reply`,
  `delayed_message`, `sync_call_via`, `via_tuple`, `registry_op`,
  `gen_event_handler`, with the extractor code that produced them.

## 0.7.3 — 2026-09-11

### Changed

- Elixir requirement lowered to `~> 1.18`; OTP 28 remains required. CI
  tests both 1.18.4 and 1.19.4.

## 0.7.2 — 2026-09-11

### Changed

- `init_waits_on_blocking_server` counts only unbounded operations in
  the callee's handler — `terminate_child`, `stop`, `restart_child`,
  `delete_child`, or a GenServer.call with `:infinity`. A handler that
  `start_child`s is bounded by the child's init; db_connection's fixed
  Watcher is that shape and was still reported.
- `permanent_child_stops_normally` is `:info`: the restart is certain,
  whether it is wanted is not (Phoenix.Config and Swoosh's storage
  manager stop themselves on purpose).
- `rest_for_one_orphaned_children` is `:warning` when the call names the
  holder and `:info` when the holder is inferred.

## 0.7.1 — 2026-09-11

Schema version 28.

### Added

- `monitor_ref_dropped(id, func)` — the ref `Process.monitor/1` returned
  is discarded at the call site, read from the instructions that follow.
- `monitor_leak`: `monitor_ref_discarded` (:info) — a server callback
  drops the ref of a monitor it establishes, so nothing can ever
  demonitor it (Phoenix PubSub's Local, for every subscriber).

### Changed

- `monitor_leak`'s lifetime rules reach helpers through closures (Redix's
  cluster manager monitors inside an `Enum.reduce` fun) and count a
  removal path anywhere in the module, not only in callbacks.

## 0.7.0 — 2026-09-11

Schema version 27. Every change below comes out of replaying 42 historical
OTP bug fixes from the Hex corpus (oban, phoenix_pubsub, db_connection,
redix, postgrex, finch, bandit, thousand_island, cachex, libcluster,
broadway, gen_stage, sentry, swoosh) against their pre-fix commits: argus
found 5 at the bug site; the rest name the gap each entry closes.

### Added (facts)

- `sup_call(id, func, api, op, target)` — synchronous management calls
  into supervisor processes (`Supervisor.start_child/2`,
  `DynamicSupervisor.terminate_child/2`, `Task.Supervisor.async_nolink/2`,
  ...). Every one is a GenServer.call underneath but none named a
  GenServer module, so `sync_call` never saw them.
- `:gen_statem.call/2,3`, `GenStateMachine.call/2,3` and `GenStage.call/2,3`
  are sync calls (the gen_statem default timeout is `:infinity`, recorded
  as such); their `cast`s are async casts.
- `callback_tag` and `callback_total` cover `handle_info/2`.
- `callback_stop_reason(id, func, reason)` — the literal reason of a
  `{:stop, reason, ...}` callback return.
- `callback_timeout(id, func, callback, timeout_ms)` — the literal integer
  timeout of an `{:ok, state, ms}` / `{:noreply, state, ms}` /
  `{:reply, reply, state, ms}` return. `callback_return` now also reads a
  return the compiler folded into a single literal.
- `statem_event_clause(mod, func, event_type)`, `statem_info_catchall(mod,
  func)`, `statem_event_catchall(mod, func)` — what a gen_statem state
  function or handle_event/4 matches on its first argument, and whether
  some clause accepts `:info` with any content / any event at all, read
  from the clause dispatch.
- `Connection`, `Postgrex.SimpleConnection` and
  `Postgrex.ReplicationConnection` canonicalise to `GenServer`, so every
  rule about GenServer callbacks applies to modules declaring them.

### Changed (supervision extraction)

- A tuple-spec child whose module is `Keyword.get(opts, key, Default)` or
  `Map.get(opts, key, Default)` resolves to `Default` (Oban's queue
  supervisor builds its producer this way; the child was dropped).
- A child list built from cons cells is walked from its outermost cell,
  so positions follow source order when literal and runtime elements are
  interleaved. Before, a runtime element was filed wherever its tuple
  happened to be built, and every position-reading rule saw the wrong
  order.

### Fixed

- gen_statem state-function IDs were minted from `String.to_atom/1` of
  the module's inspected name — `:"A.B"`, not `A.B` — so every
  transition and timeout site in `state_functions` mode was
  unresolvable.

### Added (analyses)

- `callback_receive` canonicalises behaviour names, so a module declaring
  `@behaviour :gen_statem` is a callback loop (Redix's connection init
  waited on a bare receive, unreported).
- `error_handling`: `trap_exit_without_exit_clause` — traps exits, has a
  handle_info/2, no clause matches `{:EXIT, ...}` (Bandit's HTTP/1
  handler); `handle_info_without_catchall` (:info) — a GenServer that
  monitors or traps exits defines handle_info/2 without a catch-all.
- `supervision`: `permanent_child_stops_normally` — a permanent child
  returns `{:stop, :normal | :shutdown, ...}` and is restarted (Phoenix
  PubSub's tracker shards on graceful permdown).
- `deferred_startup_deadlock`: `init_timeout_deferral` (:info) — init/1
  returns `{:ok, state, timeout}`; any earlier message cancels the
  deferred work (libcluster's Gossip strategy).
- `monitor_leak`: the timed wait and the flush may sit a call below the
  monitor in the same module (Finch's HTTP/2 response loop); two
  lifetime heuristics at :info — `monitor_never_released` (monitors from
  callbacks, removes bookkeeping entries, never demonitors: Postgrex's
  Parameters server) and `deliberate_termination_while_monitored`
  (terminate_child / GenServer.stop on a monitored pid without
  demonitoring: Oban's producer on pkill, Redix's cluster manager).
- `ets`: `ets_write_only_table` (:info) — a named table inserted into
  outside init/1 and never deleted from (Sentry's check-in ID mapping).
- `supervision`: `rest_for_one_orphaned_children` — a later child starts
  processes inside an earlier sibling (Oban's producer running jobs under
  the queue's Task.Supervisor), which survives the owner's restart.
- `sync_call_in_init`: `sup_call_in_init` (:info) — init/1 reaches a
  supervisor management call (Broadway's server, Oban's Midwife);
  `init_waits_on_blocking_server` — a call from init that the tree-order
  argument accepts, into a server whose handler blocks on a supervisor op
  or a GenServer.call of its own (db_connection's Watcher).
- `gen_statem`: `state_missing_info_catchall` — a state function has no
  `:info` catch-all while sibling states do (Redix's Cluster.Manager);
  `statem_timeout_unhandled` (:error) — a `:timeout` / `:state_timeout`
  action is armed and no clause matches that event type (Postgrex's
  SimpleConnection wrote the handler as `(:info, :timeout, ...)`).

## 0.6.1 — 2026-09-11

### Changed (supervision extraction)

- Trees defined outside `Supervisor` modules are extracted: the function
  that calls `Supervisor.start_link/2` or `Supervisor.init/2` is the tree
  definition, whoever its module is (Broadway's `Topology` GenServer,
  Cachex's `start_link/1`).
- Child specs are followed through helpers to depth 3 and into the
  closures a function creates, so a `for`/`Enum.map` comprehension that
  builds one spec per element (`for i <- 0..n, do: %{start: {Producer,
  ...}}`) contributes its module. Breadth-first, so the order approximates
  construction order.
- A strategy inside a runtime-built option list (`[name: name(config),
  strategy: :rest_for_one]`) is read from the cons cells.
- `{GenServer, :start_link, [Mod, ...]}` map specs resolve to `Mod`, and
  a spec that resolves only to the behaviour module (`GenServer`, `Agent`,
  `Task`) is dropped rather than recorded as a child.
- Tuple-shaped specs are only trusted when the tuple flows into a list,
  is returned, or is passed to `Supervisor.child_spec/2`, only at the
  tree function and its direct helpers, and only for Elixir modules;
  bare-atom and cons-cell children must be Elixir modules too. Before
  this, the deeper walk also swept up `{GenStage.DemandDispatcher, opts}`
  options and `:supervisor`/`:queue` tags as children.

On the surveyed corpus this recovers Broadway's topology (RateLimiter
before ProducerStage under `rest_for_one`, so the producer's init call
is a proven safe sibling), ThousandIsland's acceptor pool, Phoenix.PubSub's
PG2 and Tracker shards, and Oban's Nursery and queue supervisors, all of
which extracted empty or not at all.

## 0.6.0 — 2026-09-11

### Changed (schema version 26 — conditional calls)

- `conditional_call(id)`: a call instruction whose basic block is
  control-dependent on a branch in its function, derived per module
  from `Argus.Cfg`'s post-dominator tree next to `def_use`. Positional
  like `def_use`, and for the same reason emitted rather than folded
  into `remote_call`.
- Stage 0 derives `unconditional_call_edge(caller, callee)` — the call
  graph restricted to pairs with at least one site that runs on every
  path — alongside `call_edge` and `call_site`. Consumers that project
  fact directories supply it the same way.
- `sync_call_in_init` gains a `kind` column: `conditional` when every
  route from `init/1` to the sync call passes through a branch-guarded
  site in init (postgrex's `sync_connect: true`, goth's
  `prefetch: :sync`, broadway's `if rate_limiter`), `unconditional`
  otherwise. Conditional rows are titled "init/1 can block", and the
  analysis reads only stage-0 output for the distinction — no
  instruction-keyed relation enters its input set.

## 0.5.1 — 2026-09-11

Precision and cutoff work from installing scry on the 24 most-downloaded
Hex packages that ship supervision trees (16 findings, 1 of them
actionable).

### Changed (findings)

- `one_for_one_coupling` grades by mechanism. A new `kind` column
  (`call` | `cast`) says whether the caller ever waits on the sibling.
  Cast-only couplings — tzdata's `ReleaseUpdater → EtsHolder`, sentry's
  `Scheduler → ClientReport.Sender` — cannot hold a stale reply, pid, or
  monitor, so they are `:info` ("One-way coupling under one_for_one")
  rather than a warning asserting a consequence that does not follow.
  The anchor also follows the witness's local calls down to the
  instruction that reaches the sibling instead of stopping at the
  witness's head.
- `sync_call_in_init` is `:info`. Its remaining rows are exactly the
  cases where the callee's position could not be established (child
  specs built at runtime, calls behind an opt-in option such as
  postgrex's `sync_connect` or goth's `prefetch: :sync`); the proven
  startup deadlock stays an `:error` as `init_deadlock_risk`.
- `unsafe_task` suppresses leaked-task findings in any module that
  defines `handle_info/2`, not only the behaviours it could name.
  `Phoenix.Presence` consumes its `Task.Supervisor.async` replies in the
  `handle_info/2` that `Phoenix.Tracker` invokes and was reported.

### Changed (extraction)

- Literal facts drop location metadata. Logger macros embed `file:` and
  `line:` in their metadata keyword, so a comment added above a
  `Logger.warning` changed a `literal_value` row and re-solved every
  analysis reading literals in the incremental consumers. Keywords and
  maps carrying both `:file` and `:line` lose those two keys before
  they are formatted; nothing else about the literal changes.

## 0.5.0 — 2026-09-11

### Added (findings carry their remediation)

Findings gained two additive fields for remediation-quality rendering:
`:at_label` (what the anchor line IS — "supervision tree defined here" —
so a renderer that excerpts source annotates the anchor with something
other than a repeat of the title) and `:help` (resolution guidance, one
string per suggestion). Both default (nil / `[]`), every existing
`finding/2` builder is shape-compatible, and `Findings.new/4` validates
the new options loudly.

The six default-set analyses (deferred_startup_deadlock,
one_for_one_coupling, supervision, sync_call_in_init, unlinked_spawn,
unsafe_task) now populate both fields; remediation sentences that
previously lived inside `detail` prose moved into `help`, so details
state the problem and help states the fix. The remaining analyses are a
follow-on tranche.

`one_for_one_coupling` findings anchor at the coupling call itself. Stage
0 now derives `call_site(id, caller, callee_mod)` — calls into
project-defined modules plus the `GenServer.call/cast` a function
performs — alongside `call_edge`, and the output relation gained a
sixth `site` column: the instruction that calls the sibling (or the
GenServer call the witness performs), falling back to the witness
function ID so `Findings.at_site/2` always has an anchor. The extra
stage-0 relation keeps `remote_call` out of the analysis's own input
set, so its projection stays cheap.

Autoresearch loop — the tooling layer that turns the 0.4.0 measurement
surface into an iterative improvement workflow. Measure a corpus,
baseline the results, edit an extractor, re-measure, diff, accept or
revert, repeat. Inspired by pi-autoresearch's event-log + living-doc
pattern, adapted for Argus's multi-dimensional categorical metrics.

### Removed

`Argus.Schema.Pin` is gone, along with the per-consumer version ranges
it gated. Every consumer is a path or tagged-git dependency whose own
suite exercises the columns it reads, so the pin only ever added a
compile error ahead of a test failure — at the cost of one widening
commit per consumer per schema bump (gloss's history was mostly those).
`@schema_version` and `Argus.SchemaVersionTest` stay: the number is
what scry's and planchette's environment fingerprints and encore's
goldens key on, and the digest test is what keeps it honest.

### Fixed (purity, found by dogfooding)

Annotating argus itself surfaced four problems in the analysis, three of
them in the effect model.

- **`Kernel` was listed as a pure module. It is not, and this was a
  soundness hole.** Most of Kernel inlines to BIFs and never survives as a
  remote call, so the entries that DO survive are exactly the dispatching
  ones: `inspect/1` and `to_string/1` go through a protocol, which is
  user-extensible code. Kernel also exports `send/2`, `spawn/1`, `exit/1`,
  `apply/3` and `self/0`. Treating it as pure meant a function calling
  `inspect/1` could be reported **verified** while transitively running
  arbitrary user code — the exact failure the analysis exists to prevent.
  `Argus.InstrId.func_id/2` was one such false verification, and correctly
  demotes to unprovable now.

- **`Path` was listed impure wholesale**, so `Path.join/2` — pure string
  manipulation — was reported as a filesystem effect. Only the handful that
  consult the filesystem or the current directory (`wildcard`, `expand`,
  `absname`, `relative_to_cwd`, `safe_relative_to`) belong there.

- **Purity did not compose.** A call to a function carrying its own
  `@pure true` was treated as unknown, so nothing that used your own pure
  helpers could ever be verified — which is most of what pure code does.
  The declaration is now trusted at the call site and verified separately
  at the definition, the bargain every contract system makes.

- **`apply/3` with a literal MFA is now resolved rather than given up on.**
  `apply` is only opaque when M and F are genuinely unknown; with constants
  it is a static call wearing a disguise. `resolve_register/3` already
  reconstructs register contents, so the analysis looks before it shrugs.
  The payoff runs both ways: `apply(Enum, :reverse, [l])` verifies, and
  `apply(IO, :puts, [x])` is a proven violation naming `IO.puts/1` instead
  of an unprovable shrug.

Also recorded: Elixir compiles `x.field` — dot access on a value it cannot
prove is a map — to a helper that reads a map field OR calls `x.field()` as
a remote function. That second branch is a dynamic dispatch behind ordinary
syntax, so such code is not statically pure. `Argus.Lines.resolve/2` now
uses `Map.fetch!/2`, which is both provable and clearer on a plain map.

Dogfood state: **11 verified, 0 violated**, and six functions unprovable —
every one of them because it reaches `Kernel.inspect/1` or
`String.Chars.to_string/1` to format an atom. That is the honest answer,
and the annotations are deliberately left in place to document where the
limit is.

### Added (analysis)

### Added (analysis)

- **`purity`** and **`Argus.Purity`** — declare a function free of side
  effects, and have the claim mechanically checked.

  ```elixir
  defmodule Money do
    use Argus.Purity

    @pure true
    def add(%Money{cents: a}, %Money{cents: b}), do: %Money{cents: a + b}
  end
  ```

  This is a different shape from every other analysis here. The others look
  for bugs nobody claimed were absent; this one verifies a claim the author
  made, so a finding says "you declared this pure and here is the call that
  makes it not" rather than "this looks suspicious".

  It is therefore the first analysis that has to be **sound** rather than
  merely useful. A missed supervision smell costs a warning; a purity check
  that reports "verified" for a function that writes to ETS has actively
  misled someone into depending on it. So there are three outcomes:

  - `purity_violated` — reaches a known observable effect, named by
    category (io, process, process_dict, ets, port, node, time, random,
    network, code_loading) and attributed to the function that performs it.
  - `purity_unprovable` — reaches something that cannot be accounted for: a
    call through a fun value or `apply`, a **protocol dispatch** (whose
    implementations are an open set no table could enumerate), or a call the
    effect model has no entry for.
  - `purity_verified` — everything reachable is known effect-free. Emitted
    deliberately: a contract is only worth having if you can tell it was
    actually checked.

  The declaration travels as a **persisted module attribute**, so the
  contract is read out of the beam rather than the source and cannot drift
  from the code it describes. No macro wraps the function, so the emitted
  code is byte-for-byte what it would have been.

  Effects in closures the function builds are caught for free: the compiler
  lifts the lambda and argus already records a `closure_def` edge, so
  `@pure true def each(l), do: Enum.each(l, &IO.puts/1)` is a violation
  attributed to the lifted `-each/1-fun-0-`.

  The effect model (`Argus.Purity.Effects`) lives in Elixir rather than in
  rules — it is a large table that wants doctests, and expressing it as
  Datalog would mean string surgery, which is what produced the
  partial-functor unsoundness fixed in v9.

  Dogfooded: `Argus.InstrId` carries `@pure true` on its public API. Six
  functions verify; two are unprovable because they reach
  `String.Chars.to_string/1`, and that is the correct answer — protocol
  dispatch runs whichever implementation the argument's type provides, which
  is ordinary user code.

  Requires schema v13: `send_msg` and `make_fun` gain `caller`, the new
  `dynamic_call` records calls through a fun value or `apply`, and Layer 2
  gains `pure_contract`, `impure_call`, `protocol_dispatch` and
  `unknown_call`.

- **`callback_receive`** — a bare `receive` inside an OTP callback.

  An OTP process is already in a receive loop its behaviour owns. A
  `receive` in a callback runs inside that loop and selectively consumes
  from the same mailbox: `{:system, _, _}` (how `:sys.get_state` and the
  whole debug surface reach the process), `{:EXIT, _, _}` when trapping,
  and every in-flight monitor's `{:DOWN, ...}`. Messages it does not match
  stay queued and are re-scanned by every later receive. Without an
  `after` it can block forever, so shutdown waits out the child timeout and
  brutal-kills. No compiler or dialyzer diagnostic covers this.

  Two suppressions, both added because verification demanded them rather
  than in anticipation:

  - **Closure edges are subtracted.** `call_edge` treats closure
    construction as a call so reachability follows into lambdas; a
    `receive` inside `spawn(fn -> ... end)` runs in the *spawned* process
    and is not this bug.
  - **The `cancel_timer` flush idiom is excluded.** `cancel_timer/1`
    returning false means the message was already sent, so the receive is
    guaranteed to match. Both blocking receives in the first corpus sweep
    were this idiom — without the suppression it would have been the
    analysis's entire output on that project.

  Requires schema v12: `recv_start` gains `caller`, and `blocking`, which
  distinguishes a receive whose empty-mailbox block ends in `wait` (no
  timeout) from one ending in `wait_timeout`. That is only visible by
  following a label to another instruction, so the emitter resolves it —
  verified against OTP itself, where `:gen_server:loop/5` comes out bounded
  and `:timer:interval_loop/5` blocking.

- **`request_surface`** — dangerous operations reachable from callbacks that
  receive external data, rather than from "any exported function".

  `atom_safety` already finds unsafe atom creation, unsafe deserialization
  and dynamic evaluation, but gates them on reachability from some export,
  which in a real application is nearly everything. It answers "is this code
  live", not "can an attacker reach it". This analysis starts from OTP
  callbacks that take request-shaped input — `Plug.call/2`, LiveView
  `mount`/`handle_params`/`handle_event`, `Phoenix.Channel.handle_in/3`,
  `Oban.Worker.perform/1`, Broadway's message callbacks — identified by
  behaviour plus callback name and arity, which is information the beam
  already carries.

  Findings carry a **proximity**, and it is the difference between a report
  worth reading and a list of everything the app can reach:

  - `direct` (`:error`) — the sink is in the callback, operating on its own
    arguments, which ARE the request.
  - `adjacent` (`:warning`) — one call away.
  - `transitive` (`:info`) — a path exists; that a data *flow* exists is
    unproven.

  The tiers are calibrated against hand-verified findings, not chosen a
  priori. On a corpus sweep every `direct` finding was a true positive,
  `adjacent` was mixed (one real unvalidated URL parameter, one database
  primary key), and every `transitive` hit examined sourced its input from
  Postgres or Redis rather than the request — reached only because some
  LiveView loads those records. **Reachability is not taint**, and the
  analysis says so rather than pretending otherwise.

### Changed (schema version 11 — no rule reads `instruction`)

`unsafe_task` asked "was this call's result pattern-matched?" by joining
`instruction` to itself and comparing two indexes:

    instruction(id, func, sc_idx, _),
    instruction(bid, func, bidx, _),
    branch(bid, _, _),
    bidx > sc_idx.

That is a yes/no question about ordering, answered by dragging in the
largest and most volatile relation in the schema. It left `unsafe_task` as
the last analysis reading `instruction`, and by a wide margin the most
expensive one.

The emitter already knows every instruction's index, so it now answers the
question directly as `call_followed_by_branch(id)` — one row per call site
that has a later branch. The predicate is deliberately just as coarse as it
was (a branch anywhere later in the function counts, including one in an
unrelated clause), because moving where something is computed must not
change what it computes. Findings are byte-identical: 962 over 1259 beams.

**No Datalog rule reads `instruction` any more.** It is still emitted and
still used — `Argus.Cfg`, `Argus.Dataflow` and gloss all need it — but it no
longer gates any analysis's incrementality.

Measured (oban corpus for volume, sequin's 531 modules for time):

| | before W1 | after v10 | after v11 |
|---|---|---|---|
| serialized fact volume, all analyses | 416 MB | 247 MB | **160 MB** |
| `unsafe_task` input volume | 98 MB | 100 MB | **12 MB** |
| `unsafe_task` solve | — | 690 ms | **179 ms** |
| slowest single analysis | — | 690 ms | **284 ms** |

Sharpening the heuristic — asking whether the call's result register is
actually inspected, which `Argus.Extractor.Helpers` has the machinery for —
would change findings and is deliberately left as its own change.

### Changed (schema version 10 — calls carry their caller)

Twelve of the fourteen `instruction(...)` uses in the rule corpus existed
only to recover a call's containing function from its instruction ID:
`remote_call(id, ...), instruction(id, caller, _, _)`. That made
`instruction` — the largest relation in the schema, and one rewritten
whenever any function body changes, because an instruction ID is a raw
per-function offset — an input to stage 0 and therefore to every analysis
downstream of the call graph.

`remote_call`, `local_call`, `bif_call`, `spawn_call` and `try_start` now
carry a `caller` column; `try_start` also carries `kind` (`"try"` or the
older `"catch"`), which collapses two rules into one. Nothing about the
findings changes — 962 findings over 1259 beams, byte-identical.

What changes is how much has to cross the file boundary. Serialized fact
volume for a full analysis run over the oban corpus:

| analysis | before | after |
|---|---|---|
| `unlinked_spawn` | 85 MB | **1 KB** |
| `deferred_startup_deadlock` | 101 MB | 16 MB |
| `unsafe_task` | 98 MB | 100 MB |
| **all sixteen** | **416 MB** | **247 MB** |

`unlinked_spawn` is the clearest case: its entire input set was
`{instruction, spawn_call}`, and it read all 343k instruction rows purely
to learn which function did the spawning — while `spawn_call` itself is
often empty. Its input set is now a single relation.

`unsafe_task` gets slightly worse, and that is the honest cost of stopping
here. It still reads `instruction` for `start_child_result_checked`, which
compares instruction *indexes* (`bidx > sc_idx`) to ask whether a branch
follows a call — a genuine use of position, not a decode of identity — so
it pays for the new column without shedding the old relation. Replacing
that rule with an extractor-computed fact would change findings, so it is
deliberately a separate change.

Stage 0's input set is now `bif_call`, `closure_def`, `function_def`,
`local_call`, `remote_call` — exactly the relations that describe what a
function calls. Its inputs are finally as stable as its output, which is
what `stage0.dl`'s own header has claimed for the output alone since the
stratification landed.

### Fixed (soundness)

- **`clientlib/interprocedural.dl` no longer depends on Souffle's conjunct
  order.** Parameter forwarding was encoded in `call_arg`'s value column as
  the string `"arg:N"` and decoded in Datalog with
  `to_number(substr(marker, 4, strlen(marker) - 4))`. `to_number` is a
  **partial** functor — it aborts the entire program on non-numeric input —
  and the `match("arg:.*", marker)` that kept literals away from it was a
  sibling conjunct, not a precondition. Souffle promises no conjunct order.

  The default schedule happened to be safe, which is why this never showed
  up. Under `souffle -m` it is not: **7 of 16 analyses abort** with
  `wrong string provided by to_number("mic")`, measured on the oban corpus.

  Forwardings are now their own relation, `call_arg_forward`, with the
  forwarded position as a real `number` column, and every partial functor is
  gone from the rule corpus. After the change all 16 analyses run clean under
  magic sets. The split is lossless — on oban, `call_arg` 202,707 rows became
  `call_arg` 160,100 + `call_arg_forward` 42,607 — and findings are
  byte-identical (962 findings, 1259 beams).

  Beyond magic sets, this is a prerequisite for evaluating Souffle in-process:
  its generated code calls `abort()` on functor errors, which inside the VM is
  not a failed analysis but a dead node.

  Schema version 9. `Argus.DlDeclarationsTest` now fails any rule that reaches
  for a partial string functor at all.

### Changed

- **Extraction is now deterministic.** `Argus.Pipeline.extract/2` fanned out
  with `ordered: false` and merged by concatenation, so the reduce saw
  workers in completion order and row order varied run to run — measured at
  **8 distinct results from 8 extractions of the same 40 modules**. Souffle
  has set semantics and never noticed, but every consumer that memoizes,
  hashes, or diffs facts did; planchette was sorting each relation itself to
  recover value equality. Ordering the stream costs nothing measurable
  (median 128ms vs 138ms over 90 modules — ordering is inside the noise, and
  slightly reduces variance) and makes reproducibility a property of the
  library rather than something each consumer re-derives.

  For input sets whose *order* can vary — a directory listing, a set
  difference, a parallel discovery pass — the new `Argus.Facts.canonicalize/1`
  sorts every relation so two such extractions compare equal. Consumers that
  already hold facts partitioned per module or per relation should keep
  sorting those partitions instead; it is cheaper and the result is reusable.

### Added

- **Souffle fact declarations are generated from `Argus.Schema`.**
  `priv/dl/base.dl` and the new `priv/dl/layer2.dl` are written by
  `mix argus.gen.dl` and checked byte-for-byte by the suite. Declarations are
  positional, and Souffle cannot check them against what the emitter writes —
  two `symbol` columns swapped parse fine and silently join the wrong values,
  producing findings that are wrong rather than absent. They were the one part
  of the schema with no mechanical link back to it: **95 hand-written `.input`
  declarations of 50 distinct relations across 19 files**, so most relations
  were declared several times over, each an independent chance to drift.

  83 of them are now deleted; rules files include the generated declarations
  instead. Declaring the whole schema costs nothing in the solve, and the
  suite now demonstrates rather than assumes it: every analysis's true input
  set — read out of Souffle's transformed RAM — is **identical** to what it
  was when each file declared only the handful it read. Findings over the
  oban corpus (962 findings, 1259 beams) are byte-identical.

  `Argus.DlDeclarationsTest` also pins those input sets, because they are the
  unit of incremental work: a consumer re-solves an analysis when any relation
  in its set changes, so an accidental widening is a silent latency
  regression. One assertion is deliberately a marker rather than a guard —
  exactly three analyses read `instruction`, the largest and most volatile
  relation, and twelve of the fourteen `instruction(...)` uses in the rule
  corpus exist only to recover a call's containing function from its ID.

- `Argus.InstrId.mint/2`, `func_id/2,3` and `func_id_of/1` — the wire format
  for instruction and function IDs now has exactly one definition, with
  `parse/1` and `parse_func/1` as its inverses. Nineteen sites previously
  built these strings by interpolation: `Normalize` for Layer 1, seventeen
  scattered through eight Layer-2 extractors, and `Argus.Lines`, which had
  its own copy of `format/1`. Instruction indices are raw per-function
  offsets carried by 49 of the 78 relations, so any future change to how
  instructions are named needs one definition to move, not nineteen.

  This also fixes a latent bug in `Emit`: recovering a parent function ID
  split on the *first* `#`, which truncates compiler-generated names that
  contain one and yields a function ID that joins against the wrong
  function. `func_id_of/1` is right-anchored like the rest of `InstrId`.

- `Argus.Schema.Pin` — a `use`-able compile-time assertion that argus's
  fact schema is one the consumer was written against. The workspace had
  three hand-rolled copies of this check (planchette, gloss, lowdown) with
  three different semantics, and the duplication had already cost a real
  breakage: the v8 bump updated gloss's copy and missed lowdown's, so
  lowdown silently stopped compiling against its own path dependency.

  ```elixir
  use Argus.Schema.Pin, versions: 3..8, review: "Gloss.Entries and Gloss.Adapters"
  ```

  Raises `CompileError` at the `use` site naming the consumer, the pinned
  range, the version argus actually declares, and what to re-read. A
  non-contiguous pin renders as a list rather than a range, because the
  gap is the part a reader needs to notice. The per-version reasoning
  stays as comments in the consumer — whether a bump matters depends on
  which relations that consumer reads, and only the consumer knows that.

### Fixed (robustness)

- `Argus.Pipeline.Normalize` no longer crashes on improper lists in BEAM
  literals. `is_list/1` is true for `[head | tail]` with a non-list tail,
  but `Enum.map/2` raises on it, so a single such literal took the entire
  extraction down with a `FunctionClauseError` reported far from its
  cause. Found by sweeping planchette over a corpus of real projects:
  **poison** ships one, and every module in the project failed as a
  result. Normalization now walks cons cells, so proper and improper lists
  are both handled and the improper tail is preserved rather than silently
  properised. `{:alloc, _}` hints got the same treatment — `Keyword.get/3`
  raises on an improper list too.

### Changed (schema version 8 — positional columns split out)

Three relations carried positional data that no rule joined on but that
renumbered whenever anything earlier in a function changed, so they
dirtied every analysis reading them on any body edit.

- `function_def` loses its `entry` label to a new `function_entry`
  relation. The column was a wildcard in all 55 rule uses; only
  `Argus.Cfg` needs it, to root each function's control-flow graph.
- `call_arg` loses its call-site instruction ID — a wildcard in every
  use. The rules ask which FUNCTION passes which argument, which is
  stable.
- `supervisor` loses its `site` to a new `supervisor_site`. Analyses that
  only ask "is this a supervisor, with what strategy" no longer depend on
  a positional value; the two that anchor a finding at the tree
  definition join `supervisor_site` explicitly and accept the coupling.

The principle is the one that already keeps `line_info` out of a semantic
fact set: positional data is payload to resolve late, never a join key.
Measured on eusapia, a body edit that adds instructions without adding a
call now leaves `one_for_one_coupling`, `supervision`, and
`sync_call_in_init` untouched, where previously all six analyses
re-solved. An edit that genuinely changes the call graph still re-solves
all six, as it must.

Verified byte-identical over 555 beams — every analysis's full output
plus per-relation row counts and content hashes.

### Changed (stratified call graph)

The shared call graph is now derived once by `priv/dl/stage0.dl` and read
by analyses as facts, instead of being re-derived inside every solve.

- `clientlib/imports.dl` declares `call_edge` as `.input` and includes
  `base.dl` directly rather than `cfg.dl`. Souffle prunes unused *input*
  relations but not unused *derived* ones, so pulling in the cfg_edge
  rules kept every analysis demanding `branch`/`jump`/`next`/`label_at`/
  `select_branch` facts it never read. `analyses/ets.dl` and
  `analyses/unlinked_spawn.dl` likewise now include `base.dl`.
- `call_reachable` stays a per-analysis derivation over the staged edges:
  the closure is quadratic in the worst case (1.6MB of `call_edge`
  expands to 24.7MB on a 555-beam corpus), so materializing it would
  trade a cheap fixpoint for an expensive write-then-read.
- Dead `cfg_reachable` removed — nothing referenced it, and as the
  closure of a ~10M-row relation it was a standing hazard.

Analysis input sets drop from 18–21 relations to 2–10, and the
supervision family (`one_for_one_coupling`, `supervision`,
`sync_call_in_init`) no longer reads `instruction` at all — so a consumer
that memoizes per relation can tell an ordinary body edit cannot have
changed their verdict.

New API: `Argus.Analysis.derive_stage0/2`, `stage0_rules_path/0`, and
`input_relations/1` (resolved from the transformed RAM, the form that
actually executes — the parsed AST over-approximates, and walking
`.include` by hand under-approximates). `Argus.Analysis.run_rules/3`
derives stage 0 when a facts directory lacks it, so batch callers and
hand-built fact directories need no change; `extract_facts/3` stages it
up front. A stage-0 failure degrades every requested analysis rather than
collapsing the call, preserving the "Souffle trouble is visible, not
fatal" contract.

Verified byte-identical: every built-in analysis's full output plus
per-relation row counts and content hashes, over 555 beams.

### Fixed (performance)

- `clientlib/cfg.dl` no longer forces `.output cfg_edge`. The directive
  made Souffle materialize and write the control-flow graph on every
  solve even though no analysis reads `cfg_edge` or `cfg_reachable`, and
  every consumer then parsed the CSV back in only to discard it. Over a
  555-beam corpus that was ~10.3M rows / ~1.07GB written per solve; a
  single `unsafe_task` run went from 4.03s to 0.56s (7.2×), with
  byte-identical output. Analyses and tests that genuinely want the
  relation now declare `.output cfg_edge` themselves.

### Fixed (precision — 15-project OTP corpus audit)

Ran every analysis against 15 OTP libraries (bandit, broadway, cachex,
commanded, db_connection, finch, gen_stage, horde, libcluster,
nimble_pool, oban, phoenix_pubsub, quantum, redix, swarm) and verified
each finding against source. Total findings fell from ~260 to 88 with no
true positive lost; the remaining findings are the verified real ones
(the two `atom_safety` errors, Oban's coupling, the genuine timeout
chains) plus intentional-pattern warnings. Five analyses had systematic
false-positive mechanisms:

- **`gen_statem` (108 → 0, all false).** Three root causes.
  `state_functions` mode treated every arity-3 function as a state; it is
  now an arity-3 function that is exported, not called locally, and
  returns a gen_statem action — which excludes private helpers, compiler
  closures, exported client wrappers (`connect_to_node/3`), and
  action-returning helpers a state calls (`disconnect/3`). The initial
  state was inferred topologically, letting a dead state that transitions
  out masquerade as the entry point; it is now read from `init/1`'s
  return (schema v6 `statem_initial`). `handle_event_function` mode
  harvested every atom in `handle_event/4` (`:DOWN`, `:badarg`, module
  aliases) as a state; the structural rules are now scoped to
  `state_functions` mode. `extract_transitions` also models the remaining
  action forms (`repeat_state`, `stop_and_reply`, bare
  `:keep_state_and_data`), so every state now implies a transition —
  making `coverage_statem_no_transitions` unfireable, and it is removed.
- **`timeout_chain` (32 → 3).** All 29 false positives came from one
  `callback_sync_dep` clause built on `stateful_module_dep`, which (via
  its module-level heuristic) counted reaching a *pure* function
  (`Config.get`, an ETS read) as calling that module's server, never
  tied the dependency to the handle_call, and pulled `async_cast` edges
  into a "synchronous" chain. The clause is removed; the genuine chains
  derive from the `genserver_sync_api` rules. `timeout_chain_risk` gains a
  `[:from, :to]` dedup key so a cycle yields one finding, not one per
  depth.
- **`error_handling` (25 → 8).** `swallowed_error` never checked that the
  handler discards the exception — the idiom
  `catch kind, reason -> {:error, …}` was flagged; a liveness scan now
  clears a handler that reads the caught exception registers before
  overwriting them, and `raw_raise` (the OTP-21 compiled form of
  `:erlang.raise/3`) is recognized as a re-raise.
  `trap_exit_without_handler` no longer fires on gen_statem modules
  (which receive `{:EXIT, …}` in state functions). `exit_in_callback` no
  longer treats `:erlang.exit/1` (a let-it-crash self-exit) as an
  imperative kill, and is downgraded to `:info` since a `Process.exit/2`
  in a callback is usually a deliberate protocol.
- **`distributed` (21 → 5).** `rpc_in_genserver_callback` reported RPCs
  reachable transitively through a guarded dispatcher (Cachex's
  `Router.route`, whose clauses the function-granularity call graph
  collapses) — all 13 corpus findings were false; only an RPC directly in
  a callback is now reported, and the sites stay covered by
  `rpc_without_timeout` (whose message no longer claims "default" for an
  explicit `:infinity`).
- **`supervision` (1 → 0).** `wrong_start_order` fired on `init_reaches`,
  which counts a child's `init/1` calling any function in a dependency's
  module — including a pure helper (Horde's
  `NodeListener.make_members/1`). It now requires an actual process
  interaction (sync call / cast) to the dependency at init.

The harness (`scripts/harness.exs`, `analyze_project.exs`) was
modernized for this audit: it runs every analysis by default, and the
report gains an `otp_findings` section — severity-ranked findings with
source-line-resolved anchors — feeding a cross-project `triage.json`
index. Fixes along the way: ebin discovery now finds `_build/shared`
(projects with `build_per_environment: false`), and `--resume` rebuilds
the triage index from all results on disk rather than clobbering it.

### Added

- **`port_open` relation + Ports extractor (schema version 7).** A new
  `Argus.Extractors.Ports` records external port creation sites —
  `Port.open`/`:erlang.open_port` (Elixir's `Port.open` compiles to the
  latter), `System.cmd`, `System.shell`, `:os.cmd` — as
  `port_open(id, func, mechanism, target)`, with the spawned
  command/executable resolved when it's a literal. A port is owned by the
  opening process and dies with it, so consumers can attribute it to that
  process in the supervision tree, the same way ETS tables are.
- **Dataflow primitives for value provenance.** `Argus.Extractor.Helpers`
  gains `recent_writer/3` (the most recent instruction that wrote a
  register, raw — for inspecting provenance) and `keyword_value_register/4`
  (the register holding a given key's value in a runtime-built keyword
  list — for tracing a computed option like `name:` back to its source).
  `call_result_origin/3` now also reports **local** (`call`) origins, not
  just remote ones, so a value produced by a `defp` helper can be traced
  into that helper. General-purpose backward-dataflow building blocks.
- **Via-tuple (`Registry`) registration names.** The supervision extractor
  recognizes children registered under `{:via, Registry, _}` tuples built
  by a `*.Registry.via(name, role)` helper (the Oban idiom), recording the
  static *role* as the child's registered name — on both the registration
  side (`{DynamicSupervisor, name: Registry.via(conf.name, Foreman)}`) and
  the `start_child` side (`start_child(Registry.via(conf.name, Foreman),
  _)`, resolved through one level of local helper). So a queue supervisor
  Oban starts into the "Foreman" via nests under the DynamicSupervisor that
  holds it, instead of appearing unanchored. The runtime registry name is
  dropped — anchoring matches on the role alone, a deliberate
  over-approximation (correct for a single library instance).
- **`supervisor_child_name` relation (schema version 4).** A child spec's
  registered `:name` option — the `MyApp.Pool` in
  `{DynamicSupervisor, name: MyApp.Pool}` — recorded alongside
  `supervisor_child` by `{sup, position}`. Lets a consumer anchor a
  `dynamic_child` parented by a registered name (the parent of
  `DynamicSupervisor.start_child(MyApp.Pool, _)` is the *name*, not any
  module) to the child that registers it. Only atom names are recorded;
  `{:via, _, _}`/`{:global, _}` names are not, since name-based
  `start_child` targets are always atoms.
- **`use DynamicSupervisor` modules recognized as supervisors.** The
  supervision extractor now emits a `supervisor` fact for
  `DynamicSupervisor` behaviour modules (strategy read from
  `DynamicSupervisor.init/1`, `:one_for_one` otherwise — the only strategy
  the behaviour accepts). A `start_child` call whose supervisor argument
  can't be resolved to an atom now anchors to the enclosing module when
  that module is itself a supervisor (the idiomatic `start_x(sup, …)`
  helper), instead of dropping to the `"dynamic"` sentinel.
- **In-memory embedding surface.** `Argus.Pipeline.extract/2` accepts
  raw beam data binaries alongside module atoms and `.beam` paths
  (recognized via `BeamSpy.BeamFile.beam_data?/1`), and
  `Argus.Pipeline.write_facts/2` is public, so embedders that hold
  bytecode in memory and merge per-module fact maps themselves can
  produce a Souffle-ready facts directory without temp-file round
  trips. Together with `Argus.Analysis.run_rules/3` and
  `Argus.Analysis.filter_to_outputs/2`, this is the blessed surface for
  incremental consumers (the lowdown pattern: assert
  `Argus.Schema.version/0` at compile time and decode with
  `Argus.Facts.decode/1`).
- **Post-dominators and control dependence on `Argus.Cfg`.**
  `Cfg.Function` gains `ipdom` (immediate post-dominators — the same
  Cooper–Harvey–Kennedy fixpoint over the reversed CFG from a virtual
  `:exit`; blocks that never reach the exit are absent),
  `postdominates?/3`, and `control_deps/1` (Ferrante–Ottenstein–Warren
  block-level control dependence). In-process API only — no fact-schema
  change. Powers planchette's flowistry-style slicing.
- **`Argus.Lines`** — line tables built from `line_info` facts
  (`from_facts/1`, `from_facts_dir/1`) with best-effort `resolve/2` for
  instruction IDs (exact line), function IDs and MFAs (first line), and
  `Argus.InstrId` structs. `mix argus` text output and
  `scripts/analyze_project.exs` now annotate every resolvable ID cell
  with its source line.

### Changed (schema version 3) — per-line finding anchors

- **`line_info` covers every instruction.** Rows were emitted only at
  the `{:line, ref}` markers themselves, but anchors name *call-site*
  instruction IDs — so an exact `by_instr` lookup could never hit and
  every consumer silently degraded to function-first-line resolution.
  The emitter now tracks the line in effect and stamps it onto each
  instruction until the next marker; a no-location marker (reference 0,
  compiler-generated code) resets it to unknown, so generated code never
  inherits a source line it isn't from. Instruction-level anchors now
  resolve to their exact source line.
- **`supervisor` gained a `site` column** — the instruction ID of the
  `Supervisor.init`/`start_link` call (or Erlang-style flags literal)
  that defines the tree, `"dynamic"` when not statically found — and
  **`statem_state` gained a `site` column** (the state function in
  `state_functions` mode, the matching instruction in `handle_event`
  mode). Both are trailing additions; the schema version bump to **3**
  covers the `line_info` meaning change and these shape changes.
- **Every module-anchored finding now carries a per-line anchor.**
  Analysis output relations gained witness columns threaded from their
  rule bodies (`stateful_module_dep`, `init_reaches`, `module_reaches`,
  `sync_dep`, `sync_caller` and friends now carry the witnessing
  function; `ets`/`process_registry`/`distributed` relations carry the
  already-bound instruction), and `finding/2` anchors upgraded from
  `at_module` (line 1) to the witness. Only `coverage`'s absence
  findings stay module-level — they have no code location by nature.
- **Supervision-family findings anchor at the tree definition.**
  `one_for_one_coupling`, `wrong_start_order`, and
  `suspect_transient_dependency` now anchor at the supervisor's
  strategy line — the defect is the composition and that is where the
  fix goes — with the coupling call demoted to a labelled related
  location in the child.
- **The coupling analyses no longer overlap.**
  `unlinked_coupled_siblings` was `one_for_one_coupling`'s rule plus a
  link-negation — a strict subset, so running both analyses reported
  every unlinked coupled pair twice (four stacked diagnostics on one
  strategy line). The link-exclusion now lives inside
  `one_for_one_coupling` itself (a linked pair's exit propagates and
  both restart together — the hazard is already mitigated, so this is
  also a precision win), `unlinked_coupled_siblings` is removed, and
  the duplicated `wrong_start_order` keeps a single home in the
  `supervision` analysis. On eusapia: `one_for_one_coupling: 2`
  (unchanged), `supervision` now passes.
- **Witness rows deduplicate deterministically.** A relation provable
  through several call sites yields one Souffle row per witness; output
  relations now declare a `:key` (the fields that identify a logical
  finding) and `Argus.Findings.dedupe_rows/2` — public for in-process
  embedders — keeps the lexicographically least row per key, so finding
  counts never depend on witness multiplicity or row order.

### Fixed (analysis rules; schema version 5)

Five shipped rules produced wrong output; all five lived in analyses
that had **no analysis-level tests** (only their input extractors were
tested), which is how they shipped. Each fix lands with a new
`test/analyses/` file pinning positive and negative cases through real
Souffle — every analysis now has one.

- **`ignored_start_result` had never fired.** Souffle's
  `contains(needle, haystack)` takes the needle first; the rule asked
  "is the callee a substring of `'start_link'`" — false for every real
  callee, so the relation had never produced a row. Fixed the argument
  order and matched the delimited name (`.start_link/`, `.start/`) so
  `Mod.restart_link/1` cannot substring-match. Audited every other
  `contains()` in `priv/dl`: none had a swapped needle.
- **`timeout_insufficient` flagged the default-vs-default chain.**
  `t_ab <= t_bc` marked two chained calls both using the
  `GenServer.call` default (5000 vs 5000) as an `:error` — the
  universal configuration. The comparison is now strict (the equality
  trade-off is documented in the rule), and the via-API timeout rules
  no longer attribute an unrelated resolved sync call's timeout to the
  wrapper's module (callee must be the target module or `"dynamic"`).
- **`distributed` flagged any module's `init/1`.** Its local
  `init_function` had no behaviour gate, so a plain module's ordinary
  `init/1` was treated as supervisor startup; now uses the clientlib's
  behaviour-gated rule. Also: `:net_kernel.monitor_nodes` in init was
  flagged (the exclusion tested `"monitor"` but the extractor emits
  `"monitor_nodes"` — a subscription flag, not a connection attempt),
  and `global_register_risk` fired on `:global.register_name/3` — the
  arity that supplies a conflict resolver, i.e. the fix for the race
  being reported. `global_register` gained a trailing arity column
  (**schema version 5**) and the rule flags only `/2`.
- **`gen_statem` structural rules gated on extraction confidence.** A
  module whose transitions failed to extract (delegating state
  functions, unrecognized return shapes) had every state flagged both
  unreachable AND terminal — extraction-gap noise presented as
  findings. Both rules now require a concretely-resolved transition in
  the module (`coverage_statem_no_transitions` still reports the gap),
  and `unreachable_state` requires no dynamic-target transition. The
  unused `statem_timeout` input and the moduledoc's advertised-but-
  unimplemented timeout/nondeterminism checks are gone.
- **`supervision` now flags `:temporary` siblings.**
  `suspect_transient_dependency` matched only `:transient`, missing the
  strictly-worse case (a temporary child is never restarted, not even
  after a crash). Renamed to `suspect_nonpermanent_dependency` with a
  `restart` column covering both policies.
- Known limitation now pinned by a test: `trap_exit_without_handler`
  cannot fire for `use GenServer` modules — the macro compiles a
  default `handle_info/2` into every module, so the
  function-existence heuristic is vacuous for idiomatic Elixir code. A
  real fix needs clause-level pattern facts. Also dropped the unused
  `registry_op`/`via_tuple`/`named_process` input declarations.

### Fixed (schema version 2)

- **`line_info` now carries real source lines.** The emitter passed
  beam_disasm's `{:line, ref}` operand straight through, so the `line`
  field held a Line-chunk *reference* despite being documented as a
  source line number. The Disassemble stage now parses the module's Line
  chunk (`BeamSpy.Source.parse_line_table/1`) and the emitter resolves
  every marker at emit time. No-location markers (reference 0, on
  compiler-generated code) and modules without a parseable Line chunk
  emit no rows — `line_info` never contains raw references. The schema
  version is bumped to **2** for this meaning change; the relation's
  shape is unchanged.

### Fixed

- **Same-module supervisor children no longer collapse.** Child spec
  dedup keyed on the module alone, so three `{DynamicSupervisor, name: …}`
  children (or two `Livebook.Utils.SupervisionStep` steps) were recorded
  as one. Dedup now keys on `{module, registered_name}`, so children that
  register different names stay distinct; nameless same-module duplicates
  still collapse (nothing distinguishes them).
- **`debug_line` markers resolve to source lines.** OTP 28 debug builds
  (`beam_debug_info`) carry a `debug_line/4` on every executable line;
  the emitter now treats it as a line marker (same sticky semantics as
  `line`), so `line_info` covers debug twins — including the pure-data
  lines the production build never marks. `executable_line` stays
  ignored.
- **Calls now carry def/use facts.** No call form emitted `use` facts
  for its argument registers (x0..x(arity-1)), and label-form local
  calls missed their `def x0` — so data dependence broke at every call
  boundary and a pipeline (a chain of calls threading x0) produced no
  def→use edges at all. Every call form (`call`/`call_ext`/`call_fun`/
  `call_fun2`/`apply` and the tail variants) now emits argument uses,
  and returning forms define x0. `Argus.Dataflow` edges flow through
  call chains; lowdown's line-mapping goldens moved where Rule A can
  now pull argument-setup moves to their consuming call's line — the
  drift its goldens had documented as a known-coarse gap.
- **Supervision children survive runtime list construction.** One
  runtime element in a children list (the stock Phoenix `Application`
  shape — `{DNSCluster, query: Application.get_env(...)}`) splits the
  list into cons cells, and the extractor missed every literal member
  riding in `put_list` operands (bare module heads, the literal tail) —
  zero children extracted, `⚠ children not statically resolved`. The
  extractor now recovers members from cons construction (membership
  over perfect ordering: elements interleaved with runtime construction
  can land out of position), and the runtime-tuple scan accepts any
  `Elixir.`-prefixed module atom instead of requiring the module to be
  loadable in the analyzing VM — the analyzed project's deps never are.
- **Concurrent VMs no longer share temp directories.** Analysis work
  dirs and Souffle output dirs were named with `System.unique_integer/1`
  alone — a VM-local counter — so concurrent `elixir` subprocesses
  (e.g. `mix argus.autoresearch measure`'s per-project workers) drew the
  same names and silently clobbered each other's facts mid-run, making
  corpus measurements nondeterministic (the long-standing "47 vs 73 vs
  146" variance; three of five projects could return byte-identical
  reports for the wrong codebase). Names now include `:os.getpid()`.
  Consecutive corpus measures are exactly reproducible.
- **The `:dynamic` placeholder atom can no longer leak into facts.**
  Partial register resolution marks unknown structure components with
  the `:dynamic` atom; three paths let it escape into fact fields as
  the string `":dynamic"`, which every `"dynamic"` filter in the rules
  fails to match. `resolve_register/3` now reports a top-level
  placeholder as unresolved, and the GenServer `name:` option /
  `{:local, name}` / via-tuple consumers guard their nested slots.
  On the corpus this removed two forged
  `coverage_named_process_unreachable` rows (phoenix_pubsub) and
  surfaced two honest `gen_server_start_name` imprecision events in
  their place.

### Changed

- **`atom_safety` and `whereis_race` rows anchor at the call site.**
  `atom_exhaustion_risk`, `unsafe_deserialization_finding`,
  `code_injection_risk` (now `(id, func, api)`) and `whereis_race` (now
  `(id, func, name)`) carry the offending instruction ID, and the
  exhaustion/injection rules key rows by site instead of by reaching
  export (one row per unsafe call, anchored where the fix goes, rather
  than one per exported entry). Consumers of these output relations
  must account for the new leading `id` field.

### Added

- **`Argus.Extractor.Helpers.call_result_origin/3`** — traces a register
  back to the remote call whose result it holds, following move chains
  with sound register lifetimes (y registers survive calls; non-x0 x
  registers stop at call boundaries). The ETS extractor uses it to map
  operations on table references back to their same-function
  `:ets.new/2` site, so create-and-seed patterns join their `ets_new`
  rows by name instead of falling back to `"dynamic"`. (Both corpus
  tiers are unchanged by this — their remaining ref-based ops live in
  different functions than the creation, which needs cross-function
  dataflow.)
- **`Argus.run_analyses/2` — structured findings API.** Runs a selection
  of built-in analyses (`:all` by default, excluding the `coverage`
  meta-analysis) against one shared fact extraction and returns
  `{:ok, %Argus.Findings{}}`: every output-relation row becomes a finding
  map (`%{analysis, severity, title, detail, module, mfa, instr,
  related}`) with prose explaining why it matters and the most precise
  code anchor the row allows (instruction ID → `Argus.InstrId`, function
  ID → `{m, f, a}`, module string → module atom). Severities are assigned
  per relation by each analysis module's new optional `finding/2`
  callback and documented in its moduledoc. Degradation is explicit:
  missing Souffle → `{:error, :souffle_not_found}`; a single failing
  analysis → a `degraded` note while the others still run. Analyses
  share one facts directory (new `Argus.Analysis.extract_facts/3` +
  `run_rules/3`, which `Argus.Analysis.run/3`, the mix task, and the
  report builder now all compose) and evaluate in parallel — all 15
  analyses finish in ~250 ms for a single module.
- **`Argus.InstrId.parse_func/1`** — parses function ID strings
  (`"Mod:func/arity"`, the instruction ID format without `#idx`) with
  the same right-anchored rules as `parse/1`.
- **`Argus.Dataflow`** — reaching definitions over Layer-1 facts:
  `def_use_edges/1` returns the def→use edge set (which instruction's
  register write feeds which read), computed block-locally (straight-line
  chains, gen/kill summaries, worklist fixpoint, one local resolution walk).
  The successor relation comes from the explicit control-transfer facts
  (`next`/`jump`/`branch`/`select_branch`); exception and bif-fail edges
  are deliberately not followed (the handler's VM-materialized `x0`–`x2`
  have no `def` facts, so following them would fabricate flows).
- **`type_test` facts for the structural pattern tests.** `is_nonempty_list`
  and `is_tagged_tuple` now emit `type_test` rows alongside the guard-style
  unary tests. Both type-test their first operand (the `src` field);
  `is_tagged_tuple`'s arity/tag operands are not recorded. The relation
  shape is unchanged — only its row coverage grows.
- **Typed fact API for in-process consumers.** `Argus.Pipeline.extract/2`
  accepts `format: :typed`, decoding rows against the schema via the new
  `Argus.Facts.decode/1` — field-name-keyed maps with integers for
  `number`/`label` fields and `Argus.InstrId` structs (right-anchored parse,
  safe for generated `-fun-N-` names) for instruction IDs. The Souffle
  `.decl`/`.facts` surface is byte-identical: the new semantic field kinds
  (`:instr_id`, `:func_id`, `:label`) collapse to `symbol`/`number`.
- **`Argus.Schema.version/0`** — a fact-schema version (now 1) for consumers
  to assert against at compile time; bumped on any relation/field change.
- **`Argus.Cfg`** — basic-block control-flow graphs from Layer-1 facts:
  leader-algorithm blocks with typed edges (fallthrough/jump/branch-pass/
  branch-fail/select-arm/select-fail/exception), a dominator tree (iterative
  Cooper–Harvey–Kennedy over reverse postorder), natural-loop headers, and
  per-function entry resolved from `function_def`'s entry label (instruction
  0 is the func_info failure pad, not the entry). Region/dominance helpers
  on `Argus.Cfg.Function`.
- **Receive-loop control-flow facts.** `loop_rec` now emits its empty-mailbox
  branch, `loop_rec_end`/`wait` their loop-back jumps, and `wait_timeout` its
  message-arrival branch — receive loops previously had no back edges in the
  fact base, so no analysis could see them as loops.

- **`mix argus.autoresearch` Mix task** with 9 subcommands:
  `init`, `measure`, `diff`, `rank`, `checks`, `accept`, `revert`,
  `status`, `note`. Each wraps a public API function in
  `Argus.Autoresearch` so the logic is unit-testable.
- **Corpus measurement** (`Argus.Autoresearch.Measure`) — parallel
  per-project subprocess fanout extracted from `scripts/harness.exs`.
  One implementation, two entry points. Ebin discovery via runtime
  `:code.get_path/0` (replaces harness's compile-time `Path.wildcard`).
- **Canonicalized snapshot** (`Argus.Autoresearch.Snapshot`) — reduces
  per-project coverage reports to a deterministic, diffable form.
  Strips nondeterministic fields (timestamp, duration), sorts all
  lists, caps sample_funcs at 10. JSON round-trip preserving.
- **Structural diff** (`Argus.Autoresearch.Diff`) — per-category and
  per-shape-gap deltas with improvements/regressions views, net total,
  and new/removed category tracking. Schema-version-aware (refuses
  cross-version diffs).
- **Priority ranker** (`Argus.Autoresearch.Ranker`) — scores by
  `delta_weight × severity × spread_bonus × stickiness_dampener`.
  Shape-gaps get 3× severity. Dead-end exclusion from notes.md.
  `suggested_extractor` maps 25 category prefixes to source files.
- **Checks barrier** (`Argus.Autoresearch.Checks`) — configurable
  command sequence (default: format + compile + test + dialyzer) plus
  canary correctness cross-check against a committed fixture.
- **Session event log** (`Argus.Autoresearch.Session`) — append-only
  JSONL with event types: baseline_set, measure, rank, attempt_start,
  checks, remeasure, attempt_end, baseline_promoted, revert, note.
- **Baseline store** (`Argus.Autoresearch.Baseline`) — committed
  `.autoresearch/baseline/` with snapshot.json, metadata.json, and
  canary_correctness.json. Promote/read/exists? API.
- **Config** (`Argus.Autoresearch.Config`) — `.autoresearch/config.exs`
  with named corpus tiers (fast/medium/full), canary project, barrier
  commands, concurrency settings.
- **Claude Code skill** at `.claude/skills/argus-autoresearch/SKILL.md`
  — 9-step iteration workflow with two confirmation gates, commit
  protocol (two commits per accepted iteration), dead-end protocol,
  and safety rules.
- **Initial baseline** for the fast-tier corpus (poolboy, phoenix_pubsub,
  plug, jason, bandit): 95 imprecision events across 12 categories,
  19 shape-gap rows.

### Changed

- **beam_spy is now a workspace path dependency** (was hex `~> 0.1.0`):
  argus needs beam_spy's unreleased Line-chunk table fix for `line_info`
  resolution, and lowdown already overrides the dep to the sibling.
- **`scripts/harness.exs`** — subprocess invocation delegated to
  `Argus.Autoresearch.Measure.run_analysis_subprocess/4`. The harness
  still owns compile orchestration and triage; only the subprocess
  primitive is shared.

### Fixed

- **`branch` relation fields told the wrong story.** The emitter has always
  put the test's *fail* label in the field documented as `on_true` ("label if
  condition holds"). Fields are now `fail`/`reserved` (names only — `.facts`
  output is positional and unchanged), and the never-firing false-arm rule in
  `clientlib/cfg.dl` is gone.

### Notes

Day-zero baseline counts (fast tier):

| Category | Count |
|---|---|
| ets_table_ref_op | 30 |
| ignored_result_unknown_api | 22 |
| genserver_callee | 19 |
| registry_op_key | 8 |
| gen_server_start_name | 5 |
| deferred_reply_from | 2 |
| ets_table_name_new | 2 |
| process_link_target | 2 |
| supervisor_child_module | 2 |
| delayed_target | 1 |
| exit_call_target | 1 |
| sync_call_timeout | 1 |
| **Total imprecision** | **95** |

Shape-gap rows: 19 across 4 relations
(coverage_genserver_isolated: 11, coverage_ets_unused: 3,
coverage_named_process_unreachable: 3, coverage_supervisor_no_children: 2).

## 0.4.0 — Unreleased

Coverage and precision instrumentation — Argus can now measure its own
extractor pipeline. Every fallback to a dynamic placeholder is recorded
as a fact, and passive Datalog rules derive "recognized shape but no
detail extracted" findings from the existing fact base. This closes
the feedback loop for iterative precision work: run coverage, change a
resolver, re-run, see whether the imprecision count dropped.

### Added

- **`coverage` analysis** — new built-in meta-analysis measuring the
  extractor pipeline itself. Exposes raw `imprecision_event` events
  (one row per extractor fallback site that fired) plus five shape-gap
  relations derived from the existing fact base:
  - `coverage_supervisor_no_children` — supervisor recognized but no
    static or dynamic children recovered
  - `coverage_genserver_isolated` — GenServer with zero observed
    sync/async traffic in the corpus
  - `coverage_ets_unused` — concretely-named table with no observed
    read or write operations
  - `coverage_statem_no_transitions` — gen_statem with states but no
    transitions extracted
  - `coverage_named_process_unreachable` — registered name with no
    traffic targeting it
  Not in the default correctness set — it's a developer-facing
  meta-analysis. Users opt in via `mix argus coverage`.
- **`imprecision` Layer 2 fact relation** — records extractor
  fallback events (`category`, `func`, `relation`, `reason`). Categories
  are namespaced (`genserver_*`, `supervisor_*`, `ets_*`, `statem_*`,
  etc.) and documented in CHANGELOG as a versioned vocabulary.
- **`track_dynamic/5`, `track_imprecision/5`, `enable_tracing/0`,
  `disable_tracing/0` helpers** — gated on a per-process flag so
  non-coverage runs incur only a single process-dict read per
  fallback site. `Argus.Analysis.run/3` flips the flag on
  automatically when the analysis is `:coverage`.
- **28 tracking call sites across 8 extractors** — every `resolve_*`
  fallback site now either calls `track_dynamic` (when a dynamic
  placeholder is emitted) or `track_imprecision` with reason `:skipped`
  / `:missing` / `:unresolvable` (when the fact is suppressed entirely).
  Coverage categories shipped: `genserver_callee`, `process_link_target`,
  `delayed_target`, `delayed_message_pattern`, `deferred_reply_from`,
  `sync_call_timeout`, `dynamic_supervisor_parent`,
  `dynamic_supervisor_child`, `supervisor_child_module`,
  `supervisor_strategy`, `ets_table_name_new`, `ets_table_ref_op`,
  `ets_options_unresolved`, `process_register_name`, `registry_op_key`,
  `via_tuple_registry`, `via_tuple_key`, `whereis_target`,
  `gen_server_start_name`, `rpc_timeout`, `global_register_name`,
  `global_op_retries`, `exit_call_target`, `trap_exit_unresolved`,
  `ignored_result_unknown_api`, `statem_transition_target`,
  `statem_timeout_value`, `statem_callback_mode_unknown`,
  `unsafe_deserialization_safety`, `gen_event_handler_unresolved`.

### Notes

`mix argus --list` now shows 16 analyses. Existing 15 analyses are
unchanged — the imprecision side-channel is purely additive and gated
off by default, so `mix argus <anything-but-coverage>` incurs no cost
and produces empty `imprecision.facts`.

## 0.3.0 — Unreleased

Bytecode-analysis precision improvements and one new analysis built on
top of them. Implements the punch list from the post-prune gap audit.

### Added

- **`deferred_startup_deadlock` analysis** — narrowly-scoped detector
  for three `handle_continue/2` patterns: mutual continue cycles
  between two GenServers, continue calls to a sibling started later
  under `:one_for_one`, and continue calls back into the parent
  supervisor while it's still mid-`start_link`. Plus a separate
  `continue_crash_loop_risk` finding for defensively-wrapped variants
  (try/catch :exit) that catch the literal deadlock but create
  supervisor restart loops. Verified zero false positives against the
  ~100-project sample corpus, including Oban.
- **`gen_event` extractor** — covers `:gen_event.sync_notify/2`,
  `notify/2`, `call/3,4`, `add_handler/3`, `add_sup_handler/3`. Reuses
  `sync_call`/`async_cast` so existing analyses (`call_cycle`,
  `process_bottleneck`) automatically catch gen_event patterns.
- **PartitionSupervisor child shape support** — `{PartitionSupervisor,
  child_spec: SomeWorker}` now extracts to the underlying worker
  module instead of treating PartitionSupervisor as the worker.
- **DynamicSupervisor.start_child extraction** — adds a new
  `dynamic_child(sup, child_mod, caller_func)` fact and extends
  `child_subtree` so `one_for_one_coupling` and friends see workers
  added at runtime (oban Midwife, Phoenix Channels, Plug.Upload).
- **`closure_def` Layer 1 fact** — every `make_fun3` instruction now
  emits an edge from the parent function to the lifted closure body.
  Treated as a static call edge in the call graph, so `call_reachable`
  follows execution into closures passed to `Enum.map`,
  `:telemetry.span`, `Task.async`, `Phoenix.PubSub` callbacks, etc.
  Concrete fix: `Oban.Peers.Global.handle_info → :global.set_lock`,
  which lives inside a telemetry-span closure, is now reachable.
- **Function-entry barrier and `arg_position/3` helper** — backward
  resolution can now distinguish function parameters from "I don't
  know" without changing `resolve_register/3`'s value contract.
- **Pattern-matched destructuring resolution** — `{:ok, val} = call()`
  resolves to `{:call_field, "Mod:func/arity", 1}` instead of
  `:dynamic`. Foundation for future analyses that correlate
  destructured values with their originating call sites.
- **Pure-BIF whitelist** — `:erlang.element/2`, `tuple_size/1`,
  `length/1`, `byte_size/1`, `atom_to_binary/1`, `++/2`, `hd/1`,
  `tl/1`, `map_size/1`. Resolves to literals when args are statically
  known, otherwise falls back to `:dynamic`.
- **`:via` tuple resolution in OTP** — `GenServer.call({:via, Registry,
  {MyApp.Registry, key}}, _)` now emits a `sync_call_via` fact and
  tags the legacy `sync_call` with `"via:RegistryInstance"` so existing
  analyses can group calls to the same via target.
- **`:global` retries-aware blocking classification** — new `global_op`
  fact captures `:global.set_lock`, `:global.trans`, `:global.del_lock`
  with the resolved retries argument. Datalog rules derive
  `global_blocking_op` only when retries is `"infinity"` or a positive
  integer (NOT `"0"`), so non-blocking try-locks like
  `:global.set_lock(_, _, 0)` are correctly not flagged.
- **`Process.send_after` / `:timer.send_after` / `:timer.apply_after`
  tracking** — new `delayed_message(sender_func, target, message)`
  fact captures implicit `handle_info` sources. Self() targets are
  recognized via the new `last_call_writer/3` helper.
- **`GenServer.reply/2` `deferred_reply` fact** — infrastructure-only;
  no analysis consumes it yet but documents the deferred-reply pattern
  for future timeout-window analysis.
- **`named_process` emission** — ProcessRegistry now actually emits
  the schema-defined relation it previously only documented.
- **Layer 1 emit additions** — `tuple_field_access(id, src, idx, dst)`
  captures `get_tuple_element` indices, `type_test(id, name, src, fail)`
  captures unary type-test names that the generic `branch` fact
  discarded, and `unhandled_op(id, op)` records every opcode that
  fell through the catch-all (so production runs surface what we're
  silently dropping).

### Changed

- **`scripts/analyze_project.exs`** — `:deferred_startup_deadlock`
  added to `@correctness_analyses` default set.
- **OTP extractor `:via` tuple handling** — sync calls against
  `{:via, _, _}` targets now emit a structured `sync_call_via` fact
  alongside the legacy `sync_call` (callee tag becomes
  `"via:RegistryInstance"`).
- **Schema cleanup** — dropped `process_monitor` (extracted but never
  consumed). Verified `supervisor.strategy` IS still consumed by
  `one_for_one_coupling` and `supervision` rules, so kept it.

### Notes

`mix argus --list` now shows 15 analyses. The new
`deferred_startup_deadlock` is wired into both the mix task and the
default `analyze_project.exs` correctness set.

## 0.2.0 — Unreleased

A focused refactor: prune the analysis surface from 28 to 14 BEAM/OTP-specific
detectors, clarify pipeline boundaries, and shrink the codebase by ~40%
without losing the bug-finding power that matters.

### Removed

- **12 generic dataflow primitives** — `cfg`, `callgraph`, `callgraph_ctx`,
  `reachability`, `reaching_def`, `liveness`, `dominators`, `loops`,
  `tail_call`, `constant_propagation`, `function_summary`, `message_flow`.
  These were classic compiler dataflow building blocks with no direct
  bug-finding value for end users. The shared rule library that backs the
  kept analyses (`priv/dl/clientlib/`) is preserved.
- **2 non-BEAM analyses** — `phoenix_security` (framework-specific, better
  handled by web tooling) and `resource_lifecycle` (generic, high false-
  positive risk).
- **`Argus.Souffle` behaviour** — was a 13-line indirection over a single
  `Argus.Souffle.CLI` implementation. Inlined into `Argus.Souffle`.
- **DOT output format from `mix argus`** — only worked for the cut
  cfg/callgraph analyses.
- Orphaned `priv/dl/clientlib/dataflow.dl` and `priv/dl/clientlib/concurrency.dl`.
- Schema relations populated only by removed extractors.

### Changed

- **Pipeline namespace.** `Argus.Extract`, `Argus.Normalize`, and
  `Argus.Emitter` are now `Argus.Pipeline`, `Argus.Pipeline.Normalize`,
  and `Argus.Pipeline.Emit`. A new `Argus.Pipeline.Disassemble` module
  owns module-path resolution and BEAM file loading.
- **Extractor helpers.** New `scan_functions/4`, `scan_remote_calls/4`,
  `resolve_callee/1`, and `resolve_atom/3` helpers in
  `Argus.Extractor.Helpers` removed ~166 lines of duplicated per-instruction
  scan boilerplate across six extractors.
- **`mix argus` discover_dep_modules** now uses `Mix.Project.build_path/0`
  + `Mix.Project.deps_apps/0` instead of a hardcoded `_build/{env}/lib/*/ebin`
  glob. The previous version only worked when each dep had its own `_build`.
- **`mix argus` module discovery** wraps `String.to_existing_atom/1`, so
  stale `.beam` files for unloaded modules are silently skipped instead
  of crashing discovery.
- **README and docs** refreshed to focus on the kept BEAM/OTP analyses,
  with grouped descriptions and a real Oban example.

### Added

- `CHANGELOG.md` (this file).

### Notes for upstream users

This is a 0.x project with no published Hex releases. Anyone using
`Argus.Extract`, `Argus.Normalize`, or `Argus.Emitter` directly will need to
update to the `Argus.Pipeline.*` names. Anyone running cut analyses
(`mix argus cfg`, `mix argus callgraph`, etc.) will need to migrate to one
of the kept analyses or write a `mix argus custom` rules file against the
preserved `priv/dl/clientlib/` rule library.

## 0.1.0

Initial research release with 28 analyses spanning generic dataflow primitives,
BEAM/OTP bug detectors, and framework-specific checks.
