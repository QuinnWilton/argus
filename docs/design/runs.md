# Code that runs once, and code that runs again

A design note for the vocabulary in `clientlib/runs.dl`: `once_code`,
`again_code`, and what decides them for a handler's clauses. Three
questions turn on the split:

- coupling (docs/design/restart-state.md): a request a process's once
  code makes of a sibling is lost when the sibling restarts, since
  nothing makes it again;
- mailbox's monitors (docs/design/monitor-leaks.md): a monitor that code
  which runs again takes is taken again;
- mailbox's timer loops and repeated subscriptions: a second arm of a
  periodic loop, or a second subscription, made from code that runs
  again.

Before this note, the split was per function. Once code was a start
callback (init/1, a Channel's join/3, a LiveView's mount/3, and
handle_continue/2 whatever continued to it) and what it ran. Code that ran
again was every handler, whatever message entered it. Mailbox kept a
narrower rule of its own for its timer loops and subscriptions: a
handle_info/2 clause for a literal the start callback sends itself, which
no other site of the module sends (`once_message`, `once_cast`,
`sent_again`, `once_clause`).

## What the rows said

**The monitor round's "once at run time" (20 false rows).** Read again,
by what makes the clause run once:

- 2: a gen_statem's `:internal` event that init/1 inserts. sequin's
  `TableReaderServer` inserts `:init` once and takes it in state
  `:initializing`. ra's `ra_server_proc` inserts `{go, _}` into
  `post_init`, whose clause runs `do_init/1`.
- 2: a Phoenix channel's join. The transport starts the channel through a
  starter fun and sends it `{Phoenix.Channel, ...}` once
  (`Phoenix.Channel.Server:init_join/3`, `LiveView.Channel:verified_mount/8`).
- 1: a call the starter makes right after the start
  (`rabbit_amqqueue_process:init_it/3`, through `{init, Recover}`).
- 9: a state field lets the clause run once: Livebook's
  `RuntimeServer` `:attach` raises when an owner is set, `FLAME.Runner`
  boots only from `:awaiting_boot`, honeydew's `JobMonitor` claims only
  while `worker: nil`, vernemq's connection parsers take the connect
  frame once.
- 2: once per connection process by the call structure
  (`ejabberd_websocket:connect/2`, reached through a computed module).
- 1: a caller that calls once (`emqx_ft_responder`'s kickoff).
- 1: unreachable.

Only the first kind is a question of who sends the message. The others
run once because of how another process drives them (a protocol), or
because the process's state says so. Those are outside a split that asks
where the messages come from.

**ra's "No clause for a message a gen_statem is sent" (11 false rows).**
Every row names `post_init/3`. `recovered/3`, `terminating_leader/3` and
`terminating_follower/3` are partial handlers behind it. The reason is
the gen_statem extractor, not the once phase. It missed six of ra's
twelve states: `leader`, `follower`, `candidate`, `pre_vote`,
`await_condition` and `receive_snapshot`. They re-dispatch an event to
themselves (`leader(EventType, Msg, State)` with a rewritten message), and
`terminating_leader/3` runs `leader/3`'s clauses, and a state was any
function no local call reaches. It also read `terminating_leader/3`'s
generic clause as no catch-all. The walk that looks for one went past the
call into a `case` on the call's result, and took those tests for the
clause head's. With the states seen, `leader/3` and its siblings take
every message the rows name. The rule already reads "a message some state
takes may be one the program only sends while the machine is in that
state", and it covers these.

**Mailbox's own rule (6 false rows).**
- 4 timer loops were armed from a clause that only init/1's message
  enters. nerves_hub's `OrchestratorRegistration` arms
  `:monitor_orchestrators` from `:start_orchestrators`. sequin's
  `ConsumerProducer` and `SlotMessageStore` arm their loops from `:init`,
  and from `:start`, which `ProcessMetrics.start/0` sends. That helper
  lives in another module, which the old rule took for another process.
- 2 subscriptions were made in a clause only the start's message enters:
  firezone's `Relay.Channel` `{:after_join, …}`, sent from a closure
  `join/3` runs, and Lightning's `RunLive` `handle_async(:run, …)`, which
  only `mount/3` starts.

**Coupling.**
- handle_continue/2 counted as once code whatever continued to it.
  Livebook's `NotebookManager` continues to `:dump_state` after every
  change.
- A request made from a clause only init/1's message enters was not once
  code. MongooseIM's `service_domain_db` casts itself `initial_loading`
  and loads every domain into its sibling `mongoose_domain_core`.

No true row of any affected class depended on the over-approximation.

## The model

A clause runs once per incarnation of its process when every message
that can enter it is made by that process's once code. Messages come from
producers the program shows, and once-ness spreads through what the
clause runs. The definition is positive: a clause is once code because
its producers are known and all are once code. Anything unknown or
repeating makes it code that runs again, the loud direction.

### Clause functions

A clause function takes a message by the tag its first argument's head
tells apart (`clause_call`):

- handle_info/2 and handle_cast/2, by the message's tag;
- handle_continue/2, by the continue term's tag;
- a LiveView's handle_async/3, by the task's name;
- a gen_statem's state function or handle_event/4: its `:internal` clause
  only. Its other clauses take events from outside, and are code that
  runs again;
- a function a clause function hands its message to whole: same name and
  arity, the first argument forwarded (`defdelegate handle_info(msg, s),
  to: Shared`, firezone's channels). It takes the message where the
  callback would, in the callback's process.

A clause function's process is its module's, or that of the callback that
hands it the message. A clause is judged in every process that runs it.

### Producers

A producer makes a message for the process that runs it, of a kind
(`info`, `cast`, `continue`, `async`, `internal`) and a tag (`*` for any):

- a send to `self()` (`pid_send`);
- a one-shot timer armed for the process. Its message is the literal it
  spells, or the literal or tuple tag its callers hand a helper that arms
  its parameter (`call_arg`, `call_arg_tuple`, forwarded through
  `call_arg_forward`);
- a monitor (its `:DOWN`), and a task the process does not await (its
  `:DOWN`);
- a callback return that arms the idle timeout, `:timeout`
  (`timeout_return`: `{:noreply, state, ms}` and its kin, a value the
  return does not spell included), in a callback or in a function whose
  result one returns;
- a cast to `self()`;
- a return that continues (`continue_return`), in any function;
- `start_async/3,4`, by the name it is handed;
- an event a gen_statem inserts (`statem_insert`, `{:next_event, type,
  content}`): `:internal`, or any type where the function does not spell
  it (ra's `{next_event, EvtType, Evt}`);
- a call of a clause function of the same module, with its message.

A producer is attributed to what reaches it on the process's own stack:
the process's start callbacks, a clause of one of its clause functions,
or a root that runs again as a whole. A root is a callback no clause is
told for (handle_call/3, a channel's handle_in/3), a receive loop, or an
export only callers outside the program call.

Producers another process may be:

- a send, or a one-shot timer, to a process other than the sender's;
- a cast that is not to `self()`;
- an interval timer (`:timer.send_interval/2,3`), which sends again and
  again wherever it is armed. The process that arms it takes it as code
  that runs again;
- a message the program hands Phoenix.PubSub's broadcast, itself or
  through a function that hands a parameter on to one. The library sends
  it from code the facts do not show;
- a call of the clause function from another module.

Some producers belong to a process that is not known:
- one no known root reaches (a fun made to run elsewhere);
- one reached from a receive loop;
- one reached from an outside caller's export.

Such a producer counts for a process only if that process's own code
makes a call the call graph does not follow (`opaque_stack`): an apply of
an unknown module or function, a fun value's call, or a protocol's
dispatch. Only through such a call can code off the graph run on the
process's stack. An export also counts for its own module's clauses
whatever the stack. It may be a callback of a behaviour no table lists (a
LiveComponent's `update/2`), which its library runs where it runs the
module's other callbacks.

### Once clauses

`once_clause(func, tag)` holds when all of these hold:

- some producer spells the tag. A tag only a `*` producer may carry may
  come from the runtime or a library, which the facts do not show;
- no outside producer makes it;
- every producer, in every process that runs the clause, is the
  process's start or a once clause;
- the producers do not reach back to the clause itself.

The last condition keeps a periodic loop out. init/1 arms `:tick`, and
the `:tick` clause arms it again, so the clause's producers are init/1
and the clause itself. Read as "all producers once", the clause would be
once only by assuming it. Datalog computes the complement instead. A
clause runs again when any of these enters it: an outside producer, code
that runs again, a clause that runs again, a callback's untold part, or
a cycle of producers. `once_clause` is a clause some producer spells that
nothing makes run again. It is a least fixpoint over positive rules, with
one negation after it.

"Once" means caused by the start alone, which is bounded per incarnation.
An init/1 that sends itself one message per item makes that many. A
`:DOWN` clause for the monitors init/1 takes runs once per monitor. None
of them runs again after the start phase.

### What the split gives its readers

- `once_code(mod, func)`: what may run in the module's once phase, on its
  own stack. That is its start callbacks, its once clauses, and the
  start's continue chain (`start_clause`): a handle_continue/2 clause
  init/1's continue enters, or one a clause of the chain continues to,
  whatever else continues to it later. gen_server runs init/1's continue
  before any message, as part of the start. Coupling asks what a start
  may ask for once, and a request the start makes there may not be made
  again after its peer's restart: jackalope's Hare continues to
  `:consume_work_list` from init/1 and from every reconnect, and its
  corpus pair (the fix is `rest_for_one`) needs the start's subscription
  counted. A clause a message enters is part of the once phase only when
  it runs once: a periodic loop init/1 arms asks again on every tick, and
  the restart-state model leaves a peer's own schedule to the priors. It
  is seeded at supervised modules, since coupling's question is about
  children.
- `once_step(mod, func, site, callee)`: the calls the once phase makes
  at its own level, a start callback's calls and the calls at the sites
  of the once phase. once_code is the start callbacks and what the steps
  reach. The step is the module's own code where what it reaches may be a
  helper's or another module's API, so a finding about a request once code
  makes points at it (coupling's registration frame).
- `again_code(func)`: reached from a root that runs again as a whole, or
  from a call in a clause that runs again. That is a clause not once, or a
  site no clause tag names. The reach does not enter a clause function by
  a call. Entering one is a message, and its clauses are judged by what
  enters them. Every clause function is again code as a function; a site
  asks `once_clause_site`.
- `once_clause_site(site, func)`: every clause the site is in is once.
- `once_site(site, func)`: the site runs at most once per incarnation,
  in a clause that runs once or behind a gate on the state that its own
  run closes (`gated_once_site`, below). The consumers ask this word.
- `once_clause(func, tag)`, for a reader judging a clause by its tag
  (mailbox's monitor record).
- `again_root(func, "callback")` now names handle_continue/2 too.

## Once by the state

The producers are one reason a clause runs once. The state is another.
A GenServer handler asks its state whether it has done a thing yet, does
it, and records that it has:

```elixir
def handle_info(:registered, %{registered: false} = state) do
  schedule_check()
  {:noreply, %{state | registered: true}}
end
```

Whatever sends `:registered` again, the clause finds the field set and
does not arm the loop. A site runs at most once per incarnation this way
(`gated_once_site(site, func)`) when all of these hold:

1. **The gate.** Every path from the handler's entry to the site passes
   a test of a field of the state that admits only some atoms
   (`state_gate`): a clause head `%{registered: false}`, `if state.timer
   == nil`, `case state.status do :idle -> ...`, `if state.owner` (nil
   and false), an Erlang record's `#state{ref = undefined}`.
2. **Closed.** Every way the handler completes after the site hands back
   the field outside those atoms, or ends the process (`gate_closed`): a
   literal outside them, a value no atom is (a fresh ref, the caller in
   handle_call/3's `from`), a `{:stop, ...}`, a raise.
3. **Nothing sets it back.** No return of the module's handlers or
   code_change/3 sets the field to an atom the gate admits, or to a value
   the return does not show (`state_return`). init/1 starts the field
   there for each incarnation, and terminate/2's return is dropped.
4. **Only the loop runs the handler.** Nothing in the program calls it
   (`call_edge`): a call of a handler with a state of the caller's making
   runs the site whatever the process holds.

The module is a GenServer, or a wrapper that hands its users GenServer's
callbacks (`behaves_as`). A result of a shape GenServer does not return
(Connection's `{:connect, info, state}`, a replication connection's
`{:noreply, [data], state}`) reads as any state. A server under a
behaviour the alias table does not know is not read.

Each condition is a positive witness the extractor reads
(`Argus.Extractors.StateGate`), and each is needed:

- The gate is read on the state the handler was handed: a map pattern,
  `state.key` (the fast and the slow path), `:erlang.map_get/2` in a
  guard, a record's field (`get_tuple_element`, `element/2`). A field of
  a value made from the state (`state.conn.ready`, `Map.get/2`, a
  helper's answer) is not. The site is walked to once for each atom the
  function compares the field with, and once for a value it compares
  with none (another atom, a value of another type, an absent field);
  the site is gated when that last walk misses it, and admits the atoms
  whose walks reach it. A struct's `__struct__` is its type, not a
  status, and is not read.
- Closing is read over every way the handler completes after the site:
  its returns and tail calls, the handler of a `try` the site may be
  inside. A return reads the result's state slot (`{:noreply, state,
  ...}`, `{:reply, r, state, ...}`), through the local helpers it
  returns through or hands the state to, and the helper's own returns.
  A `throw` after the site closes nothing: gen_server takes a thrown
  value as the handler's result.
- `state_return` reads every way the handlers and code_change/3
  complete, for the fields the module's gates test. A value is
  `dynamic` when it comes from the message, a call the reading does not
  know, or a state the return does not show (a helper of another
  module, a state from the message). Each row names the clause its
  return is in (the tag of the handler's first argument on the way, `*`
  for none), and init/1's returns are read too: the state each
  incarnation starts with. The races' handoff reads both
  (docs/design/races.md, "Handed off"), with `state_excluded`: a site
  the walk for an atom misses while another walk reaches it does not run
  while the field holds that atom. A walk that fixes a field takes the
  state to have the shape the field is read under (a record's tuple
  tests, a map's `is_map` and the `get_map_elements` that reads the
  key): a state that holds the field has it.
- The fourth: honeydew's `JobMonitor` claims in `handle_call({:claim,
  job}, {worker, _}, %State{worker: nil})`; if another handler ran
  `handle_call({:claim, j}, from, %{state | worker: nil})`, the claim
  would run again.

`gated_once_site` joins `once_clause_site` as `once_site`. The reach of
code that runs again does not pass a call at a gated site (`gated_edge`
cuts a handler's callee every call of which is gated; a clause
function's gated call is no root). Coupling's once code gains the
gated sites' reach, and a call or a cast a handler makes at a gated site
is a once request.

## The gen_statem extractor

Three readings changed, each a miss of the machine's states:

- **A state an event is re-dispatched to.** A function a local call
  reaches is a state when every such call hands it an event and some
  transition of the module names it. The event is the caller's own first
  argument or an event type. The transition is one of these:
  - a literal `{:next_state, state, ...}`;
  - init/1's `{:ok, state, ...}`;
  - the literal a call hands a local helper whose `{:next_state, target,
    ...}` reads that parameter (ra's `next_state(follower, State,
    Actions)`).

  Redix's `disconnect(data, reason, flag)`, handed the data first, stays
  a helper, and so does a shared event handler no transition names.
- **A state whose clauses return through a helper.** A state returns an
  action itself or through a local function whose result it returns.
- **A call ends the head.** The catch-all walk stops at a call: no clause
  head calls anything, and after one `{x, 0}` holds its result. A test
  before the call still decides (a content pattern, a guard on the type).

The extractor also reads `statem_insert` (inserted events).

## Consumers

- **Monitors** (mailbox): a leak site is a monitor in again code at a
  site that does not run once (`!once_site`). The dropped-ref walk
  does not pass a call at a site that runs once. The monitoring clause of
  the "ended" witness is a clause that runs again.
- **Timer loops and subscriptions** (mailbox): a second arm, or a
  subscription, at a site that runs once is no second path. Their entries
  are `again_root`'s callbacks, so a handle_continue/2 clause a handler
  continues to is judged like any handler, and one only init/1 continues
  to is not. This replaces `once_message`, `once_cast`, `sent_again`,
  `cast_again`, `once_candidate`, `sends_literal`, `sends_literal_out` and
  mailbox's `once_clause`, which are deleted.
- **Coupling**: once code grows by the once clauses' reach, and a call or
  a cast a clause of the once phase makes directly is a once request.
  handle_continue/2 is once code only for the start's continue chain:
  `start_callback` no longer names it, and a clause only handlers continue
  to (Livebook's NotebookManager `:dump_state`) is not. A gated site's
  reach is once code, and a call or a cast at one is a once request. The
  request is asked of the site (`sync_request_at`, `async_request_at`,
  calls.dl) and so is the finding's registration frame, the `once_step`
  that makes the request or leads to it: a handle_continue/2 clause is no
  once code as a function. Until 2026-09-26 only a call at a site of the
  phase was asked, and a cast made there directly went unseen.

## What it assumes

- A tag's producers are the program's sites that spell it. A message the
  runtime or a library writes under a tag the program also sends itself
  once is not seen. The kinds read above are the exceptions: the idle
  timeout, a monitor's or task's `:DOWN`, an interval, Phoenix.PubSub.
- Code off the call graph runs on a process's stack only through a call
  the graph does not follow, or as its own module's callback. A library
  that calls another module's code back on the caller's stack, through a
  module name it was handed, is not seen.
- A dynamic-message send to another process carries none of the tags
  judged.
- A `start_async` in a clause function counts for every clause of it,
  since the facts do not carry its site.
- A GenServer's state changes only by its callbacks' results. A
  `:sys.replace_state/2` from outside, and a result thrown from deeper
  than the handler itself (gen_server takes it as the result), are not
  read.
- The atoms a gate compares its field with are the values that field
  holds when the gate admits the site: a value of another type never
  equals one.

## What it deliberately does not claim

- **Once by protocol.** A message another process sends exactly once, to
  a process it has just started: a Phoenix channel's join, rabbit's
  `{init, Recover}`. The starter is outside the process, and a fresh pid
  from a starter fun is not known to be fresh. A witness in the manner
  of `monitor_started` (a send to the pid a start in the same function
  answered, of the receiver's own module, the only such send per start)
  would clear none of the three rows: Phoenix starts the channel through
  a starter fun it was handed, and rabbit through
  `rabbit_amqqueue_sup_sup:start_queue_process/2`, a program function
  that may hand back a process others hold. (Blockster's `:registered`,
  sent to what `GlobalSingleton.start_link/2` answers, is the same; the
  state gate clears its two servers.) It is left to the priors: a
  library's handshake (Phoenix.Channel.Server's join message, a
  gen_server2 queue's init call) as a fact of the library.
- **Once by state, where the reading stops.** A gate on a field of a
  map the state holds (FLAME's `Runner`, `state.runner.status`), in a
  helper the handler hands its state to (vernemq's connection parsers,
  whose state is an argument of a receive loop's helpers), a field set
  to a value the message carries (Livebook's `RuntimeServer` sets
  `owner` to the one `:attach` names, which may be nil), a membership
  test (`MapSet.member?(state.monitored, pid)`) that keys the site's
  once-ness by what it registers. The subscription and dropped-ref walks
  keep their older reading of any test of the state as deciding
  (`state_decided`) beside the gate. Over the evaluation sets it
  suppresses 43 rows (27 monitors, 16 subscriptions). The gate reads one
  of them itself (blockster's SortedPostsCache subscribes in its
  `:registered` clause, the BuxBoosterBetSettler shape). The rest test
  the state in ways the gate does not read: a stored pid compared with
  the current one (firezone's re-join after its scope restarts), a
  membership test (exq's mock), a nested field or one the message sets
  (FLAME, rabbit's mirrored_supervisor), a gate a handler opens again
  (zotonic's z_db_pgsql). Removing `state_decided` needs the keyed
  witness the exclusion census names: a state test tracks a
  registration when the field it reads is one the registering path
  writes.
- **A start's message a handler sends again.** For coupling, a clause a
  message enters is once code only when it runs once. A registration made
  in the clause for a message init/1 sends, which a reconnect sends again,
  is made again on the next reconnect but not after the peer's restart,
  and it is not reported. The restart-state model already left this out.
- **Which state an inserted event enters.** A gen_statem's `:internal`
  clauses are told apart by the event type alone. ra inserts `internal`
  events on its way from `post_init` through `recover` to `recovered`,
  each from the clause before. By type alone, `post_init`'s clause is
  entered by its own insert, so it runs again. To tell them apart, the
  model needs the state each insert's return enters. ra's computed
  targets (`next_state(NextState, ...)` from `ra_server`'s results) could
  name any state. ra's `do_init/1` monitor row stays.
- **A retry chain's exit.** A clause that re-sends itself until something
  is ready, and then arms the loop once (blockster's `:wait_for_mnesia`),
  is a cycle, and runs again.

## Soundness

`test/soundness/runs_test.exs` asserts each narrowing's adversarial
neighbours. Each one takes a monitor in the clause and throws its ref away,
and must keep "Monitor taken again with its ref thrown away":

- a message clause:
  - a tag init/1 sends and a handler sends again;
  - one another process may send;
  - a two-clause cycle;
  - a sender both init/1 and a cast reach;
  - a handler that sends itself any tag;
  - an interval init/1 arms;
  - a cast that runs the clause itself;
  - a Phoenix.PubSub broadcast of the tag;
  - the clause run directly from another module;
- handle_continue/2:
  - a continue init/1 and a handler return;
  - one returned through a helper;
  - one of any tag;
- a gen_statem's `:internal` clause:
  - an event init/1 and a cast insert;
  - one of a type a cast is handed;
  - an inserting helper both reach;
- the idle timeout:
  - a timeout init/1 and a cast arm;
  - one the return does not spell;
  - one returned through a helper;
- handle_async/3:
  - a task mount/3 and an event start;
  - one started under any name;
  - a starting helper both reach;
- a producer no known root reaches:
  - a fun another module builds, run by a call;
  - a hook module's export, run through the module the state names;
  - a LiveComponent's `update/2`, for its own handle_async/3;
- a delegated clause function:
  - another of its clauses re-sends;
  - the delegating server's own cast re-sends;
  - one of two delegating servers re-sends.

The timer loop and subscription rules keep their findings for a
handle_continue/2 clause a handler continues to. Coupling keeps its
finding for a request the start's continue chain makes, whatever else
continues to it: a continue init/1 and a reconnect return (the Hare
shape), a chain from a once clause's continue, a chain of continues a
reconnect re-enters. A continue only a handler returns is quiet.

The gen_statem readings keep "No clause for a message a gen_statem is
sent":

- a call after a content test;
- a catch-all for casts alone;
- a type guard before the call;
- a re-dispatched helper no transition names;
- one whose name is written only as a message;
- a helper handed the data first;
- a state whose clauses return through a helper.

Quiet controls sit beside each group: the once-only shape of each
producer, ra's re-dispatched named state, and ra's delegating catch-all.

`test/soundness/gated_once_test.exs` asserts the state gate's. Each
module takes a monitor behind a test of its state whose other arm
raises, so no other reading of the state decides it, and must keep
"Monitor taken again with its ref thrown away":

- the gate:
  - the monitor before the test;
  - a test of a field of a map the state holds;
  - a test of `Map.get/2`'s answer;
  - a head that tests the message, not the state;
- closed:
  - the return sets another field;
  - one way out hands the state back as it came;
  - a throw after the site;
  - a catch that raises again what it took, in its own class;
  - a rescue that hands the state back as it came;
  - the field set to what the message carries;
- nothing sets it back:
  - a handler sets it back to the atom;
  - a call sets it to what it is handed;
  - a handler hands the state to a helper that clears it;
  - a handler returns what a clearing helper returns;
  - code_change/3 starts it over;
  - a call replaces the whole state;
  - an Erlang record's field a call sets back;
- only the loop runs the handler:
  - another handler runs it with the field set back;
  - a client function runs it in its caller's process;
  - a handler hands it a state of its own making;
  - a server under a behaviour the alias table does not know.

Quiet beside them: a boolean flag in the head, a nil check, a status
atom a case takes, an Erlang record's field, closed through a helper, by
a stop, by the caller in `from`, cleared only in terminate/2, another
field cleared elsewhere. The timer loop rule keeps "Periodic timer loop
armed again while it runs" for a loop a gated clause starts when a
handler sets the field back, and is quiet for blockster's shape, where
nothing does. Each quiet control fires without the gate
(`gated_once_site` removed), so each is quiet by it.
`test/extractors/state_gate_test.exs` pins what the extractor reads at
each monitor.

## Measured

Over the 44 evaluation sets (the 26 live projects, the ETS and supervision
rounds' sets, madrigal and the postgrex and supavisor pairs), against
3d3cd39c. Every changed row was read against its source.

| class | rows before → after | true before → after |
|---|---|---|
| No clause for a message a gen_statem is sent | 11 → 0 | 0 → 0 |
| Periodic timer loop armed again while it runs | 20 → 17 | 7 → 8 |
| Subscription made again each time a callback runs | 11 → 9 | 5 → 5 |
| Entry dropped while its process stays monitored | 24 → 23 | 6 → 6 |
| Coupled children under one_for_one (warning, judged) | 28 → 29 | 24 → 26 |

- **Gone, 19 rows, all false.**
  - ra's 11 (the extractor).
  - 4 loops' first arms from a once clause.
  - 2 subscriptions in once clauses.
  - sequin's `TableReaderServer` monitor.
  - Livebook's `NotebookManager` → `Storage` coupling pair: only a change
    continues to `:dump_state`.
- **Come, 3 rows, all true.**
  - firezone's `Cluster.PostgresStrategy`: every reconnect continues to
    `:connect`, which sends `:heartbeat` beside a running loop that keeps
    no ref.
  - MongooseIM's `service_domain_db` → `mongoose_domain_core`: domains
    loaded from the once-only `initial_loading` clause. A core restart
    loses them until the loader crashes on the vanished loader state and
    reloads.
  - vernemq's `vmq_reg_sync_action` → `vmq_reg_sync`. The action reports
    `done` from its once-only `:timeout` and `:DOWN` clauses, and a restart
    of the sync server alone orphans running actions.
- **No other row** of any analysis moves.

Exclusions:
- mailbox's once carve-out (8 relations) is deleted, with its 8 negated
  atoms: 4 inside it and 4 reading it. Its 4 readers now read the shared
  `once_clause_site`, and the monitors add 4 reads of the shared word.
  mailbox's negated atoms stay at 112.
- The start-callback exception for handle_continue/2 is deleted. It made
  every continue once, the one quiet exception the old split stated.
- runs.dl's own negations define the split (the complement of runs
  again, stratified). No analysis adds a carve-out of its own.

What is left false in these classes is outside the producer question:
- once by protocol: the Phoenix join, twice;
- once by state: a gate and a start handshake;
- retry chains' exits (3);
- cancels through helpers (2);
- two loops a shared helper mixes;
- an unreachable clause;
- a test helper;
- a Registry-guarded subscribe.

## Measured: once by the state

Over the same 44 sets, against d2a1d3ad. Every changed row was read
against its source.

| class | rows before → after | true before → after |
|---|---|---|
| Periodic timer loop armed again while it runs | 17 → 16 | 8 → 8 |
| Monitor taken again with its ref thrown away | 44 → 43 | 4 → 4 |
| Monitor left live each time a wait returns | 32 → 32 | 8 → 8 |
| Entry dropped while its process stays monitored | 23 → 23 | 6 → 6 |
| Subscription made again each time a callback runs | 9 → 9 | 5 → 5 |
| Coupling (every title) | 36 → 36 | |

- **Gone, 2 rows, both false.**
  - blockster's `BuxBoosterBetSettler` arms its `:check_unsettled_bets`
    loop in `handle_info(:registered, %{registered: false})`, which
    returns `registered: true`; init/1 starts the field false and no
    return sets it back.
  - honeydew's `JobMonitor` monitors its worker in `handle_call({:claim,
    job}, {worker, _}, %State{worker: nil})`, which sets `worker` to the
    caller's pid; every other return keeps the field or stops the
    process.
- **No other row** of any analysis moves, and no encore benchmark row.

Over the sets, 765 sites in 129 handlers are gated, 166 of them closed,
and 44 (in 9 handlers) run once. Most of the rest are opened again by a
return of the module (553), or not closed by the clause's own return (a
value the reading cannot tell from the gate's atom, a return that keeps
the field). The rows of these classes at a gated site that stay are
right to:
- Livebook's `RuntimeServer` `:attach` (the `wait` and the dropped
  row): `if state.owner` raises, and the clause sets the owner to the one
  the message names, which may be nil;
- zotonic's `z_db_pgsql` (three `wait` rows): its idle disconnect sets
  the connection back to `undefined`;
- rabbit's `mirrored_supervisor` `reconcile` loop: the head's
  `overall = undefined` is closed by the supervisor the message names;
- partisan's plumtree broadcast: its "gate" is a `case` on the engine
  mode, which every run passes and no run changes.

Exclusions: none deleted, 8 negated atoms added, all in runs.dl's
definition of the witness:
- `gated_once_site`'s `!call_edge(_, f)` and `!gate_reopened(s, f, k)`:
  its soundness conditions, the fourth and third above;
- `gated_edge`'s complement (`open_edge`: 2 `!open_edge`, 2
  `!gated_once_site`, `!call_instr`, `!fun_handed`): "every call of the
  callee is gated", a universal.

The consumers read `once_site` where they read `once_clause_site`
(mailbox 5 atoms, renamed). The reach of code that runs again asks
`!once_site(c, h)` in place of `(again_tag_site(c, h) ; !clause_call(c, h,
_))`, the same set for a clause function, and coupling's once code reads
`once_phase_site` in place of `start_clause_site`: neither adds an atom.
