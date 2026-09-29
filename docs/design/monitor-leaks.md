# Monitors that pile up

A design note for mailbox's monitor-leak class (`monitor_leak`, three
titles) and for the vocabulary it rests on, `clientlib/runs.dl`. It
replaces three rules that started from every monitor and subtracted
correct code: "Monitor left live after a wait times out"
(`unconsumed_monitor` `timed_wait`), "Server monitors but never
demonitors" (`never_released`) and "Server drops the ref of a monitor it
establishes" (`ref_discarded`).

## What the rows said

The three rules made 102 rows over the 39 evaluation sets: the 19 of the
ETS and supervision rounds, and the 26 live projects (six are in both).
The rows were 71 dropped refs, 19 servers that never demonitor and 12
timed waits. Every row was read against its source, with the questions:
how often the site runs, what the monitor stands for, whether the
relationship can end while the monitored process lives, and whether live
monitors grow with the number of runs.

**True, 7.** Each is one live process monitored again and again:
- ejabberd's `ejabberd_router_mnesia` monitors a route's owner on every
  write of the route table, and an owner that registers its routes again
  (a vhost added, a module reloaded) gains another monitor.
- `rabbit_alarm` monitors an alertee on every `register`, and a peer's
  alarm handler registers again on each `node_up`.
- Livebook's `ObjectTracker` monitors on every `add_reference`, and
  `remove_reference_sync` drops the references without a demonitor.
- Finch's HTTP/2 pool monitors a caller when it has no request in flight,
  and deletes that record when the last request ends, without a
  demonitor.
- postgrex#781's `Postgrex.Parameters` monitors on every insert, and a
  reconnecting connection's delete leaves the monitor.
- eventstore's `AdvisoryLocks` resets its locks when its connection's
  `:DOWN` comes, and each owner's monitor stays; the owner locks again.
- Phoenix's `LiveViewTest.render_chunk/3` monitors the test's proxy and
  returns on its success path with the monitor live, once per upload
  chunk.

**False, 95.** None was a leak:
- 29: one monitor per live relationship. A registration ends only with
  its process's `:DOWN`, or the site asks the state first: each process
  is monitored once while it is registered (eventstore's
  `MonitoredServer`, `Ecto.Repo.Registry`, syn's scopes, emqx's broker
  helper).
- 28: code that runs once per process: an `init/1`, a
  `handle_continue/2`, a channel's join, or a handler clause for a
  message that comes once.
- 20: a process the server started and keeps (mod_muc's rooms, zotonic's
  pool connections): one monitor per started process, which its `:DOWN`
  ends.
- 6: a wait that releases the monitor on every way out, through a helper
  or a plain demonitor the rules did not see.
- 5 unreachable; 3 on the way out (terminate); 2 on a process already
  dead; 2 in a monitoring process that ends right after.

Three more rows are credited outside the evaluation sets: the corpus pair
postgrex#781 (the `Parameters` row above), the corpus pair
supavisor@e80c9a2 (`Supavisor.ClientHandler` drops its manager monitor's
ref, and its `:DOWN` clause takes any `:DOWN` as the manager's), and
encore's madrigal seed (`Madrigal.Wait.await_downfall/2`, a timed wait
with no demonitor).

## The hypothesis, tested

The hypothesis was that the harm of an unconsumed monitor is a leak, and
a leak needs repetition: a long-lived process that takes monitors on a
path that runs again, with nothing that releases them.

Repetition is necessary. No true row is in code that runs once, and the
28 once-code rows and 3 terminate rows are all false. It is not
sufficient: 77 rows are in code that runs again, and 70 of them are false.
Most of those (29) are registrations: a handler that monitors each
process that registers, keeps it until its `:DOWN`, and never meets the
same process twice while the first monitor lives. A monitor per live
relationship is bounded by the relationships. What the true rows share
is a **second live monitor on one process**: the site runs again, meets
a process it already monitors, and the first monitor is still live.

A `:DOWN` that is taken as another monitor's is a second harm. It is the
supavisor pair's: the `:DOWN` clause matches any ref, and the handler
takes no other monitor, so nothing is misattributed at run time. A
`:DOWN` no clause takes is unhandled_info's (its `monitor` source) and is
not asked here.

## The model

Let s be a monitor site in function f, taken by process P on process T.

**The run repeats** (`again_code(f)`, clientlib/runs.dl). f is reached,
on P's own stack (no side path), from a root that runs again:
- a callback that runs whenever its request or message comes
  (`runs_again_callback`, and a GenEvent handler's `handle_event/2` and
  `handle_call/2`);
- a gen_statem's state function or `handle_event/4`;
- a receive loop, a function that receives and reaches itself again;
- a function only callers outside the program call. That is an export
  that no function of the program calls, that no start of the program
  runs (`process_start`), that no supervisor starts (the `start_link` of
  a module a child spec names), and that no library's macro wrote
  (`library_written`).

It is the complement of the restart-state model's `once_code`, which
moves to runs.dl beside it. A helper that `init/1` and a handler share is
both.

**It can meet T again** (`!starts_its_target(s)`). T is not, on every
path, a process f itself started. `monitor_answer` (the Monitor
extractor, `Argus.Extractor.Answers`) names the calls whose answer the
pid is on every path: the pid itself, or the one in its `{:ok, pid}`. A
start's `{:error, {:already_started, pid}}` is not a fresh process: its
pid is an element of an element, and a path that monitors it leaves the
site without an answer. Each call is followed through the program's
wrappers (`call_origin`, clientlib/answers.dl: a function every way out
of which hands back one of its calls' answers, in any module, to any
depth; issue #3's `Tortoise.TransmitterSupervisor.start_transmitter/1`
over `DynamicSupervisor.start_child/2`) to calls outside the program,
and every one of those origins must start a process: a start the
process facts know (`process_start`), or a library's call named like a
start (`:gun.open`). A function of the program that looks a process up
on some way out (review 2, item 25), re-wraps an already-started pid,
hands back a parameter or answers a reply answers nothing, and T is not
taken as new.

**The run does not release it** (`!released_by_run(s, f)`). Some way out
of f keeps the monitor live. A way out releases it when it:
- takes its `:DOWN` in a receive clause,
- demonitors its ref, with `[:flush]` or without,
- hands the ref to a function of the module that releases it on every
  way out,
- or returns to callers that all release it after the call
  (`monitor_released`, `collected_by_callers`).

A demonitor without `[:flush]` is a release: a `:DOWN` already queued is
one late message, the mailbox's to take, not a monitor left live.

**The monitor before is still live**, shown one of three ways (`how`):
- **wait**: f, or a caller its ref goes back to, waits for a `:DOWN` (a
  receive with a `:DOWN` clause, `recv_takes_down`). A way out keeps the
  monitor: the wait timed out, or the answer came first. The next run
  asks the same process again.
- **ended**: the run records T in P, where it keeps the monitor's ref or
  T's pid (`monitor_kept`, over `Argus.Extractor.StateFields`): a field
  of the state it returns whose value is made of the ref, or made whole
  of the pid; a row a table write it makes is handed such a value; or,
  through the functions that hand back what holds it, the field a
  caller keeps their answer in (by the element of a returned tuple that
  holds it). A field the monitoring clause sets to anything else is no
  record. A clause of a callback that runs again drops that record,
  while T may live, without releasing the monitor:
  - a clause other than a `:DOWN` one removes an entry and returns the
    field it removed from (the field whose value is the removal's
    answer), or deletes rows of the table;
  - or any clause empties the field, `:DOWN` clauses included
    (AdvisoryLocks resets every lock on its connection's `:DOWN`).

  The drop releases when its clause demonitors or stops a process. T's
  next registration monitors it again.
- **dropped**: the ref is thrown away (`monitor_ref_dropped`, which
  follows a ref every return answers into the callers). Only T's death
  releases the monitor. The site is reached from a root that runs again
  with no call on the way decided by P's state (`state_decided`, the
  guard a repeated subscription's walk asks). Each time T is named again,
  one more monitor.

The severity is `:warning` for wait and ended: a leak that needs one more
thing a running system supplies, the run again. It is `:info` for
dropped: whether the same process is named again is the protocol's, and
the code does not show it (the rubric's evidence clause).

### What it assumes

- A raise ends the run: the walk that asks whether every way out releases
  the monitor does not follow a path that raises. A timed wait whose
  `after` raises (madrigal's seed, `RaisingAfter`) starts no such walk, so
  it is reported: a caller that catches keeps the monitor.
- The record is read by where it is kept (a field, a table of the module),
  not by its key: a drop of one field entry ties to every monitor whose
  ref or pid that field holds. Until issue #3's follow-up it was every
  field and table the monitoring clause wrote (hackney's connection
  buffers, ra's notifications, other modules' clauses reaching a helper
  that monitors); the eval sets lost 11 rows to the change, 10 false and
  one true (below). A field set to a scalar literal is not a drop:
  global_group's sync keeps its refs in `config_check` and three clauses
  reset it to `undefined` without a demonitor, a true leak this misses
  (Postgrex.Notifications resets a pending `ref` it also keeps in its
  listeners the same way, and would be reported with it). A clause is a callback's by its message's
  tag, and a gen_statem's by its event's type and content together
  (`clause_event`, issue #3): what the `:internal :connect` clause
  records is not what an `:internal {:received, _}` clause resets, and an
  `:info` clause whose content is `:DOWN` is a `:DOWN` clause.
- A function nothing in the program calls is called again from outside.

### What it deliberately does not claim

- **The protocol.** Whether the same process registers twice while its
  first registration lives is not in the code: dropped rows over
  registrations one process makes once (a subscriber's `init/1` asking a
  registry) are reported. This is the class's largest false kind, and a
  prior candidate: does the requester ask again?
- **Once at run time, but by protocol or by state.** A clause whose
  every message once code makes runs once (runs.dl's once clauses,
  docs/design/runs.md: sequin's `TableReaderServer`, whose `:internal`
  event `init/1` alone inserts), and so does a site a gate on the state
  lets run once and its own run closes (runs.dl's `gated_once_site`:
  honeydew's `JobMonitor` claims while `worker: nil` and sets the
  caller's pid). A clause that runs once because another process drives
  it so (a channel's join, sent once by the process that started the
  channel), or because a status field lets it past what the gate reads
  (Livebook's `RuntimeServer` `:attach` sets the owner the message names,
  which may be nil), runs again as far as the code shows. So does ra's
  `post_init/3` clause: ra inserts `:internal` events on its way through
  three states, and the event's type and content do not tell them apart
  (the state would).
- **A start the facts do not know.** A process a program function starts
  and does not hand back whole on every way out (a room it registers and
  then answers from a lookup, an outbound connection behind a function
  that also reuses one) is taken as one the site can meet again. One
  handed back on every way out, through any number of the program's
  functions, is the start's (answers.dl).
- **A monitoring process that ends.** A per-job or per-request process
  whose every end stops it holds its monitors for its own short life.
- **Stale `:DOWN`s.** A `:DOWN` that arrives after the wait gave up, into
  a clause that takes it for something else or into no clause, is not a
  leak: unhandled_info (no clause, or a catch-all) and the handler's own
  clauses own it.

## What it replaces, and what it subsumes

Deleted: `unconsumed_monitor` and its three kinds, `monitored_entry_removal`,
and in mailbox.dl:
- `timed_wait`, `outlives_its_wait`: the wait witness asks for a `:DOWN`
  clause, not an `after`. A wait's answer path keeps the monitor as
  surely as its timeout does.
- `process_tail`, `called_otherwise`, `monitor_loop`, `recurses`,
  `ends_its_process`, `live_reach`, `on_the_way_out`: a spawned body's
  last act and a terminate-only drain are not reached from a root that
  runs again.
- `owned_monitor`, `calls_program_starter`, and the extractor fact
  `monitor_owns` with its hand-off walk: one monitor per started process
  is the "it can meet T again" condition. A worker whose pid is handed to
  another process is still new on every run (`MonitorsHandedWorker` is
  quiet now).
- `removes_entries` and `!module_demonitors` for the never-released kind:
  a removal anywhere in the module, and any demonitor anywhere, became
  the drop of the record the run wrote, and the drop's own release.

Renamed: `awaits_down_after` is `monitor_released_after`, and
receive.dl's `waited_out` is `monitor_released`. A plain demonitor and a
helper handed the ref now release the monitor.

Added:
- runs.dl's `again_code`.
- The facts `recv_takes_down`, `monitor_started` (since issue #3,
  `monitor_answer` over clientlib/answers.dl), and `param_decided` of
  monitor sites.
- `monitor_ref_dropped` through a ref every return answers.
- The helpers that release a ref they are handed.
- The record and drop joins.
- The evidence relation `monitor_leak_frame`, which relates where the
  record is dropped and the callback that runs the site again: a root
  whose way to the monitoring function passes no site that runs once
  (`once_site`), and, for a thrown-away ref, no call the state decides
  either (`unasked`'s walk). A handle_continue/2 clause init/1 continues
  to that also reaches the helper is not one.

The unhandled_info monitor source keeps its own question (`flush`, a
receive in reach) unchanged.

## Soundness

Every credited true row still fires:
- the seven above;
- the corpus pairs postgrex#781 ("Entry dropped while its process stays
  monitored", absent at the fix's demonitor) and supavisor@e80c9a2
  ("Monitor taken again with its ref thrown away", absent once the ref is
  kept);
- madrigal's seed ("Monitor left live each time a wait returns");
- every test/soundness fixture of review 2 (`ReplyOrDown`,
  `ReplyOrDownCaller`, `HelperReplyOrDown`, `TimedGivesUp`, `MaybeWaits`,
  `SameBody`, `Tracker`, `MixedCallers`, `MapDropped2`,
  `ListsMapDropped`, `RaisingAfter`).

Each narrowing has three adversarial neighbours in
test/soundness/monitors_test.exs that it must not excuse:
- the run repeats: a helper `init/1` and a handler share, a gen_statem's
  event handler, a spawned receive loop;
- it can meet T again: a start beside a monitor of the caller, a named
  start that answers the running process, a worker another callback
  started; and through a wrapper, one that looks the process up first,
  one that re-wraps the already-started pid, one that hands back its
  parameter, a function named like a start that answers a reply;
- released by the run: a demonitor on the answer path only, a demonitor
  of the other monitor, a helper that releases on one way out;
- dropped: a test of the request, a clause that reaches the same helper
  without asking, a test of the state after the monitor;
- ended: a drop in a helper for an unsubscribe, a reset in another
  monitor's `:DOWN` clause, a row a cast deletes.

Two quiet controls sit beside them: a demonitor without `:flush` on every
way out, and a drop that demonitors.

Fixtures that changed their verdict, by the model:
- `MonitorLeak.Blocks` and `ClientSideMonitor` now fire. Their answer path
  returns with the monitor live, so each call adds one on the peer.
- `MonitorsHandedWorker` is quiet. Its worker is new on every run.

## Measured

Over the 39 evaluation sets:

| | before | after |
|---|---|---|
| rows | 102 (71 dropped, 19 never released, 12 timed) | 97 (43 dropped, 23 ended, 31 wait) |
| true | 7 | 17 |
| precision | 7% | 18% |

- **Gone.** 50 of the 99 sites reported before, all false: the once code,
  the terminate drains, the owned processes, the waits a plain demonitor
  or a releasing helper closes, and the registrations whose only removal
  is their `:DOWN`.
- **Kept.** All 7 true rows.
- **Added.** 44 sites, 10 of them true:
  - Livebook's `Evaluator.call/2`: the runtime server gains one monitor
    on the evaluator per evaluation.
  - Phoenix's `CodeReloader.Server.sync/0`: one monitor on the reloader
    per request under a keep-alive server, in dev.
  - elixir-ls's `Stacktrace.get/1`: one monitor per stop on the debugged
    process.
  - elixir-ls's paused-process bookkeeping, twice: an overwrite loses a
    ref.
  - partisan_monitor: a monitor a timed-out requester never releases.
  - emqx's durable-storage `subscribe/3`: a monitor on the beamformer per
    subscription, never released.
  - OTP `global_group`'s sync: a check that is overwritten keeps its
    monitor.
  - Livebook's smart-cell scan: a record dropped when the cell stops
    mid-scan.
  - OTP `pg:join_local/3`: the leave demonitors without `:flush`, and a
    `:DOWN` meets a newer ref. This is a crash by the stale message, not a
    pile-up.

By witness:
- wait: 8 of 31 true;
- ended: 5 of 23 true;
- dropped: 4 of 43 true.

What is left false, 80 rows:
- 29: one monitor per live relationship (the protocol);
- 20: once at run time;
- 9: a process a program function started;
- 7: a short-lived monitoring process;
- 6: a release the walk does not see;
- 5: on the way out, in a terminate the model does not see as one (a
  module that declares no behaviour, a special process's shutdown);
- 3: unreachable or test-only;
- 1: a target already dead.

### The record, since issue #3's follow-up

The record became where the monitor's ref or pid is kept. Over the 44
evaluation sets, 11 `ended` rows went and none came:
- 10 false: hackney's `do_request_async/9` and `track_h2_stream/4`
  (buffers and stream maps reset beside the owner's monitor), ra's
  `ra_monitors:add/3` (a notification map emptied on leadership),
  ejabberd's `new_connection_int/7` (fields of other modules' clauses that
  reach it), firezone's four channel registrations and presence tracks
  (other assigns removed from the socket), OTP `global`'s `insert_lock/4`
  and `insert_global_name/6` (fields of the calling clause; the lock and
  name tables they do keep are released with a demonitor).
- 1 true: OTP `global_group`'s sync. Its row was reported for a drop of
  `nodes`, which holds no monitor; the refs are in `config_check`, which
  three clauses reset to `undefined` without a demonitor. The record is
  now `config_check` (through the fold's answer, by the element that
  holds the refs), and a reset to a scalar literal is not a drop.
