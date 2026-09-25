# Bug classes

Every class of bug argus reports, stated as a property of the program
rather than as the rule that finds it. A bug class is one defect a
reader would recognise: usually one output relation, or one value of a
relation's `kind`, `reason` or `source` column when the values are
different defects. Evidence relations, the frames attached to another
finding (`call_cycle_path`, `bottleneck_caller`, `ets_race_frame`, ...),
are described under the class they support.

The catalog is the reference a rule change is checked against: a new
rule adds its entry, a precision change updates its limits, and a
suppression names the assumption it rests on so it can be checked
against it. The classes a round of mining found and argus does not yet
catch are listed at the end, ranked.

## How to read an entry

Each entry opens with its relation, the column value that selects it,
and its titles as `Argus.Findings` spells them (`#{...}` is a column
value the builder interpolates), each with its severity. Then:

- **Property.** The defect as a property of the program: which process,
  function, call, message or table; what must hold on which paths; what
  is absent. Then the runtime consequence.
- **Assumptions and limits.** What the rule takes on trust for soundness,
  the false negatives it is known to have, and the false-positive shapes
  it suppresses. A suppression names the quiet fixture that pins it.
- **Fixtures.** The positive and quiet fixture modules and the test that
  asserts them. Fixture modules are named relative to
  `Argus.Test.Fixtures`.
- **Corpus.** The closed-issue pairs in `test/corpus/pairs.exs`: a fix
  pair's finding is present at the commit before the fix and absent at
  the fix; a present-only pair names a tree where the bug is live.
- **Precision.** What is known, with its source: a sampled judgement, a
  corpus tally, a commit that measured it. "Not measured" says so.

Terms in backticks that are not relations of the entry's own analysis
are defined once in the vocabulary below. A term "errs quiet" when what
it cannot see yields fewer findings, and "errs loud" when the same
uncertainty can add one.

## Classes by concern

| Concern | Classes | Owns |
|---|---|---|
| [`startup`](#startup) | 17 | work in `init/1` or `handle_continue/2` that blocks, deadlocks or races the tree's start |
| [`shutdown`](#shutdown) | 8 | cleanup a supervisor shutdown will skip, and teardown that hurts a peer |
| [`blocking`](#blocking) | 15 | synchronous waits that can last forever or nest: call chains, cycles, fan-in, rpc, locks, receives in callbacks |
| [`coupling`](#coupling) | 5 | two owners of one relationship across supervisor branches |
| [`mailbox`](#mailbox) | 20 | messages that arrive with no clause for them, and replies that never come |
| [`failure`](#failure) | 10 | error paths swallowed, half-caught or ignored |
| [`structure`](#structure) | 4 | child specs, registrations and tree shapes that are wrong on their own |
| [`races`](#races) | 8 | check-then-act races on a process name, an ETS key or a Mnesia record that another process can write between the check and the act, ETS values published before the rows they point to, and ETS rows acted on after another process may have removed them |
| [`state_machine`](#state_machine) | 2 | gen_statem states no transition reaches, and terminal states that never stop |
| [`ets`](#ets) | 8 | ETS table ownership, concurrency options and lifecycle |
| [`effects`](#effects) | 4 | `@pure` contracts, and effects inside a transaction that a rollback cannot undo |
| [`unsafe_input`](#unsafe_input) | 5 | atom exhaustion, unsafe deserialization, unbounded decompression and code execution reachable from a request |
| [`exposure`](#exposure) | 4 | secrets that `inspect/1` prints, and TLS that does not verify the peer |
| [`coverage`](#coverage) | 5 | extractor coverage and imprecision (meta-analysis, opt-in) |

## Vocabulary

The rules of every concern are written in a shared vocabulary, defined once in
`priv/dl/clientlib/` and, for the call graph and process points-to, derived once
per program by the two stages (`priv/dl/stage0.dl`, `priv/dl/points_to.dl`) and
read back as facts. Each entry below names a concept, states what it says about
the program, says which way it errs, and lists the concerns that read it. A word
errs in the quiet direction when what it cannot see yields fewer findings rather
than more; it errs loud when the same uncertainty can add a finding.

### The call graph

- **Names.** `call_edge`, `call_site`, `call_instr`, `unconditional_call_edge`, `fun_handed_to`, `call_reachable` (stage0.dl, imports.dl).
- **Meaning.** `call_edge(f, g)` holds when f calls g (a remote, local or BIF call), builds the closure g, hands the fun g to a call without calling it, or makes an apply whose target the value flow resolves to g. `call_site` and `call_instr` name the instruction behind an edge into a project function (and behind GenServer calls and the few library calls findings anchor at), so a finding points at the calling line; a closure or a fun handed on has no `call_instr` row. `unconditional_call_edge` keeps the edges with at least one site that no branch controls.
- **Direction.** Counting a closure built or a fun handed on as a call over-approximates what runs (the same-process and guarded walks refine it); a call the compiler cannot resolve (a fun from a variable, an unresolved apply) reaches nothing. `call_reachable`, the full closure, is declared for custom programs and read by no shipped analysis.
- **Used by.** Every concern that walks code: blocking, coupling, effects, ets, failure, mailbox, races, shutdown, startup and unsafe_input.

### A behaviour and its callbacks

- **Names.** `behaves_as`, `process_behaviour`, `otp_callback`, `callback_name`, `init_function` (`is_init`), `handle_call_function`, `handle_cast_function`, `handler_function`, `terminate_callback` (`is_terminate`), `process_behaviour_module`, `statem_process` (behaviours.dl, callbacks.dl, vocabulary.dl).
- **Meaning.** `behaves_as(mod, b)` is the declared behaviour under one spelling for both languages (`:gen_server` is GenServer; Connection and Postgrex's connection wrappers are GenServer too), and an unlisted behaviour passes through unchanged. `process_behaviour` says whether a behaviour runs a callback loop over its own mailbox (`loop`), answers calls by GenServer's contract (`gen_server_like`) or calls terminate (`terminating`). `otp_callback` is a function with a loop callback's name (`callback_name`) in a loop-behaviour module; `init_function` is init/1 of a process module; `handler_function` is a GenServer's handle_call, handle_cast, handle_info or handle_continue.
- **Direction.** Callbacks are matched by name at any arity, so a helper that shares a callback's name counts; a behaviour missing from the tables (a channel's join/3 is not a callback name) is not a process entry.
- **Used by.** blocking, coupling, coverage, effects, ets, failure, mailbox, races, shutdown, startup, structure and unsafe_input.

### Where a process's own code starts

- **Names.** `process_entry`, `server_side` (callbacks.dl, process_statem.dl, process.dl).
- **Meaning.** `process_entry(mod, f)` is a function where mod's process starts running mod's code: its loop callbacks, its init/1, a terminate/2 and, where the analysis includes process_statem.dl, a gen_statem's state functions. What an entry reaches in its own process runs in that process; what only the module's API reaches runs in its callers. `server_side(mod, f)` is what a callback or state function reaches without leaving the module.
- **Direction.** `server_side` stays in the module but does not cut `runs_elsewhere`, so a closure a callback spawns counts as the server's own code (loud), and a helper in another module does not (quiet). The terminate/2 clause of `process_entry` is not gated on a behaviour.
- **Used by.** blocking, ets, failure, mailbox, races and shutdown (`process_entry`); mailbox and shutdown (`server_side`).

### A process, by points-to

- **Names.** `process`, `server_process`, `instance`, `supervised_process`, `private_process`, `named_pid`, `source_process` (processes.dl, staged by points_to.dl, read through staged_processes.dl).
- **Meaning.** A process is named by the site that started it (`spawn <id>`, `server <id>`), by each call that keeps what a factory start returns (`start <site>`), or by a supervisor's child position (`child <sup>#<pos>`); `instance(proc, base)` maps each to its start site. `server_process(proc, mod)` runs mod's callbacks, `supervised_process` is a supervisor's child, `private_process` is one a function starts and keeps for itself, and `named_pid(name, proc)` is a registered name that may hold it.
- **Direction.** Parameters are context-insensitive (a parameter points to whatever any caller passes), so every relation here means "may be"; a rule that concludes something from it asks what a process does not do. A pid that travels through something PidFlow does not model leaves a use with no target, not a wrong one.
- **Used by.** blocking, coupling, coverage, failure, mailbox and shutdown directly, races through `source_table`, and every reader of `sync_dep`.

### Which process a use reaches

- **Names.** `process_call`, `call_site_target`, `call_target`, `self_call`, `send_target`, `signal_target`, `pid_use` (processes.dl, staged_processes.dl, sends.dl, signals.dl).
- **Meaning.** `process_call(f, anchor, site, kind, proc)` says f calls, casts to or sends to (`kind` is call, cast or info) proc through the use at site, its own or one in a helper f hands the pid to at anchor. A helper's use of its parameter is lifted to each caller, where the pid is known, instead of being resolved in the helper. `call_site_target` is the same per use, whoever supplies the pid, and `call_target` the function-level projection. `self_call(f, site)` is a synchronous call provably to the calling process: to self(), or to a name only the caller's module's processes hold, from that module's own entry.
- **Direction.** "May reach", as for processes. An analysis that includes signals.dl also sees exits, monitors and links in `process_call` and `pid_use`; one that includes sends.dl gets `send_target`.
- **Used by.** blocking (`self_call`), coupling, coverage, failure, mailbox and shutdown, and calls.dl's dependency words.

### Runs elsewhere

- **Names.** `runs_elsewhere`, `awaits_task`, `hands_funs_off`, `fun_sink` (runs_elsewhere.dl).
- **Meaning.** `runs_elsewhere(f, g)` holds when f's edge to g leaves f's stack: g is what a spawn, task or agent in f runs and f does not call it itself; f hands g's fun to a helper that starts a process on it; g is the only closure f builds into a term beside a start whose fun is unknown; or g is a fun f only registers or keeps (`:telemetry.attach`, `:persistent_term.put`, the state init/1 returns) and never calls. `awaits_task(f, start, g)` restores the edge for a question about what holds f up: a Task.async whose task f awaits anywhere.
- **Direction.** A fun handed to a call this file does not know stays on f's stack, since a library's higher-order function may run it there (loud). A fun built into a term that a callee then runs is taken as kept (quiet).
- **Used by.** The same-process and holding reach components, calls.dl, global_reach.dl and the points-to stage; blocking, mailbox, races and startup directly; failure reads `hands_funs_off`.

### Reach over the call graph

- **Names.** `CallReach`, `SameProcessReach`, `SameProcessReachCut`, `HoldingReach`, `IntraModuleReach`, their `…Set` forms, `ForwardCallReach`, `ForwardSameProcessReach`, `ForwardIntraModuleReach`, `ForwardCallReachSet`, `ForwardBoundedCallReach`, `BackwardBoundedCallReach` (reach.dl components).
- **Meaning.** Each closure over `call_edge` is written once as a component: an analysis instantiates one, seeds it with the few functions it asks about, and reads `reaches`. Backward forms answer which functions reach a seed; forward forms, what a root reaches. The step is the difference: `CallReach` follows every edge; `SameProcessReach` drops `runs_elsewhere` edges, so it is what one process runs; `SameProcessReachCut` also drops edges the instance names (startup's calls after `:proc_lib.init_ack`, mailbox's side paths); `HoldingReach` adds awaited tasks; `IntraModuleReach` stays in one module; the bounded forms stop after a set number of calls.
- **Direction.** A question about one process asked with `CallReach` or `IntraModuleReach` attributes spawned work to its starter (loud where the result is a premise, quiet where it is negated).
- **Used by.** blocking, coupling, effects, ets, failure, mailbox, races, shutdown, startup and unsafe_input.

### Guarded and data-flow reach

- **Names.** `ForwardGuardedCallReach`, `ForwardUnguardedSet`, `BackwardUnguarded`, `ParamReach`, `ParamReadsReach` (reach.dl components).
- **Meaning.** The guarded forms walk only the calls no guard covers: the instance marks a call `guarded` (a try that takes the class in question), and an edge with no call instruction is held against the call its fun is handed to. shutdown walks terminate/2's paths no exit-catching try covers, races the path to an act that raises, failure what some entry reaches past no try of a class, mailbox the callers that leave a task uncollected. `ParamReach` steps from a function's parameter into the callee parameter a derived argument fills; `ParamReadsReach` also follows data-only reads and is wider on purpose.
- **Direction.** An edge with no call instruction and no call it is handed to is open unless the instance seals it (loud); a fun handed to a process start is not followed (quiet).
- **Used by.** failure, mailbox, races and shutdown (guarded forms); unsafe_input (data-flow forms).

### Clause-aware entry

- **Names.** `literal_entry` and `site_clause` (calls.dl), `literal_first` and `clause_of` (global_reach.dl), over the `clause_call` fact.
- **Meaning.** When every call from f to g passes the same literal atom first, the call enters only g's clauses for that atom and the clauses that take any value; `clause_call(site, g, tag)` says which clause a site in g belongs to. `Router.route(:local, n)` therefore does not wait on what the `:remote` clause waits on, though a call graph by function merges the two.
- **Direction.** A forwarded parameter, a computed value or a tuple enters every clause (loud).
- **Used by.** blocking (per-site requests) and blocking and startup (global lock reach). Each walk defines the test for itself.

### Side paths

- **Names.** `side_api`, `side_call` (calls.dl).
- **Meaning.** `side_call(f, g)` is an edge from a function outside the logging and telemetry APIs (`:logger`, `:error_logger`, Logger, `:telemetry`) into one of them. Their handlers are dispatched by value, so the call graph reaches only the APIs' own machinery, which waits on its own servers and writes to no mailbox of the program's.
- **Direction.** The waits calls.dl propagates and mailbox's late-message walk do not cross a side path; a handler the program attaches that does wait is not seen from the call site (quiet).
- **Used by.** calls.dl's dependency words (blocking, coupling, shutdown, startup) and mailbox.

### A wait on a peer

- **Names.** `sync_dep`, `reaches_sync_dep`, `sync_site`, `genserver_sync_api`, `peer_call`, `unresolved_target`, `async_dep`, `reaches_async_dep`, `sync_dep_timeout`, `reaches_sync_dep_timeout` (calls.dl, resolved_calls.dl).
- **Meaning.** `sync_dep(f, mod)` holds when f itself waits on mod's process: a synchronous call whose target is mod by name, a call into mod's client API (`genserver_sync_api`), a call points-to resolves to a server of mod, or a call attributed to mod by its message tag. `reaches_sync_dep` carries it back to every caller over edges that stay in the caller's process and are not side paths, and `sync_site` names the instruction. `async_dep` is the one-way counterpart; the timeout forms carry the call's timeout (-1 is :infinity).
- **Direction.** A target in `unresolved_target` ("dynamic", ":dynamic", "via:…") never becomes a dependency (quiet). `reaches_async_dep` does not cut `runs_elsewhere`, so a cast a spawned closure makes is its starter's (loud).
- **Used by.** blocking, coupling, shutdown and startup; blocking and startup also include resolved_calls.dl, whose self-directed rows extend `sync_dep`.

### Message-tag attribution

- **Names.** `call_tag`, `tag_handler`, `tag_resolved_site`, `reaches_tag_dep`, `self_directed_call` (stage0.dl, calls.dl, resolved_calls.dl).
- **Meaning.** A call whose target the extractor could not name is attributed to the one GenServer module whose handle_call (or handle_cast) compares its message tag (`call_tag`: the atom, or a tuple's first element): the handler the caller's module refers to among several, or the only one in the program for a tag specific enough to name it. A call points-to resolves keeps the resolved target. `self_directed_call` is a wrapper whose own module's handle_call compares the tag it sends: it calls its own server.
- **Direction.** Handlers are over-approximated (every atom a body compares), so ambiguity suppresses attribution rather than inventing it; generic tags (`:get`, `:stop`, …) and tags a handle_info also matches attribute nothing (quiet). `reaches_tag_dep` marks the waits that exist only by tag, so a finding can call its edge inferred.
- **Used by.** blocking, shutdown and startup (`tag_resolved_site`), blocking (`reaches_tag_dep`), mailbox (`call_tag`, `tag_handler`).

### The request a wait makes

- **Names.** `sync_request_at`, `reaches_sync_request`, `site_demand`, `site_request` (calls.dl).
- **Meaning.** The same waits, carrying the request's tag, or "any" where the message has none the program can see; `reaches_sync_request(f, mod, _)` holds exactly where `reaches_sync_dep(f, mod)` does. `site_request(f, site, mod, tag)` is asked per call site of the functions a rule seeds in `site_demand` and enters callees clause by clause, so a chain through a server follows the clause the request enters.
- **Direction.** A callee entered without a literal first argument is taken whole (loud).
- **Used by.** blocking (call chains and cycles by request).

### Module-level dependency

- **Names.** `module_sync_dep`, `stateful_module_dep`, `stateful_module_dep_kind`, `private_dep`, `private_module_dep`, `module_reaches` (calls.dl).
- **Meaning.** `module_sync_dep(a, b, w)` says a function w of module a waits on b's process somewhere below it. `stateful_module_dep` adds a's one-way dependencies and an inferred clause: a reaches some function of b, a supervised module, and b makes a call or cast somewhere. `stateful_module_dep_kind` is "call" when some path waits on a reply and "cast" when every path is one-way. `private_dep(f, mod)` holds when every process of mod that f talks to is one a function kept for itself, none a supervisor's or a registered name's.
- **Direction.** The inferred clause over-approximates a facade (loud); coupling marks those rows "inferred" or "doubted".
- **Used by.** blocking and coupling (`module_sync_dep`), coupling (`stateful_module_dep`, `private_module_dep`), shutdown (`private_dep`).

### The startup phase

- **Names.** `is_init`, `init_dep`, `continue_dep`, `handler_dep`, `deferral_path`, `unconditional_call_edge` (vocabulary.dl, entries.dl, clientlib/startup.dl, stage0.dl).
- **Meaning.** init/1 of a process module runs inside its supervisor's start, so what it waits on holds the whole start. `init_dep(mod, to, kind, w)` is init/1 reaching a synchronous ("call") or one-way ("cast") dependency, with no filter for mod's own module; `continue_dep` is a handle_continue init/1 continues to that waits on another module; `handler_dep` is a request handler's wait ("tag" when only attribution makes it). `deferral_path(mod, kind)` names a module's ways to try again later: a timer, a message to itself, a handle_continue, a gen_statem timeout. `unconditional_call_edge` answers whether a dependency holds on every path through init/1.
- **Direction.** The phase ends at init/1's return: code after `:proc_lib.init_ack` is cut only in startup's own receive walk, so the lock and rpc walks still count it as init's (loud).
- **Used by.** startup and blocking.

### Global lock reach

- **Names.** `global_path`, `retrying_lock`, `lock_until_granted`, `bounded_lock` (global_reach.dl, vocabulary.dl).
- **Meaning.** `global_path(f, call, site)` holds when the `:global` operation at site runs while f waits on it: on f's stack, over edges that stay in f's process and enter only the clauses a literal first argument matches, or in a task f awaits; `call` is f's own call that starts the path. `lock_until_granted` is a lock or transaction whose retries are :infinity or not shown (then assumed :infinity, a forwarding wrapper's usual default), `bounded_lock` one that gives up after a positive count, and `retrying_lock` either.
- **Direction.** An unknown retry count or node list is assumed the worst (loud); the one walk keeps a lock init's finding or blocking's, never both and never neither.
- **Used by.** blocking and startup.

### Supervision structure

- **Names.** `child_subtree`, `starts_before`, `sibling`, `sup_management_call`, `child_creating_op`, `unbounded_sup_op`, `stopping_sup_op` (supervision.dl).
- **Meaning.** `child_subtree(sup, branch, mod)` maps every module under a supervisor, static and dynamic children at any depth, to the direct child branch it belongs to. `starts_before(sup, earlier, later, …)` joins two branches in start order: earlier is running when later's init runs, and under rest_for_one later restarts when earlier crashes. `sibling` is two direct children of one supervisor. `sup_management_call` is a call to a supervisor's API, and the op tables say which calls create a child, which wait for a whole shutdown and which stop children.
- **Direction.** Supervision is module-level: two instances of one child module are one module here.
- **Used by.** coupling, shutdown and startup; calls.dl limits module-level reach to supervised modules through it.

### A request entry and its parameters

- **Names.** `request_entry`, `request_param` (request_entry.dl).
- **Meaning.** `request_entry(f, kind)` is a callback whose arguments carry data an outside party controls: a Plug's call/2, a Phoenix controller's actions (every exported arity-2 function of a module that defines `phoenix_controller_pipeline/2`, kind `controller`; no call edge reaches them, since `action/2` applies the name the router put in the conn), a LiveView's mount/3, handle_params/3 and handle_event/3, a LiveComponent's handle_event/3, a channel's handle_in/3, an Oban worker's perform/1, a Broadway processor's handle_message/3 and handle_batch/4, a ThousandIsland handler's handle_data/3 (the socket's bytes, kind `socket`) and a WebSock handler's handle_in/2 (a websocket frame, kind `websocket`). `request_param(f, pos)` names the positions that carry it; a socket, a Plug's opts and a mount's signed session do not.
- **Direction.** The list is closed: a surface it does not name (a raw cowboy handler, a GenStage consumer) is no entry (quiet).
- **Used by.** unsafe_input, and races through concurrency.dl, which counts what a request entry reaches as run by many processes at once.

### Runs concurrently

- **Names.** `RunsConcurrently` (`entry_reaches`, `many_instances`, `single_process`, `runs_apart_from`), `open_entry`, `called_by_other_module` (concurrency.dl).
- **Meaning.** Seeded with the functions a rule asks about, the component walks back in one process to the entries that run each: a process module's entries, Application.start/2, and each spawn, task or agent start as an entry of its own. A seed runs in more than one process when two entries reach it, when a request entry does, or when its entry has many instances (a module with a request entry, a DynamicSupervisor child, a start reached from a request or a message handler, in a closure or in a recursive function); otherwise it is `single_process`. `open_entry` is an exported function nothing in the program calls, in a module no other module calls into: a caller outside the program runs it.
- **Direction.** A function no entry reaches is neither single nor concurrent; races then asks `runs_apart_from` whether another entry or an outside caller can run the other side.
- **Used by.** races.

### Test code

- **Names.** `test_code`, `runs_under_test` (test_code.dl).
- **Meaning.** A module that calls into ExUnit is test code; `runs_under_test(f)` holds for test code and for program functions that only test code reaches, since no function the program runs outside its tests reaches them.
- **Direction.** It chooses among sites and does not judge them: a library's public function that only its compiled test helpers call looks run only under test, so no rule quiets a finding on it.
- **Used by.** mailbox, to point a timer finding at the cancel the program itself runs.

### Receives and mailbox handlers

- **Names.** `receives`, `timed_receive`, `blocking_receive`, `receives_message`, `mailbox_handler`, `partial_handle_info`, `trap_exit_without_exit_clause`, `module_demonitors` (receive.dl, process.dl).
- **Meaning.** receive.dl names the receive questions so the encoding of `recv_start` stays in one place: any receive in a function, one with an `after`, one without. `mailbox_handler(mod)` takes arbitrary messages (a handle_info/2, or a gen_statem's handle_event/4); `partial_handle_info(mod, h)` is a handle_info/2 with no catch-all, where a message no clause matches is a FunctionClauseError; `trap_exit_without_exit_clause` traps exits and has a partial handle_info/2 with no `{:EXIT, …}` clause.
- **Direction.** Receive shapes are per function, not per receive; rules that anchor at one receive read `recv_start` directly.
- **Used by.** effects and mailbox (receive.dl), mailbox and shutdown (process.dl).

### A late-message source

- **Names.** `late_message_source` (local to mailbox.dl).
- **Meaning.** A process has a late-message source when one of its entries reaches, in its own process and not through a side path, something that writes to its mailbox on a schedule it does not control: a timer, a task's reply, a subscription, a monitor, a message it sends itself, or a call through a fun or module the process's own code did not build or name.
- **Direction.** A self-timer whose tag the module's handle_info compares and a timed GenServer call (since OTP 24 a late reply is dropped) are not sources; a source in what a callback spawns writes to that process, not this one (quiet).
- **Used by.** mailbox (a partial handle_info/2 with a late-message source).

### Timer flush

- **Names.** `flush_receive` (timer_flush.dl).
- **Meaning.** `flush_receive(recv)` is a receive in a function that cancels a timer, where the receive can take the timer's message: a clause for a literal the module's timers carry, for `:timeout`, or for anything. cancel_timer returning false means the message is already in the mailbox, so the receive matches at once.
- **Direction.** When the module arms no timer the program can see, or one whose message is not a known literal, the receive may be the flush and is suppressed (quiet).
- **Used by.** blocking (a receive in a callback) and startup (a receive during init). mailbox asks the mirror question, whether a cancel has a flush, with a local rule.

### What a try takes

- **Names.** `catches_class`, `site_catches_class`, `try_takes`, `covered_by_catch`, `rescues_argument_error`, `site_rescues_argument_error` (exceptions.dl).
- **Meaning.** One question at three granularities: does anything in f catch class c, does this try take c (a path through its handler establishes the class and returns without raising again), and is this call inside the protected region of a try that takes c (Erlang's `catch Expr` takes every class). The ArgumentError pair asks the same of the badarg a BIF raises on a missing table or a taken name.
- **Direction.** The function-level forms count a handler around unrelated code (quiet); the site forms are the precise ones.
- **Used by.** blocking, ets, failure, races and shutdown.

### Effect categories

- **Names.** `durable_effect`, `slow_effect`, `structural_call`, `config_writer`, `config_write_api`, `removal_api` (clientlib/effects.dl).
- **Meaning.** The effect model classifies each call by category and mode (`impure_call`). `durable_effect` is a category that leaves the process and cannot be taken back (io, network, process, ets, port, node; logging is not io); `slow_effect` one with no bound of its own (network, port); `structural_call` an unknown call into Kernel, Access, Enum, Map, Keyword, `:lists` or `:maps`, which builds data. `config_writer` writes state other processes read (persistent_term, ETS inserts, application env); `removal_api` removes an entry from a map, set, list or ETS table.
- **Direction.** Reads never count as effects worth keeping, so a missed write in an unclassified call is quiet.
- **Used by.** effects and shutdown (durable), shutdown (slow, structural), startup (config), mailbox (removal).

### A sink

- **Names.** `unsafe_safety_class` (sinks.dl); `sink` (local to unsafe_input.dl).
- **Meaning.** A sink is an operation attacker data must not reach: atom creation, code execution or deserialization. `unsafe_safety_class` lists the deserialization option classes that still count as unsafe: `unsafe`, `atoms_only` (`[:safe]` stops new atoms but not a fun that references a loaded module) and `dynamic`; only Plug.Crypto's term-walking decoders clear it.
- **Direction.** A sink whose argument is one of a set the program wrote on every path, or that is a compiler copy of another site, is dropped (quiet).
- **Used by.** unsafe_input.

### A table and its identity

- **Names.** `ets_table`, `site_table`, `table_readable_elsewhere`, `public_table`, `source_table` (tables.dl, vocabulary.dl, points_to.dl).
- **Meaning.** A table is known the way the runtime knows it: a named table by its name (`named`), an unnamed one by the `:ets.new/2` site that made it (`new`), whose reference process points-to follows like a pid. `ets_table(op, kind, ident)` is the set of tables an operation may touch: a name spelled there, a literal a caller passes, what points-to finds, and as a fallback the map field of a parameter it was read under (`field`, meaningful within the module only). `table_readable_elsewhere` is a table made in view and not private; `public_table` a named :public one.
- **Direction.** An operation points-to cannot follow has no table and takes part in no pair (quiet).
- **Used by.** races. ets, coverage and failure key tables by the name `ets_new` records instead.

### Check-then-act

- **Names.** `CheckThenAct` (`check`, `act`, `meets`) (check_then_act.dl).
- **Meaning.** An instance supplies checks (reads of shared state) and acts (writes of it), each naming a resource and a key in its own function's terms: a literal, a parameter, an element of one, a field, a local, a dynamic value or `any`. `meets(f, check, act, …)` holds where the check's result decides or feeds the act, in f or through the calls f makes, and both touch the same resource and key; an act that merely follows a read is not one.
- **Direction.** Identities cross a call when the caller renames them (a parameter, an element), when they name the same thing everywhere (a literal, a named table, an `:ets.new` site), or within a module for a table it keeps under a field. A map field, a local, a dynamic value, a closure's environment and an unknown higher-order call do not cross, and the pair goes quiet.
- **Used by.** races (registered names, ETS rows, missing rows, Mnesia records).

### Closures and their owners

- **Names.** `enclosing_function`, `sole_closure` (closures.dl).
- **Meaning.** `enclosing_function(f, owner)` walks closure ownership to the top: a closure built inside a closure belongs to the function two levels up, and a function owns itself. `sole_closure(f, c)` is the one closure f builds, which stands in for the dataflow that would pair a closure with the call it is handed to.
- **Direction.** With more than one closure, `sole_closure` says nothing (quiet).
- **Used by.** ets, failure and mailbox (`enclosing_function`), effects (`sole_closure`).

### A spec's claim

- **Names.** `callee_returns` (specs.dl).
- **Meaning.** `callee_returns(f, shape)` is what f's spec says it returns: the analyzed beam's own spec for a function the program defines, the installed one for anything else.
- **Direction.** A spec is a claim nothing verified: rules read it only to stay quiet about a callee whose spec rules out what they ask, or to confirm what they already derived, never to report on a spec alone. No row means unknown, not "cannot fail".
- **Used by.** failure and races.

### A literal a caller passes

- **Names.** `resolved_arg` (calls.dl).
- **Meaning.** `resolved_arg(g, pos, value)` holds when some caller passes g the literal value at pos, directly or through callers that forward a parameter of their own.
- **Direction.** Context-insensitive: g's parameter is every literal any caller passes, so a rule that reads it as "the" value errs loud.
- **Used by.** mailbox, and timer_flush.dl for a timer's message armed through a parameter.

### Signals

- **Names.** `signal_target`, `watched_process`, `exit_to_own_process` (signals.dl).
- **Meaning.** The exit signals, monitors, links and unlinks the points-to stage stages apart, rejoined. `signal_target(id, f, signal, proc)` is where one may go; `watched_process(proc, how)` is a process something monitors or links to, so its crash is observed; `exit_to_own_process(id, f)` is an exit signal whose every resolved target the sending module started itself.
- **Direction.** "May go to", as for calls; an exit with no resolved target is not the sender's own.
- **Used by.** coupling and failure.

### A socket a process holds

- **Names.** `socket_active`, `socket_opts_arg`, `socket_wait` (facts, `Argus.Extractors.Sockets`); `socket_activation`, `server_holds` (local to mailbox.dl); `socket_wait_infinity` (local to blocking.dl).
- **Meaning.** `socket_active(id, f, transport, mode, param)` is a connect or setopts call and the `:active` mode its literal options give: an active socket sends its data and its close to the process that controls it, the one that connected it unless it was handed on. `socket_opts_arg` is the literal list a caller hands a wrapper whose options are a parameter. `socket_wait(id, f, api, timeout, param)` is a blocking socket call and how long it may wait: `infinity` when its arity leaves the timeout out or `:infinity` is passed.
- **Direction.** Only literal options are read: a mode built at runtime is `dynamic` and says nothing (quiet). `:inet.setopts/2` is a TCP socket's only where the process also connects one.
- **Used by.** mailbox (the socket source of `unhandled_info`) and blocking (the `socket` kind of `unbounded_wait`).

## startup

Work in a phase whose invariants do not hold yet: `init/1` runs inside the supervisor's start sequence and `handle_continue/2` runs before any message, so what either waits on decides whether the tree boots; the concern also owns state written after `Supervisor.start_link` has returned and a start result the caller throws away. A mutual `handle_continue/2` cycle is blocking's `call_cycle` in the `continue` phase, and a wait outside the start (an rpc, a `:global` lock or a `receive` in a handler, or in a task `init/1` starts and does not await) is blocking's; a discarded `start_child` result is failure's.

### Start-order deadlock with a later sibling

`blocks_on_peer` · phase=`init`, kind=`call`, ordering=`later`
· titles: "Startup deadlock: init waits on a later sibling" (`:error`)

**Property.** A supervisor S lists child C before child D (D's branch sits at a later position in S's static child list, `starts_before`), and C's `init/1`, on its own stack (not in what it spawns, a task or an agent runs: `runs_elsewhere`; not through the logging or telemetry API: `side_call`), makes a synchronous call that waits on D's process. S starts children in order and cannot start D until C's `init/1` returns, so the call cannot be answered: it exits with `:noproc` or waits, `init/1` fails, and the tree never finishes booting. The finding anchors at C's `init/1`, with the tree definition, the function that makes the call and D as related frames.

**Assumptions and limits.**
- The tree must be static and visible: a child list built at runtime places nothing, and the call is then only the "unknown place" finding below.
- Children and dependencies are compared by module; two instances of one module under different supervisors are not told apart.
- Target resolution is blocking's (literal names, client wrappers, process points-to, tag attribution); a call to an unresolved pid is missed.
- The same call is also reported as "init/1 blocks on a synchronous call" (the unknown-place rule does not exclude a later sibling; the test pins both rows).
- Suppressed: a call made in a task `init/1` starts (`InitRecv.TaskCalls`), and a call only to a pure function of the sibling's module (`InitPureCaller`).

**Fixtures.** Positive: `DeadlockOrderSupervisor` with `SyncInitServer` and `WorkerA` (test/fixtures/sync_init_fixture.ex, test/fixtures/supervision_fixture.ex); `ProcessDepSupervisor` with `InitProcessCaller` and `InitDepWorker` (test/fixtures/supervision_fixture.ex). Quiet: `PureDepSupervisor` with `InitPureCaller` and `InitDepWorker`; `InitRecv.TaskCalls.Sup` with `Early` and `Later` (test/fixtures/init_recv_fixture.ex). Asserted in test/analyses/startup_init_test.exs, startup_supervision_test.exs and singleton_shapes_test.exs.

**Corpus.** None. The corpus has no such pair; encore's fugue benchmark seeds one (7ba8526).

**Precision.** The predecessor start-order rule was 0 true and 1 false on the 2026-07-17 corpus (horde's `RegistryImpl` calling a pure function of `NodeListener`), fixed by requiring a dependency on the sibling's process (c379382). Not measured since.

### Child starts before a sibling it casts to

`blocks_on_peer` · phase=`init`, kind=`cast`, ordering=`later`
· titles: "Child starts before its dependency" (`:warning`)

**Property.** A supervisor S lists child C before child D, and C's `init/1` sends D's process a one-way request (a cast) and makes no synchronous call to it. When C's `init/1` runs, D is not alive yet: a cast to a name nothing has registered is dropped without an error, so whatever it was meant to start never happens. The finding anchors at the tree definition, with the function that casts and D as related frames.

**Assumptions and limits.**
- A cast from a task or spawn `init/1` starts is counted as `init/1`'s own: the one-way dependency is propagated over every call edge, including the edge into what a start runs.
- When C both calls and casts to D, only the synchronous deadlock is reported.
- Static trees only, as above.

**Fixtures.** None.

**Corpus.** None.

**Precision.** Not measured.

### Synchronous call from init/1 to a peer of unknown place

`blocks_on_peer` · phase=`init`, kind=`call`, ordering=`unknown` · detail=`unconditional`, `conditional`
· titles: "init/1 blocks on a synchronous call" (`:info`); "init/1 can block on a synchronous call" (`:info`)

**Property.** The `init/1` of a process module C, on its own stack, makes a synchronous call that waits on the process of a module D, no supervisor in the program is known to start D before C, and the two are not known to sit in disjoint trees (one in some supervisor's subtree, the other in a subtree too or a behaviour module with `start_link/1`, and no supervisor holding both). `detail` is `unconditional` when some path from `init/1` reaches the call on every init, and `conditional` when every route leaves `init/1` through a call site a branch guards (an option such as `sync_connect: true`). The supervisor's start sequence stalls for as long as D takes to answer, and fails if D is not running.

**Assumptions and limits.**
- This is a note, not a diagnosis: where D starts relative to C is unknown.
- The conditional verdict looks only at the first call out of `init/1`; a branch deeper in a helper still reads as unconditional.
- "Likely supervised" is a module-level guess (a behaviour and `start_link/1`), used only to quiet the finding.
- A call to a sibling the tree does place later is reported here too, beside the deadlock, though the prose says the place could not be established.
- A Plug's or Ecto type's `init/1` is not a process's and is not judged (`PidFlow.PlugLike`).

**Fixtures.** Positive: `SyncInitServer` with `WorkerA` (unconditional), `ConditionalInitServer` (conditional), `MixedInitServer` with `WorkerA` and `WorkerB` (one of each) (test/fixtures/sync_init_fixture.ex, test/fixtures/supervision_fixture.ex). Quiet: `SafeOrderSupervisor`, `DisjointSupervisor` with `CallerSupervisor`, `TopologyServer` (a tree defined in a GenServer's `init/1`), `PidFlow.PlugLike` with `PidFlow.Hub` (test/fixtures/pid_flow_fixture.ex), `InitRecv.TaskCalls`. Asserted in test/analyses/startup_init_test.exs and singleton_shapes_test.exs.

**Corpus.** None.

**Precision.** On the 2026-07-17 corpus the predecessor produced two findings, both judged true (commanded and broadway; maintainer notes). Supervision-aware filtering removed Phoenix's `Endpoint.Supervisor` → `CodeReloader.Server` and `PoolSupervisor` → `Config` (e911da5); a Plug's `init/1` stopped counting as a process's (c456d1d); OTP kernel's `logger_server:init/1` stopped counting a wait its spawned handler makes (CHANGELOG 0.20.0-dev, "Process points-to").

### Supervisor management call from init/1

`blocks_on_peer` · phase=`init`, kind=`sup`
· titles: "init/1 makes a synchronous supervisor call" (`:info`)

**Property.** The `init/1` of a process module, on its own stack, makes a supervisor management call (`start_child`, `terminate_child`, `restart_child`, `delete_child`, `which_children`, `count_children`, `stop`, or a `Task.Supervisor` start or `async`) on some supervisor, named or not. Each is a GenServer.call into the supervisor: `start_child` returns only when the new child's `init/1` has, so that init now runs inside this one on the tree's startup path, and `terminate_child` waits for the child's whole shutdown. A child that calls back into the caller, or into anything not yet started, deadlocks the boot.

**Assumptions and limits.**
- Reported for every management operation at `:info`: whether a child calls back is not asked.
- `detail` is `api.op`; one finding per operation per module.
- A supervisor call in a task `init/1` starts, or in a fun it builds into a child's options and does not run, is not `init/1`'s.

**Fixtures.** Positive: `StartsChildrenInInit` (test/fixtures/sync_init_fixture.ex, `DynamicSupervisor.start_child` on the name `PoolSup`). Quiet: `InitRecv.SpawnsWork` (test/fixtures/init_recv_fixture.ex). Asserted in test/analyses/startup_init_test.exs and singleton_shapes_test.exs.

**Corpus.** None.

**Precision.** Not judged. Motivated by Broadway's server and Oban's Midwife starting children from `init/1` (88c1fdd). Setting aside funs that are kept rather than run removed sequin's `MutexedSupervisor`, the only corpus change (CHANGELOG 0.20.0-dev, "Funs that leave the caller's stack").

### init/1 waits on a running server whose handler can block

`blocks_on_peer` · phase=`init`, kind=`blocking_server`, ordering=`earlier`
· titles: "init/1 waits on a server whose handler can block" (`:warning`)

**Property.** The `init/1` of C, on its own stack, synchronously waits on D, D is known to be running by then (an earlier sibling, or a disjoint tree), and some GenServer handler of D (`handle_call`, `handle_cast`, `handle_info`, `handle_continue`), on its own stack, makes a supervisor operation with no bound of its own (`terminate_child`, `restart_child`, `delete_child`, `stop`) or a `GenServer.call` with `:infinity`. While that handler blocks, D answers nobody: every C whose `init/1` runs in that window hangs behind it, and so does the supervisor starting them. A running callee is not an answering one.

**Assumptions and limits.**
- Any handler of D counts, not only the one C's request enters.
- Only `GenServer.call` spelled so is read for `:infinity`; `:gen_server.call(_, _, :infinity)` and a gen_statem call that defaults to `:infinity` are missed.
- `start_child` is taken as bounded by the child's `init/1`.
- One finding per (C, D).

**Fixtures.** Positive: `WatcherAppTree` with `BlockingWatcher` and `WatchedPool`; `InfiniteAppTree` with `InfiniteWatcher`, `InfiniteWatchedPool`, `WorkerA` and `WorkerB` (test/fixtures/sync_init_fixture.ex). Quiet: `StarterAppTree` with `StartingWatcher` and `WatchedByStarter`. Asserted in test/analyses/startup_init_test.exs.

**Corpus.** None.

**Precision.** Not judged. Written for db_connection's `ConnectionPool.init` calling a `Watcher` blocked in `DynamicSupervisor.terminate_child` (88c1fdd); counting only unbounded operations removed the `Watcher`'s `start_child` (0f01f7b); following only `init/1`'s own process removed supavisor's `DbHandler`, whose `Manager` stops a supervisor from a task (df9919a).

### handle_continue calls a later sibling

`blocks_on_peer` · phase=`continue`, kind=`call`, ordering=`later`
· titles: "handle_continue races a later sibling" (`:warning`)

**Property.** A supervisor S lists C before D, C's `init/1` returns `{:continue, _}`, and a `handle_continue/2` of C, on its own stack, makes a synchronous call that waits on D's process. The continue runs as soon as `init/1` returns, while S is still starting later children, so whether D is registered when the call lands is a boot-time race: it works on a fast machine and exits with `:noproc` on a slow one.

**Assumptions and limits.**
- Any `handle_continue/2` clause of C counts, not only the one `init/1` continues to.
- A cast from the continue is not reported.
- Static trees only.

**Fixtures.** Positive: `ContinueLateCallerServer` with `ContinueLateTargetServer` and `ContinueLateSiblingSupervisor` (test/fixtures/continue_chain_fixture.ex). Quiet: `SafeContinueOrderSupervisor`; `SafeContinueExternalCaller`/`SafeContinueExternalTarget` with their supervisors; `SafeContinueCastCaller`/`SafeContinueCastTarget` with `SafeContinueCastSupervisor`. Asserted in test/analyses/startup_continue_test.exs.

**Corpus.** None.

**Precision.** Not measured. The predecessor found nothing on the corpus search it was written against (d1b02f8).

### handle_continue calls its own supervisor

`blocks_on_peer` · phase=`continue`, kind=`parent`
· titles: "handle_continue calls its own supervisor" (`:warning`)

**Property.** A worker W whose `init/1` continues is a static child of supervisor S and not its last one, and a `handle_continue/2` of W, on its own stack, makes a supervisor management call on S (`Supervisor.which_children/1`, `count_children/1`, `start_child/2`, ...) or a synchronous call that waits on S's process. S is still in `start_link`, starting the children after W and not reading its mailbox, so W blocks until the rest of the child list is up; if a later child waits on W, startup deadlocks. `detail` is the management call's `api.op` (empty for a plain synchronous call) and `site` the call.

**Assumptions and limits.**
- Both a management call (`sup_management_call`, read through the continue's own stack by `sup_reach`, as init/1's supervisor calls are) and a synchronous call the call resolution sees as a dependency on S's process count. A target S is the supervisor module a call names (its registered name); a pid or a computed name is not judged.
- W as S's last child is quiet (`ContinueLastChildCaller`): its init returning is S's last wait, and S reads its mailbox as soon as the continue runs. Whether a later child actually waits on W is not asked.
- Static trees only.

**Fixtures.** Positive: `ContinueParentCallerServer` with `ContinueParentSupervisor`, whose later child is `ContinueParentLaterSibling` (test/fixtures/continue_chain_fixture.ex). Quiet: `ContinueLastChildCaller` with `ContinueLastChildSupervisor`. Asserted in test/analyses/startup_continue_test.exs.

**Corpus.** None.

**Precision.** 0 rows over the corpus tally and ten live projects (ejabberd, rabbit, brod, exq, sentry, elixir-ls, changelog.com, kafka_ex, quantum, firezone's portal) in round 2 (2026-09-25), before and after management calls were read. Until then the rule could not fire on its own fixture, which calls `Supervisor.which_children/1` (a supervisor call, not a synchronous one).

### Retrying :global lock during init/1

`blocks_on_peer` · phase=`init`, kind=`global`, `global_assumed`
· titles: "Cluster-wide lock during init" (`:error`); "Lock during init" (`:warning`)

**Property.** The `init/1` of a process module reaches, on its own stack, a `:global.set_lock` or `:global.trans` call whose retries are `:infinity` (`global`) or not shown by the bytecode and assumed `:infinity`, the default wrappers forward (`global_assumed`). The walk (`global_path`) follows calls that stay on `init/1`'s stack, enters only the clauses a literal first atom selects, and steps into a task `init/1` starts with `Task.async` and awaits; it does not follow a fun `init/1` registers or keeps (`runs_elsewhere`). `dep` is the node list: `cluster` and `unknown` (assumed cluster-wide) take the first title, `local` (`[node()]`) the second. The supervisor waits on the lock and the lock waits on cluster-wide agreement, so local startup hangs whenever the cluster is partitioned or slow; over `[node()]`, it hangs for as long as another local process holds the lock. When the lock is in a helper, a related frame points at the call in `init/1` that starts the path ("init/1 reaches it from here", `init_lock_path`).

**Assumptions and limits.**
- An await anywhere in `init/1` is taken to collect a task it starts.
- A call whose first argument is not one literal atom enters every clause of its callee.
- A literal list of node names is `unknown`.
- Suppressed: a zero retry count (`InitLock.NoRetries`), a positive count over `[node()]` (`InitLock.BoundedLocal`), a lock in a `:telemetry` handler, a stored callback, a child spec's closure, a helper that starts a task, an unawaited task, and a helper clause `init/1` never enters (`InitLock.SharedHelper`).

**Fixtures.** Positive: `GlobalLockInInit` (test/fixtures/distributed_fixture.ex); `GlobalNodes.Cluster`, `Default`, `Local`, `Unknown` (test/fixtures/global_nodes_fixture.ex); `ReachPath.ClusterLock`, `LocalLock`, `TwoPaths` (test/fixtures/reach_path_fixture.ex); `InitLock.DynamicRetries` (`global_assumed`), `EachClosure`, `StartChildBeside`, `WarmupBeside`, `AwaitedTask`, `SharedHelperEntered` (test/fixtures/init_lock_fixture.ex). Quiet: `InitLock.BoundedLocal`, `NoRetries`, `TelemetryHandler`, `TelemetryClosure`, `StoredCallback`, `SpecClosure`, `HelperStart`, `SpawnedLock`, `UnawaitedTask`, `SharedHelper`; `InitRecv.SpawnsWork`. Asserted in test/analyses/init_lock_test.exs, global_lock_nodes_test.exs, reach_path_frame_test.exs, blocking_rpc_test.exs and singleton_shapes_test.exs.

**Corpus.** Present-only: `nebulex:bootstrap-global-lock-in-init` (cabol/nebulex, faff154, `Nebulex.Adapters.Replicated.Bootstrap`).

**Precision.** A precision audit on 2026-09-24 pinned one regression per issue found (test/analyses/init_lock_test.exs; 185c262, 6a45e32). A `:telemetry` handler taking a lock was reported until registered funs were set aside (CHANGELOG 0.20.0-dev, "Funs that leave the caller's stack"); counting every fun a function held would have added two false rows on sequin (a6303d8). Splitting local from cluster-wide locks moved no corpus title: nebulex's list is unread and stays cluster-wide, sequin's are cluster-wide (acf3a28).

### Bounded cluster-wide lock during init/1

`blocks_on_peer` · phase=`init`, kind=`global_bounded`
· titles: "Bounded cluster-wide lock during init" (`:warning`)

**Property.** The `init/1` of a process module reaches, by the same walk, a `:global` lock with a positive retry count whose node list holds other nodes or may (`cluster` or `unknown`). The lock gives up and returns false once its retries are spent, after backoff that OTP caps at eight seconds a try, but each try asks every node in the list; a partitioned node not yet declared down holds the try, and `init/1` and the supervisor's start wait with it, for a bounded but possibly long time.

**Assumptions and limits.**
- The walk's assumptions are the unbounded lock's.
- The same count over `[node()]` is quiet: it is the fix "Lock during init" recommends.

**Fixtures.** Positive: `InitLock.Bounded` (test/fixtures/init_lock_fixture.ex). Quiet: `InitLock.BoundedLocal`. Asserted in test/analyses/init_lock_test.exs.

**Corpus.** None.

**Precision.** Not measured.

### Distributed operation in init/1

`blocks_on_peer` · phase=`init`, kind=`remote`
· titles: "Distributed operation in init/1" (`:warning`)

**Property.** The `init/1` of a process module reaches, on its own stack, a remote call site of any variant and any timeout; or makes, in `init/1` itself, a `:global.register_name`, a node operation other than `Node.list`, `Node.monitor` and `:net_kernel.monitor_nodes` (`Node.connect`, `Node.ping`, `:net_kernel.connect_node`, ...), or a Mnesia or DETS distributed-store operation. `detail` is the operation. The supervisor's start sequence waits on another node, so a slow or partitioned peer stalls local startup.

**Assumptions and limits.**
- An rpc with a finite timeout is reported (it bounds the stall, it does not remove it), and so is one to a function blocking's rpc rule vouches for as answering at once.
- `:global.register_name`, node and store operations are read only in `init/1` itself, not in its helpers.
- The row's `mod` column holds the `init/1` function, not the module.
- Suppressed: an rpc in a process `init/1` starts (`RpcSpawnedFromInit`), a plain module's `init/1` (`PlainInit`), `:net_kernel.monitor_nodes` (`NodeMonitorServer`).

**Fixtures.** Positive: `RpcInInit`, `RpcViaHelperInInit`, `ConnectInInit` (`Node.connect`) (test/fixtures/distributed_fixture.ex). Quiet: `RpcSpawnedFromInit`, `PlainInit`, `NodeMonitorServer`. Asserted in test/analyses/startup_distributed_test.exs and blocking_rpc_test.exs.

**Corpus.** None.

**Precision.** Not judged. Gating `init/1` on a behaviour and excluding `monitor_nodes` removed the predecessor's two false shapes (e198d08); the 2026-07-17 audit took the predecessor distributed analysis from 21 corpus findings to 5 across its rules (maintainer notes).

### init/1 waits on a socket with no timeout

`unbounded_effect_in_init` · kind=`recv`
· titles: "init/1 waits on a socket with no timeout" (`:warning`)

**Property.** The `init/1` of a process module reaches, in its own process (not in what it spawns), a function that reads a socket with `:gen_tcp.recv` or `:ssl.recv` and an `:infinity` timeout: given literally, by the two-argument form, or handed down as `:infinity` through wrapper parameters (`msg_recv(s, :infinity, buffer)`). Until the peer sends, the process is not started: its supervisor's start, and whoever called `start_child`, wait for as long as the server stays silent. One finding per receiving function; the `init/1` callbacks that reach it are related frames pointing at the call that starts the path (`init_reaches_recv`).

**Assumptions and limits.**
- Only `:gen_tcp` and `:ssl`; a `:gen_udp` or `:socket` receive is missed.
- The walk does not stop where `init/1` acknowledges its start, so a read after `:proc_lib.init_ack/1` is still reported as holding the start.
- Suppressed: a finite timeout (`InitRecv.Bounded`), a read made after `init/1` returns (`InitRecv.Later`).

**Fixtures.** Positive: `InitRecv.Blocking` (test/fixtures/init_recv_fixture.ex). Quiet: `InitRecv.Bounded`, `InitRecv.Later`; `Quiet.BoundedReceive` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/singleton_shapes_test.exs, test/evidence_frames_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Present-only: `postgrex#746` (elixir-ecto/postgrex, 412b555, `Postgrex.Protocol`).

**Precision.** Not judged. Postgrex had one identical finding per `init/1` until the rows were deduplicated per receiving function (da1fcf8); a loop `spawn_link` starts from `init/1` stopped being read as `init/1`'s wait (df9919a).

### init/1 waits on a message with no timeout

`unbounded_effect_in_init` · kind=`receive`
· titles: "init/1 waits on a message with no timeout" (`:warning`)

**Property.** The `init/1` of a process module reaches, in its own process and before it acknowledges its start (`start_acked`; the edge into `:gen_server.enter_loop` or `:gen_statem.enter_loop` is cut too), a `receive` with no `after` that cannot be shown to end with its peer: it does not take the pinned `:DOWN` or `:EXIT` of the process it waits on (`recv_down`, `recv_signal`) and is not the cancel_timer flush (`flush_receive`). Until the message arrives the process is not started, and its supervisor's start and any `start_child` caller wait forever if the sender is gone or never sends. Related frames point at the call in each `init/1` that starts the path (`init_reaches_recv`).

**Assumptions and limits.**
- An acknowledgement made in a helper `init/1` calls is not seen.
- A peer that is alive and never answers a pinned-signal wait is the synchronous-call rules' concern, not this one's.
- A loop's clause for its parent's exit does not bound its wait for the next message (`InitRecv.LoopsOnParent` is reported).
- Suppressed: a loop `init/1` spawns (`InitRecv.SpawnsLoop`), a fun built into a child spec (`InitRecv.HandsOff`), a wait after the ack (`InitRecv.AcksThenLoops`, `AcksThenWaits`), waits bounded by a monitor or a port (`InitRecv.AsksWithMonitor`, `AwaitsHandedDown`, `ClosesPort`), and the flush (`InitRecv.FlushesTimer`).

**Fixtures.** Positive: `InitRecv.Waits`, `AwaitsEach`, `HandsOffAndWaits`, `WaitsBeforeAck`, `LoopsOnParent` (test/fixtures/init_recv_fixture.ex); `CallbackReceive.StatemBlockingInInit` (test/fixtures/callback_receive_fixture.ex); `ReachPath.WaitsInInit` (test/fixtures/reach_path_fixture.ex). Quiet: `InitRecv.SpawnsLoop`, `HandsOff`, `AcksThenLoops`, `AcksThenWaits`, `AsksWithMonitor`, `AwaitsHandedDown`, `ClosesPort`, `FlushesTimer`. Asserted in test/analyses/singleton_shapes_test.exs, blocking_receive_test.exs and reach_path_frame_test.exs.

**Corpus.** None.

**Precision.** Before the peer-bounded and acknowledgement cuts the finding was 0 of 8 true on a sample of OTP and Phoenix, and OTP's kernel, stdlib and mnesia went from 23 rows to 5 (3f95685). The five left are `:ets.all/0`'s and `:socket.close/1`'s waits for the runtime's reply, win32reg's port reply and kernel_config's boot handshakes (CHANGELOG 0.20.0-dev, "Waits that end on their own").

### Connect in init/1 with no way to retry

`unbounded_effect_in_init` · kind=`connect`
· titles: "init/1 connects with no reconnect path" (`:warning`)

**Property.** The `init/1` of a process module M reaches, in its own process, `:gen_tcp.connect`, `:ssl.connect`, `:gen_udp.open` or `:httpc.request`, and nothing in M can try again later (`deferral_path`: no timer, no message to itself, no `handle_continue`, no gen_statem timeout). When the dependency is not up yet, `init/1` fails, the supervisor restarts the child at once, and after `max_restarts` the tree, usually the application, goes down at boot.

**Assumptions and limits.**
- The retry path is module-level: any timer or continue anywhere in M quiets the finding, whether or not it reconnects.
- The rule does not ask whether `init/1` fails when the connect fails; an `init/1` that keeps the error and returns `{:ok, state}` is still reported.
- `:gen_udp.open` binds a local port and does not wait on a remote dependency.
- One finding per module; a connect in a task `init/1` starts is not `init/1`'s (`InitRecv.SpawnsWork`).

**Fixtures.** Positive: `Hypothesized.ConnectInInit` (test/fixtures/hypothesized_shapes_fixture.ex). Quiet: `Hypothesized.ConnectWithBackoff`, `Hypothesized.ConnectWithGenericBackoff`; `InitRecv.SpawnsWork`. Asserted in test/analyses/hypothesized_shapes_test.exs and singleton_shapes_test.exs.

**Corpus.** None. tortoise#46, the class's clearest issue, has a pre-fix tree that does not build on Elixir 1.15 or later (bd64e38).

**Precision.** Not measured.

### Deferred work on an init/1 timeout

`deferral_defect` · kind=`init_timeout`
· titles: "init/1 defers work with a zero timeout" (`:info`); "init/1 relies on a #{ms}ms idle timeout" (`:info`)

**Property.** The `init/1` of a process module returns a literal integer timeout, `{:ok, state, ms}`; `ms` of 0 takes the first title, any other the second. The `:timeout` message arrives only if nothing else reaches the mailbox first: any message (a datagram on a socket `init/1` opened, a broadcast it subscribed to, a call from the starter) cancels it, and the deferred work silently never runs.

**Assumptions and limits.**
- Reported for every literal timeout, whether or not anything can arrive first; the rule does not look for sockets, subscriptions or senders.
- A timeout built at runtime is not read.

**Fixtures.** Positive: `TimeoutDeferredInit` (test/fixtures/continue_chain_fixture.ex). Quiet: `ContinueDeferredInit`. Asserted in test/analyses/startup_continue_test.exs.

**Corpus.** None. Written for libcluster's Gossip strategy, whose first UDP datagram cancelled its deferred connect (0cee346).

**Precision.** Not measured.

### Defensive catch in a racing handle_continue

`deferral_defect` · kind=`continue_catch`
· titles: "Defensive continue turns deadlock into a restart loop" (`:warning`)

**Property.** A module W has a "handle_continue races a later sibling" finding under supervisor S, and some `handle_continue/2` clause of W contains a `try`. The catch hides the symptom but the call still fails during the startup race, so W either initializes with the wrong state or crashes and restarts repeatedly under S, and the ordering bug stays hidden.

**Assumptions and limits.**
- Any `try` in any `handle_continue/2` clause counts: the rule does not check that it guards the racing call or catches exits, though the finding says so.

**Fixtures.** Positive: `DefensiveContinueCaller` with `DefensiveContinueTarget` and `DefensiveContinueSupervisor` (test/fixtures/continue_chain_fixture.ex). Quiet: none. Asserted in test/analyses/startup_continue_test.exs.

**Corpus.** None. Modelled on a near miss in Electric's Materializer (d1b02f8).

**Precision.** Not measured.

### Shared state written after the tree is up

`post_start_initialization`
· titles: "Shared state written after the tree is up" (`:info`)

**Property.** A function calls `Supervisor.start_link` and afterwards, in the same function, makes a call that writes a `:persistent_term`, an ETS row (`insert`, `insert_new`) or the application environment, itself or through anything it calls. The children are already running when that write lands, and one that reads the state in the meantime finds nothing there. The anchor is the late call, with the `Supervisor.start_link` as a related frame.

**Assumptions and limits.**
- The rule does not ask whether any child reads what is written; any table, key or env write counts.
- The write is followed through every call, including into a task or a fun registered for later.
- Only a call after `Supervisor.start_link` in the same function is seen; a write from the caller of that function is missed.

**Fixtures.** Positive: `SupervisionShapes.LateWarmup` with `SupervisionShapes.Conn` (test/fixtures/supervision_shapes_fixture.ex). Quiet: `SupervisionShapes.EarlyWarmup`; `Quiet.OwnStateAfterStart` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/startup_supervision_test.exs and quiet_shapes_test.exs.

**Corpus.** Fix pairs: `phoenix#5981` (phoenixframework/phoenix, d34efa8 → 092605f, `Phoenix.Endpoint.Supervisor`).

**Precision.** Not measured beyond the pair.

### Start result ignored

`ignored_start_result`
· titles: "Start result ignored" (`:warning`)

**Property.** A function calls `GenServer.start_link`/`start`, `Supervisor.start_link`, `Agent.start_link`/`start` or `:gen_server.start_link`/`start` in a non-tail position, and the instruction after the call overwrites the result without reading it. An `{:error, reason}` goes unnoticed: the process is not running, and the first symptom is a crash later at a call site that assumed it was.

**Assumptions and limits.**
- The API list is fixed: `:supervisor`, `:gen_statem`, `DynamicSupervisor` and `Task` starts are not read; a discarded `start_child` result is failure's "start_child result not checked".
- The result's fate is read from the next instruction only; a result saved and never tested is not reported.
- The finding anchors at the calling function, not the call.

**Fixtures.** Positive: `IgnoredResultModule` (`ignored_start`; test/fixtures/error_handling_fixture.ex); hand-written facts naming `GenServer.start_link/3`. Quiet: `IgnoredResultModule`'s `checked_start`; hand-written facts naming `MyPool.restart_link/1`. Asserted in test/analyses/startup_start_result_test.exs and failure_consistency_test.exs.

**Corpus.** None.

**Precision.** Not measured. The rule never produced a row until 2026-07-17: Soufflé's `contains` takes the needle first, and the argument order was swapped (c1de271).

## shutdown

Cleanup that cannot run, or teardown that hurts a peer. OTP runs terminate/2 when a callback returns `{:stop, ...}` or raises, and on a supervisor shutdown only if the process traps exits; trapping brings its own obligations, and a process being torn down still has neighbours: a sibling that may already be gone, children in another tree, a monitored child, a permanent child that stops itself. A live server's monitor bookkeeping and its `handle_info/2` clauses belong to mailbox, siblings coupled while they run to coupling, and an exit signal a callback sends to a supervised child to failure (`orphan_process`).

### Cleanup that a supervisor shutdown skips

`cleanup_defect` · kind=`never_runs` | `unclear`
· titles: "#{mod} cleans up in terminate/2 but never traps exits" (`:error`); "#{mod}'s terminate/2 does work that a supervisor shutdown will skip" (`:warning`)

**Property.** Some module M of a behaviour that calls terminate/2 on the way down (`process_behaviour` "terminating": GenServer, GenStage, gen_statem, GenEvent, Broadway, LiveView), no function of which sets `trap_exit` to true, whose terminate/2, or a function it reaches within three calls (`ForwardBoundedCallReach`), makes a write the effect model classifies as durable (`durable_effect`: io, network, process, ets, port, node). That is kind `never_runs`, one finding per module, category and API. With no such write, a call there the effect model cannot classify, other than a structural `Kernel`, `Access`, `Enum`, `Map`, `Keyword`, `:lists` or `:maps` call (`structural_call`), is kind `unclear`, one finding per module. A supervisor stops its child with an exit signal, and a process that does not trap exits dies on it without running terminate/2: the cleanup never happens on the normal way a process stops. Tests miss it because `GenServer.stop/1` takes the path that does run terminate/2.

**Assumptions and limits.**
- Trapping is read per module: a `Process.flag(:trap_exit, true)` anywhere in M counts, even in a function that runs in another process (a client function, a spawned closure). A flag set from a value not known at compile time counts as not trapping.
- Reads and logging are not cleanup. `:telemetry` is not in the effect model, so a terminate/2 that only emits a telemetry event is `unclear`.
- The three-call bound keeps the evidence near the module: an unbounded reach once credited a module with a client library's pool internals five calls down (31bfd35).
- `unclear` cannot say what is skipped, only that terminate/2 does more than log; a module with classified cleanup is not also `unclear`. The structural-call filter is not applied to calls in terminate/2's own body, so a direct `Kernel.struct!/2` there reads as work.
- A gen_event handler module is reported, though its event manager traps exits and runs the handler's terminate/2 on shutdown.
- A terminate/2 written only for self-requested stops is reported alike; the rule has no notion of intent.

**Fixtures.** Positive: `Shutdown.Leaks`, `Shutdown.LeaksIndirect` (`never_runs`), `Shutdown.Unclear` (`unclear`) (test/fixtures/shutdown_fixture.ex). Quiet: `Shutdown.Traps`, `Shutdown.UnclearTraps`, `Shutdown.LogsOnly`, `Shutdown.ReadsOnly`, `Shutdown.CleansUpElsewhere` (same file); `Quiet.ClockInTerminate` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/shutdown_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Fix pairs: `anubis-mcp#209` (zoedsoupe/anubis-mcp, ca0b963 → a224c00, `Anubis.Server.Session`: terminate/2 replied to pending callers and the process never trapped exits).

**Precision.** Calibrated on four projects with every finding read against source: oban 0 (four real cleanups, all trapping), sequin 1, livebook 2, keila 1; the `unclear` bucket added about one module per project (cae50c8). On sequin's full tree the rule then went from 16 to 5 findings once Erlang-spelled reads, `:error_logger`, the unbounded reach and structural calls were fixed, every survivor a plausible cleanup call (`:amqp_channel.close/3`, `Gnat.unsub/3`, a send in terminate/2) (31bfd35). A terminate/2 that only timestamps and logs (Phoenix.LiveView.Channel) stopped being reported when clock reads became time effects (CHANGELOG 0.13.2). Not measured since.

### Unbounded cleanup inside the shutdown timeout

`cleanup_defect` · kind=`truncated`
· titles: "#{mod}'s terminate/2 does unbounded work inside the shutdown timeout" (`:warning`)

**Property.** Some module M that traps exits, of a behaviour that calls terminate/2, whose terminate/2 or a function it reaches within three calls makes a durable write whose category has no bound of its own: network or port (`slow_effect`). terminate/2 runs on a supervisor shutdown, but the supervisor waits only the child's shutdown timeout (5000 ms unless the spec says otherwise) before killing it, and the cleanup is cut off wherever it had got to, often worse than not starting.

**Assumptions and limits.**
- Whether the call carries a timeout of its own is not read: a network call bounded below the shutdown timeout is reported. The child spec's `shutdown` value is not read either.
- The three-call reach follows a closure terminate/2 hands to `Task.start` or a spawn; work there runs off terminate/2's stack and cannot hold the shutdown up (reports).
- A synchronous call to another process (`GenServer.call(..., :infinity)`) or a `Task.await` is not a slow category: a terminate/2 that blocks on a peer is not reported.
- Trapping is read per module, as above.

**Fixtures.** Positive: `Shutdown.Truncatable` (test/fixtures/shutdown_fixture.ex). Quiet: `Shutdown.Traps` (a trapping file write, not slow). Asserted in test/analyses/shutdown_test.exs.

**Corpus.** None.

**Precision.** Not measured.

### A trapped exit nothing takes

`unhandled_exit_signal` · kind=`no_handler` | `no_exit_clause`
· titles: "trap_exit without an :EXIT handler" (`:warning`); "trap_exit without an {:EXIT, ...} clause" (`:warning`)

**Property.** Some module M, not a gen_statem, whose process sets `trap_exit` to true (`module_traps`: a function M's own callbacks reach on their stack sets it, in M or in another module, or M holds a function that sets it and no process module's callbacks reach), that either defines no `handle_info` at any arity (`no_handler`), or defines a `handle_info/2` with no clause that accepts every message and compares the atom `:EXIT` nowhere in it (`no_exit_clause`, `trap_exit_without_exit_clause`). Trapping turns the exit of a linked process into a `{:EXIT, pid, reason}` message. With a partial `handle_info/2` no clause takes it, and the process dies with a FunctionClauseError the first time anything it linked to exits, on the very signal trapping was meant to absorb (Bandit's HTTP/1 handler, trapping through its ThousandIsland `use`, with one clause for `{:plug_conn, :sent}`). With no `handle_info` at all, OTP's gen_server logs the message as unexpected and drops it: the linked process's death goes unanswered.

**Assumptions and limits.**
- `no_handler` cannot fire for a `use GenServer` module, which always compiles in a default `handle_info/2` (a known false negative, pinned by `TrapExitModule`). It fires for a raw `@behaviour :gen_server` module, and for any module that traps without a `handle_info`, including a hand-rolled loop that takes `{:EXIT, ...}` in its own `receive` (reports).
- `:EXIT` compared anywhere in `handle_info`'s body counts as a clause for it (over-approximation, quiet direction).
- A gen_statem receives exits in its state functions and is left out.
- Trapping is read per process, as for cleanup (round 2, 2026-09-25): a helper module's function that traps for the server calling it in init/1 makes the server trap and the helper not (`TrapsThroughHelper` through `TrapHelper`). A trap in a closure the module spawns is that process's (`SpawnsATrapper`). A trap no process module's callbacks reach (a `start_link` that traps its caller, a library function whose caller is outside the program) stays with the module holding it, the old reading. A process is found only through its own callbacks (`process_entry`): a behaviour whose callbacks argus does not know leaves its trap with the helper's module.
- One finding per module and kind, anchored at one function that sets the flag.

**Fixtures.** Positive: `TrapsWithoutExitClause` (`no_exit_clause`), `TrapsThroughHelper` (`no_exit_clause`, its trap in `TrapHelper`), `RawTrapExit` (`no_handler`) (test/fixtures/error_handling_fixture.ex). Quiet: `TrapsWithExitClause`, `TrapExitModule` (the pinned false negative), `StatemTrapExit`, `SpawnsATrapper`, `TrapHelper` (no process of its own), `CleansUpThroughHelperTrap` (same file). Asserted in test/analyses/shutdown_trap_exit_test.exs.

**Corpus.** Fix pairs: `phoenix_live_view@2b4d182` (phoenixframework/phoenix_live_view, de89632 → 2b4d182, `Phoenix.LiveView.UploadChannel`) and `bandit@094d3c5` (mtrudel/bandit, f72e4e8 → 094d3c5, `Bandit.HTTP1.Handler`); each fix leaves a sibling module with the shape (LiveViewTest's UploadClient, Bandit's InitialHandler).

**Precision.** Leaving gen_statem out removed two false positives on a 15-project corpus, Swarm's Tracker among them, which matches `{:EXIT, ...}` in its state functions (5cebc80). `no_exit_clause` came from Bandit's handler (e3ce1b5); moving it into clientlib/process.dl left the output identical over the corpus and four large programs (dd9649a). Not measured.

### A sibling called from terminate/2 after the supervisor stopped it

`teardown_touches_sibling` · phase=`terminate`, kind=`call` | `call_restart` | `call_unordered`
· titles: "terminate/2 calls a sibling that may already be down" (`:warning` for `call` and `call_restart`, `:info` for `call_unordered`)

**Property.** Some module M that traps exits has a terminate/2 that waits on another module S's process (`sync_dep`: a synchronous call resolved to S, a call into S's client API, or a fun of S's API handed to a call), in its own body or in a helper it reaches within three calls along calls that stay in its own process and that no exit-catching try covers (`ForwardGuardedCallReach`). The waiting call is itself covered by no try that takes the exit or names `{:noproc, _}`, is made when terminate/2's reason is `:shutdown`, and goes to a process of S that M did not start for itself (`private_dep`). A supervisor P, under which M and S sit in different branches (`starts_before`), stops S before it terminates M:
- `call`: S's branch is started after M's, and never before it, so P's shutdown, in reverse start order, stops S first, under any strategy.
- `call_restart`: S is P's own child, started before M, and P is `rest_for_one` or `one_for_all`, so S's crash is why P terminates M (oban#21: the Producer exits, the queue supervisor takes the Watchman down, and the Watchman pauses the Producer).
- `call_unordered`: the child list puts the same module on both sides of M, or P's strategy was not read.

The call exits with `:noproc`, so what it was for never happens, and terminate/2 crashes, skipping whatever follows it. `site` is the unguarded call, `sup_site` where P places both, and the first call of the unguarded path is a related frame (`terminate_path`, "terminate/2 reaches it from here").

**Assumptions and limits.**
- Only a process that traps exits runs terminate/2 when P stops it with `exit(pid, :shutdown)`; a non-trapping caller's lost cleanup is `cleanup_defect` (`SiblingOrder.NonTrappingCalleeLater`). Trapping is read per module.
- A child spec with `shutdown: :brutal_kill` kills M even when it traps; the spec's shutdown value is not read (reports).
- A restart that escalates past a nested supervisor's intensity is not followed: `call_restart` needs S to be P's own child (quiet).
- terminate/2's own tests on its reason are read (a call in a `terminate(:normal, s)` clause is spared); a helper that dispatches on the reason it is handed, or an apply, is taken to run (reports).
- A bare `catch :exit, :noproc` does not guard: it is `GenServer.stop`'s reason, and a call exits with `{:noproc, {GenServer, :call, _}}`. A fun no call is handed (stored, then called through a variable) is spared by any exit-catching try in its function (quiet).
- A path into a fun handed to a spawn or a task's start stops there: its `:noproc` ends that process, not terminate/2. A cast waits on nothing.
- Start order comes from static child positions; children started at runtime are not ordered.

**Fixtures.** Positive: `ShutdownSiblings.Watchman` under `ShutdownSiblings.Sup` with `ShutdownSiblings.Producer`; `SiblingOrder.CalleeStartsLater`, `CalleeEarlierRestForOne`, `NestedCallerFirst` (with `WriterSup`), `NestedCalleeLater` (with `DirectorySup`), `NestedCallerRestForOne`, `CalleeEarlierUnknownStrategy` (with `SiblingOrder.Writer` and `Directory`); `SiblingGuard.TryElsewhere`, `ErrorOnly`, `HelperTryElsewhere`, `NestedAfterInner`, `NoprocBare`, `OtherReasonFirst`, `RefTryElsewhere`, `ClosureTryElsewhere` (all test/fixtures/shutdown_fixture.ex); `PrivateConn.Reporter` (test/fixtures/private_conn_fixture.ex). Quiet: `ShutdownSiblings.CarefulWatchman`, `ShutdownSiblings.GuardedWatchman`; `SiblingOrder.CalleeStartsEarlier`, `NestedCalleeRestForOne`, `NonTrappingCalleeLater`; `SiblingGuard.CallInside`, `HelperInside`, `HelperGuards`, `NestedOuterExit`, `NoprocInside`, `ClosureInside`, `ClosureInTask`, `ShutdownClauseFirst` (test/fixtures/shutdown_fixture.ex); `PrivateConn.Pool`; the `Quiet` modules (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/shutdown_test.exs, test/analyses/quiet_shapes_test.exs and test/analyses/private_instance_test.exs.

**Corpus.** Fix pairs: `oban#21` (oban-bg/oban, 7143d7a → 882febd, Oban.Queue.Watchman). Present-only: `horde:signal-shutdown-unguarded-call` (elixir-horde/horde, 74820c2, Horde.SignalShutdown).

**Precision.** Firing only for a sibling the supervisor itself has stopped kept both corpus findings, each a restart case under `rest_for_one` or `one_for_all`, which a start-order-only rule would have dropped (349663b). Guarding by the try that covers the call left the corpus tally identical and both findings unchanged field for field (41b0558), and so did the seven fixes of the sibling-rule precision audit (e27eb7e..8846f8a). Not judged beyond the pairs.

### A callback stops a sibling the supervisor owns

`teardown_touches_sibling` · phase=`handler`, kind=`stop`
· titles: "A callback stops a sibling the supervisor owns" (`:warning`)

**Property.** Some GenServer M, a direct child of a supervisor P, has a message handler h (`handle_call`, `handle_cast`, `handle_info`, `handle_continue`) that reaches, through any chain of calls, either a `GenServer.stop` naming a sibling S (another direct child of P, `sibling`), or a function of S's module that calls `GenServer.stop` (S's own stop API), unless every process h hands that API is one some function started and keeps for itself (`private_process`). P still owns S: a permanent S comes straight back, and during P's shutdown S may already be gone, so the stop exits with `:noproc` in M (horde#154 and #193: the DynamicSupervisorImpl stopping its ProcessesSupervisor sibling on quorum loss and crashing at SIGTERM). The sibling's stop API and P's child list are related frames.

**Assumptions and limits.**
- Reach from the handler is unbounded, not limited to h's own process, and value-insensitive: a stop inside a closure h spawns counts, as does one on a path h's arguments never take.
- Siblings are direct children only; the terminate rule above reads branches.
- A function of S's module counts as its stop API whenever it calls `GenServer.stop` on anything.
- Only `GenServer.stop`: a `Process.exit` to a supervised child is failure's `orphan_process`, and `Supervisor.terminate_child`, asking the supervisor, is the fix. Only GenServer handlers.

**Fixtures.** Positive: `Hypothesized.SiblingStop.Coordinator` with `SiblingStop.Sup` and `SiblingStop.Workers` (test/fixtures/hypothesized_shapes_fixture.ex). Quiet: `Hypothesized.SiblingStop.PoliteCoordinator` (same file; it is not listed under `SiblingStop.Sup`, so it has no sibling); `PrivateConn.Pool`, stopping its own connection through `Conn.stop/1` (test/fixtures/private_conn_fixture.ex). Asserted in test/analyses/hypothesized_shapes_test.exs and test/analyses/private_instance_test.exs.

**Corpus.** Present-only: `horde#193` (elixir-horde/horde, 74820c2, Horde.DynamicSupervisorImpl).

**Precision.** Not measured. Exempting private instances left the corpus and realtime, logflare, hexpm and OTP unchanged (fbab8ff).

### Children left under another tree's supervisor

`foreign_dynamic_children`
· titles: "children started under another tree outlive their owner" (`:warning`)

**Property.** Some process module M whose callbacks reach a function f, not defined in the supervisor's own module, that starts children under a supervisor S named by a literal (`DynamicSupervisor.start_child`, or a Task.Supervisor `start_child`, `async`, `async_nolink`, `async_stream` or `async_stream_nolink`), where some supervision subtree holds S, as a module or by the name a child spec gives it, but not M, and no terminate/2 of M, within three calls, terminates a child or stops a supervisor. The children's lifetime follows S's tree, not M's: when M's tree shuts down they keep running, reconnecting, logging, calling into applications that have already stopped (postgrex#763: pool connections under `:db_connection`'s supervisor outliving the user's Repo).

**Assumptions and limits.**
- A supervisor held as a pid, or named through `{:via, ...}`, is not placed (quiet).
- A start function in the supervisor's own module is that tree's shared service, meant to own what it starts, whoever asks (`Quiet.SharedService`).
- "Another tree" is any subtree that holds S and not M: a sibling branch of the same application tree counts, though a whole-tree shutdown stops those children after M.
- A task from `Task.Supervisor.async` or `async_stream` is linked to its caller and dies with it, yet is reported like an unlinked one.
- A terminate/2 that terminates children counts whether or not M traps exits (a non-trapping M's terminate/2 does not run on shutdown), and whichever children it terminates.
- The starter is found by call reach from M's callbacks, not only in M's own process. The anchor is the `DynamicSupervisor.start_child` call; a Task.Supervisor start has no site of its own and the finding points at f, and the prose says "a DynamicSupervisor" for both.

**Fixtures.** Positive: `ForeignChildren.Manager` (DynamicSupervisor) and `ForeignChildren.TaskStarter` (Task.Supervisor), with `ForeignChildren.LibraryTree`, `AppTree`, `Worker` and `TaskTree` (test/fixtures/shutdown_fixture.ex). Quiet: `ForeignChildren.TidyManager` (same file); `Quiet.ServiceClient` with `Quiet.SharedService` and `Quiet.Server` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/shutdown_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Present-only: `postgrex#763` (elixir-ecto/db_connection, 6c4e5c2, DBConnection.Ownership.Manager). The issue's own instance, the pool manager, reaches the supervisor through a Watcher message argus does not resolve; the same shape in the ownership manager is what the rule sees, and the fix leaves it.

**Precision.** Attributing a start to the process whose callbacks reach it removed a plain helper module's false positive (encore's canon; CHANGELOG 0.12.1), and a start function in the supervisor's own module (`Postgrex.TypeSupervisor.start_server/2`) stopped being reported (CHANGELOG 0.13.0). Not measured.

### A monitored process terminated on purpose

`kills_monitored_child`
· titles: "#{mod} terminates a process it still monitors" (`:info`)

**Property.** Some process module M whose own-stack functions (`server_side`: its callbacks and what they reach inside M) monitor some process and, in some function, terminate a supervisor's child (`terminate_child`) or stop a process (`GenServer.stop`), while no function of M ever demonitors (`module_demonitors`). The `{:DOWN, ...}` for a death M caused itself is delivered like any other, into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop (Oban's producer handling its own `:DOWN` after pkill; Redix's cluster manager reconnecting the connection it had just terminated). One finding per terminate site; a monitor site is a related frame.

**Assumptions and limits.**
- The monitored process and the terminated one are not tied: the rule asks only that both calls and no demonitor occur in M, so a module that monitors its clients and stops an unrelated child is reported.
- One demonitor anywhere in M quiets every terminate in it.
- A `:DOWN` clause that ignores a reference M dropped from its state before terminating is safe without a demonitor, and is still reported.
- A kill by `Process.exit` is not read.

**Fixtures.** Positive: `MonitorLeak.KillsMonitored` (test/fixtures/monitor_fixture.ex). Quiet: `MonitorLeak.NeverReleases`, `ReleasesOnDelete`, `ClientSideMonitor`, `DropsRef` (same file), none of which terminates a process; no fixture demonitors before terminating. Asserted in test/analyses/shutdown_monitor_test.exs.

**Corpus.** None.

**Precision.** Not measured.

### A permanent child that stops itself

`permanent_child_stops_normally`
· titles: "Permanent child stops itself and is restarted" (`:info`)

**Property.** Some supervisor P lists a child C as `:permanent`, and some callback of C other than terminate/2 returns `{:stop, :normal, ...}` or `{:stop, :shutdown, ...}` with a literal reason. A supervisor restarts a permanent child whatever its exit reason: the process asks to go away and is started straight back, what the stop was for (a graceful permdown, a drain-and-quit) is undone at once, and the restart counts toward P's intensity (Phoenix PubSub's tracker shards on graceful permdown, until their spec became `:transient`). One finding per supervisor and child, with P's child spec as a related frame.

**Assumptions and limits.**
- The restart is the one P's child list gives. A shorthand spec (`C` or `{C, args}`) is taken as permanent even when C's own `child_spec/1` (`use GenServer, restart: :transient`) says otherwise (reports).
- Only a literal `:normal` or `:shutdown`: `{:shutdown, term}`, which is restarted too, and a computed reason are not read; neither is `exit(:normal)` from a callback.
- Children started under a DynamicSupervisor, permanent by default, are not read.

**Fixtures.** Positive: `PermanentQuitter` under `QuitterSupervisor` (test/fixtures/supervision_fixture.ex). Quiet: `PermanentQuitter` under `TransientQuitterSupervisor` (same file). Asserted in test/analyses/shutdown_supervision_test.exs.

**Corpus.** Fix pairs: `phoenix_pubsub#194` (phoenixframework/phoenix_pubsub, 8b92e8f → 148ae10, Phoenix.Tracker.Shard).

**Precision.** Not measured.

## blocking

A synchronous wait that can last forever or nest: every finding is a process waiting on another, and the mechanism (GenServer.call, rpc, `:global`, `receive`) is a column or a relation while the concern is the wait. A wait that `init/1` holds on its own stack belongs to startup, which reports an rpc, a `:global` lock or a blocking `receive` on init's path once, as a stalled start; how a caller handles an rpc's failure value (`{:badrpc, _}`, `{:erpc, _}`) belongs to failure.

### Nested call chain

`call_chain` · kind=`chain`
· titles: "GenServer call chain of depth #{depth}" (`:warning`)

**Property.** There are GenServer modules S0, S1, ..., Sd with d ≥ 2 such that a request into some clause of S0's `handle_call/3` makes a synchronous call, on S0's own stack, whose request enters a clause of S1's `handle_call/3` that in turn calls S2, and so on to Sd. A hop is a call the clause makes itself or through functions it runs in its own process: not what a spawn, task or agent runs (`runs_elsewhere`), and not the logging or telemetry API (`side_call`). A call into a function with a literal first atom enters only the clauses that match it (`clause_call`, `site_request`); a clause the extractor cannot tell serves every request, and a request with no literal tag enters every clause. The finding names the shortest chain from S0 to Sd and does not pass through a clause that lies on a cycle of requests (that is the call cycle's finding). `inferred` is `tag` when some hop exists only because a call to a pid or name held in state was attributed by its message tag. Each hop carries its own timeout, usually GenServer.call's default five seconds, so a slow leaf times out every caller above it and each level exits or retries on its own schedule.

**Assumptions and limits.**
- A hop exists only where the call's target is known: a literal name, a client-API wrapper of the target's module, a pid process points-to follows back to its start, or a tag exactly one GenServer handles (`tag_resolved_site`; generic tags such as `:get` and `:stop` are never attributed). A call to an unresolved pid with no attributable tag is no hop, and the chain through it is missed.
- Only GenServer `handle_call/3` clauses are hops; a gen_statem or GenStage call handler in the middle of a chain breaks it (false negative).
- Depth is capped at ten hops.
- Suppressed: a `handle_call/3` that reaches only a pure function of a server module (`TimeoutChain.ChainOuter`), a call into `:logger` or `:telemetry` (`SidePaths.Logs`), a chain around a cycle (`ChainShapes.CycW`), and a dispatcher's clause the literal argument never enters (`ChainShapes.FugRouter`).
- Not suppressed: a tag attribution that names the wrong server; the finding says the hop is inferred and asks the reader to check it.

**Fixtures.** Positive: `TimeoutChain.ServerA` → `ServerB` → `ServerC` (test/fixtures/timeout_chain_fixture.ex); `ChainShapes.ShortA`–`ShortD` and `ChainShapes.FugCounter` → `FugAnswer` → `FugSubject` (test/fixtures/chain_shapes_fixture.ex); `PidCalls.Impatient`, `Middle`, `Tail` (test/fixtures/pid_call_fixture.ex, a chain points-to proves, marked `static`). Quiet: `ChainShapes.CycW`–`CycZ`, `ChainShapes.FugRouter`/`FugRelay`, `TimeoutChain.ChainOuter`/`ChainMiddle`/`ChainInner`, `SidePaths.Logs`/`CallsLogs` (test/fixtures/side_path_fixture.ex), `PidFlow.Front`/`Back`/`Side` (test/fixtures/pid_flow_fixture.ex). Asserted in test/analyses/blocking_chain_test.exs, blocking_pid_call_test.exs and blocking_cycle_test.exs.

**Corpus.** None.

**Precision.** The predecessor rule was 3 true and 29 false on a 15-project corpus (9.4%), every false one from a module-level dependency clause that was then removed (d5b57ac). Treating logging and telemetry as side paths took OTP from 7 rows to 3 (CHANGELOG 0.20.0-dev, "Process rules, read against real programs"). Moving to per-request hops left the corpus tally identical, two depth-2 chains (ca0fb73).

### Synchronous call in a cast handler

`call_chain` · kind=`cast`
· titles: "handle_cast blocks on a synchronous call" (`:warning`)

**Property.** Some GenServer module M has a `handle_cast/2` that, on its own stack (not in what it spawns, and not through the logging or telemetry API), makes a synchronous call to the process of another module T, with T ≠ M. Senders treat the cast as fire-and-forget, but the server is blocked for the whole call; casts queue behind it with no caller waiting on, or noticing, the slow handler.

**Assumptions and limits.**
- Target resolution is the chain rule's; an unresolved target is missed.
- GenServer only, and any clause of `handle_cast/2` counts: the rule does not follow which clause a cast enters.
- The call's timeout and the target's behaviour are not read: a call to a server that answers at once is reported like an `:infinity` one.
- A cast handler calling its own module's process is the self-call finding, not this one.

**Fixtures.** Positive: `TimeoutChain.BlockingCastServer` with `TimeoutChain.ServerC` (test/fixtures/timeout_chain_fixture.ex); `PidCalls.HandOffCaster` with `PidCalls.Named` (test/fixtures/pid_call_fixture.ex, a closure beside a child spec's fun stays the handler's own). Quiet: none. Asserted in test/analyses/blocking_chain_test.exs and blocking_pid_call_test.exs.

**Corpus.** None.

**Precision.** Not measured.

### Caller's timeout shorter than the callee's downstream wait

`call_chain` · kind=`budget`
· titles: "Call timeout shorter than the callee's downstream budget" (`:error`)

**Property.** GenServer A's `handle_call/3`, on its own stack, calls GenServer B with a finite timeout t_ab, and some `handle_call/3` of B calls another server with a finite timeout t_bc, where t_ab < t_bc. `caller_ms` is t_ab and `downstream_ms` is t_bc. A's call can time out, and A crash or retry, while B's work is still legitimately running, which duplicates effort and leaves state inconsistent.

**Assumptions and limits.**
- GenServer.call's default is recorded as 5000 ms. Equal timeouts are not reported: t_ab = t_bc almost always means both sides use the default (87458c0). Unknown and `:infinity` timeouts are left out (the latter is the `:infinity` hop's finding).
- B's downstream call may sit in any `handle_call/3` clause of B, not only the clause A's request enters; the rule is module-granular on B. Encore's fugue benchmark has a budget row through a router's `:remote` leg that A's request never takes (maintainer notes, 2026-09-23).
- GenServer only.

**Fixtures.** Positive: `TimeoutChain.TightBudgetServer` → `TimeoutChain.DeepServer` → `TimeoutChain.ServerC` (test/fixtures/timeout_chain_fixture.ex); `PidCalls.Impatient` → `PidCalls.Middle` (test/fixtures/pid_call_fixture.ex, through pids). Quiet: `TimeoutChain.ServerA`/`ServerB`/`ServerC` (all defaults). Asserted in test/analyses/blocking_chain_test.exs and blocking_pid_call_test.exs.

**Corpus.** None.

**Precision.** Not measured. The strict comparison removed every default-against-default report (87458c0).

### Infinite wait on a hop that serves callers

`unbounded_wait` · kind=`infinity`
· titles: ":infinity timeout inside a call chain" (`:warning`)

**Property.** GenServer M's `handle_call/3`, on its own stack, calls GenServer T (T ≠ M) with timeout `:infinity`, and T's `handle_call/3` can itself wait: something it runs in its own module has a `receive` with no `after`, a call through a fun value or an apply, a function of another module handed as a fun, or a call out of its module that no list vouches for as answering at once (a vetted BIF, ETS or clock call, a file's metadata, a module that only computes, a call with a finite timeout of its own). While M serves synchronous callers it hangs for as long as T hangs, and no timeout ever unblocks M or the callers queued behind it.

**Assumptions and limits.**
- T is judged by the code of its own module; T's calls into other modules are judged only by the vetted lists, so a call into the logging API from T's handler counts as a call that can wait.
- Any clause of T's `handle_call/3` counts, not only the one M's request enters.
- One finding per (M's `handle_call/3`, T), anchored at the function.
- GenServer only: an `:infinity` call from a gen_statem's call handler is not seen.
- Suppressed: a hop into a server whose handler answers at once (`SidePaths.Proxy`, Phoenix's CodeReloader stopping its own proxy), and waits reached only through the logging or telemetry API (`SidePaths.Logs`).

**Fixtures.** Positive: `PidCalls.Waiter` → `PidCalls.Slow` (test/fixtures/pid_call_fixture.ex, a pid the server started); `SidePaths.AsksWorker` → `SidePaths.Worker` (test/fixtures/side_path_fixture.ex); `TimeoutChain.ServerWithInfinityTimeout` (test/fixtures/timeout_chain_fixture.ex, asserted only when the extractor records the timeout). Quiet: `SidePaths.StopsProxy` → `SidePaths.Proxy`; `SidePaths.Logs`/`CallsLogs` with OTP's logger. Asserted in test/analyses/blocking_pid_call_test.exs and blocking_chain_test.exs.

**Corpus.** None.

**Precision.** Treating logging and telemetry as side paths took OTP from 24 rows to 13 (CHANGELOG 0.20.0-dev). Requiring that the target can wait removed Phoenix's CodeReloader; Phoenix's `MixListener.purge/1` and mnesia's servers are still reported (af4dfa0). Not sampled.

### Synchronous call cycle between processes

`call_cycle` · phase=`call`
· titles: "Synchronous call cycle" (`:error`)

**Property.** There are modules A ≠ B, each running as a process, such that A's process makes a synchronous wait on B's process and B's process makes one on A's. A direction counts only when the wait is made by the module's own process: in a function reached from one of its callbacks (`process_entry`, a channel's `join/3`, or a callback-named function of a process module) on its own stack, or in a task it starts and awaits (`HoldingReach`, `awaits_task`). A client function of a server module runs in its caller and does not count. A wait made only while a process starts (`init/1`, `join/3`) counts only when the process can be named during its start (a registered name, or a call or cast to it by name) or when the peer's `handle_call/3` clause for that request calls it back. If both directions are ever in flight at once, each process blocks in a call the other cannot answer, and GenServer.call's timeouts turn the deadlock into cascading crashes. Each edge is attached as a related frame (`call_cycle_path`), marked `tag` when it exists only by message-tag attribution and `static` otherwise.

**Assumptions and limits.**
- The cycle is by module, deliberately: a server busy in one clause cannot answer a call into another.
- Target resolution is the chain rule's (literal names, client wrappers with the literal target lifted to the caller that passes it, process points-to, tag attribution); an edge through an unresolved pid with no attributable tag is missed.
- Known false negative: a peer that holds the start's request unanswered (`{:noreply, _}`) and calls the starting process from another callback deadlocks too; the reply is not followed (priv/dl/analyses/blocking.dl, "A wait made on the way up").
- The rule does not ask whether the two directions can ever be in flight at the same time; a direction made only at boot and another only on an operator's request are still a cycle.
- Suppressed: thin wrappers over one server module (`CallCycle.EventBuffer`), a client function in a server module (`CallCycle.Producer`), a helper shared by two servers (`PidFlow.SafeCall`), an unnamed process that waits on its peer only while it starts (`CallCycle.UploadChannel`, `CallCycle.Worker`), and logging side paths.

**Fixtures.** Positive: `CycleServerA`/`CycleServerB` (test/fixtures/call_cycle_fixture.ex); `PidFlow.CycleA`/`CycleB`, `PidFlow.Hub`/`Listener`, `PidFlow.NamedPeerA`/`NamedPeerB` with `PidFlow.NamedCall` (test/fixtures/pid_flow_fixture.ex); `CallCycle.Awaiter`/`Awaited`, `CallCycle.NamedManager`/`NamedWorker`, `CallCycle.Greeter`/`Joiner` (test/fixtures/call_cycle_fixture.ex); `GenEventCycleA`/`GenEventCycleB` (test/fixtures/gen_event_fixture.ex); `PidCalls.StatemFront`/`StatemPeer` (test/fixtures/pid_call_fixture.ex); `TagServerA`/`TagServerB` (test/fixtures/tag_cycle_fixture.ex, `tag` edges); `ChainShapes.FugAnswer`/`FugCounter`. Quiet: `PidFlow.Front`/`Back`/`Side`; `PidFlow.SafeCall` with `UserA`, `UserB`, `TargetA`, `TargetB`; `PidFlow.NamedCall` with `NamedUserA`, `NamedUserB`, `NamedTargetA`, `NamedTargetB`; `CallCycle.WriteBuffer`, `EventBuffer`, `SessionBuffer`, `Buffers`; `CallCycle.Producer`/`Batcher`; `CallCycle.View`/`UploadChannel`; `CallCycle.Manager`/`Worker`. Asserted in test/analyses/blocking_cycle_test.exs, blocking_pid_call_test.exs, blocking_chain_test.exs and test/clientlib/tag_resolution_test.exs.

**Corpus.** Present-only: `horde#217` (elixir-horde/horde, 74820c2, no module pinned).

**Precision.** Treating logging and telemetry as side paths took OTP from 5 rows to 2 (CHANGELOG 0.20.0-dev). Lifting a literal target to the caller of a wrapper removed three false errors on Plausible's write buffers (CHANGELOG 0.20.0-dev, blocking). Requiring each direction to be the module's own process, and a start-time wait to be reachable, removed the two phoenix_live_view Channel ↔ UploadChannel rows; horde#217 stays (4568d1d, c4188e5). No sample has been judged.

### Mutual handle_continue deadlock

`call_cycle` · phase=`continue`
· titles: "Mutual handle_continue deadlock" (`:error`)

**Property.** There are modules A ≠ B whose `init/1` returns `{:continue, _}`, and a `handle_continue/2` of each, on its own stack, synchronously waits on the other's process. Both inits return and the supervisor moves on, then each process blocks in its continue before it ever reads its mailbox; neither can answer, and both calls time out on every boot.

**Assumptions and limits.**
- Any `handle_continue/2` clause of a module whose `init/1` continues counts, not only the clause `init/1` continues to.
- Target resolution is the chain rule's.
- The start-order side of a continue (a later sibling, the parent supervisor) is startup's.

**Fixtures.** Positive: `ContinueCycleServerA`/`ContinueCycleServerB` with `ContinueCycleSupervisor` (test/fixtures/continue_chain_fixture.ex). Quiet: `SafeContinueExternalCaller`/`SafeContinueExternalTarget` with their two supervisors. Asserted in test/analyses/startup_continue_test.exs.

**Corpus.** None.

**Precision.** Not measured. The predecessor rule found nothing on the corpus search it was written against (d1b02f8).

### Synchronous call to the calling process

`call_cycle` · phase=`self`
· titles: "Synchronous call to the calling process itself" (`:error`)

**Property.** Some synchronous call site's target is provably the process making the call (`self_call`): `self()`, `self()` handed to a helper that calls its parameter, or, from a server's callback, a name only that module's own processes hold. A process cannot answer a call while it waits for the reply, so gen exits the caller with `:calling_self` and the process crashes on the first call.

**Assumptions and limits.**
- The target must be proved by process points-to; a self-call through a pid the analysis cannot follow is missed.
- One finding per call site.
- A cast to the process itself is not a finding.

**Fixtures.** Positive: `PidCalls.SelfCaller` (test/fixtures/pid_call_fixture.ex, three sites: `self()`, the module's name, `self()` handed to a helper). Quiet: the cast to itself in the same module. Asserted in test/analyses/blocking_self_call_test.exs.

**Corpus.** None.

**Precision.** Nothing on the corpus, realtime, logflare, hexpm or OTP when added (a7a11ae).

### High synchronous fan-in

`sync_call_fan_in`
· titles: "High synchronous fan-in (#{cnt} caller modules)" (`:warning`)

**Property.** Some GenServer module T is waited on synchronously by functions of at least five distinct other modules, each such function reaching the wait on its own stack. The callers are attached as related frames (`bottleneck_caller`, one per caller module). One process serializes all of their requests: under load its queue and every caller's latency grow together until callers start timing out.

**Assumptions and limits.**
- It counts modules whose code waits on T, not processes or call rates; a module whose only callers are tests, or a facade of T's own API, counts as a caller.
- The threshold of five is fixed and separates a central service from a bottleneck by module count alone.
- Target resolution is the chain rule's; unresolved callers are not counted.

**Fixtures.** Positive: `BottleneckTarget` with `BottleneckCallerA`–`BottleneckCallerE` (test/fixtures/bottleneck_fixture.ex). Quiet: `CycleServerA`, `CycleServerB` and `MyGenServer` (test/fixtures/otp_fixture.ex; below the threshold). Asserted in test/analyses/blocking_fan_in_test.exs.

**Corpus.** None.

**Precision.** Not judged. Resolving self-directed calls moved sequin from 2 servers to 3 and Livebook from 5 to 5 (4ab9ea9); making callers frames rather than findings removed 56 "Caller of a high fan-in GenServer" rows from the corpus tally (fab1217).

### Blocking receive in an OTP callback

`receive_in_callback` · bounded=`false`
· titles: "Blocking receive inside a #{behaviour} callback" (`:error`)

**Property.** A `receive` with no `after` runs on the stack of a process whose behaviour owns its receive loop (GenServer, gen_statem, GenEvent, GenStage, Broadway, Supervisor, LiveView, LiveComponent, Channel): in one of its callbacks other than `init/1`, or in a function that callback calls directly on the same process (a closure it runs included, what it spawns not: `runs_elsewhere`). The receive does not take the `:DOWN` of a monitor its own function took (`recv_down`) and is not the cancel_timer flush (`flush_receive`). It consumes from the mailbox the behaviour manages (system messages, `{:EXIT, ...}` when trapping, every monitor's `:DOWN`), and with no timeout it can block forever; a supervisor's shutdown then waits out the child's timeout and kills it.

**Assumptions and limits.**
- Only a receive in the callback or one call away is seen; one deeper is missed.
- A gen_statem's state functions (state_functions mode) are not callbacks here, so a receive in one is missed.
- A receive that pins the exit signal of a linked or otherwise monitored process (`recv_signal`) is still reported, though startup counts that wait as bounded.
- A blocking receive in `init/1` is startup's finding.
- The flush is judged per receive: a receive whose every clause waits for some other literal, in a module whose timers carry known literals, is still reported.

**Fixtures.** Positive: `CallbackReceive.BlockingInCallback`, `BlockingInHelper`, `ReceiveInEach`, `StatemBlockingInInit` (its `terminate/3`), `CancelThenWait`, `AwaitsAnotherDown`, `AwaitsNormalDown`, `DemonitorsThenAwaits` (test/fixtures/callback_receive_fixture.ex). Quiet: `CallbackReceive.SpawnedReceive`, `TimerFlush`, `TimerFlushArmed`, `PlainProcess`, and `StatemBlockingInInit`'s `init/1`. Asserted in test/analyses/blocking_receive_test.exs.

**Corpus.** Fix pairs: `broadway_kafka@e380290` (dashbitco/broadway_kafka, 6ef6f41 → e380290, `BroadwayKafka.Producer`: a receive for the coordinator's `:DOWN` in handle_info/2 deadlocked the producer).

**Precision.** Both blocking receives on the first corpus sweep were the flush idiom, now suppressed (e9508c3). Broadway's `Topology.terminate/2` and `Terminator` moved from this error to the bounded warning (fbb7efa). Following closures added OTP's `:global` `handle_call(disconnect)`, which waits for a nodedown in a fold's closure with no `after` (84ff4ac). Not sampled.

### Bounded receive in an OTP callback

`receive_in_callback` · bounded=`true`, `down`
· titles: "receive inside a #{behaviour} callback" (`:warning`)

**Property.** A `receive` runs on an OTP process's own stack, in a callback or one call away, and either has an `after` clause (`true`, `init/1` included) or has none but takes the `:DOWN` of a monitor its own function took (`down`, `init/1` excluded). It is not the cancel_timer flush at any bound. It cannot hang, or cannot outlast the monitored process, but it selectively consumes from the behaviour's mailbox: messages it does not match stay queued and are rescanned, system messages wait behind it, and a `down` wait holds the callback until the monitored process exits.

**Assumptions and limits.**
- The facts carry whether a receive can block, not its timeout, so a one-millisecond wait and a one-hour wait read alike.
- Proximity and behaviour coverage are the blocking receive's.

**Fixtures.** Positive: `CallbackReceive.BoundedInCallback`, `CancelThenBoundedWait`, `KillsAfterGrace` (one timed receive, one `down`), `AwaitsOwnDown`, `AwaitsDoneOrDown`, `AwaitsReplyOrDown` (test/fixtures/callback_receive_fixture.ex). Quiet: `CallbackReceive.TimerFlushAfterZero`. Asserted in test/analyses/blocking_receive_test.exs.

**Corpus.** None.

**Precision.** Exempting the bounded flush removed one corpus row, sequin's `ReorderBuffer.maybe_cancel_flush_batch_timer/1` (ab7aebc). Not sampled.

### RPC without a bounded timeout

`unbounded_wait` · kind=`rpc`
· titles: "RPC without a bounded timeout" (`:warning`)

**Property.** Some remote call site (`:rpc.call`, `block_call`, `multicall`, `yield`, `nb_yield`; `:erpc.call`, `multicall`, `receive_response`) waits for `:infinity`: its arity leaves the timeout out, it passes `:infinity`, or it takes the timeout as a parameter that some caller passes as a literal `:infinity` (`detail` is `caller`, and those callers are attached as frames by `rpc_infinity_caller`). The remote function is not one known to answer at once (a process or ETS key operation, a clock, a signal or send, a file's metadata), does not bound its own wait (`:application.which_applications/0`), and, for a closure, runs nothing that can wait; and the site is not reached by `init/1` on its own stack. A peer that stays connected while its callee never answers holds the calling process forever; a peer that goes away is noticed only after net_ticktime, about a minute by default.

**Assumptions and limits.**
- A remote function named by module and function is judged only by the vetted lists: the peer runs whatever it has loaded under that name. A closure is judged by its own body and its module's functions, since it runs only where the same module version is loaded.
- Only a literal `:infinity` one parameter away is followed; one forwarded through a further wrapper is missed.
- A remote target the site does not name (an apply) is reported.
- An rpc `init/1` reaches on its own stack is startup's "Distributed operation in init/1"; a helper shared by `init/1` and a handler is then reported only there.

**Fixtures.** Positive: `RpcCaller` (`call_no_timeout`), `RpcCollectors` (`block/1`, `collect/1`, `await/1`), `RpcTimeoutParam` (`remote/5`, `caller`), `RpcQuickTargets` (`lookup/2`, `scan/2`), `RpcSelfBounded` (`apps_within/2`), `RpcClosures` with `RpcClosures.Directory` (`await/1`, `handed/2`, `named/2`, `other_module/2`, `ping_forever/2`), `RpcViaHelperCallback`, `RpcViaHelperInInit` (`fetch_later/1`), all in test/fixtures/distributed_fixture.ex. Quiet: `RpcCaller`'s `call_with_timeout`, the other functions of `RpcQuickTargets`, `RpcSelfBounded` and `RpcClosures`, and the init paths of `RpcInInit` and `RpcViaHelperInInit`. Asserted in test/analyses/blocking_rpc_test.exs.

**Corpus.** Present-only: `cachex:router-rpc-without-timeout` (whitfin/cachex, 44ac7e4, `Cachex.Router`).

**Precision.** Not sampled. The 2026-07-17 corpus audit took the predecessor distributed analysis from 21 findings to 5 across its rules (maintainer notes). Later fixes removed named false positives: horde's `Process.alive?`, nerves_hub's `:ets.tab2list` and phoenix_live_dashboard's `:code.is_loaded` (d93dd63), Livebook's `:ets.delete` (f39733e), Swarm's `which_applications/0` (ba02d71) and Req's closure over `File.stat!` (e7995c5).

### RPC inside a GenServer callback

`unbounded_wait` · kind=`rpc_in_callback`
· titles: "RPC inside a GenServer callback" (`:warning`)

**Property.** Some GenServer `handle_call`, `handle_cast`, `handle_info` or `handle_continue` function itself contains a remote call site, whatever its timeout or target. The server is blocked for the network round trip: every queued caller waits on it, and a peer outage stalls the whole server.

**Assumptions and limits.**
- Direct only: an rpc in a helper the callback calls is not reported here (its site is still "RPC without a bounded timeout" when untimed). The transitive form reported through guarded dispatchers whose clauses route locally, and was removed (c9706c4).
- GenServer only; no exemption for a finite timeout or a target that answers at once.
- The finding anchors at the callback, not at the rpc.

**Fixtures.** Positive: `RpcInCallback` (test/fixtures/distributed_fixture.ex). Quiet: `RpcViaHelperCallback`. Asserted in test/analyses/blocking_rpc_test.exs.

**Corpus.** None.

**Precision.** All 13 corpus findings of the transitive predecessor were false, and that form was removed (c9706c4). The direct form is not measured.

### Socket call with no timeout inside a callback

`unbounded_wait` · kind=`socket`
· titles: "Socket call with no timeout inside a callback" (`:warning`)

**Property.** A socket call that waits with no deadline of its own runs on the stack of an OTP behaviour's callback other than `init/1` (`otp_callback`: a GenServer's, gen_statem's or GenStage's handler, a terminate, a LiveView's or Channel's callback), in the callback or in anything it calls in the same process (`SameProcessReach`: not in what a spawn, task or agent runs). The calls: `:gen_tcp.recv/2`, `:ssl.recv/2`, `:ssl.connect/2` (an upgrade) and `:ssl.connect/3` as `connect(host, port, options)`, `:ssl.handshake/1` and `:ssl.handshake/2` with options, which wait with `:infinity`; any timed form given `:infinity`, literally or through a timeout parameter a caller fills with `:infinity` through any chain of parameters; and `:gen_tcp.connect/3`, which waits until the operating system gives up on the connect (minutes on Linux). `detail` is the server whose callback runs it. While it waits the process answers nothing: its callers wait out their own timeouts, a gen_statem's timeouts cannot fire, and a peer that stops answering (a black-holed host, a client stalled mid-handshake) holds the process for as long as it likes.

**Assumptions and limits.**
- A recv `init/1` reaches on its own stack is startup's "init/1 waits on a socket with no timeout", reported once. A connect or a handshake `init/1` reaches is judged here when another callback reaches it too: startup asks of a connect only whether it can be retried.
- `:ssl.connect/3`'s two forms are told apart by a literal list or timeout in the call; when neither argument is a literal the call is not judged (quiet).
- `:gen_tcp.accept/1` and `:ssl.transport_accept/1` are not judged: an acceptor waiting for a client is doing its job.
- A process that is not an OTP behaviour's (a reader loop a spawn runs) is made to wait, and is not judged.
- Any callback counts, not only the clause a request enters (L9 gap, as for the call-chain rules).
- `:gen_tcp.send/2`, whose `send_timeout` defaults to `:infinity`, is not read.
- One finding per function, API and server, anchored at the call.

**Fixtures.** Positive: `Sockets.RecvInCallback` (recv/2 in handle_info/2), `Sockets.ReconnectsInCall` (kafka_ex's shape: connect/3 two calls below handle_call/3), `Sockets.HandshakeInState` (supavisor's shape: `:ssl.handshake/2` with options in handle_event/4), `Sockets.InfinityThroughHelper` (recv/3 whose timeout a caller passes as `:infinity`) (test/fixtures/socket_fixture.ex). Quiet: `Sockets.RecvBounded`, `Sockets.ReconnectsBounded`, `Sockets.HandshakeBounded`, `Sockets.RecvInTask`, `Sockets.RecvInInit` (startup's) (same file). Asserted in test/analyses/blocking_socket_test.exs; the extractor's rows in test/extractors/sockets_test.exs.

**Corpus.** Fix pairs: `kafka_ex#556` (kafkaex/kafka_ex, c6ba2a7 → e33abf0, `KafkaEx.Network.Socket`); `supavisor#1153` (supabase/supavisor, 369dc80 → 9d7df2d, `Supavisor.ClientHandler`); `redix#99` (whatyouhide/redix, 0d25d1f → 9a2eed6, `Redix.Utils`: the AUTH reply read with recv/2 from `handle_info(:connect)`); `supavisor#962` (b1a680a → 08c1423, `Supavisor.DbHandler`); `aprs.me@709780f` (aprsme/aprs.me, d8ea2b7 → 709780f, `Aprsme.AprsIsConnection`). Mined but not pairs: scout_apm 44e62f6 (its fix leaves two connects in the same module), thousand_island a2858bb (the handshake is reached through a transport module held in a variable, which the call graph does not follow).

**Precision.** Over 30 large Elixir trees and OTP's ssl, inets, ssh, kernel, mnesia and stdlib it made three rows, each a wait the rule describes: supavisor's `ClientHandler.Cancel.maybe_forward_cancel_to_db/2` (a connect/3 to the database host from the client handler, live at the fix), ssh's `ssh_connection:handle_msg/4` (a direct-tcpip channel open connects on the connection handler's stack) and `erl_epmd:open/1` (a connect/3 to the local epmd, which in practice refuses at once).

### Retrying :global lock

`unbounded_wait` · kind=`global`
· titles: "Cluster-wide :global synchronization" (`:info`); "Local :global lock without a retry bound" (`:info`)

**Property.** Some `:global.set_lock` or `:global.trans` call site retries while the lock is held: its retries are `:infinity` (the default) or a positive count, and the site is not reached by `init/1` on its own stack (`global_path`). `nodes` says whose agreement the lock waits on: `cluster` (a list of the connected nodes, or none, which means every known node) and `unknown` (a list the bytecode does not show) take the first title, `local` (`[node()]`) the second. Over the cluster every caller shares one distributed lock and partition recovery stalls them all; over the local node the caller waits for as long as another local process holds the lock.

**Assumptions and limits.**
- A retry count the bytecode does not show is not reported, where startup assumes it is `:infinity`.
- A positive count is reported though `set_lock/3` gives up after that many backoff sleeps; the local title then says "without a retry bound" of a bounded lock.
- A literal list of node names is `unknown`: the bytecode cannot say whether one of them is this node.
- A lock in a task or agent `init/1` starts, or in a fun it registers or keeps, is this finding rather than startup's.

**Fixtures.** Positive: `GlobalLockModule` (`lock_default`, `lock_infinity`; test/fixtures/distributed_fixture.ex); `GlobalNodes.Shapes` (`cluster`, `default`, `local`, `arg`; test/fixtures/global_nodes_fixture.ex); `InitLock.TelemetryHandler`, `TelemetryClosure`, `StoredCallback`, `SpecClosure`, `HelperStart`, `SpawnedLock`, `UnawaitedTask`, `SharedHelper` (test/fixtures/init_lock_fixture.ex); `InitRecv.SpawnsWork` (`connect/2`; test/fixtures/init_recv_fixture.ex). Quiet: `GlobalLockModule`'s `try_lock_once` and `del`; `GlobalLockInInit` (startup's). Asserted in test/analyses/blocking_rpc_test.exs, global_lock_nodes_test.exs, init_lock_test.exs and singleton_shapes_test.exs.

**Corpus.** None.

**Precision.** Not measured. Splitting local from cluster-wide locks moved no corpus title (acf3a28).

### Peer call that catches :noproc but not a stopping peer

`partial_noproc_catch`
· titles: "Peer call catches :noproc but not :shutdown" (`:warning`)

**Property.** A `try` guards a synchronous peer call (GenServer.call, `:gen_server.call`, `:gen_statem.call`, GenStateMachine.call) and its handlers catch the exit `:noproc` but have no clause for `:shutdown` or `:normal` and none that catches every exit. The catch says the peer may not exist; the peer stopping while the call is in flight is the same condition, but it arrives as `{:shutdown, _}` or `{:normal, _}`, and the exit crashes the caller.

**Assumptions and limits.**
- A clause counts as handling every atom it compares, so a clause that mentions `:shutdown` anywhere quiets the finding.
- Only calls the `try` guards directly are judged.
- Other exit reasons a peer can end a call with (`:killed`, `{:nodedown, _}`, a crash reason) are not asked about.

**Fixtures.** Positive: `CatchShapes.NoprocOnly` (test/fixtures/catch_shapes_fixture.ex). Quiet: `CatchShapes.NoprocAndShutdown`, `CatchShapes.AnyExit`; `Quiet.CatchesEveryExit` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/singleton_shapes_test.exs and quiet_shapes_test.exs.

**Corpus.** Fix pairs: `phoenix_live_view#4359` (phoenixframework/phoenix_live_view, 01b8517 → b100e10, `Phoenix.LiveView.Channel`).

**Precision.** Not measured beyond the pair.

## coupling

`coupling` owns a relationship between two supervised processes that a restart breaks: a supervisor restarts what it owns, and a sibling holding a pid, a monitor or a cached reply of the restarted child is not restarted with it. The strategy decides who survives whom, so most findings anchor at the tree definition, with the dependency's call as a labelled frame. What a sibling does to another during teardown is `shutdown`'s (`teardown_touches_sibling`), and a wait on a sibling during `init/1` is `startup`'s (`blocks_on_peer`).

### Coupled children under one_for_one

`sibling_dependency` · reason=`restart_isolation`, detail=`call` | `cast`
· titles: "Coupled children under one_for_one" (`:warning`; `:info` when basis is `doubted`); "One-way coupling under one_for_one" (`:info`)

**Property.** Some supervisor S has the literal strategy `:one_for_one`, and modules A and B lie in different child branches of S (`child_subtree`: a direct child and everything supervised below it). Some function of A depends on B's process (`stateful_module_dep`): it calls or casts to a process started with B's callbacks, whether the target is B's literal name, a literal handed to a forwarding wrapper, a pid process points-to follows to B's server, or a message tag only B's handlers take; or it reaches a function of B's module that does so; or, with nothing resolved, it reaches any function of B's module while some function of B makes a call or cast (column `basis` = `inferred`). A must not depend on B only through processes A started for itself (`private_module_dep`), and no link may join the two modules' processes. `detail` is `call` when some depending function waits on a reply along some path, `cast` when every path is one-way. When B crashes and S restarts it alone, A keeps running with whatever pid, monitor or reply of the old B it holds: calls to the old pid exit with `:noproc` and casts to it vanish.

**Assumptions and limits.**
- The tree is what the supervision extractor reads: literal child lists, specs built by helpers up to three calls deep and by comprehensions; a child list built wholly at runtime has no children (`coverage.coverage_supervisor_no_children` reports it). The strategy must be a literal.
- The call graph is complete except for dynamic calls. A target registered through `{:via, ...}` is followed only by process points-to or a unique message tag.
- The dependency is module-level and value-insensitive: a guarded dispatcher whose other clause calls B couples A to B. The `inferred` basis is the July 2026 false-positive class (reaching a pure function of a module that calls a server elsewhere); it is reported at full severity unless the `prior_talks_to_process` prior (off by default) puts B's API at 0.3 or below, which marks the row `doubted` and steps it down. An inferred row with no path that waits is graded `cast` and its prose says A "sends casts" to B although A sends nothing (`FacadeCaller` in the fixture below).
- The rule does not ask whether A holds anything across the restart: a caller that names B by its registered name on every call is reported too.
- Any link excludes the pair, including a link from a caller that traps exits, which the link does not restart.
- Only `:one_for_one` is judged. Under `:rest_for_one` an earlier child that depends on a later one survives the later one's restart with the same stale state, and is not reported.
- A dependency that is also `restart_policy` or `cached_pid` is reported under each reason, stacked at the same anchor for the first two.

**Fixtures.** Positive: hand-authored fact sets in `test/analyses/coupling_test.exs` (a sync call, a cast-only dependency, an Erlang-spelled `:gen_statem.call` anchor, the inferred and doubted bases) and in `test/analyses/coupling_supervision_test.exs` (a call through a pid, anchored at that call); `DeadlockOrderSupervisor` with `SyncInitServer` and `WorkerA` (`test/fixtures/sync_init_fixture.ex`, `test/fixtures/supervision_fixture.ex`), asserted in `test/findings_test.exs`; `PrivateConn.Reporter` depending on `PrivateConn.Cache` (`test/fixtures/private_conn_fixture.ex`), asserted in `test/analyses/private_instance_test.exs`; `FacadeSupervisor`, `FacadeCaller`, `FacadeHelper` (`test/fixtures/coupling_facade_fixture.ex`), the inferred one-way row with and without a doubting prior, asserted in `test/priors/priors_test.exs`. Quiet: `Argus.CouplingTest.LinkA` and `LinkB` (inline source in `test/analyses/coupling_test.exs`, linked through a whereis pid); `PrivateConn.Pool` and its own `PrivateConn.Conn` (`test/analyses/private_instance_test.exs`); the linked hand-authored fact set in `test/analyses/coupling_test.exs`.

**Corpus.** Fix pairs: `jackalope@8b7415f` (smartrent/jackalope, 35b0670 → 8b7415f, Hare.Application). Present-only: None.

**Precision.** On the July 2026 audit of 15 OTP libraries the rule (then `one_for_one_coupling`) left three rows, Oban's Sonar, Midwife and Stager, all judged true positives (maintainer notes, 2026-07-17; CHANGELOG 0.5.0 "Fixed (precision — 15-project OTP corpus audit)" lists "Oban's coupling" among the verified real findings). The 0.5.1 survey of 24 Hex packages graded tzdata's `ReleaseUpdater → EtsHolder` and sentry's `Scheduler → ClientReport.Sender` as cast-only couplings, now `:info` (d22e5df). The `inferred`/`doubted` basis exists because the module-level clause was the audit's false-positive class (2d5b41c). Merging the three coupling relations left the corpus tally and a 14-tree diff unchanged (4f92fcf); the private-instance and cached-pid changes left the corpus, realtime, logflare, hexpm and OTP unchanged (fbab8ff, 120dfc6). No sampled precision figure beyond these.

### Permanent child depends on a sibling that may not come back

`sibling_dependency` · reason=`restart_policy`, detail=`transient` | `temporary`
· titles: "Permanent child depends on a #{restart} sibling" (`:warning`; `:info` when basis is `doubted`), rendered "Permanent child depends on a transient sibling" and "Permanent child depends on a temporary sibling"

**Property.** Some supervisor S, with any strategy, lists a child P whose restart is `:permanent` and a child Q whose restart is `:transient` or `:temporary`, and some function of P depends on Q's process in the sense of `stateful_module_dep` (as for the class above), not only through processes P started for itself. A transient Q that exits normally is never restarted, and a temporary Q is never restarted at all, so P keeps running against a process that no longer exists: every call exits with `:noproc`.

**Assumptions and limits.**
- The restart column of a shorthand spec (`{Mod, args}` or a bare module) is taken as `:permanent`, the default, even when the module's own `child_spec/1` declares otherwise (`use GenServer, restart: :temporary`): a temporary child written in shorthand is read as permanent (a false positive on the P side) and a transient or temporary sibling written in shorthand is missed. The extractor records what `child_spec/1` declares, but this rule does not read it.
- The dependency is the same module-level, value-insensitive `stateful_module_dep` as `restart_isolation`, with the same `inferred`/`doubted` basis.
- The rule does not ask whether P tolerates Q's absence (monitors it, or re-resolves it on every use).
- The related frame points at the witness function, not at the call instruction.

**Fixtures.** Positive: hand-authored fact sets in `test/analyses/coupling_supervision_test.exs` (a transient sibling, a temporary sibling). Quiet: the same facts with a permanent sibling, in the same file. No compiled fixture.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured. The temporary case was added in f8d1b06 (it had been missed entirely).

### Sibling pid cached in init/1

`sibling_dependency` · reason=`cached_pid`
· titles: "Sibling pid cached in init/1 under one_for_one" (`:info`)

**Property.** A GenServer module M is a direct child of a `:one_for_one` supervisor S; M's `init/1` itself looks up a literal name N with `Process.whereis/1`, where N is another direct child of S, by module or by the name its child spec gives it; and some request handler of M (`handler_function`) calls, casts or sends to the process registered under N through something other than the name, as process points-to follows it (`process_call`, `named_pid`). Where N names no process points-to knows, a handler's call or cast to a pid the extractor could not name stands in. When N's process restarts alone, M keeps the dead pid: every call exits with `:noproc` and every message is lost.

**Assumptions and limits.**
- The lookup must be in `init/1`'s own body: a lookup in a helper `init/1` calls, or in `handle_continue/2`, is missed.
- Only GenServer handlers are asked; a gen_statem that caches a sibling's pid is missed.
- `Registry.lookup/2` and `{:via, ...}` names are not read as the lookup.
- The rule does not exclude a temporary N (never restarted), which the rule's comment mentions.
- The same pair can also fire `restart_isolation`, at the tree definition and at `:warning`, while this better-evidenced row is `:info`. The finding anchors at `init/1`'s head, not at the lookup, and names no handler frame.
- `Hypothesized.CachedPid.Relay` pins the suppressed shape: a handler that calls whatever pid its caller hands it.

**Fixtures.** Positive: `Hypothesized.CachedPid.Client` under `CachedPid.Sup` (`test/fixtures/hypothesized_shapes_fixture.ex`). Quiet: `CachedPid.OrderedClient` under `CachedPid.RestSup` (`:rest_for_one`), `CachedPid.Relay` under `CachedPid.RelaySup` (same file). Asserted in `test/analyses/hypothesized_shapes_test.exs`.

**Corpus.** Fix pairs: None (the shape is k8s 99c05d6, cited in the rule; not in `test/corpus/pairs.exs`). Present-only: None.

**Precision.** Not measured. Requiring the handler to use the cached pid (120dfc6) left the corpus, realtime, logflare, hexpm and OTP unchanged.

### rest_for_one restarts the owner but not the processes it started

`rest_for_one_orphaned_children` · confidence=`named` | `inferred`
· titles: "rest_for_one restarts the owner but not the processes it started" (`:warning` when `named`, `:info` when `inferred`)

**Property.** Some supervisor S has the literal strategy `:rest_for_one`, with a direct child H at position h and a child branch at a later position o containing module O. Some function of O starts processes inside H: a `start_child`, `async` or `async_nolink` call (`sup_management_call`, `child_creating_op`) whose supervisor argument is H's child-spec name (`named`), or is a runtime value while H is the only direct child of S before position o whose module is the API called, such as the one `Task.Supervisor` (`inferred`). When O's process crashes, S restarts it and every later child but not H, so the processes the old owner started keep running inside H while the new owner starts its own: duplicated work (Oban's jobs ran twice), or a stale process holding a resource the replacement expects to own.

**Assumptions and limits.**
- Any function of O counts, including a client function that runs in its caller's process rather than O's.
- `Task.Supervisor.async` is counted, but that task is linked to its caller and dies with the owner: that shape is a likely false positive, not pinned by a fixture.
- The `inferred` holder stands in for points-to, which does not follow a supervisor management call's supervisor argument. A custom `use DynamicSupervisor` module as H has its own module name, so it is never the "one earlier sibling of the API's kind".
- Erlang's `:supervisor.start_child/2` is not a management call the extractor records.

**Fixtures.** Positive: `NamedQueueSupervisor` with `NamedJobProducer` (`named`), `QueueSupervisor` with `JobProducer` (`inferred`) (`test/fixtures/supervision_fixture.ex`). Quiet: `AllForOneQueueSupervisor` (`:one_for_all`), `ForemanLastSupervisor` (the holder starts after the owner) (same file). Asserted in `test/analyses/coupling_supervision_test.exs`.

**Corpus.** Fix pairs: `oban#532` (oban-bg/oban, 5c64333 → f5afde4, `Oban.Queue.Producer`, the `inferred` holder): the bug the rule was written from, fixed with `:one_for_all`. Present-only: None.

**Precision.** Not measured.

### Two restart authorities for the same child

`dual_restart_authority`
· titles: "Two restart authorities for the same child" (`:warning`)

**Property.** A module M has a function F that, through calls within M, reaches both a `DynamicSupervisor.start_child/2` of a known child module C under supervisor S and a monitor of the pid that start returned (named so by the extractor, or followed back to the start by process points-to); some function of M whose clause heads match `{:DOWN, ...}` reaches, within M, a start of C under S again; and C's own `child_spec/1` does not declare `restart: :temporary`. M and the supervisor both restart C: a child that fails on a semantic error crash-loops under two authorities, exhausts the supervisor's restart intensity, and the escalation reaches the tree above (redix#334).

**Assumptions and limits.**
- Only `DynamicSupervisor.start_child/2` with a resolvable child module is a start; `Task.Supervisor` children and a static supervisor's `restart_child` are not.
- A `restart: :temporary` given at the call site (an inline map spec, or `Supervisor.child_spec/2` overrides) is not read, so that shape is reported although M is then the only authority.
- The `:DOWN` handler is the whole function: a `handle_info/2` whose `:DOWN` clause only forgets the child, while another clause starts one, is reported.
- F need not run in M's own process: a client function that starts and monitors in its caller's process counts.
- `Quiet.UnrelatedMonitorRestarter` pins the suppressed shape: the monitor is of another process than the one started (Oban.Queues).

**Fixtures.** Positive: `SupervisionShapes.DualManager` and `SupervisionShapes.StatemDualManager` (`test/fixtures/supervision_shapes_fixture.ex`), asserted in `test/analyses/coupling_supervision_test.exs`; `Argus.CouplingTest.MonOwner` (inline source in `test/analyses/coupling_test.exs`, the monitored pid followed through state). Quiet: `SupervisionShapes.TemporaryManager` (a `:temporary` child; `test/analyses/coupling_supervision_test.exs`); `Quiet.CleanupManager` and `Quiet.UnrelatedMonitorRestarter` (`test/fixtures/quiet_shapes_fixture.ex`), asserted in `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: `redix#334` (whatyouhide/redix, d3bab6e → e67e61a, Redix.Cluster.Manager). Present-only: None.

**Precision.** Not measured. Requiring the monitor to be of the started child removed the Oban.Queues false positive (06c3f57).

## mailbox

`mailbox` owns a message that arrives and that nothing takes, or takes wrongly, and a reply a caller waits for that never comes. More than its owner writes a process's mailbox: a task's reply, a monitor's `:DOWN`, a timer that fired before it was cancelled, a subscription, the module's own client API. Every finding is such a message and the clause that is missing for it, or a promise of a reply that cannot be kept. Some neighbouring defects belong to other concerns. A trapped exit with no `:EXIT` clause, and a process that traps exits with no handle_info/2 at all, are `shutdown`'s (`unhandled_exit_signal`). So is the `:DOWN` a server causes by killing a child it monitors (`kills_monitored_child`). A receive that can hang a callback, and a synchronous call a process makes to itself, are `blocking`'s. A gen_statem's state graph is `state_machine`'s.

### A monitoring or trapping server with no handle_info/2 catch-all

`partial_handler` · source=`runtime`
· titles: "handle_info/2 has no catch-all in a process the runtime writes to" (`:info`)

**Property.** A module that behaves as GenServer or GenStage defines handle_info/2 with no clause that accepts every message. The process has also asked the runtime for messages whose timing it does not control. Either some function of the module calls `Process.flag(:trap_exit, true)`, or some function on the server's own stack (`server_side`: a callback, or what the callbacks reach inside the module) takes a monitor. Once handle_info/2 is defined, a message that no clause matches is a FunctionClauseError instead of GenServer's log-and-continue. Examples are a late `{:DOWN, ...}` after a demonitor without `:flush`, and an `{:EXIT, ...}` from a port a callback opened. The server crashes on the first such message.

**Assumptions and limits.**
- A catch-all is read from the bytecode: it is a clause whose failure never reaches the function's `func_info`. A guarded catch-all (`msg when is_tuple(msg)`) is not total, so a module with only a guarded catch-all is reported.
- A trap_exit call counts wherever it is in the module, including in a client function that runs in its caller. A monitor counts only on the server's own stack: `def await_up, do: Process.monitor(...)` is the caller's monitor (pinned by `ClientMonitorsServer`).
- The rule steps aside for two more specific findings on the same module. The first is `shutdown`'s `unhandled_exit_signal` "no_exit_clause", when the process traps exits and no clause compares `:EXIT` (pinned by `TrapsWithoutExitClause`). The step-aside is computed here, so a run of `mailbox` without `shutdown` reports neither. The second is `unhandled_info` "crash", when a message the module is sent names the missing clause.
- A handle_info/2 that another module's macro wrote in full is still judged here, although the late-message source skips it.
- The finding does not name a message. It is one finding per module and handler.

**Fixtures.** Positive: `MonitorsWithoutCatchall` (`test/fixtures/error_handling_fixture.ex`). Quiet: `MonitorsWithCatchall`, `ClientMonitorsServer`, `TrapsWithoutExitClause` (same file). Asserted in `test/analyses/mailbox_info_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured. 24c1ba3 stopped counting a monitor in a client function, but gives no count.

### A server with a late-message source and no handle_info/2 catch-all

`partial_handler` · source=`late_message`
· titles: "handle_info/2 has no catch-all" (`:info`)

**Property.** The module is a GenServer or GenStage, not a gen_statem. Its handle_info/2 is partial (`partial_handle_info`), and the module wrote at least one clause of it. Some entry of the process (`process_entry`: init/1, a callback, terminate/2) reaches a mailbox writer in the server's own process. The reach does not pass through a logging or telemetry call (`side_call`). A mailbox writer is a call after which something other than a peer's request can land in the mailbox:
- a Task.async or Task.Supervisor.async reply, or a Task.Supervisor.async_nolink task;
- a timer, unless the process arms it for itself with a message whose tag its own handle_info/2 compares;
- a subscription (Phoenix.PubSub, Registry, `:pg`, a `:gen_event` handler);
- a message the function sends to itself;
- a call through a fun or a module the program does not show. That covers a fun read from the state, a message or a call's result, a callback calling through its own parameter, and a parameter that some caller fills from such a place.

Such a message is a FunctionClauseError the first time it arrives, and a restart loop if a restart sends it again.

**Assumptions and limits.**
- These are not sources:
  - A timed GenServer.call. Since OTP 24, gen waits on an alias and drops a late reply (`LateMessage.TimedCall`).
  - A logging or telemetry call (`LateMessage.LogsOnTick`).
  - A closure the function builds and hands to a helper that calls it (`LateMessage.HandsClosure`).
  - An `:erlang.start_timer` whose `:timeout` the handler takes (`LateMessage.StartTimer`).
  - A self-armed timer with a handled tag (`HandledTimerServer`, `TaggedTimerServer`).
  - A timer armed by a task the server starts (`TaskTimerPartialInfoServer`).
- The rule does not judge a handle_info/2 whose every clause another module's macro wrote (`LateMessage.Warmer`, the Cachex.Warmer shape). That handle_info/2 is the library's protocol, and the finding would point at the `use` line.
- It still reports these shapes, which may be false positives:
  - A timer armed for another process. Its message lands elsewhere, but it still counts as a source for the arming server.
  - A task collected where it starts. Task.await or Task.yield plus Task.shutdown leaves no late message, but the task still counts.
  - A source that only terminate/2 reaches.
  - A mailbox writer in a dispatcher clause that no callback selects, because reach is not clause-aware.
- An async_nolink task that the function does not collect is both a source here and the next class. As the rules are written, the same handle_info/2 gets both findings, even when it has clauses for both of the task's messages (`Hypothesized.NolinkBothClauses`).
- The rule steps aside for the runtime source, for `shutdown`'s missing-`:EXIT` finding and for `unhandled_info` "crash". The finding does not name the source it found.

**Fixtures.** Positive: `PartialInfoServer`, `PartialInfoStage`, `AppliesPartialInfoServer`, `SelfSendPartialInfoServer`, `InlineOrTaskPartialInfoServer` (`test/fixtures/error_handling_fixture.ex`); `LateMessage.RunsSentFun` (`test/fixtures/late_message_fixture.ex`). Quiet: `TotalInfoServer`, `QuietPartialInfoServer`, `HandledTimerServer`, `TaggedTimerServer`, `TaskTimerPartialInfoServer`, and `MonitorsWithoutCatchall`, which is reported as runtime instead (`test/fixtures/error_handling_fixture.ex`); `LateMessage.Warmer`, `LateMessage.HandsClosure`, `LateMessage.TimedCall`, `LateMessage.StartTimer`, `LateMessage.LogsOnTick` (`test/fixtures/late_message_fixture.ex`); `Quiet.TimerWithCatchAll` (`test/fixtures/quiet_shapes_fixture.ex`). Asserted in `test/analyses/mailbox_info_test.exs` and `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: `gen_stage#238` (elixir-lang/gen_stage, ee272d3 → ae0a6c6, GenStage.Streamer). Present-only: `commanded#332` (commanded/commanded, 9f45a30, Commanded.ProcessManagers.ProcessManagerInstance).

**Precision.** Before 92f6404, about 83% of this title's rows on real programs were noise. That commit stopped counting calls through funs whose code the program shows, logging and telemetry, timed gen calls and handlers a macro wrote. After it, logflare went from 22 rows to 9 and the Phoenix stack from 6 to 3, and both corpus instances still fire. Seven of logflare's rows were a macro-written handle_info (CHANGELOG 0.20.0-dev, "Process rules, read against real programs"). 022d1e7 and 794635d stopped counting self-armed timers that the handler takes, but give no count.

### An async_nolink task whose reply or :DOWN has no clause

`partial_handler` · source=`task_nolink`, missing=`reply` | `down`
· titles: "async_nolink task's messages have no handle_info clause" (`:warning`)

**Property.** A process module's entries reach a function in the module's own process. That function calls Task.Supervisor.async_nolink and does not collect the task (it calls no Task.await, yield or shutdown). The module's handle_info/2 is partial and lacks a clause for one of the two messages the task sends the starting process. The first is a `{ref, result}` clause headed by a reference (`missing` = `reply`); the second is any clause comparing `:DOWN` (`missing` = `down`). The first task to finish is a FunctionClauseError in the server.

**Assumptions and limits.**
- "Collected" means a collector call anywhere in the starting function. It need not be on every path or for this task.
- An async_nolink inside a task the server starts writes to that task's mailbox, and is not counted.
- The module need not be a GenServer: any process module with a partial handle_info/2 is judged.
- `:DOWN` counts as handled when it is compared anywhere in handle_info/2's body. This over-approximates, which keeps the rule quiet.
- There is one finding per module and starting function. When both clauses are missing, the two rows merge. The finding's prose then names only the `:DOWN`, although its help names both clauses.
- The same handle_info/2 also gets the late-message note.

**Fixtures.** Positive: `Hypothesized.NolinkPartialInfo` (`test/fixtures/hypothesized_shapes_fixture.ex`). Quiet: `Hypothesized.NolinkBothClauses`, `Hypothesized.NolinkCollected` (same file). Asserted in `test/analyses/hypothesized_shapes_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None. CHANGELOG 0.14.0 draws the rule from archethic-node#1306, sentry-elixir#172 and Engram#1552, but none of them is a pair.

**Precision.** Not measured. The maintainer notes record that 0.14.0's six new rules, this one among them, added four findings over the 14-tree diff, all confirmed real. It does not say how many were this rule's.

### A gen_statem timeout no clause handles

`partial_handler` · source=`statem_timeout`, missing=`event_timeout` | `generic_timeout` | `state_timeout`
· titles: "Timeout armed but never handled" (`:error`)

**Property.** A gen_statem state function (or handle_event/4) returns an action that arms a timeout, and no callback of the module either accepts every event or has a clause for the event type the timeout delivers. There are three kinds:
- `{:timeout, ms, content}` delivers event type `:timeout`;
- `{{:timeout, name}, ms, content}` delivers event type `{:timeout, name}`;
- `{:state_timeout, ms, content}` delivers event type `:state_timeout`.

When the timer fires, the event raises FunctionClauseError or falls through to a clause written for something else. The common shape handles it as `(:info, :timeout, ...)`. The work the timeout was meant to trigger never runs.

**Assumptions and limits.**
- The question is asked per module, not per state: a `:state_timeout` clause in one state counts for a timeout armed in another.
- A timeout counts as armed only when the action flows into the callback's return. A `{:timeout, ref, payload}` tuple built to send is not an armed timeout (pinned by `Quiet.GenericTimeoutStatem`).
- The rule reads generic-timeout heads compiled as a tuple test plus an element test. This is the Postgrex.ReplicationConnection and Finch.HTTP2.Pool shape (`GenericTimeoutHandledStatem`).
- Event-type clauses are over-approximated: any comparison of the first argument counts. The rule therefore errs quiet.
- There is one finding per module and timeout kind. No positive fixture arms a `:state_timeout`.

**Fixtures.** Positive: `TimeoutMismatchStatem` (`event_timeout`), `GenericTimeoutMismatchStatem` (`generic_timeout`) (`test/fixtures/gen_statem_fixture.ex`). Quiet: `TimeoutHandledStatem`, `TimeoutStatem`, `GenericTimeoutHandledStatem` (same file); `Quiet.GenericTimeoutStatem` (`test/fixtures/quiet_shapes_fixture.ex`). Asserted in `test/analyses/mailbox_statem_test.exs` and `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: `postgrex@83bac66` (elixir-ecto/postgrex, 0b73cfa → 83bac66, `Postgrex.SimpleConnection`: the `{:timeout, ms, _}` action taken as `(:info, :timeout, ...)`). Present-only: None.

**Precision.** Not measured. Two false-positive shapes were removed while the rule lived in `gen_statem`. First, DBConnection.Connection and Finch.HTTP2.Pool were reported at error severity for timeouts they handle (CHANGELOG 0.13.2, Fixed). Second, 2b77fef made the rule read unfused generic-timeout heads, which would otherwise have reported Postgrex.ReplicationConnection and Finch.HTTP2.Pool.

### A gen_statem state without the :info catch-all its siblings have

`partial_handler` · source=`statem_info`
· titles: "State #{state} has no :info catch-all" (`:warning`)

**Property.** A gen_statem runs in `state_functions` mode. One of its state functions accepts neither every `:info` event nor every event, while some other state function of the same machine has an `:info` catch-all. Suppose a message arrives while the machine is in that state and matches none of its clauses: a late `:DOWN`, a reply to a call that timed out, a library's notification. The message is a FunctionClauseError. It takes the machine down, and under `:one_for_all` its whole tree.

**Assumptions and limits.**
- The sibling asymmetry is the precision gate. A machine none of whose states has the catch-all is not reported, because it is read as a decision.
- A clause that takes any `:info` content is a catch-all whatever it asks of the data (`ready(:info, msg, %{events: e})`), as a GenServer's is whatever it asks of the state (391ecc6; `DataPatternInfoStatem`).
- The rule does not judge `handle_event_function` mode.
- It steps aside for a state function that `unhandled_info` "state_crash" names for a message the program sends.
- There is one finding per state.

**Fixtures.** Positive: `AsymmetricInfoStatem` (`test/fixtures/gen_statem_fixture.ex`). Quiet: `SymmetricInfoStatem` (same file). Asserted in `test/analyses/mailbox_statem_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None. 5976d53 draws the shape from Redix's Cluster.Manager, but it is not a pair.

**Precision.** Not measured.

### A message a server is sent with no handle_info/2 clause

`unhandled_info` · fallback=`crash`
· titles: "No handle_info/2 clause for a message the server is sent" (`:warning`)

**Property.** A message reaches a GenServer or GenStage process in one of three ways the program spells out:
- a send that process points-to follows to the server (`send_target`, `server_process`);
- a timer that a function run by the server's callbacks arms for the server itself;
- a monitor that such a function takes, whose `{:DOWN, …}` the runtime sends.

The message is a literal atom or a tuple with a literal atom tag. No clause of the server's handle_info/2 compares that tag, and none takes the message by shape alone (`msg when is_atom(msg)`, `{ref, result} when is_reference(ref)`). No receive in the server's own code could take it, and handle_info/2 has no catch-all. Every time the message arrives it is a FunctionClauseError that takes the server down.

**Assumptions and limits.**
- Only literal messages are judged. A message computed whole, a binary or a number is not (`UnhandledInfo.Unjudged`). A tuple the site builds around a literal tag is judged by its tag (`{:backoff, …}` in `UnhandledInfo.Retry`).
- Clause tags are over-approximated: an atom compared anywhere in handle_info/2's body counts. A module that mentions the tag anywhere in handle_info/2 is therefore quiet.
- A monitor is not judged when the function that takes it runs any receive, or demonitors with `:flush` (`WaitsForDown`, `Flushes`). "The function" includes what it calls in its own process, and the receive need not be for this monitor. A monitor in a client function is the caller's (`Client`).
- Receives in anonymous functions are read since e24fe22 (`TerminateWaits`: Broadway's Topology.Terminator waits for each `:DOWN` in a comprehension).
- A timer counts only where the server's callbacks reach it in the server's own process. A timer a task arms is the task's.
- The sender need not be in the server's module (`Pinger` sends to `PingServer`). The finding anchors at the send, timer or monitor, and relates the handle_info/2. There is one finding per site and server.
- A handle_info/2 that another module's macro wrote is judged like the module's own.
- This finding makes the runtime and late-message catch-all notes step aside for the module.

**Fixtures.** Positive: `UnhandledInfo.MemoryCheck`, `UnhandledInfo.Reconnect`, `UnhandledInfo.Pinger` (to `UnhandledInfo.PingServer`), `UnhandledInfo.Retry` (two rows) (`test/fixtures/unhandled_info_fixture.ex`). Quiet: `UnhandledInfo.Handled`, `Delegates`, `OpenClause`, `WaitsForDown`, `Flushes`, `Client`, `WarmUp`, `Unjudged`, `TerminateWaits` (same file). Asserted in `test/analyses/mailbox_unhandled_info_test.exs`.

**Corpus.** Fix pairs: `sequin@6693949` (sequinstream/sequin, 94fbd52 → 6693949, Sequin.DatabasesRuntime.SlotMessageStore); `astarte@f3edb85` (astarte-platform/astarte, subdir `apps/astarte_data_updater_plant`, 6539a98 → f3edb85, Astarte.DataUpdaterPlant.AMQPEventsProducer). Present-only: None.

**Precision.** The rule was added in 1d059ca. At that point its only rows over the corpus, realtime, logflare, hexpm and OTP's kernel, stdlib, mnesia, ssl, inets and ssh were those of its three corpus pairs (CHANGELOG 0.20.0-dev "mailbox"). 794635d later removed nerves_hub's CLISessionCache: it arms a literal-tuple timer that its tuple clause takes. No sampled rate.

### A message a server drops in a catch-all or in GenServer's default handler

`unhandled_info` · fallback=`catch_all` | `default`
· titles: "A message the server is sent reaches only its catch-all handle_info/2" (`:warning` when source is `monitor`, `:info` otherwise); "A message is sent to a server with no handle_info/2 of its own" (`:warning`)

**Property.** The message is the same as in the class above: a literal message that a send, a self-armed timer or a monitor delivers to a GenServer or GenStage. No clause names it. What takes it instead does nothing with it but log it or ignore it. With `catch_all`, that is a catch-all clause every path of which hands the message only to Logger, `:logger`, IO or `inspect/2`. With `default`, the module defines no handle_info/2 of its own, and the one `use GenServer` injects logs the message as an error. The message is dropped: the timer's work never runs, or the cleanup a monitor was taken for never happens, and dead listeners pile up.

**Assumptions and limits.**
- A catch-all that hands the message on (to a helper, into the state, into its return) may take it there, and is not judged (`UnhandledInfo.Delegates`).
- A catch-all may be meant. A message the program sends is therefore info-grade, while a monitor's `:DOWN` that a catch-all drops is a warning.
- `default` means any handle_info/2 that some macro generated with a dropping body. The prose assumes the macro is GenServer's, so a library's injected handle_info/2 is described as GenServer's.
- The class shares the judging limits of the crash class: literal messages only, a monitor exempted by any receive or `:flush` in its function, and over-approximated tags.

**Fixtures.** Positive: `UnhandledInfo.Listeners` (monitor, `catch_all`), `UnhandledInfo.Repair` (timer, `catch_all`), `UnhandledInfo.Ticker` (send, `default`) (`test/fixtures/unhandled_info_fixture.ex`). Quiet: `UnhandledInfo.Delegates`, `TerminateWaits`, `Handled` (same file). Asserted in `test/analyses/mailbox_unhandled_info_test.exs`.

**Corpus.** Fix pairs: `oban@5518653` (oban-bg/oban, 9448f03 → 5518653, Oban.Notifiers.PG). Present-only: None. teslamate@91f6a8f has the timer shape, but its 2020 tree builds on no installed toolchain (CHANGELOG 0.20.0-dev "mailbox").

**Precision.** When the rule was added (1d059ca), its only row over the programs listed for the crash class was the oban pair's. e24fe22 removed Broadway's Topology.Terminator, whose `:DOWN` waits sit in a comprehension. No sampled rate.

### A message a gen_statem is sent that no state takes

`unhandled_info` · fallback=`state_crash`
· titles: "No clause for a message a gen_statem is sent" (`:warning`)

**Property.** A literal message reaches a gen_statem by a send that points-to follows, a timer its own code arms for itself, or a monitor it takes. No callback of the machine compares the message's tag in an `:info` clause, or takes `:info` content of its shape. No receive in the machine's code could take it. Some state function (or handle_event/4) has neither an `:info` catch-all nor a catch-all for every event. If the message arrives while the machine is in that state, it is a FunctionClauseError that takes the machine down.

**Assumptions and limits.**
- The rule judges a message only when no state takes it. A message some state takes may be one the program sends only while the machine is in that state (`UnhandledInfo.PollerTakes`).
- An `:info` clause that takes any content is a catch-all whatever it asks of the data or, in handle_event/4, of the state (391ecc6). For handle_event/4 that is quieter than the truth: a catch-all for some states counts for the machine (`OneStateInfoStatem`; Postgrex's ReplicationConnection names its one state).
- It does not judge whether a machine's catch-all drops the content.
- The finding names the state function that crashes. There is one finding per site.
- It makes the `statem_info` finding step aside for that state.

**Fixtures.** Positive: `UnhandledInfo.Poller` (`test/fixtures/unhandled_info_fixture.ex`). Quiet: `UnhandledInfo.PollerTakes` (same file). Asserted in `test/analyses/mailbox_unhandled_info_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured.

### The close of a socket the server holds, with no clause for it

`unhandled_info` · source=`socket`, fallback=`crash` | `catch_all` | `default` | `state_crash`
· titles: "No handle_info/2 clause for the close of the server's socket" (`:warning`); "The close of the server's socket reaches only its catch-all handle_info/2" (`:warning`); "The close of the server's socket reaches only GenServer's default handle_info/2" (`:warning`); "No clause for the close of a gen_statem's socket" (`:warning`)

**Property.** A function that a GenServer's, GenStage's or gen_statem's callbacks run in the server's own process (`runs_in_server`, over `SameProcessReach`) makes a TCP or TLS socket active. It connects one (`:gen_tcp.connect/3,4`, `:ssl.connect/2,3,4`) whose literal options leave `:active` at its default, which is true, or set it to true, `:once` or a count; it sets one of those modes with `:inet.setopts/2`, `:ssl.setopts/2`, `:ranch_tcp.setopts/2`, `:ranch_ssl.setopts/2` or a transport module's `setopts/2` called through a variable; or it hands such a literal option list to a function of the program whose options parameter reaches one of those calls, through any chain of parameters (kafka_ex's `Socket.setopts(s, [:binary, {:packet, 4}, {:active, true}])`). The server controls the socket, so the socket's end arrives there as a message whenever the connection goes: `{:tcp_closed, socket}` for TCP, `{:ssl_closed, socket}` for TLS. Which close is meant follows the socket: an `:ssl` call means TLS, `:inet.setopts/2` means TCP when the server's process connects TCP sockets, and a transport in a variable means whichever kinds the process connects. No clause of the server's handle_info/2 (or of the machine's callbacks) compares the close's tag or takes it by shape, and no receive in the server's own code could take it. With no catch-all the first disconnect is a FunctionClauseError that takes the server down; with a catch-all that only logs or ignores it, or GenServer's default handler, the server goes on holding a socket that is gone and answers its callers with timeouts or errors until something else restarts it.

**Assumptions and limits.**
- Soundness rests on the extractor's literal reading (`socket_active`, `socket_opts_arg`): options built at runtime say nothing, so a socket made active by them is missed, never assumed active. An accepted socket takes its mode from the listening socket and is not read.
- A function that also hands a socket to another process (`controlling_process`) is not judged: the messages go to that process (`Sockets.HandsOff`).
- A catch-all that hands the message on (to a protocol module, into the state) may take the close, and is not judged (`Sockets.HandsTheRestOn`); so is a gen_statem `:info` clause that takes any content whatever it asks of the data or, in handle_event/4, the state (`Sockets.StatemHandsOn`, `Sockets.OneStateHandsOn`: Postgrex's ReplicationConnection).
- A clause that takes any tuple by shape (`{transport, socket, data}`) counts as taking the close, though a close is a two-element tuple (quiet).
- Only the close is asked about: `{:tcp_error, s, reason}` and `{:ssl_error, s, reason}` are not, nor a socket made active whose data nothing takes.
- A socket a library opens in the caller's process is not modelled: hackney's leaked `{:ssl_closed, _}` (hackney#464, the most common fix of this family in the mining) and Mint in active mode are backlog.
- A port's messages (`{port, {:exit_status, n}}`) are not modelled.
- The server must be one the program starts (`server_process`), as for the other sources: a protocol module Ranch or Thousand Island starts through `:gen_server.enter_loop` is not judged.
- One finding per server and handler, anchored at the handler, with the activation as a related frame ("the socket is made active here"). When a server misses both closes, the one reported is the lexicographically first.

**Fixtures.** Positive: `Sockets.ActiveTcp`, `Sockets.DefaultActive`, `Sockets.TlsTakesTcpClose` (the TLS close, where only the TCP one has a clause), `Sockets.Wrapped.Client` with `Sockets.Wrapped.Socket` (kafka_ex's wrapper; both closes), `Sockets.LogsTheRest` (`catch_all`), `Sockets.InetTcp`, `Sockets.ThroughTransport`, `Sockets.StatemTcp` (`state_crash`) (test/fixtures/socket_fixture.ex). Quiet, each beside the positive it differs from in one premise: `Sockets.ActiveTcpHandled`, `Sockets.PassiveTcp`, `Sockets.TlsTakesBoth`, `Sockets.Wrapped.HandledClient`, `Sockets.HandsTheRestOn`, `Sockets.HandsOff`, `Sockets.WaitsForIt`, `Sockets.InetUdp`, `Sockets.StatemHandsOn`, `Sockets.OneStateHandsOn` (same file). Asserted in test/analyses/mailbox_socket_test.exs; the extractor's rows in test/extractors/sockets_test.exs.

**Corpus.** Fix pairs: `exshome@c1e2a01` (exshome/exshome, f89ed6e → c1e2a01, `Exshome.MpvSocket`: a socket `:gen_tcp.connect/3` left active, with only a data clause; the fix adds the close clause and reconnects). Mined but not pairs: kafka_ex#381 (1113a82 → 4ffa488, `KafkaEx.New.Client`; the 2020 tree fails on its `snappy` dependency under OTP 28), sentinelix 611fa54 and mailroom 8879d22 and chromoid 0caf37b (do not build), cqerl#151, mongodb#170, mochiweb#59 and tsung#100 (rebar3 or pre-1.15 trees), grizzly efbfe22 (its catch-all hands the close to a transport's parser, which the rule does not follow).

**Precision.** Over 23 large Elixir trees (logflare, nerves_hub_web, plausible, sequin, realtime, hexpm, livebook, supavisor, postgrex, xandra, grizzly, klife, bandit, thousand_island and others) and OTP's ssl, inets, ssh, kernel and mnesia it first made one row, Postgrex's ReplicationConnection, false: its `:info` catch-all names its one state. The gen_statem catch-all reading (391ecc6) removed it, and over 30 trees and six OTP applications it makes none. No true positive in mature code; the class shows up as fixes (exshome's, and the mined instances above).

### A message a spawned process never receives

`unreceived_message`
· titles: "#{message} is sent to a process whose receive never takes it" (`:warning`)

**Property.** Process points-to follows a send (`send_target`) to a process started by a bare spawn. The message is a literal atom or a tuple with a literal tag. The process runs at least one receive, in the spawned function or in what that function calls in its own process (`ForwardSameProcessReach`). No clause of any of those receives names the message or matches anything. The process runs no call through a fun or an apply, no gen_server, gen_statem or gen_event `enter_loop`, and no hibernate that resumes elsewhere. The message is not dropped: it stays in the mailbox for the life of the process, every later receive scans past it, and the sender never learns it went nowhere.

**Assumptions and limits.**
- A receive clause whose pattern is not a literal atom (a tuple, a variable, a guard) reads as "takes anything". A loop that matches tuples is therefore never judged, whatever it is sent. On OTP's kernel, 35 of 71 literal sends to a spawned process met such a clause (cf5d8fb).
- The receives are all the ones the process runs, not the one running when the message arrives. A message taken in one phase and sent in another is quiet (`UnreceivedMessage.TwoPhase`).
- GenServer and gen_statem targets are `unhandled_info`'s (`UnreceivedMessage.Server`).
- The destination comes from points-to, which keeps pids held in different fields apart (`PidFlow.Relay` and `PidFlow.Subscriber`).
- There is one finding per send and spawned function.

**Fixtures.** Positive: `UnreceivedMessage.Shop` (to `UnreceivedMessage.Audit`), `UnreceivedMessage.Tagged`, `UnreceivedMessage.Helper`, `UnreceivedMessage.Closure` (`test/fixtures/unreceived_message_fixture.ex`). Quiet: `UnreceivedMessage.Cart`, `Taken`, `CatchAll`, `TwoPhase`, `EntersLoop`, `Variable`, `Server` (same file); `PidFlow.Relay`, `PidFlow.Subscriber` (`test/fixtures/pid_flow_fixture.ex`); `Quiet.LoopWithCatchAll` (`test/fixtures/quiet_shapes_fixture.ex`). Asserted in `test/analyses/mailbox_unreceived_test.exs` and `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None. The rule ships on fixtures by decision (9807d1a). A pickaxe scan of about 120 repositories for a fix pair found every added-receive fix in a handle_info/2 or a `:DOWN` clause (maintainer notes).

**Precision.** The rule has zero rows on the corpus, realtime, logflare, hexpm and OTP's kernel, mnesia, inets, ssh and ssl (cf5d8fb). On kernel there are 71 literal sends to a spawned process. 35 meet a clause that takes anything, 27 a process that runs code through a fun, 7 a clause for the message, and 2 a process with no receive.

### A cancelled timer whose stale message is not flushed

`timer_cancel_without_flush`
· titles: "Timer cancelled without flushing its message" (`:warning`)

**Property.** A process cancels a timer it armed for itself and arms it again. The timer's message is a literal that carries nothing identifying the timer: a bare atom, or a literal that the callers of the arming helper fill in. Nothing flushes that message after the cancel. There are two shapes:
- The ref is kept under a state key K. Some `cancel_timer` takes the ref read from K, either at the site or at a caller that reads it and hands it down. Some arm in the same module, outside init/1, stores its ref under K.
- The ref is kept in a local of one function that both arms and cancels it (`key` empty).

Three cancels are not findings:
- a cancel in terminate/2, or in a helper that only terminate/2 reaches (two calls deep);
- a cancel in the handle_info/2 clause of that very message;
- a cancel with a flush in scope: a receive that names the message, or matches anything, in the cancelling function, in a caller that handed it the ref, or in what those call in the same process.

`Process.cancel_timer/1` does not remove a message already delivered, so a stale message is handled as if it were the next one. The action runs twice or early. With a local ref, it runs on a later call as if it were that call's timeout.

**Assumptions and limits.**
- The timer's identity follows the ref through the state by literal map key, through arming helpers, and through one wrapper (a default argument). A ref stored under a computed key, or read from somewhere the walk cannot follow, pairs with nothing, so the rule stays quiet.
- A message that carries anything computed (a ref, `{:tick, now}`) is taken to identify the timer and is not judged. So is `:erlang.start_timer`'s `{:timeout, ref, msg}` (`TimerWithRef`, `TimerLocalStartTimer`).
- The rule does not ask whether the flush runs after the cancel inside the function. That needs the instruction-level control-flow graph, which the analyses do not read.
- An arm in init/1 does not count as re-arming (`TwoTimers`). A timer armed for another process is not this process's to flush (`TimerForOther`).
- The arming module need not be a process: a helper module that arms for `self()` of whoever drives it counts (`TimerHelper`, the BB.Loop shape).
- A ref stored from inside an anonymous function is not followed.
- There is one finding per module and key, or per arming site for a local ref. The finding points at a cancel the program itself runs rather than one only its tests reach (`runs_under_test`). The cancels left out are related frames (`timer_cancel_under_test`).

**Fixtures.** Positive: `Hypothesized.TimerCancelNoFlush`, `Hypothesized.TimerCancelWrongFlush`, `TimerFlushedElsewhere`, `TimerForwarded`, `TimerHelper`, `TwoTimersViaHelper` (two keys), `TimerCancelOwnClauseAndDown` (its other cancel), `WriteBuffer` (with `WriteBufferIngest`, `WriteBufferTestSupport`), `FlushOnlyBuffer` (with `FlushOnlyBufferTestSupport`), `TimerLocalNoFlush` (`test/fixtures/hypothesized_shapes_fixture.ex`). Quiet: `Hypothesized.TimerCancelWithFlush`, `TimerCancelBlockingFlush`, `TimerFlushInHelper`, `TimerCancelHelperFlushInCaller`, `TimerWithRef`, `TimerForOther`, `TwoTimers`, `TimerCancelInOwnClause`, `TimerCancelInTerminate`, `TimerLocalFlushed`, `TimerLocalStartTimer`, `TimerLocalEitherArm` (same file). Asserted in `test/analyses/hypothesized_shapes_test.exs`.

**Corpus.** Fix pairs: `bb#214` (beam-bots/bb, 6c5dc2b → 4bd552c, BB.Loop). Present-only: `nebulex:generation-heartbeat-no-flush` (cabol/nebulex, faff154, Nebulex.Adapters.Local.Generation).

**Precision.** Later changes kept the findings stable:
- 95e4112, which moved the rule to state-key identity, found the same real sites as the looser rule before it (three in bb, two keys in nebulex), and the 14-tree diff did not change.
- 2cdadee left the corpus tally unchanged. The only two flushes the rule has ever seen sit in the cancelling function (bb's `BB.Loop.cancel/1`, sequin's ReorderBuffer).
- 3624d2c, which added local refs, left the tally unchanged.
- 3362cfb made supavisor's own-clause cancels (the Postgres heartbeat, TenantsMetrics) quiet, and moved the anchor of its Manager to the `:DOWN` clause.
- 453ad3c moved Plausible's WriteBuffer anchor to handle_cast/2.

No sampled rate.

### A monitor left live past a timed wait

`unconsumed_monitor` · kind=`timed_wait`
· titles: "#{func} leaves a monitor live after its wait times out" (`:error`)

**Property.** A function takes a monitor and waits, in its own process, in a receive with an `after` clause. The wait may be in the function itself, in what it calls, or in a closure it runs. All of the following also hold:
- No path of the function demonitors with `[:flush]`.
- None of its blocking receives pins that monitor's `:DOWN`.
- Its return does not end its process. A function whose return does is a spawned function's last act, called from nowhere else and not recursing.
- The monitor is not collected by the function's callers. It is collected when every way the program has into the function passes a call after which the caller waits for a `:DOWN` (or flushes it) on every path, and none of those ways comes from an exported function, an uncalled one or what a spawn runs.

On the timeout branch the monitor is still live. The `{:DOWN, ...}` arrives after the function has returned, into whatever runs then. If no clause matches, it is a FunctionClauseError; otherwise a clause runs with a reason the code stopped caring about.

**Assumptions and limits.**
- The timed receive is any receive in the function's same-process reach, before or after the monitor. It need not be one that waits on that monitor. Likewise, a demonitor with `:flush` of any ref discharges the monitor. A server callback that monitors, keeps the ref and calls a helper with an unrelated `receive ... after` is therefore reported, at error severity.
- A plain `Process.demonitor(ref)` does not discharge the monitor, because a `:DOWN` that is already delivered stays in the mailbox (`MonitorLeak.Flushes` shows the `:flush` form).
- A blocking receive discharges the monitor only when it sits in the monitoring function and pins that monitor's ref (`GraceThenKill`, Phoenix's Channel.Server.close/2). A blocking wait in a helper does not.
- The function need not belong to a process module; library code counts. There is one finding per function.

**Fixtures.** Positive: `MonitorLeak.Leaks`, `MonitorLeak.LeaksThroughHelper`, `InEach`, `TaskPolls`, `ReturnsLive`, `WaitsOnOnePath`, `CollectedOnOneCaller`, `WaitsForAnotherRef` (`test/fixtures/monitor_fixture.ex`). Quiet: `MonitorLeak.Flushes`, `Blocks`, `NoMonitor`, `FlushesInHelper`, `TaskGivesUp`, `GraceThenKill`, `CollectedByCaller`, `CollectedByRef`, `FlushedByCaller` (same file). Asserted in `test/analyses/mailbox_monitor_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** The rule's first version (42566d6) made one finding across teslamate, livebook, oban, sequin and keila. It was `TeslaMate.Vehicles.Vehicle:handle_event/4`, a true positive read against source. livebook's seven monitor-plus-receive functions all wait without `after`, and stay quiet. Later changes:
- 84ff4ac began following closures, kept hexpm's streaming task quiet (its wait is the task's last act), and dropped OTP's `mnesia_loader:finish_copy/6`.
- 3c34fa3 removed GenStage's and Horde's `monitor_child/1` (gen_stage ×2, horde ×3 checkouts), the only titles that moved.
- 1eabfbf removed Phoenix's Channel.Server.close/2.

### A server that monitors and never demonitors

`unconsumed_monitor` · kind=`never_released`
· titles: "#{mod} monitors but never demonitors" (`:info`)

**Property.** A server takes monitors on its own stack (`server_side`) and keeps their refs. Some function of the module removes an entry from a map (`removal_api`), and no function of the module calls `Process.demonitor`. Suppose an entry can leave by a path other than the monitored process dying: an explicit delete, an unsubscribe, a checkin. Then its monitor stays live, one per cycle for the life of the server, and each is a future `:DOWN` for an entry that is gone.

**Assumptions and limits.**
- This is a module-wide heuristic, reported as info. Any map removal anywhere in the module counts, including the removal in the `:DOWN` handler, the one path where the monitor is already gone. e00304c kept that removal out of the evidence frames, but not out of the rule. So a server whose only removal is in its `:DOWN` clause is still reported, with no frame. Conversely, any demonitor anywhere in the module, of any ref, silences the rule.
- Removal from a set, a keyword list or an ETS table is not seen, because `removal_api` lists map functions only.
- A monitor whose ref is discarded is the next class, not this one. A monitor in a client function runs in the caller (`MonitorLeak.ClientSideMonitor`).
- There is one finding per module, anchored at a monitor site. Up to three removal sites are related frames (`monitored_entry_removal`).

**Fixtures.** Positive: `MonitorLeak.NeverReleases` (`test/fixtures/monitor_fixture.ex`). Quiet: `MonitorLeak.ReleasesOnDelete`, `KillsMonitored`, `ClientSideMonitor`, `DropsRef` (same file). Asserted in `test/analyses/mailbox_monitor_test.exs`. The frames are asserted in `test/evidence_frames_test.exs`.

**Corpus.** Fix pairs: `postgrex#781` (elixir-ecto/postgrex, 313d6c9 → 85c7cf4, Postgrex.Parameters). Present-only: None.

**Precision.** Not measured. 326e156 introduced the rule as a heuristic at info.

### A monitor whose ref is discarded

`unconsumed_monitor` · kind=`ref_discarded`
· titles: "#{mod} drops the ref of a monitor it establishes" (`:info`)

**Property.** A function on a server's own stack (`server_side`) calls `Process.monitor/1` or `:erlang.monitor/2`, and on every path next overwrites the result without reading it. Nothing can ever demonitor that monitor, so it ends only with the monitored process. If the relationship it stands for can end another way (an unsubscribe, a checkin, a disconnect), the monitor outlives it, one per cycle. A `:DOWN` then arrives for a process the server stopped caring about.

**Assumptions and limits.**
- The rule reads the bytecode after the call. A read anywhere, a return, or an instruction the scan does not understand keeps the ref, in the quiet direction.
- It does not ask whether the relationship can end another way. A server whose subscriptions end only when the subscriber dies is reported too.
- There is one finding per site.

**Fixtures.** Positive: `MonitorLeak.DropsRef` (`test/fixtures/monitor_fixture.ex`). Quiet: `MonitorLeak.NeverReleases`, `ReleasesOnDelete`, `KillsMonitored`, `ClientSideMonitor` (same file). Asserted in `test/analyses/mailbox_monitor_test.exs`.

**Corpus.** Fix pairs: `supavisor@e80c9a2` (supabase/supavisor, 0fe1410 → e80c9a2, `Supavisor.ClientHandler`: the manager monitor's ref was discarded, so any `:DOWN` read as the manager going down). Present-only: None. a3ef85b draws the shape from Phoenix PubSub's Local.

**Precision.** Not measured.

### A Task.async nothing awaits

`task_result_defect` · kind=`never_awaited`
· titles: "Async task never awaited" (`:warning`)

**Property.** A function starts a task with Task.async or Task.Supervisor.async. Through any calls, it reaches no Task.await, await_many, yield, yield_many or shutdown. It does not return the task in tail position. Its module defines no handle_info/2 and is not a gen_statem with handle_event/4 (`mailbox_handler`). The task is linked to the caller and always sends a result. A crashing task takes the caller down, and completed results accumulate unread in the caller's mailbox.

**Assumptions and limits.**
- The check is function-level. An await anywhere in the function's reach counts for every task it starts, and so does an await in a process the function spawns.
- Any handle_info/2 in the module is taken as the place replies land, whichever process starts the task. A client function of a GenServer module is exempt, although it runs in the caller.
- Only a tail-position Task.async is a factory. A helper that returns the task some other way (`{:ok, task}`, or after a log call) is reported, although its callers await.
- A fun literal `&Task.await/1` handed to Enum.map is not an await, so `Enum.map(tasks, &Task.await/1)` reads as never awaited. The `LibraryPmap` fixture avoids the capture for this reason.
- Task.Supervisor.async_nolink is excluded: its messages are the async_nolink class's.
- Test support compiled with the program is judged.

**Fixtures.** Positive: `LeakedTaskModule` (`fire_and_forget`) (`test/fixtures/unsafe_task_fixture.ex`). Quiet: `LeakedTaskModule` (`safe_async`), `GenServerTaskConsumer`, `PlainTaskConsumer`, `SupervisedFireAndForget`, `TaskFactory`, `LiveViewTaskConsumer`, `GenStatemTaskConsumer`, `TaskShutdownUser` (same file). Asserted in `test/analyses/mailbox_task_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured.

### Task.yield on a linked task

`task_result_defect` · kind=`yield_linked`
· titles: "Task.yield on a linked task cannot see it crash" (`:warning`)

**Property.** A function, together with the closures it defines, starts a task with Task.async or Task.Supervisor.async and collects with Task.yield or Task.yield_many, and no function of its module sets trap_exit. `yield`'s `{:exit, reason}` result is documented for a crashed task. But the link delivers the crash to the caller first, so the branch that handles a failed task never runs: the caller is already dead.

**Assumptions and limits.**
- The yield can be any yield in the function; it need not collect this task.
- The trap_exit check is module-level. A library function called from a trapping process in another module is reported. A module that traps exits in an unrelated function is quiet.
- A closure counts for the function that defines it, even when the closure runs in another process.
- There is one finding per task start. Up to three yield sites are related frames (`task_yield_site`).

**Fixtures.** Positive: `YieldsLinkedTask` (`test/fixtures/unsafe_task_fixture.ex`). Quiet: `TrapsAndYields` (same file). Asserted in `test/analyses/mailbox_task_test.exs`. The frames are asserted in `test/evidence_frames_test.exs`.

**Corpus.** Fix pairs: `redix#317` (whatyouhide/redix, cef6129 → 3f88e8e, Redix.Cluster). Present-only: None.

**Precision.** Not measured.

### A linked task started in library code

`task_result_defect` · kind=`linked_in_library`
· titles: "Task.async in library code links to an unknown caller" (`:info`)

**Property.** A function that runs in its caller's process starts a task with Task.async or Task.Supervisor.async, directly or in a closure it defines: a function of a module that implements no behaviour, or a function of a process module (GenServer, Supervisor, gen_statem, ...) that its own callbacks do not reach on the server's stack (`server_side`), its client API. It awaits somewhere in its reach and does not return the task. The task is linked to whichever process called the function. In a caller that traps exits, the task's normal exit arrives as an `{:EXIT, pid, :normal}` that Task.await never consumes. A crashing task takes an unrelated caller down with it.

**Assumptions and limits.**
- A behaviour module that runs no process of its own (a plug, an Ecto type, a controller) is exempt: it owns its callers' expectations, and argus cannot tell its callbacks from its other functions. A process module is judged by where the function runs (round 2, 2026-09-25): its callbacks and what they reach in the module are the server's own (`ServerSideTaskAwait`, quiet), and its client API runs in whoever calls it (`PoolCallSupervisor.call/2`, elixir-nodejs#45's `NodeJS.Supervisor.call/3`). Until round 2 every behaviour module was exempt, the API of a `use Supervisor` or `use GenServer` module included.
- The rule fires on essentially every Task.async plus await in plain library code, which is why it is info-grade. The maintainer notes record that it moved encore's and scry's fixture counts.
- A closure counts for the function that defines it, even when the task links to a process started on that closure.
- Test support compiled with the program is judged.

**Fixtures.** Positive: `LibraryPmap`, `PoolCallSupervisor` (`test/fixtures/unsafe_task_fixture.ex`). Quiet: `GenServerTaskConsumer`, `ServerSideTaskAwait` (same file); `Quiet.ServerAwaits` (`test/fixtures/quiet_shapes_fixture.ex`). Asserted in `test/analyses/mailbox_task_test.exs` and `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: `ecto#2338` (elixir-ecto/ecto, 5422d31 → 12a7452, Ecto.Repo.Preloader). Present-only: None.

**Precision.** Not measured.

### A tag a module sends its own server with no clause for it

`reply_defect` · kind=`self_call` | `self_cast`
· titles: "#{mod} sends itself #{tag}, which it cannot handle" (`:error`)

**Property.** A function of a GenServer module makes a GenServer.call (or cast) whose message has a literal tag: an atom, or a tuple's first atom. The module's handle_call/3 (or handle_cast/2) neither compares that tag anywhere nor has a catch-all. The function is not a proxy:
- it calls or casts no literal other module;
- points-to follows none of its calls or casts to another module's server;
- no other module's handler discriminates on a tag it sends.

For a call, the server raises FunctionClauseError and the caller exits with it, pointing at the call instead of the missing clause. For a cast, the caller learns nothing, and the server restarts with its state gone.

**Assumptions and limits.**
- The rule does not prove the call's target is the module's own server. A target it cannot resolve is assumed to be the module's own. 9ead86a kept this deliberately: the real mismatches are client functions whose pid is a parameter that no caller resolves.
- The tag is the one that reaches the call site by data flow. A message that is a parameter has no tag (`MessageContract.StaleWrite`).
- Clause tags are over-approximated: an atom compared anywhere in the handler's body counts. A clause that takes the request by shape alone (`req when is_atom(req)`) is not read as taking it.
- There is one finding per module and tag, anchored at a sender.

**Fixtures.** Positive: `MessageContract.Mismatch` (`test/fixtures/message_contract_fixture.ex`). Quiet: `MessageContract.Agrees`, `CatchAll`, `StaleWrite`, `Forwarder` (with `Sink`) (same file). Asserted in `test/analyses/mailbox_message_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** The rule's first version found the tag by scanning the bytecode. It made two findings on about 8,000 modules, and both were false. The join that replaced it found none on sequin, Livebook or oban (f94f640). Its reasoning: "a client/server tag mismatch crashes the first time the path runs, so it does not survive testing". 9ead86a stopped reporting a server that calls a catch-all server it started. The corpus, realtime, logflare, hexpm and OTP were unchanged.

### A handle_call that defers a reply without keeping from

`reply_defect` · kind=`dropped_from`
· titles: "#{mod} defers a reply it cannot send" (`:error`)

**Property.** A module's behaviour is gen_server-like. Its handle_call/3 has a `{:noreply, _}` return site that some path reaches without ever reading `from`, the second argument. Reading means mentioning its register, or making a call of arity two or more. That execution promised a later GenServer.reply/2 that nothing can send, because `from` exists nowhere else. Every caller that reaches the clause blocks for its full call timeout and then exits. The exit is raised in another module, with a message that names neither this function nor this clause.

**Assumptions and limits.**
- The check is per return site, so a correct sibling clause does not vouch for a broken one (`Reply.MixedClauses`).
- Any call of arity two or more counts as reading `from`, because positional arguments compile to no move. This errs quiet (`Reply.PassesThrough`).
- A module that keeps `from` and replies nowhere is not reported, because that needs escape analysis (`Reply.StoresAndForgets`, pinned as a non-finding).
- Erlang gen_servers are judged. All three historical findings were Erlang modules.

**Fixtures.** Positive: `Reply.Forgets`, `Reply.MixedClauses` (`test/fixtures/reply_fixture.ex`). Quiet: `Reply.RepliesDirectly`, `DefersProperly`, `StoresAndForgets`, `HandsOff`, `StopsWithReply`, `CastsAndInfos`, `NotAGenServer`, `PassesThrough` (same file). Asserted in `test/analyses/mailbox_reply_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** aac276c reports three findings across about 14,000 modules, each read against source:
- `:amqp_channel`'s unexported handle_call(flush) is a landmine: the natural call hangs.
- `:dogstatsd_vm_stats` and `:ranch_server_proxy` have a catch-all handle_call that returns `{noreply, State}` deliberately, because they accept no calls. The commit still counts them, because hanging a caller for a full timeout is worse than refusing.

### A gen_statem call clause that never replies

`reply_defect` · kind=`statem_unreplied`
· titles: "A {:call, from} clause never replies" (`:warning`)

**Property.** A gen_statem clause for a `{:call, from}` event has a path to a return that does none of three things: carry a `{:reply, from, _}` action, postpone the event, or hand `from` to anything (the data, a tuple, a call). The caller of `:gen_statem.call/2` waits `:infinity` by default, so it stays blocked for as long as the machine lives.

**Assumptions and limits.**
- The walk is path-sensitive per clause. `from` parked in a tuple, or read back from a register the event was saved to, counts as kept (`PendingCallStatem`).
- Handing `from` to any call counts as keeping it, so `:gen_statem.reply(from, value)` anywhere on the path discharges the clause.
- The anchor is the clause's last pattern test, which carries the previous clause's line. The tested literal (the `tag` column) is what a consumer with the source uses to find the clause head.

**Fixtures.** Positive: `UnrepliedCallStatem` (`test/fixtures/gen_statem_fixture.ex`). Quiet: `PendingCallStatem` (same file); `Quiet.PostponingStatem` (`test/fixtures/quiet_shapes_fixture.ex`). Asserted in `test/analyses/mailbox_statem_test.exs` and `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: `finch#213` (sneako/finch, 2882794 → ca530c8, Finch.HTTP2.Pool). Present-only: None.

**Precision.** Not measured. CHANGELOG 0.12.1 records one false-positive fix: a clause that parks `from` at the head of a tuple.

## failure

An error path the code could have seen and did not take: an exception a catch-all handler discards, a remote call whose failure value nothing matches, a result used without its failure case, a process nothing watches, an exit signal sent from a callback past the supervisor that owns its target, and a call site that breaks the program's own convention for a callee's failure. A discarded `start_link`/`start` result belongs to startup (`ignored_start_result`), an rpc or call with no bounded timeout and a `{:noproc, _}`-only catch to blocking, a lookup-then-start race on a process name and a missing ETS row to races (`registry_race`, `ets_missing_row`), and a callback stopping a sibling through its API to shutdown.

### Catch-all handler that swallows every exception

`unhandled_failure` · kind=`rescue`
· titles: "Catch-all rescue swallows exceptions" (`:warning`)

**Property.** Some `try` in a function f has a handler that takes every class without testing the class, the reason or the exception's type, does not raise again (no `raise`, `reraise`, `:erlang.raise/3` or `:erlang.error`), is not empty, and never reads the caught class, reason or stacktrace before overwriting them: `catch _, _ -> :ok`, `catch _kind, _reason -> default`. The finding spans the `try` through the end of its handler. Every error, exit and throw raised inside the `try` becomes the handler's value, so a bug surfaces later, far from its cause, with the stacktrace gone.

**Assumptions and limits.**
- The handler is read from bytecode, from its label to the next label or return. Any test instruction in it counts as filtering, and a read of the exception registers on any path (returning `{:error, {kind, reason}}`, logging the reason, handing it to a function) counts as handling it, even when another path discards it.
- Elixir's `rescue` is never reported: `rescue _ -> ...` tests that the class is `:error` and raises the others again, and `rescue e -> ...` normalizes the exception, which reads it. A handler that swallows every error this way is a false negative, pinned by `FilteredRescue`.
- Erlang's `catch Expr` with its value discarded swallows every class too, and is not read: it is not a `try`.
- A handler that logs a constant message without the exception is reported; the finding's "logging" means logging the exception. A handler that ends in `exit/1` or `throw/1` is reported as swallowing.
- A catch-all another module's macro wrote (a `use` expansion) is judged as the program's, and deliberate isolation (a loop that must outlive any callback) is reported alike: the rule has no notion of intent.

**Fixtures.** Positive: `BareRescue` (test/fixtures/error_handling_fixture.ex). Quiet: `FilteredRescue`, `ReifyingRescue`, `ReraisingRescue` (same file). Asserted in test/analyses/failure_error_test.exs.

**Corpus.** None.

**Precision.** On a 15-project corpus the error_handling analysis this rule came from was 5 true positives to 20 false (5cebc80); reading whether the handler uses the exception removed about 10 false positives, and recognizing the `raw_raise` opcode (what `:erlang.raise/3` in a handler compiles to since OTP 21) removed 2 more. The maintainer notes on that audit (2026-07-17) put the whole analysis at 25 → 8 findings afterwards. Not measured since.

### An :erpc rescue with no clause for transport failures

`unhandled_failure` · kind=`erpc_transport`
· titles: ":erpc.call transport failures fall through the rescue" (`:warning`)

**Property.** Some call to `:erpc.call/4,5` in a function f is covered by a `try` whose handler compares the reason to `:exception` (it unwraps the `{:exception, reason, stack}` a remote raise produces), names `:erpc` in none of its clauses, and holds a `case`, reached after that comparison, with no clause for some value. `:erpc` raises `{:erpc, :noconnection}`, `{:erpc, :timeout}` or `{:erpc, :system_limit}` when the node or the transport fails; that reason reaches the `case`, and the caller gets a CaseClauseError in place of a result or a meaningful error. The finding spans the call through the end of the handler.

**Assumptions and limits.**
- Only `:erpc.call/4,5`. The fun forms `:erpc.call/2,3`, `:erpc.multicall` and `:erpc.receive_response` are not read (false negatives).
- Every atom a handler clause compares counts as a reason it takes, a nested `case` included: a handler that mentions `:erpc` anywhere is quiet (over-approximation in the quiet direction).
- A handler with no `case` on the reason, which makes every ErlangError a value, is quiet (`Quiet.ErpcRescueAll`).

**Fixtures.** Positive: `CatchShapes.Erpc` (`partial/4`) (test/fixtures/catch_shapes_fixture.ex). Quiet: `CatchShapes.Erpc` (`total/4`, same file); `Quiet.ErpcRescueAll` (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/singleton_shapes_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Fix pairs: `nebulex#140` (cabol/nebulex, faff154 → bde4e3f, Nebulex.RPC).

**Precision.** Not measured beyond the pair.

### An rpc result matched without a badrpc clause

`unhandled_failure` · shape=`case` (kind is the variant: `rpc`, `block_call`, `yield`, `multicall`)
· titles: "RPC result matched without a {:badrpc, _} clause" (`:warning`)

**Property.** Some call to `:rpc.call`, `:rpc.block_call`, `:rpc.multicall`, or the `:rpc.yield` that collects an `:rpc.async_call`, in a function f whose result is next tested by shape (a pattern, a type test, a `select`), where f has a clause-less exit (a `case` or a match that raises when nothing matches) and nothing in f compares a value to `:badrpc`. A node that is down, a timeout or a remote exit answers `{:badrpc, reason}` rather than raising; no clause takes it, and a cluster failure becomes a CaseClauseError or MatchError instead of an error value (rabbitmq-cli#193, phoenix_live_dashboard#218, livebook#972).

**Assumptions and limits.**
- The result is followed along straight-line code from the call to the first instruction that examines it, stores it or passes it on.
- `:badrpc` compared anywhere in f quiets every rpc in f (quiet direction); the clause-less exit may belong to another `case` in f than the one matching the result (noisy direction).
- `:rpc.nb_yield` wraps its answer in `{:value, _}`: a `case` over it has a clause for the wrapper, and the badrpc it leaves out is nested, not this shape (`NbYieldCase`).
- For `:rpc.multicall` only the match of the `{results, bad_nodes}` pair is read, not the failures inside the results list.
- **Through wrappers** (round 2, 2026-09-25). An rpc whose answer f returns (`rpc_result` "returned") makes f a wrapper, and so does returning a wrapper's result (`result_tested` "returned": a tail call or a returned result, local or remote); a wrapper compares nothing to `:badrpc`. The finding is then at a caller's call of the wrapper, where the caller matches the result by shape or tests it as a boolean (`result_tested` "case" or "boolean", in a function comparing nothing to `:badrpc`), with the rpc as a related frame (`rpc_wrapped`) and the wrapper named in the prose ("the result of `M.f/2`, which returns :rpc.call's answer,"). EMQX's BPAPI proto modules are the shape: the handler, a facade, the proto's one `rpc:call` (`RpcWrapperCaller` through `RpcFacade` and `RpcProto`).
- Only an answer that is a `{:badrpc, _}` itself is carried through a wrapper (`:rpc.call`, `block_call`, `yield`): a multicall wrapper's pair is always a pair, and a caller's `{replies, _bad} = ...` takes it (mnesia's own multicall wrappers).
- A wrapper that takes the failure itself (`RpcProto.lookup/2`, a `{:badrpc, _}` clause) wraps nothing; a caller with a `:badrpc` clause is quiet (`RpcWrapperCallerHandled`), as is one that stores or passes the result on. A predicate wrapper (a name ending in `?`) is judged at its own rpc, where its name makes the answer a boolean; calls into the runtime and to compiler-made functions are not read.
- A wrapper whose `case` passes `{:badrpc, _}` = Err -> Err and everything else through unchanged is compiled to a bare return and reads as a wrapper (rabbit's `is_booting/1`): what it returns is still the tuple, so its callers are judged, rightly.

**Fixtures.** Positive: `Hypothesized.RpcCaseNoBadrpc`, `Hypothesized.BlockCallCaseNoBadrpc`, and through wrappers `Hypothesized.RpcWrapperCaller` (`delete/2` through `RpcFacade` and `RpcProto`, `status/2` through `RpcProto`) (test/fixtures/hypothesized_shapes_fixture.ex). Quiet: `Hypothesized.RpcCaseWithBadrpc`, `Hypothesized.NbYieldCase`, `Hypothesized.RpcWrapperCallerHandled` (a `:badrpc` clause, a wrapper that handles the failure, a result passed on) (same file). No multicall or yield-in-a-case fixture. Asserted in test/analyses/hypothesized_shapes_test.exs.

**Corpus.** Present-only: `phoenix_live_dashboard#218` (phoenixframework/phoenix_live_dashboard, e562c63, Phoenix.LiveDashboard.SystemInfo); `phoenix_live_dashboard:rpc-wrapper` (same tree, Phoenix.LiveDashboard.ProcessInfoComponent, which matches `SystemInfo.fetch_process_info/1`'s pass-through `:rpc.call` answer for `{:ok, info}` and `:error` only; the later "Use erpc" commit makes it raise instead, no fix of the class). EMQX's audit (emqx#18287, fix b32a01f, pre 8fe9f79) is the motivating fix; see the corpus comment for whether its tree builds here.

**Precision.** Round 2 (2026-09-25), the wrapper arm only. Corpus tally: 9 new rows, all in the class: phoenix_live_dashboard e562c63's seven info components and pages (the #218 shape, one call away) and Livebook's `ErlDist.initialize/2` (`{:ok, _} = start_node_manager(node, ...)`, an `:rpc.call` wrapper, twice). Live projects (ejabberd, rabbit and rabbit_common, eight more) and OTP kernel, mnesia, ssl and inets: 5 new rows, 4 real — ejabberd's `mod_configure` get_form closure (`case ejabberd_cluster:call(...) of Type when is_atom(Type) -> ...`, where the module's other sites take `{badrpc, _}`), rabbit's `await_startup/2,3` (`case is_booting(Node) of true -> ...; false -> ...`), and `rabbit_khepri:check_cluster_consistency/2`, whose `try {ok, remote_node_info(Node)} catch _:_ -> error end` catches nothing an rpc returns and has no clause for `{ok, {badrpc, _}}` — and 1 false: rabbit's `is_booted/1` tests the answer against `false` and sends everything else, the tuple included, to a `_ -> false` clause (the boolean arm cannot tell which branch a tuple takes). Multicall wrappers, which made mnesia's `{Replies, _Bad} = multicall(...)` rows before they were excluded, are out.

### A remote call's failure read as a boolean

`unhandled_failure` · shape=`boolean` (kind is the variant: `rpc`, `block_call`, `yield`, `multicall`, `erpc`)
· titles: "RPC result used as a boolean" (`:warning`); ":erpc.call in a boolean context with no rescue" (`:warning`)

**Property.** Some remote call in a function f whose result is tested against `true`, `false` or `nil` (an `&&`, an `if`), or is f's own return value where f's name ends in `?`, so its callers test it. For `:rpc.call`, `:rpc.block_call`, `:rpc.yield` or `:rpc.multicall`, a node that is gone answers `{:badrpc, :nodedown}`, and a tuple is truthy: the failure reads as true (horde's `member?(n) && :rpc.call(n, Process, :alive?, [pid])` said a process on a gone node was alive). For `:erpc.call` (kind `erpc`), f has no handler clause that takes every error and none that compares `:erpc`: a node that went away between the check that chose it and the call raises `{:erpc, :noconnection}` out of the predicate.

**Assumptions and limits.**
- Besides the `?` naming convention, a result returned through a wrapper and tested against a boolean by its caller is followed (see the previous class, "Through wrappers"); the test does not say which branch the tuple takes, so a caller that sends everything but `false` to a `false` clause is still reported (rabbit's `is_booted/1`).
- For `erpc`, a handler anywhere in f that takes every error, or compares `:erpc`, quiets the call whether or not it covers it (a function-wide reading, in the quiet direction).
- `:erpc.call/2,3` (the fun forms) are not read.

**Fixtures.** Positive: `Hypothesized.RpcBoolean`, `Hypothesized.YieldBoolean`, `Hypothesized.ErpcBooleanNoRescue` (test/fixtures/hypothesized_shapes_fixture.ex). Quiet: `Hypothesized.ErpcBooleanRescued` (horde's fix, same file). Asserted in test/analyses/hypothesized_shapes_test.exs.

**Corpus.** Fix pairs: `horde:erpc-noconnection-race` (derekkraan/horde, f9ef5c4 → 30bb1a1, Horde.Registry), on the `:erpc` title.

**Precision.** Not measured.

### A Task.Supervisor.start_child result discarded

`unchecked_result` · api=`Task.Supervisor.start_child`
· titles: "start_child result not checked" (`:warning`)

**Property.** Some call to `Task.Supervisor.start_child` in a function f that is not in tail position and after which f has no branch at all. An `{:error, reason}` return (the supervisor at `max_children`, not started yet, a bad child spec) is dropped, and a failed launch looks exactly like a successful one.

**Assumptions and limits.**
- "Checked" is a coarse proxy kept on purpose: any branch later in f counts, including one in an unrelated clause (false negatives).
- Only `Task.Supervisor.start_child`. A discarded `DynamicSupervisor.start_child` or `Supervisor.start_child` is reported only by the result belief below, when the program's other sites match it, and a discarded `start_link`/`start` by startup.
- A site this rule reports is not reported again by the result belief.

**Fixtures.** Positive: `UncheckedStartChild` (`start_unchecked/1`) (test/fixtures/unsafe_task_fixture.ex). Quiet: `UncheckedStartChild` (`start_checked/1`, `start_tail/1`). Asserted in test/analyses/failure_start_child_test.exs.

**Corpus.** Fix pairs: `livebook@56ecd47` (livebook-dev/livebook, c70c4d9 → 56ecd47, `Livebook.Hubs`; the same commit fixes two more sites).

**Precision.** Not measured.

### A whereis result used without its nil case

`unchecked_result` · api=`Process.whereis`
· titles: "whereis result used without a nil check" (`:warning`)

**Property.** Some call to `Process.whereis/1` or `:erlang.whereis/1` on a literal name in a function f, whose result the straight-line code after the call never compares to `nil` or `:undefined`, type-tests, or selects on with a `nil` branch. The named process can die, or not yet be registered, between the lookup and the use: `nil` travels on as though it were a pid (a time-of-check to time-of-use race).

**Assumptions and limits.**
- Only a literal name; a name computed at runtime is not read (`WhereisModule`).
- The check is looked for in straight-line code after the call; one made by a callee, or on a later branch, is missed (reports). A result returned to the caller counts as unchecked.
- Looking a name up and then starting the process under it is races' `registry_race`, not this.

**Fixtures.** Positive: `StaticWhereis` (test/fixtures/process_registry_fixture.ex). Quiet: `WhereisModule` (same file). Asserted in test/analyses/failure_whereis_test.exs.

**Corpus.** None.

**Precision.** The rule once reported every `Process.whereis/1`; reading the nil check removed the shape the finding recommends, nerves_hub_link's `case Process.whereis(n) do nil -> ...` (04d0234, CHANGELOG schema 31). Not measured since.

### A bare spawn nothing watches

`orphan_process` · kind=`spawn`
· titles: "Unlinked process spawned" (`:warning`)

**Property.** Some call in a function f starts a process with neither a link nor a monitor (`spawn/1..4`, `:proc_lib.spawn`, or `spawn_opt` with a literal option list that asks for neither), and no process started at that call is monitored or linked to anywhere in the program afterwards (`watched_process`, over process points-to). If the process crashes, nothing observes it: no restart, no exit signal, no cleanup.

**Assumptions and limits.**
- Not read: `spawn_link`, `spawn_monitor`, `spawn_opt` whose options are not known at compile time, and `:proc_lib.start`, which waits for the new process's `init_ack` and reports its own crash.
- A monitor or link counts wherever it is made and by whichever process: the key is the process points-to allocates at the spawn, not the spawning function.
- `:proc_lib.spawn` is reported though proc_lib writes a crash report for its processes; the finding's "no log" is not true of it.
- `Task.start/1,3`, unlinked and unmonitored, is not a spawn here (false negative).
- A process whose body catches everything, and so never dies silently, is still reported.

**Fixtures.** Positive: `UnlinkedSpawner` (`spawn_unlinked/0`) (test/fixtures/unlinked_spawn_fixture.ex); `ExitSignals.Watched` (`unwatched/0`) (test/fixtures/exit_signal_fixture.ex). Quiet: `UnlinkedSpawner` (`spawn_linked/0`, `spawn_monitored/0`, `start_synchronously/0`); `ExitSignals.Watched` (`monitored/0`, `linked/0`). Asserted in test/analyses/failure_spawn_test.exs.

**Corpus.** Fix pairs: `finch@9ae43ef` (sneako/finch, 8bae1ce → 9ae43ef, `Finch.HTTP1.Pool`: an async request's bare spawn outlived its caller).

**Precision.** Reading monitors and links through points-to took the corpus's `orphan_process` rows, both kinds, from 14 to 11; over OTP kernel, the spawns of file_server, inet_gethost_native and user_sup, which go on to monitor or link, dropped out (e70936e). `:proc_lib.start` stopped being reported with schema 93 (peer's `start_orphan_supervision/0`, CHANGELOG 0.20.0-dev). Not otherwise measured.

### An exit signal from a callback past the supervisor

`orphan_process` · kind=`exit`
· titles: "Process.exit inside a GenServer callback" (`:info`)

**Property.** Some GenServer message handler h (`handle_call`, `handle_cast`, `handle_info`, `handle_continue`) reaches, in its own process (`SameProcessReach`: not through a function a spawn or a task runs), a `Process.exit/2` or `:erlang.exit/2` sent to another process, where process points-to does not resolve every target to a process h's module started itself (`exit_to_own_process`). When a target resolves to a child a supervisor owns (`supervised_process`), `target` is that child and the supervisor is attached as a related frame (`exit_target_owner`: "#{child} is #{sup}'s child"); otherwise `target` is the literal name or `dynamic`. Killing a process imperatively bypasses the supervisor that started it and the target's own stop protocol: a permanent child is restarted at once, and nothing in the target's teardown runs.

**Assumptions and limits.**
- `exit/1` raises in the current process (let it crash, visible to supervision) and is not read.
- Only GenServer handlers (and the wrappers argus treats as GenServer); a gen_statem state function or a GenStage callback sending the same signal is not seen.
- Reach from the handler is unbounded and value-insensitive: an exit on a path the handler's arguments never take is reported.
- A kill of a process the module started itself (a helper kept in its state, a worker it spawned) is quiet, and a kill inside a closure the handler spawns belongs to that process, not the handler; a target points-to cannot resolve is reported as "a process it holds as a value".
- Most remaining cases are deliberate (process-manager handoff, registry name-conflict resolution, an ownership watcher killing dependents), hence `:info`.

**Fixtures.** Positive: `ExitingServer` (test/fixtures/error_handling_fixture.ex); `ExitSignals.Killer` under `ExitSignals.Tree` with `ExitSignals.Worker` (test/fixtures/exit_signal_fixture.ex, target and supervisor named). Quiet: `SelfCrashCallback`, `ExitCaller` (test/fixtures/error_handling_fixture.ex); `ExitSignals.OwnHelper` (test/fixtures/exit_signal_fixture.ex). Asserted in test/analyses/failure_error_test.exs; the related frame in test/evidence_frames_test.exs.

**Corpus.** None.

**Precision.** Leaving out `exit/1` removed the self-crash false positives, and the rule went to `:info` because the remaining `Process.exit/2` sites were overwhelmingly deliberate (5cebc80, 15-project corpus). Process points-to then removed phoenix's CodeReloader, which kills the IO proxy it started, and supavisor's SecretChecker, whose kill runs in a spawned closure; the corpus's `orphan_process` rows went 14 → 11 (e70936e). Not otherwise measured.

### A result ignored where the program checks it

`inconsistent_handling` · belief=`result_checked`
· titles: "#{callee} result ignored where every other call site checks it" (`:warning` or `:info`); "#{callee} result ignored where most call sites check it" (`:warning` or `:info`)

**Property.** Some call site s of a process or OTP API c (a function of GenServer, Supervisor, DynamicSupervisor, PartitionSupervisor, Registry, Task, Task.Supervisor, Agent, Process, `:gen_server`, `:gen_statem`, `:supervisor` or `:ets`, the process half of `:erlang`, or any `start_link`, `start` or `start_child`), in a function no other module's macro wrote, discards c's result, while at least three other sites of c on the same target use it and the discarding sites are a quarter or fewer of the sites that use or discard it. The target is the call's literal first argument (a table, a registered name, a supervisor), or "processes of M" when the call raises an exit and its first argument is a parameter of a client function of M, a module that runs a process loop. c's spec must not rule out a failure value (`callee_returns`: a callee whose spec always returns a value or never returns has nothing to miss), and s is neither a Task.Supervisor.start_child site `unchecked_result` reports nor a discarded `start_link`/`start` startup reports. `agree` and `deviate` are the counts; the title says "every other" only when s is the only deviant. The program's own sites say c's result carries a failure, and here it is dropped: the caller carries on as though the call succeeded. The severity is `:warning` when the agreeing fraction lies two standard deviations or more above a coin flip (about seven sites to one), else `:info`. Up to three agreeing sites are attached (`handling_site`, "its result matched here").

**Assumptions and limits.**
- No list names the callees whose results must be checked; the belief is the program's. It needs three agreeing sites and a deviant quarter: three checked against three ignored is a convention either way.
- Only the used and ignored fates take part: a site that returns the result hands the question to its callers.
- A site whose target is not known takes no part, and sites on different literal targets never judge each other. Whether the pid is a client function's parameter is read per function and callee, not per call.
- Sites are bytecode call sites: compiler copies of one source line, and an Erlang macro's expansions, count once each (a known limit in the rule's comment).
- A spec only quiets: a callee with no spec stays in. A callee outside the process APIs (`File.write`) is out of scope.
- Test-support modules compiled into the build take part like the program's own code.

**Fixtures.** Positive: `Consistency.DeviantIgnore` (test/fixtures/consistency_fixture.ex); with `Consistency.WeakBelief` the population spans modules, seven against two. Quiet: `Consistency.WeakBelief`, `NoMajority`, `OutsideScope`, `TotalCallee`, `StartIgnored`, `TailReturns` (same file). Asserted in test/analyses/failure_consistency_test.exs.

**Corpus.** None.

**Precision.** No corpus finding at introduction (00917e6; maintainer notes). Not measured since.

### A call left unguarded where the program guards it

`inconsistent_handling` · belief=`exception_guarded` (with `cover` = `none` | `try` | `callers`)
· titles: "#{callee} called bare where every other call site catches its #{class}"; "#{callee} called bare where most call sites catch its #{class}"; "#{callee} called in a try that lets its #{class} through where every other call site catches it"; "#{callee} called in a try that lets its #{class} through where most call sites catch it"; "#{callee} called with its #{class} uncaught where every other call site catches it"; "#{callee} called with its #{class} uncaught where most call sites catch it" (each `:warning` or `:info`, as for the result belief; `#{class}` is error, exit, throw, or exception for a call whose class is not known)

**Property.** Some call site s of such a callee c, on a known target, whose arguments do not rule out failure, is covered by no `try` that takes the class c raises, neither in s's own function nor on every way into that function, while at least three other sites of c on that target are so guarded and the unguarded sites are a quarter or fewer. A call into a process raises an exit; a BIF or an ETS operation an error. A `try` takes a class when some path through its handler establishes the class and returns without raising again (`try_takes`): an `after`, a handler that only re-raises, or `catch :exit` around an ETS badarg takes nothing the call raises, and Erlang's `catch Expr` takes every class. A function is guarded by its callers when every path from an exported function, or from a closure a process-starting function builds, passes such a try (`ForwardUnguardedSet`). A site cannot fail, and takes no part, when it is a send to anything but a literal local name, an ETS operation that fails only on a missing table made inside the process that created the named table, or a `lookup_element` of a row the table's owner writes in `init/1` and nothing removes. `raises` is the class and `cover` how s stands: `none` (no try here, and some way in passes none), `try` (a try here takes other classes or nothing; `caught` names what it takes), `callers` (every way in passes a try, not always one that takes the class). The failure the other sites catch, a `:noproc` or timeout from a dead server or a badarg from a missing table, crashes the caller here. Up to three guarded sites of the same population are attached (`handling_site`: "guarded by this {guard}", or "guarded by a try around every call of its function").

**Assumptions and limits.**
- A closure counts as run inside a try only when every read of its value is a call in the try's region; a closure a process-starting function builds may run in that process and is an entry of its own (`TaskInTry`).
- The class a call raises comes from its module, not its function: `GenServer.cast` or `Task.async`, which do not raise, carry `exit` like `GenServer.call`; only sends and ETS operations are recognized as unable to fail.
- The table owner is found by module: a function runs "in the owner" when only the creating module's callbacks reach it in their own process and nothing outside can call it (a private function or a callback).
- Population, target, spec, macro, copy and test-code limits are the result belief's; mnesia's `?catch_val`, one guarded lookup expanded a hundred times, counts a hundred sites.

**Fixtures.** Positive: `Consistency.DeviantBare` (`none`, target "processes of"), `HelperOutsideTry`, `SameTargetBare`, `WrittenBare`, `LocalSends`, `ClientDeletes`, `UnseededRows`, `GuardedByCallers`, `TaskInTry`, `HiddenDeviant` (`try`, catches nothing), `WrongClassDeviant` (`try`, catches only `:exit`), `CallersWrongClass` (`callers`) (test/fixtures/consistency_fixture.ex); `:consistency_catch` (test/fixtures/erl/consistency_catch.erl, Erlang's `catch`). Quiet: `Consistency.AfterOnly`, `WrongClass`, `ReraiseOnly`, `CallerGuards`, `ClosureInTry`, `PerTarget`, `SequinLiteral`, `OwnSplit`, `TableMissing`, `UnknownTargetBare`, `GeneratedBare`, `RemoteSends`, `OwnerDeletes`, `SeededRows` (same file); the `Quiet` modules (test/fixtures/quiet_shapes_fixture.ex). Asserted in test/analyses/failure_consistency_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Present-only: `supavisor@a8463de` (supabase/supavisor, a8463de, Supavisor.DbHandler), ":gen_statem.call/3 called bare where every other call site catches its exit". No fix pair exists: the rule needs three guarded sites and a quarter or fewer bare, and the eleven catch-adding fixes the hunt found were all below that (maintainer notes, 2026-09-23).

**Precision.** Two corpus sites at introduction, both `:ets.lookup_element` called bare where the module rescues it elsewhere (00917e6), later judged deliberate (maintainer notes). The guard-class audit took the corpus from 3 to 2 when db_connection's `Holder.hash_holder/2`, guarded by its caller, dropped out (the belief audit, 5478aa7). Keying the belief on its target took OTP kernel, stdlib and mnesia, the Phoenix stack and sequin from 22 findings to 2: supavisor's DbHandler, a real bug, and user_sup's `register(user, self())` against peer.erl's three guarded registrations of the same name, not judged in the entry (364e74b, CHANGELOG 0.20.0-dev).

## structure

`structure` owns child specs, registrations and tree shapes that are wrong on their own: no dependency between processes is needed to see them, only the spec, the name or the call. The lookup-then-start race on a process name is `races.registry_race`, and a permanent child that stops itself normally, under any supervisor, is `shutdown.permanent_child_stops_normally`.

### Supervisor registered as a worker

`supervisor_registered_as_worker`
· titles: "#{sup} registers #{child} as a worker, but it is a supervisor" (`:error`)

**Property.** Some supervisor S's child list holds a spec that states `type: :worker` explicitly, and the spec's start module declares the Supervisor behaviour (`behaves_as`, so Erlang's `-behaviour(supervisor)` counts). The type decides the default shutdown: a supervisor child gets unlimited time to take its own subtree down, and a worker gets a finite one (5 s). Registered as a worker, the supervisor is killed part-way through terminating its children, and its grandchildren are orphaned rather than terminated. They keep running, holding what they held, with no supervisor above them (RabbitMQ e40387e4).

**Assumptions and limits.**
- Only a spec that states its type counts. The `{Module, args}` and bare-module shorthands state none, so `Module.child_spec/1` decides, and `use Supervisor` gets it right. The extractor writes `worker` as those shorthands' default, and before the rule required a stated type it reported 26 modules, every one that artefact (3b597f2).
- The child is the module in the spec's `start` MFA. A spec that starts a supervisor through a helper module's function is missed.
- The child must declare the Supervisor behaviour. A DynamicSupervisor or ConsumerSupervisor callback module declares its own, and Elixir's `DynamicSupervisor`, `PartitionSupervisor` and `Task.Supervisor`, started directly, are usually outside the analyzed modules, so a worker-typed spec for any of them is missed.
- The legacy Erlang six-tuple spec (`{Id, StartMFA, Restart, Shutdown, Type, Modules}`) is not read, and neither is a spec handed to `supervisor:start_child/2`. That is how RabbitMQ built its specs, so the motivating instance itself is out of reach.
- A spec that says `type: :worker` but also `shutdown: :infinity` escapes the orphaning, and is still reported.

**Fixtures.** Positive: `SupAsWorker`. Quiet: `SupShorthand`, which lists the same child `SubSupervisor` by shorthand (`test/fixtures/supervision_fixture.ex`). Asserted in `test/analyses/structure_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** It went from 26 false positives to 0 when the rule began requiring a stated type, and it finds nothing on the corpus, which is expected: Elixir's shorthand resolves the type correctly (3b597f2).

### ConsumerSupervisor template restarts finished children

`consumer_supervisor_permanent_child`
· titles: "ConsumerSupervisor template restarts finished children" (`:warning`)

**Property.** A module declaring the ConsumerSupervisor behaviour has a child template whose restart is `:permanent`, either stated or taken as the default when the spec states none. A ConsumerSupervisor starts one child per event, and the child exits `:normal` when it is done. A permanent template starts each finished child straight back, where it fails again, consumes demand and counts toward the restart intensity until the supervisor gives up (gen_stage#195).

**Assumptions and limits.**
- A shorthand template (`{Module, args}` or a bare module) is taken as `:permanent` even when the module's own `child_spec/1` declares `restart: :temporary` (`use GenServer, restart: :temporary`). That shape is a false positive the rule does not suppress.
- Only the ConsumerSupervisor behaviour is recognised. A plain Supervisor or DynamicSupervisor running one-shot permanent children is `shutdown.permanent_child_stops_normally`'s.
- A template child that returns `{:stop, :normal, _}` is also reported by `shutdown.permanent_child_stops_normally` at `:info`.

**Fixtures.** Positive: `SupervisionShapes.PermanentConsumers`. Quiet: `SupervisionShapes.TemporaryConsumers` (`test/fixtures/supervision_shapes_fixture.ex`), asserted in `test/analyses/structure_test.exs`; `Quiet.TransientConsumers` (`test/fixtures/quiet_shapes_fixture.ex`), asserted in `test/analyses/quiet_shapes_test.exs`.

**Corpus.** Fix pairs: None (gen_stage#195 is cited in the rule; it is not in `test/corpus/pairs.exs`). Present-only: None.

**Precision.** Not measured.

### Process name registered by two modules

`duplicate_process_name`
· titles: "Process name registered by two modules" (`:error`)

**Property.** Two distinct modules each contain a function that registers the same literal name. A registration is `Process.register/2`, `:erlang.register/2`, the `name:` option of a GenServer, GenStateMachine, Supervisor or Agent start, or the `{:local, n}` / `{:global, n}` of an Erlang `:gen_server`, `:gen_statem`, `:supervisor` or `:gen_event` start. A global name is spelled apart from the local atom, so the two never collide. Registration is exclusive: whichever process registers second crashes with an `ArgumentError`, or its start returns `{:error, {:already_started, pid}}`, so at most one of the two can run at a time.

**Assumptions and limits.**
- Identity is the registering module, not the process. Two modules that each start the same server under the same name, alternative entry points of which only one runs, are reported. So are implementations that configuration chooses between, and a test double that registers the production name (test code is not excluded).
- Only literal names count. A name computed at runtime, a `{:via, ...}` name and a `Registry` key take no part (738e945: literal Registry keys are rare, and the interesting collisions use dynamic keys).
- The same module registering one name at two sites, or one named module listed as a child of two trees, is not this rule's: the rule compares modules, and a child spec's name is not a registration.

**Fixtures.** Positive: `ProcessRegisterer` with `DuplicateRegisterer`, both registering `:my_process`. Quiet: `ProcessRegisterer` alone, which registers two distinct names (`test/fixtures/process_registry_fixture.ex`). Asserted in `test/analyses/structure_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured.

### :global registration without a conflict resolver

`global_register_risk`
· titles: ":global registration without conflict resolution" (`:warning`)

**Property.** Some function calls `:global.register_name/2`, the form with no resolve function. After a network partition heals, both halves hold the name, and `:global`'s default resolution keeps one holder and kills the other, chosen at random: the survivor's state is kept and the loser's is lost by coin flip.

**Assumptions and limits.**
- Only a direct `:global.register_name/2` counts. A `name: {:global, n}` start (which registers with the same default) and `:global.re_register_name/2` are missed.
- Any `register_name/3` is taken as deliberate, including one that passes `&:global.random_exit_name/3`, the default itself. The quiet fixture is that shape.
- The rule does not ask whether the program runs distributed.

**Fixtures.** Positive: `GlobalRegisterModule.register/2`. Quiet: `GlobalRegisterModule.register_with_resolve/2` (`test/fixtures/distributed_fixture.ex`). Asserted in `test/analyses/structure_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not measured. It fired on `register_name/3`, the fixed form, until e198d08.

## races

`races` owns check-then-act races on shared state, after Christakis and Sagonas (PADL 2010): a read of a process name, an ETS key or a Mnesia record decides a write of the same thing, nothing holds it between the two, and another process can write it in the window. The read and the write may sit in different functions; they meet where the read's result is born or returned to (`CheckThenAct`), and the finding's `func` is that meeting function. It also owns two ETS races that are not check-then-act, a value published in one table before the row it points to and a row acted on after another process may have removed it; table ownership, options and lifecycle belong to `ets`, and an ETS call left bare where its sibling call sites guard it belongs to `failure`.

### Lookup-then-start race on a process name

`registry_race` · create_api=`register`, `start_link`, `start`, `start_via`, `registry_register` or `start_child`
· titles: "Lookup-then-start race on a process name" (`:warning`)

**Property.** Some function f in which the answer of a name lookup (`Process.whereis/1`, `:erlang.whereis/1`, `Registry.lookup/2`, or `Process.registered/0`, which reads every name at once) decides, directly or through helpers, arguments and later loop iterations, a claim of the same name in the same registry: `register/2`, a start with `name:` or `{:local, n}`, a `{:via, Registry, ...}` start, `Registry.register/3`, or a `start_child`, whose name hides in the child spec, so that any lookup whose answer is tested against nil counts for it. Nothing takes the losing outcome: no comparison with `:already_started` or `:already_registered` and no rescue of ArgumentError (Erlang's `catch` included) in f or in the act's function, no such comparison in a function that calls either, and neither in a function that returns their result on; nor is the act a named start that can fail whose `{:error, {:already_started, pid}}` nothing reads on its way back to f (then whichever start won holds the name the program goes on with). And f runs in more than one process (`RunsConcurrently`): two process entries reach it, or an entry with many instances does (a LiveView, a Channel, a DynamicSupervisor child, a Broadway processor, a task started per message), or a request entry does, or no process entry reaches it at all (a plain API every caller runs). Two callers that look in the same window both see the name free and both claim it; one start returns `{:error, {:already_started, pid}}` or `register/2` raises ArgumentError, and nothing handles it.

**Assumptions and limits.**
- The act must depend on the lookup (run because of a test on its answer, or be handed a value made from it); a start that merely follows a lookup is not the shape. The lookup and the act name the same thing only when they agree on registry, key source and key once parameters are renamed across calls; a name read from a map field or a dynamic value does not cross a call, and the pair goes quiet.
- An unknown higher-order call (`Fun(M)` on a parameter) is not followed, the paper's evaluated setting (`padl2010_higher_order:foo/3`). Names that cannot be shown equal are not a pair (`unrelated/2`).
- The loser's outcome counts as taken when `:already_started` or `:already_registered` is compared anywhere in the function, and when a rescue of ArgumentError sits anywhere in it, not only around the act: over-approximate on purpose, in the quiet direction.
- A process module started as several named instances by a static supervisor counts as one process, so a race among those instances is missed. The owner deciding on its own registry from its own callbacks is one process and is not reported.
- `GenServer.whereis/1`, `:global.whereis_name/1` and `:global.register_name/2`, Horde and `:pg` lookups are not lookups here; a `{:global, n}` start never agrees with a local lookup.
- Suppressed: a loser handled in the function, the act's function or a caller; a `register/2` inside an Erlang `catch` (inet_gethost_native's shape); a named start whose failed answer the program drops and then goes on by name (ssh_dbg's `switch/2`); a worker `init/1` spawns once.
- One finding per meeting function and name. The evidence is the lookup, as a related frame.

**Fixtures.** Positive: `CheckThenAct.WhereisThenStart`, `AgentWhereisThenStart`, `LookupThenStartChild`, `WhereisThenRegister`, `ManyInstances`, `LaterClauseName`, `OwnerSpawnsClaims`, `RegisterIfUnlisted`, `LookupHelper`, `StartHelper`, `DispatchHelper`, `AcrossModules` with `NameDirectory` and `NameStarter` (test/fixtures/check_then_act_fixture.ex); `:padl2010_proc_reg`, `:padl2010_registered`, `:padl2010_higher_order` `known/1`, `:registry_losers` `ensure/0` (test/fixtures/erl/). Quiet: `CheckThenAct.HandlesAlreadyStarted`, `HandlesAlreadyRegistered`, `CallerHandlesAlreadyStarted`, `AgentHandlesAlreadyStarted`, `RescuesArgumentError`, `OwnerRegisters`, `OwnerSpawnsClaimer`, `UncheckedWhereisThenStart`, `DifferentNames`, `HelperTakesLoser`, `HelperOtherName`; `:registry_losers` `server_init/0` and `switch/0`; `:padl2010_higher_order` `foo/3`, `call_foo/0` and `unrelated/2`. Asserted by test/analyses/registry_race_test.exs and test/analyses/padl2010_race_test.exs; test/analyses/quiet_shapes_test.exs also runs the relation over the quiet fixtures.

**Corpus.** Fix pairs: `tesla#768` (elixir-tesla/tesla, 727cb0f → 8cf7745, Tesla.Mock). Present-only: none.

**Precision.** One row in the corpus tally of 2026-09-25 (after 1a571e2), the tesla#768 pre tree. At introduction the rule found no registry race on the corpus (bff3308); when `races` became a concern it reported one registry race over the corpus and four large programs (f115fc7, CHANGELOG `### races`). The `key_source` entry (2cba34d, CHANGELOG) counts 14 name-race findings "across the corpus", a different population from the tally. Maintainer notes (2026-09-22) record present-only shapes in hobby apps (mailgun_logger, appcenter-dashboard) that are not pairs. Not sampled and judged.

### Lookup-then-unregister race on a process name

`registry_race` · create_api=`unregister`
· titles: "Lookup-then-unregister race on a process name" (`:warning`)

**Property.** Some function f in which the answer of `whereis` (or `Process.registered/0`) decides `Process.unregister/1` or `:erlang.unregister/1` of the same locally registered name when the answer says the name is taken, with no rescue of ArgumentError (or Erlang `catch`) in f or in the function that unregisters, and f runs in more than one process. Between the lookup and the unregister the name can go: its process exits and is unregistered with it, or another caller unregisters it first, and `unregister/1` then raises ArgumentError in a process that meant only to release the name. This is the second registry warning of Dialyzer's `-Wrace_conditions` (removed in OTP 25), which the paper itself does not describe.

**Assumptions and limits.**
- The window the name's own process opens by exiting exists even when f runs in one process; the rule reports only when f runs in more than one, so a single process racing the named process's exit is missed.
- Only the local registry is covered: `Registry.unregister/2` and global names are not acts.
- The rescue is asked of the whole function, as for the start race.
- It shares the start race's dedupe key (meeting function and name), so a function that both starts and unregisters one name after one lookup yields one finding.

**Fixtures.** Positive: `CheckThenAct.UnregisterIfPresent` (test/fixtures/check_then_act_fixture.ex); `:dialyzer_whereis_unregister` `stop/1` (test/fixtures/erl/dialyzer_whereis_unregister.erl). Quiet: `CheckThenAct.UnregisterRescued`; `:dialyzer_whereis_unregister` `stop_caught/1`. Asserted by test/analyses/registry_race_test.exs and test/analyses/padl2010_race_test.exs.

**Corpus.** None.

**Precision.** No row in the 2026-09-25 corpus tally. Not measured.

### Read-then-write race on an ETS key

`ets_check_act`
· titles: "Read-then-write race on an ETS key" (`:warning`)

**Property.** Some function f in which the answer of a deciding read of table T at key K (`:ets.lookup/2`, `lookup_element/3`, `member/2`, or `match/2` and `match_object/2` on the key) decides or feeds, directly or through helpers, arguments and loop iterations, a plain write of T at K (`insert/2`, `delete/2`, `delete_object/2`, `update_element/3`), where:
- another process can write T: T was created `:public` under that name (`public_table`), whether it reaches f by name or as the reference `:ets.new/2` returned, or T is a table parameter no caller in view fills, a library user's table, which the finding names `param N`; and
- f runs in more than one process, or, where f runs in one, some write of T that can land on K runs, after that process has started, in a process other than f's (another entry's, or a caller's outside the program through `open_entry`); a writer that only removes rows does not count against a pair whose write makes no row; and
- the race is not one both racers win, and the row is not one only its holder writes (both below).

Two processes that read in the same window act on the same stale answer: one increment vanishes, both insert a first row, both are told they claimed the key, the older value lands last, or a delete removes the row another process just put back.

Races both racers win are not reported, unless the program also writes T back at the pair's key, by storing what a read returned, by `update_counter`, or by inserting a row that holds an `:atomics` or `:counters` array it then counts in:
- a delete decided only by whether the row is there (an invalidation), a delete on a table every row of which is a refill (losing a cached copy is a miss), and any `delete_object`, which deletes only the object it names;
- a refill: a value a call or a read of another store computes (the cache-aside `[] -> v = load(k); insert(t, {k, v})`), both racers computing the same thing, unless the call mints the value (a random API, a unique integer, a ref) and the function hands it out, when each racer returns its own and only one is stored;
- a trip: a value made of neither the read nor a call, not guarded by a comparison of the row with the value written, with no send, outside effect or other shared write under the decision, and a decision that stays in the program (no caller branches on the function's result, no exported function hands it out; a spec returning one literal atom says the result carries no decision). A claim handed to a caller, a guard on the row's contents and a marker whose decision also sends are reported.

Rows only their holder writes are not reported: when every write that can make a row of T keys it by a value minted there (a reference, a monitor, a unique integer), and the pair's write makes no row (`update_element`, a delete), many processes running the pair are many holders at their own rows (Postgrex.Parameters' shape).

An operation that is the whole body of an accessor (one ETS operation on a named table and no other shared-state operation, as mnesia_lib's `set/2`) is judged at the accessor's call: the pair meets in the function that calls the accessor, and when the accessor takes its key as a parameter, only over a key that function holds as a variable and hands to both sides. The finding's read and write are then those calls. One finding per write: of the pairs a write is in, the least read and meeting function; the other reads deciding it and the same race's later writes in one function are related frames (`ets_race_frame`, roles `read` and `also_writes`, at most four).

**Assumptions and limits.**
- A table is known by the atom given to `:ets.new/2`, named or not: two unnamed public tables created with one atom are one table to this rule (the `ets_table` identities that `ets_missing_row` and `ets_publish_order` use are not read here). A public table created out of view, by a dependency or under a name computed at runtime, is not known to be public, and the pair is quiet.
- An inserted object's key is its first element, or element N on a table made with `keypos: N`. A `select` match spec and a match whose key is a wildcard name no key; a key read from a map field, a local value or a dynamic one does not cross a call. Both go quiet.
- The other writer of a one-process pair must spell the table's name; a write through a table parameter or a reference is not counted (a false negative). A writer reached from other processes only through an `init/1` or an Application's `start/2` is taken to run before the pair's process starts.
- "Made of the read" is data dependence alone; a send made in a helper the decision calls is not counted (supavisor's circuit breaker, which tells the other nodes, stays quiet). Where a minted key goes after it is made the facts do not say, so a program that hands one minted key to several processes is not seen.
- Known limit (races.dl comment): a read and a write of one literal row through parameter accessors both called in one function (`n = read_counter(:c)`, `set_counter(:c, n + 1)`) is not reported.
- `open_entry` misses a module a library both calls itself and hands its users through a function it never calls.
- `insert_new/2`, `update_counter` and `select_replace/2` are the atomic forms and the fix; they are never the act.

**Fixtures.** Positive: `CheckThenAct.PublicCache`, `LaterBranchKey`, `BroadwayCount`, `RecordTable`, `MatchThenWrite`, `TokenMint`, `IdMint`, `RefillWrittenBack`, `Claim`, `SerialsOk`, `NotifyOnce`, `LockRelease`, `CounterClobber`, `WindowCounters`, `HeldParametersNamed`, `HeldParametersInsert`, `HandedCounters`, `GvarAccessors` (`add/2`), `SerialAccessors`, `HelperCache`, `CachedTwice`, `UnnamedTable`; `SerializedSessionCache` alone or with `SessionAdmin`, `SessionImporter` or `SessionReaper`; `SerializedTouch` with `TouchClient` and `TouchImporter`; `SeedingOwner` and `SerializedCounter` with `CountImporter` (test/fixtures/check_then_act_fixture.ex); `:padl2010_ets_inc` and `:padl2010_loop` (test/fixtures/erl/). Quiet: `CheckThenAct.InsertNewCache`, `ProtectedOwnerOnly`, `DifferentKeys`, `CacheRefill`, `CacheWithHits`, `Trip`, `BreakerTrip`, `ExpiringCache`, `LockReleaseObject`, `HeldParameters`, `HeldSessions`, `HandedCountersFixed`, `FetchedTable`, `GvarAccessors` (`maybe_work/0`, `running?/0`, `level/0`); `SerializedSessionCache` with `SessionAccounts`; `SerializedTouch` with `TouchClient` and `TouchReaper`; `SeedingOwner` and `SerializedCounter` alone or with `VersionStamper`. Asserted by test/analyses/ets_check_act_test.exs and test/analyses/padl2010_race_test.exs; test/analyses/quiet_shapes_test.exs also runs it over the quiet fixtures.

**Corpus.** Fix pairs: `hammer#94` (ExHammer/hammer, f86fe7e → 8c7a5b2, Hammer.Backend.ETS); `hammer#129` (ExHammer/hammer, 7dcff06 → 252029e, Hammer.Atomic.LeakyBucket). Present-only: none.

**Precision.** 19 rows in the 2026-09-25 corpus tally, counted per checkout: Hammer 12 over three checkouts, Sequin 4 over three (`Sequin.Functions.TestMessages`), ztlp 2, blockster_v2 1. Judged: every Hammer row is a race (5819e47: the three `hit/5`s #130 fixed, `FixWindow.inc/4` and `set/4` it missed, and the ETS backends' lookup-then-insert; CHANGELOG `### Check-then-act, read closer`); ztlp's `RateLimiter` and `RegistrationAuth` are unserialized lookup-then-inserts, one run in a task per UDP packet (dece7d0, d5d5361); blockster's `claim_sync_slot/2` is a claim reported by design (41a2ae3); the Sequin rows are unjudged. False positives removed on the way: `Postgrex.Parameters.put/3` in every Postgrex tree (26d48dc), blockster's two settings caches (0e44564), supavisor's `CircuitBreaker.record_failures/3` (9d17082), nerves_hub_web's `CLISessionCache` and ztlp's `AdminApiRateLimiter` (dece7d0, "ETS rows 10 to 7"). On OTP's mnesia, kernel and stdlib the accessor rule took 34 findings to 4: three read-modify-writes of a shared variable and a guarded maximum over a serial (24aa6ab); whether mnesia's own locks order those writes the rule does not see (d5d5361).

### Uniqueness check then insert race on a Mnesia table

`mnesia_check_act` · kind=`unique`
· titles: "Uniqueness check then insert race on a Mnesia table" (`:warning`)

**Property.** Some function f in which a dirty read of table T that finds records by something other than their key (`:mnesia.dirty_index_read/3`, `dirty_index_match_object`, `dirty_select`, or `dirty_match_object` whose key is a wildcard) decides a `dirty_write` of a record not made of what the search returned, and another process can write T in the window: f runs in more than one process and is not serialized by a `:global.trans/2` lock every writer of T takes, or f runs in one process and some writer of T (a dirty write, a transaction's write, or `dirty_update_counter`) runs in a process other than f's. Two callers that search in the same window both find nothing and both insert, each under a key of its own: the table keeps the duplicate the search was there to prevent, and neither write overwrites the other.

**Assumptions and limits.**
- Never excused as a trip both racers win, as a key read's constant fill is: the racers write different records.
- A write is reported once, at its strongest kind, and `unique` ranks first; the same read's weaker pairs on other writes are not reported apart.
- The shared Mnesia assumptions of the read-then-write class below (one writer per node, the cluster lock, dirty activities) apply.

**Fixtures.** Positive: `CheckThenAct.MnesiaIndexThenWrite`, `MnesiaUniqueQuiet` (reported despite its name) (test/fixtures/check_then_act_fixture.ex). Quiet: none specific to the kind. Asserted by test/analyses/mnesia_check_act_test.exs.

**Corpus.** None.

**Precision.** 3 rows in the 2026-09-25 corpus tally, all blockster_v2 at e8b3d3c: an idempotency check by secondary index before inserting a referral earning (the live and the backfill path) and an X-account uniqueness check by `dirty_match_object` (44f4c12, 1a571e2). Maintainer notes (2026-09-23) classify the index and match check-then-inserts as true positives. Not otherwise sampled.

### Read-then-write race on a Mnesia record

`mnesia_check_act` · kind=`lost_update`, `guarded`, `claim` or `delete`
· titles: "Read-then-write race on a Mnesia record" (`:warning`)

**Property.** Some function f in which a dirty read of table T at key K (`dirty_read/1,2`, `dirty_match_object` on the key, or `:mnesia.read` inside `async_dirty` or a `sync_dirty` activity) decides or feeds, through helpers, arguments, loops and records handed in whole, a dirty write of the same record (`op`: `dirty_write`, `dirty_delete` or `dirty_delete_object`), where another process can write T in the window (as for the uniqueness race), and the pair is not one both racers win. Dirty operations bypass Mnesia's transactions and locks; `kind` says what the interleaving costs:
- `lost_update`: the write stores a value made, by data, of what the read returned (the paper's snmp time-stamp counter), and one of two updates vanishes;
- `guarded`: the decision compares a field of the record past its key with the value the write stores (ztlp's serial check), and two updates can both pass and the older land last;
- `claim`: the read found nothing, the write marks the record taken, and the decision reaches a caller that branches on it or an exported function whose spec does not return one constant, so two callers can both be told they won; a get-or-create that answers with the record it read or wrote, an upsert whose read picks one of two writes, and a value a call computes under the decision are not claims;
- `delete`: the read decides a dirty delete on a table the program also writes back from a read or counts in, and the delete can remove a record another process wrote back in between.

The four share a title, a remedy (read and write in one `:mnesia.transaction/1`, or `dirty_update_counter/3` for a counter) and one defect, a dirty read-modify-write another writer interleaves; the prose names the cost. Not reported: a dirty delete on a table nothing writes back (deleting twice is deleting once), and a trip, a constant record not guarded by the record's contents, with no send or other write under the decision and a decision that stays in the program (an idempotent ensure-default).

One finding per write, at its strongest kind, then at the read in the write's own function (a read further up that a fresh read beside the write shadows is a frame), then the least read. The other reads, the same race's later writes in one function, and, for a pair one process runs, the writers outside that process are related frames (`mnesia_race_frame`, roles `read`, `also_writes`, `other_writer`, at most four).

**Assumptions and limits.**
- A table only one process writes is not reported, and "one process" is one per node: a locally registered owner runs on every node and a replicated table is written by each node's owner, which the rule does not see, since whether a table is replicated is `create_table`'s copies lists, computed at runtime (acc5196).
- A pair in a closure built where `:global.trans/2` is called, or in a private function only such closures call, is serialized when every writer of T is; the lock's identity is not compared, so writers under different locks are taken as serialized (quiet direction). One unlocked writer keeps the finding.
- A dirty activity is dirty only for the closure's own calls; a helper it calls is not known to run in the activity.
- A record's key is compared by identity (a literal, a parameter, an element of one, a local value with one definition); a key two definitions reach is dynamic and the pair is quiet. A record handed in whole names its table by its first element, as the callers' tuples say.
- Transactions and `dirty_update_counter` are the fixes and never the act, but count as other writers and as write-backs.

**Fixtures.** Positive, with the kind asserted where given: `CheckThenAct.MnesiaCounter` (`lost_update`), `MnesiaPutElem`, `MnesiaRecordUpdate`, `MnesiaHelperUpdate`, `MnesiaHelpers` (`lost_update`), `MnesiaShadowedRead` (`lost_update`), `MnesiaTwoBranches` (`lost_update`), `MnesiaCachedTotals` (`update_a/2`, `update_b/2`: `lost_update`), `MnesiaAsyncDirty`, `MnesiaComputedKey` (`guarded`), `MnesiaClaim` (`claim`), `MnesiaRecordHelper` (`claim`), `MnesiaMatchThenWrite`, `MnesiaExpireCounted` (`delete`), `MnesiaExpireSaved`, `MnesiaExpireHits`; `MnesiaGlobalLock` with `MnesiaLockBypass`; `MnesiaOwner` with `MnesiaOwnerResetter`, `MnesiaOwnerTxnResetter` or `MnesiaOwnerCounter` (test/fixtures/check_then_act_fixture.ex); `:padl2010_time_stamp` and `:padl2010_snmp_shadow_table` (`lost_update`, test/fixtures/erl/). Quiet: `CheckThenAct.MnesiaPutElemKey`, `MnesiaExpire`, `MnesiaJoinedKey`, `MnesiaTransaction`, `MnesiaUpdateCounter`, `MnesiaOtherKey`, `MnesiaRecordOther`, `MnesiaEnsureDefault`, `MnesiaGlobalLock` alone, `MnesiaOwner` alone. Asserted by test/analyses/mnesia_check_act_test.exs and test/analyses/padl2010_race_test.exs.

**Corpus.** Fix pairs: `elvengard_ecs@1118693` (elvengard-mmo/elvengard_ecs, 20c5297 → 1118693, ElvenGard.ECS.MnesiaBackend). Present-only: `blockster_v2@e8b3d3c` (rubyad/blockster_v2, e8b3d3c, BlocksterV2.EngagementTracker); `ztlp@39fa329` (priceflex/ztlp, 39fa329, subdir ns, ZtlpNs.Store).

**Precision.** 35 rows in the 2026-09-25 corpus tally: 33 in blockster_v2 at e8b3d3c, one each in elvengard_ecs and ztlp. The three pairs are judged real (a double spend across helpers, a serial check both updates pass, an insert-if-absent). The per-write rework took blockster from 44 findings to 41 and describes its rows one by one (1a571e2, CHANGELOG `### races`); the rest of blockster's rows are not individually judged.

### Dirty write fills a Mnesia record on a stale read

`mnesia_check_act` · kind=`fill`
· titles: "Dirty write fills a Mnesia record on a stale read" (`:info`)

**Property.** Some function f in which a dirty read of table T at key K decides a dirty write of a record computed afresh: not made of the read, not after a search, not guarded by the record's contents, and either a decision that stays in the program, one branch of an upsert, a value a call computes only because of the read (cache-aside), or a get-or-create that answers with what it read or wrote. The pair is not harmless: the program writes T back from a read or counts in it elsewhere, or the decision does more than write (a send, an outside effect, another shared write that is not the upsert's other branch), or, for the last three shapes, the decision reaches a caller. Another process can write T in the window. A write another process makes between the read and the fill is overwritten by a value computed before it: weaker than a lost update, since every racer would compute the same fill, but it can undo an update.

**Assumptions and limits.**
- A fill whose read also decides a stronger race on another write is that race's other branch and is not reported apart; fills fanning in to one write site (several getters through one save helper) are one finding.
- The Mnesia assumptions of the read-then-write class apply.

**Fixtures.** Positive: `CheckThenAct.MnesiaCachedTotals` (`save/2`, reached from `get_total/1` or `get_parts/1`), `MnesiaGetOrDefault` (`get/1`, not a claim) (test/fixtures/check_then_act_fixture.ex). Quiet: `MnesiaEnsureDefault` (a trip on a table nothing writes back); `MnesiaHelpers`' `[]` branch (the lost update's other branch). Asserted by test/analyses/mnesia_check_act_test.exs.

**Corpus.** None.

**Precision.** 5 rows in the 2026-09-25 corpus tally, all blockster_v2 at e8b3d3c (`UnifiedMultiplier.save_unified_multipliers/2`, `EngagementTracker.update_user_rogue_balance/4` and `get_user_x_multiplier/1`, `TelegramBot.PromoEngine.get_or_reset_daily_state/0`, `BotSystem.DevSetup.seed_pool/2`). 1a571e2 folded six findings at unified_multiplier.ex:485 into one fill and three at engagement_tracker.ex:1717 into another. Not judged.

### ETS row published before the row it points to

`ets_publish_order`
· titles: "ETS row published before the row it points to" (`:warning`)

**Property.** Some function f writes, on its own stack (its own inserts, or its callees' that run on the same stack, not code it hands to another process), a row of table A holding a value V past its key (`{name, id}`), and later in one trip through f, not merely around a loop, the row of a different table B keyed by V (`{id, name}`). Some read of A hands out what it found, and some function g reads B with an operation that raises on a missing row (`:ets.lookup_element/3`, `:ets.update_counter/3`) at a key that can hold V: made from a read of A, or from a source whose origin the program does not show (a parameter of an exported function or of one taken as a fun, a call nothing summarises). g has no handler that takes ArgumentError, B is readable by other processes, and g can run while f is between the two writes: f or g runs in more than one process, or g runs in a process that does not run f. A reader that finds V in A before B's row exists crashes with ArgumentError (badarg); the fix is the order, B's row first, then V, deleting the row a losing `insert_new` wrote.

Tables are `ets_table` identities: a named table by its name, an unnamed one by the `:ets.new/2` site that made it (followed as process points-to follows a pid), and, only where neither is known, the module and map path a parameter's table is read under. The two tables must not possibly be one (then one row replaces another).

**Assumptions and limits.**
- A value that is a literal is known without reading A and publishes nothing.
- Two calls to two other modules' writers, with no insert in f itself, are not ordered: which functions of another module insert is not known while f's module is extracted.
- The reader's rescue is asked of the reader's whole function, not of the read.
- Only inserts publish: removing B's row before V leaves A (the unpublishing twin) is not covered.
- BEAM puts no call inside a loop body within one function, so the loop case has no fixture (5c40a43).

**Fixtures.** Positive: `PublishOrder.MapFields`, `NamedTables`, `CountedById`, `LocalPair`, `SameFieldTwoMaps`, `HelperCompletes`, `KeyFromFirst` (test/fixtures/publish_order_fixture.ex). Quiet: `PublishOrder.ReverseFirst`, `LocalPairSafe`, `HelperFirst`, `KeyFromElsewhere`, `DefaultedReader`, `RescuedReader`, `PrivateTables`, `OwnerOnly`, `SameKey`. Asserted by test/analyses/ets_publish_order_test.exs; test/analyses/quiet_shapes_test.exs runs it over `ReverseFirst`, `LocalPairSafe`, `HelperFirst` and `KeyFromElsewhere`.

**Corpus.** None in pairs.exs. Argus reported the shape in its own `Argus.Symbols.ETS.intern/2` at 0bf9543, fixed in 6fc3a59.

**Precision.** No corpus row at introduction (1d1b6ee: tally unchanged at 1,143 rows) or in the 2026-09-25 tally. The one known row is a true positive: in argus's own `intern/2`, four readers resolving ids as they appeared saw 3,000 to 6,000 badargs per 20,000 keys (6fc3a59).

### ETS row acted on after another process may have removed it

`ets_missing_row`
· titles: "ETS row acted on after another process may have removed it" (`:warning`)

**Property.** Some function f in which a deciding read of table T at key K (`lookup`, `lookup_element`, `member`, `match`, `match_object`) decides, in f or through helpers and across modules, an operation on T at K that raises when the row is missing (`:ets.update_counter/3`, `:ets.lookup_element/3`), where:
- no handler that takes ArgumentError covers the act, or a call on every path of calls from f down to it, nor every call to f (when f is private and never handed out as a fun);
- T is readable by other processes: made where the program shows and not private, or a named table the program does not show being made; and
- some operation that deletes rows of T (`take`, `delete`, `delete_object`, `select_delete`, `match_delete`, `delete_all_objects`, or deleting the table), at a key that can be K, can run while f is between the check and the act: f runs in more than one process, or the remover runs in a process that does not run f (a timer's `apply_after` counts as a process of its own).

Another process takes or deletes the row between the check and the act, and the act raises ArgumentError (badarg) in a process that meant only to update the row (sequin's DebouncedLogger, whose timer flush takes the bucket its `log/4` counts into).

**Assumptions and limits.**
- A remover's key is asked only to rule it out: one removing `self()`'s row does not race a pair keyed by `self()`, nor a literal row, and a literal remover takes only that row, not another literal's nor the rows kept beside it under keys callers pass. A remover whose key the facts cannot equate, such as a flush keyed by what a timer was handed, counts.
- A named table made out of view (by a dependency, or under a name from config) is taken as shared: nothing says it is private (2e1a812).
- A named table and an `:ets.new/2` site cross every call unchanged; a table a module keeps under a field of its own crosses calls within the module.
- The rescue walk follows calls at most 16 deep, and an act further down is taken as rescued; a closure or fun is asked of the call it is handed to, and one handed to a process start runs elsewhere.
- A remover only a caller outside the program runs does not count when f runs in one process.
- Quiet: an act with a default (`update_counter/4`, `lookup_element/4`), a rescued miss, and one process doing all of it.

**Fixtures.** Positive: `MissingRow.Debounce` with `Debounce.Config`, `InlineTupleKey`, `NameFromConfig`, `UnrelatedRescue`, `OneCallerRescues`, `OwnRowReaped`, `SentinelRow` (`total/0`), `HelperAct`, `HelperCheck`, `CrossModuleAct` with `Counter` (test/fixtures/missing_row_fixture.ex). Quiet: `MissingRow.WithDefault`, `Rescued`, `OneOwner`, `HelperRescue`, `CallerRescues`, `OwnRow`, `SentinelRow` (`hit/1`). Asserted by test/analyses/ets_missing_row_test.exs; test/analyses/quiet_shapes_test.exs runs it over `OneOwner`.

**Corpus.** Fix pairs: none. Present-only: `sequin@46ce4e1` (sequinstream/sequin, 46ce4e1, Sequin.DebouncedLogger).

**Precision.** One row in the 2026-09-25 corpus tally, the sequin pair, live at upstream HEAD; maintainer notes (2026-09-22) judge it a real race with the timer's `:ets.take`, fixed by `update_counter/4` with a default. Not otherwise measured.

## state_machine

`state_machine` reads a gen_statem as a graph of states and transitions and reports states no transition enters and states no transition leaves. It is scoped to `state_functions` mode, where each state is a callback function the extractor can name; in `handle_event_function` mode states are data values, and no graph is built. A message, timeout or call that a state does not handle, and a `{:call, from}` clause that never replies, are `mailbox`'s.

### Unreachable state

`unreachable_state`
· titles: "Unreachable state #{state}" (`:warning`)

**Property.** Take a module that declares `:gen_statem` (or GenStateMachine) and whose `callback_mode/0` resolves to `state_functions`. At least one of its transitions names its target literally, and none computes it at runtime, in a state function or in a helper. A state S (a state function: exported, arity 3, not a standard callback, never called locally, and returning a gen_statem action; or a state some transition names) is entered by no transition from another state, by no helper's `{:next_state, S, …}`, and is not the initial state. The initial state is what `init/1` returns in `{:ok, State, _}`. Only when that is computed, a state that has transitions of its own but no incoming one is taken as initial. The machine can never enter S: S is dead code, or a transition that should produce it is missing.

**Assumptions and limits.**
- A state's own `keep_state` or `repeat_state` return, and a `next_state` naming itself, is a self-loop: no way in (`ClosedForeverStatem`'s `abandoned`, whose catch-all keeps the state).
- A transition a function that is not a state function returns (`statem_helper_transition`: a Redix-style `disconnect/2` returning `{:next_state, :disconnected, …}`, a lifted closure) is a way in from an unnamed state (`HelperTransitionStatem`). It errs quiet: a helper no state calls still counts.
- A single transition to a computed state, a state function's or a helper's, silences the whole module, since it could land anywhere. The rule does not fall back to the states a dynamic target could be. A state name a helper carries in a tuple that is not an action (h2's `{ok, goaway_received, _}` which a caller drops) is not a transition, which is how h2's dead state is found.
- A state entered only from `:gen_statem.enter_loop/4,5`, or from an `init/1` that returns through a helper, has no initial state read. The topological fallback then takes any state with transitions of its own and no incoming one for initial, so a dead state that transitions out escapes.
- A state function whose body only delegates to a helper returns no action of its own and is not a state at all. A machine with no resolved transitions produces no findings (`DelegatingStatem`).
- Modules that do not declare the behaviour, and `handle_event_function` machines, are not judged.

**Fixtures.** Positive: `OrphanStateStatem` (`abandoned/3`), `ClosedForeverStatem` (`abandoned/3`, a keep-state catch-all). Quiet: `OrphanStateStatem`'s `idle` (the `init/1` state, with no incoming edge) and `running`; `HelperTransitionStatem` (`disconnected`, entered only through a helper); `RestingStatem`; `SimpleStatem`, `DelegatingStatem` and `HandleEventStatem` (`test/fixtures/gen_statem_fixture.ex`). Asserted in `test/analyses/state_machine_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** The July 2026 audit of 15 OTP libraries found 108 gen_statem structural findings, all false. The causes were every arity-3 function taken as a state, a topologically guessed initial state, and atoms harvested as states in `handle_event_function` mode. After the fixes there were 0 findings on that corpus (ed26d0a, 44375ed; CHANGELOG 0.5.0 "Fixed (precision — 15-project OTP corpus audit)"). Round 2 of the mining (2026-09-25) ran it over OTP's ssl, kernel and ssh, ejabberd and the 19 gen_statem libraries in the corpus checkouts: 2 rows, both dead states. h2 0.12.1's `goaway_received` is never entered (`handle_frame` returns `{ok, goaway_received, _}` and `process_frames` drops the name for `determine_state_transition`'s `connected`/`settings`); webtransport 0.4.6's `connecting` ("for client sessions") is entered by no transition, and init/1 returns `open` or `draining`. Chatterbox's `closing`, reported before, is entered through a helper and is quiet now.

### Terminal state that never stops

`terminal_without_stop`
· titles: "Terminal state #{state} never stops" (`:info`)

**Property.** Take a gen_statem module in `state_functions` mode with at least one transition to a literal state. A state S with an exported arity-3 function is entered from another state (a transition from a state other than S, or a helper's `{:next_state, S, …}`) and is not the initial state, and S has no way out: none of its returns is a transition to another state or a stop, and none returns what a call returns that may be one. A machine that enters S stays there. Unless S is a deliberate resting state, the process idles forever, one leaked process per machine that reaches S.

**Assumptions and limits.**
- A `keep_state` or `repeat_state` return, and a `next_state` naming S, is a self-loop and no way out: the resting state this class describes returns only these (`ClosedForeverStatem`'s `closed`).
- A state function that returns what a call returns leaves for whatever the callee may return (`statem_returns_call`): a local helper's transitions, followed through the helpers it returns the result of in turn, or anything at all for a remote call, an apply or a throw (gen_statem takes a thrown value as the result). `HelperTransitionStatem`'s `connected` leaves only through `disconnect/2`, and its `waiting` returns another module's answer in one clause: both quiet. A raise in tail position returns nothing and is no way out: the compiler ends most map-updating functions with a `{:badmap, _}` raise, and a state that crashes on a malformed event still never leaves (encore's `abyss` updates a map).
- A machine that never leaves its initial state is a server with one state (`RestingStatem`), not a machine stuck in a terminal one: the initial state is not judged.
- A state is judged by its exported arity-3 function, recognised as a state or only named by a transition because it returns no action of its own: a function that hands every event to a helper is judged by what the helper returns (`DelegatedAbyssStatem`, encore's Rondo.Broken `abyss`, delegating to a private keep-state helper, is reported; ssl's `hello`, delegating to another module, may leave). A state named only by transitions with no such function in the module is not judged; that missing function is an `undef` crash no rule reports yet.
- The finding is `:info`, and its prose says to ignore a deliberate resting state.

**Fixtures.** Positive: `ClosedForeverStatem` (`closed/3`), `DelegatedAbyssStatem` (`abyss/3`). Quiet: `HelperTransitionStatem`, `RestingStatem`, `SimpleStatem`, `DelegatingStatem`, `HandleEventStatem` (`test/fixtures/gen_statem_fixture.ex`). Asserted in `test/analyses/state_machine_test.exs`; the relations the rules read in `test/extractors/gen_statem_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Part of the 108 → 0 above (ed26d0a). Before round 2 every recognised state function was non-terminal by construction, and the rule's positives were extraction gaps: over OTP's ssl, xandra and pgo it made 6 rows, all states whose function it did not recognise (ssl's `hello` and `user_hello`, reached through `tls_gen_connection`). Round 2 made self-loops no way out and judges a state by its function's returns and delegations: 0 rows over OTP's ssl, kernel and ssh, ejabberd and the corpus's 19 gen_statem libraries, with the fixtures' resting states caught and encore's seeded `abyss` still reported (now at `abyss/3` rather than at the transition naming it). No true positive is known outside the fixture.

## ets

`ets` owns ETS table ownership, concurrency options and lifecycle: a table that dies with the process that owns it, a table read from callers' processes while its owner restarts, options that do not suit how the table is shared, a table that only grows, and an unnamed table held by a process. The read-then-write race on an ETS key and the other races on ETS rows (a row published before the row it points to, a row acted on after another process may have removed it) belong to `races`; a named table nothing uses belongs to `coverage` (`coverage_ets_unused`). Tables are known by the atom given to `:ets.new/2`, and a table whose name is computed at runtime takes part only where a rule says so.

### Table dies with its owner

`ets_unprotected_owner`
· titles: "ETS table dies with its owner" (`:warning`)

**Property.** Some `:ets.new/2` call, of a table whose name is a known atom (named or not), sits in a function of a module that declares a behaviour, and the table has no `heir` option, while that module is not an Application, is not a permanent child of any supervisor in view, and is not started under a DynamicSupervisor. ETS deletes a table when the process that owns it exits: after one crash of the owner the table and every row in it are gone, and with no permanent supervisor to run the `:ets.new/2` again, readers get ArgumentError until something recreates it.

**Assumptions and limits.**
- The owner is taken to be the creating function's module, and "is a process" to be "declares any behaviour" (a plug's or a type's included), not the process that runs the `:ets.new/2`: a table created in an API function a caller's process runs is attributed to the module, and a table created in a plain spawned process is not reported (encore chaconne's `Chaconne.Scratch`, a documented false-negative probe).
- A permanent child is excused because its restart recreates the table; the rows are still lost on every crash, which the finding's prose describes but the excuse does not weigh. A library's process whose supervisor is the user's, out of view, is reported.
- The creation site is joined to the owner by the table's atom, not by the owner's own function, so a name created in two modules can pair one module's owner with the other's site.
- When the `:ets.new/2` options cannot be read, the table looks as if it had no heir and is reported.
- The idiomatic unnamed table in a server's state is reported here and by `ets_unnamed_in_process` at the same `:ets.new/2`.
- One finding per table and owner module, anchored at the `:ets.new/2`.

**Fixtures.** Positive: `EtsOwner` (test/fixtures/ets_fixture.ex), asserted by test/analyses/ets_test.exs and test/findings_test.exs. Quiet: `EtsOwner` beside `EtsPermanentSupervisor` or `ErlangStyleEtsSupervisor`, and `EtsApplicationOwner` (test/fixtures/ets_fixture.ex), asserted by test/analyses/ets_test.exs. No test asserts that a heir silences it (`EtsWellConfigured` has one, but no assertion reads its row).

**Corpus.** None.

**Precision.** 15 rows in the corpus tally of 2026-09-25 (after 1a571e2), counted per checkout, at six creation sites: `DBConnection.ConnectionPool.init/1`, `Postgrex.Protocol.queries_new/0`, `Redix.Connection.init/1`, `Supavisor.ClientAuthentication.RefreshLimiter.init/1`, `Supavisor.PeepStorage.new/1` and a closure in it. Three of the six are unnamed tables `ets_unnamed_in_process` also reports at the same site. Unjudged on the corpus. In encore, chaconne's `Chaconne.Orphan.init/1` is hand-verified (frozen 2026-08-12), and three heirless named tables are pinned quiet by the permanent-child excuse.

### Table read while its owner may be restarting

`ets_read_outside_owner`
· titles: "ETS table read while its owner may be restarting" (`:info`)

**Property.** Some table T is created by an `:ets.new/2` in a function a process's own callbacks reach (the owner's process), with no `heir` option, and some read of T that raises when the table is gone (every read but `:ets.info/1,2`; `take` included) sits in a function the owner's callbacks do not reach, such as the module's API, run in callers' processes. T is named at the read, or passed as a literal through the reader's table parameters, and no handler that takes ArgumentError (a rescue of ArgumentError or `:badarg`, a bare rescue or `catch :error`, or Erlang's `catch`) sits in the reader, or, for a read inside a closure, in the function that built the closure or in a function that builder calls (a rescuing wrapper the closure is handed to). A table under a name computed at runtime is tied only to reads of computed-name tables in its owner's own module. From the moment the owner crashes until its restart reaches `:ets.new/2` again, the read raises ArgumentError in the caller instead of returning a value; Redix.Cluster's callers saw exactly that during a `:one_for_all` restart (redix#338).

**Assumptions and limits.**
- "The owner's callbacks reach" is call-graph reach from the process's callbacks, not reach within its process: a function both the owner's callbacks and callers' processes call is taken to run in the owner, and so is a closure the owner hands to another process, so those reads are missed.
- The rescue is asked of the reader's whole function, not of the read: a rescue around unrelated code in the reader silences it.
- A read through a table reference held in state or a variable, rather than a literal name passed through parameters, is not tied to T.
- Whether the owner restarts at all is not asked; an owner that never comes back makes the window permanent, which the finding still describes.
- One finding per owner module and reader function, anchored at the read, with the `:ets.new/2` as a related frame.

**Fixtures.** Positive: `EtsOwners.Owner`, `EtsOwners.HelperOwner` with `EtsOwners.Helper` (test/fixtures/ets_reader_fixture.ex); `:ets_catch_reader` `peek/1` (test/fixtures/erl/ets_catch_reader.erl). Quiet: `EtsOwners.GuardedOwner`, `ClosureGuardedOwner`, `HeirOwner`, `InsideOwner`, `InfoOwner`, `BadargOwner`, `DynamicOwnerNamedRead`; `:ets_catch_reader` `lookup/1`; `Quiet.RescueAllReader` (test/fixtures/quiet_shapes_fixture.ex). Asserted by test/analyses/singleton_shapes_test.exs and test/analyses/quiet_shapes_test.exs.

**Corpus.** Fix pairs: `redix#338` (whatyouhide/redix, b77331e → b31bd23, Redix.Cluster.Manager). Present-only: none.

**Precision.** 37 rows in the 2026-09-25 corpus tally, counted per checkout, at 21 reader functions in bb, commanded, db_connection, ecto, phoenix, phoenix_pubsub, postgrex, redix and ztlp; unjudged as a set. Corpus reading removed three false-positive shapes (6527007): `:ets.info` reads in ztlp's and nerves_hub_web's `count/0`, postgrex's `catch :error, :badarg` soft read, and computed-name tables joined to every read in the owner's module. Making `:ets.take/2` a read added bb's `BB.Command.ResultCache.fetch_and_delete/1`, judged real (dcdf78c).

### Table without read_concurrency

`ets_missing_read_concurrency`
· titles: "Table without read_concurrency" (`:info`)

**Property.** Some table, known by its atom, is read (by any read operation) from functions of at least two different modules, and an `:ets.new/2` that creates it lacks `read_concurrency: true`; the finding sits at each such creation site. When many processes read the table at once they contend on its lock; for a read-heavy table shared across processes the option is close to free. A performance hint whose right setting depends on the access pattern.

**Assumptions and limits.**
- Two modules stand in for two concurrent processes: reads from two modules may all run in one process, and the common contended case, one module's read run by many processes, is not seen.
- The table's access mode is not asked.
- When the `:ets.new/2` options cannot be read, the option looks absent and the hint fires.

**Fixtures.** Positive: `EtsSharedCounters` with `EtsSharedCountersClient`. Quiet: `EtsSharedTuned` with `EtsSharedTunedClient` (test/fixtures/ets_fixture.ex). Asserted by test/findings_test.exs ("the concurrency hints anchor at the table's :ets.new").

**Corpus.** None.

**Precision.** No row in the 2026-09-25 corpus tally. encore chaconne pins it at zero (its shared table sets the option; its other tables are read by one module each). Not measured.

### Table without write_concurrency

`ets_missing_write_concurrency`
· titles: "Table without write_concurrency" (`:info`)

**Property.** Some table, known by its atom, is written from functions of at least two different modules (any write: `insert`, `insert_new`, `delete/2`, `take`, `delete_object`, `delete_all_objects`, `update_element`, `update_counter`, `select_delete`, `select_replace`, and the administrative `give_away`, `rename` and `setopts`), and an `:ets.new/2` that creates it sets neither `write_concurrency: true` nor `:auto`; the finding sits at each such creation site. Concurrent writers serialize on one lock; for a write-heavy table the option reduces contention at the cost of slightly costlier reads.

**Assumptions and limits.**
- Two modules stand in for two concurrent processes, as for the read hint.
- The administrative operations count as writes, so a module that only hands the table away or sets its options is a writer.
- When the `:ets.new/2` options cannot be read, the option looks absent and the hint fires.

**Fixtures.** Positive: `EtsSharedCounters` with `EtsSharedCountersClient`. Quiet: `EtsSharedTuned` with `EtsSharedTunedClient` (test/fixtures/ets_fixture.ex). Asserted by test/findings_test.exs.

**Corpus.** None.

**Precision.** No row in the 2026-09-25 corpus tally; encore chaconne pins it at zero. Not measured.

### Ordered set written from several modules

`ets_ordered_set_contention`
· titles: "ordered_set shared across modules" (`:info`)

**Property.** Some table created with type `ordered_set` is written (any write, as above) from functions of two different modules; the finding sits at the `:ets.new/2`, once per pair of writer modules. `ordered_set` operations are O(log n) and contend harder than a hash table's under concurrent writers; the hint asks whether the ordering is needed.

**Assumptions and limits.**
- `write_concurrency` is not asked, though an `ordered_set` with it (OTP 22 and later) uses a tree built for concurrent writers.
- Two modules stand in for two concurrent processes; reads do not count, although the prose says the table is "accessed" by both modules.
- A table written from n modules gets n(n - 1)/2 findings at one site.

**Fixtures.** Positive: `EtsSharedCounters` with `EtsSharedCountersClient`. Quiet: `EtsSharedTuned` with `EtsSharedTunedClient`, a `set` (test/fixtures/ets_fixture.ex). Asserted by test/findings_test.exs.

**Corpus.** None.

**Precision.** No row in the 2026-09-25 corpus tally; encore chaconne pins it at zero (its protected `ordered_set` has one writer module). Not measured.

### Table that only grows

`ets_write_only_table`
· titles: "ETS table #{name} only grows" (`:info`)

**Property.** Some table created with `:named_table` is inserted into (`insert` or `insert_new`, by its name) from a function not named `init`, and nothing removes rows from it: no `delete` of a key or of the table, `delete_object`, `delete_all_objects`, `select_delete`, `match_delete` or `take` on that name anywhere in the program, and no removal through a table reference of unknown name in the creating module. Every insert stays for the owner's life, which for a supervised process is the VM's: when entries have a natural end (a request completing, a check-in resolving), the table is a slow memory leak (Sentry's check-in ID mapping was one).

**Assumptions and limits.**
- Whether the inserted keys are bounded is not asked: a table written under a fixed set of keys, such as a configuration table, replaces rows rather than growing, and is reported (encore fugue's `:fugue_config`).
- "Outside init" is by name: a function named `init` of any arity in any module counts as filling at start, so a table filled in some other module's `init` and then only read is quiet; inserts in `handle_continue/2` count as growth.
- Inserts whose table the extractor cannot name (a reference it does not resolve), and rows made by `update_counter/4` with a default, are not counted, so such tables are missed.
- A removal on any reference of unknown name in the owner's module is taken as possibly this table (the quiet direction). Unnamed tables are not considered.

**Fixtures.** Positive: `EtsGrowOnly`. Quiet: `EtsBounded`, `EtsWarmCache` (test/fixtures/ets_fixture.ex). Asserted by test/analyses/ets_test.exs.

**Corpus.** None.

**Precision.** 7 rows in the 2026-09-25 corpus tally, counted per checkout, at five creation sites of four tables (`Postgrex.SCRAM.LockedCache`'s table, ztlp's `:ztlp_ns_antientropy_metrics` at two sites and `:ztlp_ns_registration_rate_limit`, blockster_v2's `:altcoin_analyzer_cache`); unjudged. In encore, chaconne's three heirless named tables (`:chaconne_ordered`, `:chaconne_bag`, `:chaconne_dupbag`) are hand-verified as correct, and fugue's `:fugue_config` is hand-verified as a bounded configuration table the rule cannot tell apart (both 2026-09-11).

### Unnamed table held by a process

`ets_unnamed_in_process`
· titles: "Unnamed table held by a process" (`:info`)

**Property.** Some `:ets.new/2` without `:named_table`, for a table whose atom is known, sits in a function of a process module (one declaring a process behaviour, or defining `handle_call`, `handle_cast` or `handle_info` under some behaviour). The table is reachable only through the reference `:ets.new/2` returned: if the owner drops the reference or never shares it, nothing else can read or clean up the table, and a reference other processes hold stops working when the owner restarts. Often deliberate, hence `:info`.

**Assumptions and limits.**
- Attributed to the creating function's module, not to the process that runs it.
- Whether the reference is kept in state, handed out, or deleted is not asked.
- When the `:ets.new/2` options cannot be read, the table looks unnamed and is reported.
- It fires with `ets_unprotected_owner` at the same site for the common table kept in a server's state.

**Fixtures.** Positive: `EtsUnnamed`. Quiet: `EtsOwner`, `EtsWellConfigured` (named tables) (test/fixtures/ets_fixture.ex). Asserted by test/findings_test.exs.

**Corpus.** None.

**Precision.** 21 rows in the 2026-09-25 corpus tally, counted per checkout, at seven creation sites (`Commanded.Subscriptions.initial_state/1`, `DBConnection.ConnectionPool.init/1`, `Postgrex.Protocol.queries_new/0`, `Redix.Connection.init/1`, sequin's `Sequin.Telemetry.PosthogReporter.create_table/0`, `Supavisor.Manager.init/1`, `Supavisor.TenantCache.init/1`); unjudged. encore chaconne's `Chaconne.Orphan.init/1` is hand-verified (frozen 2026-08-12).

### Named ETS table created in a server's start function

`ets_created_in_start`
· titles: "Named ETS table created in start_link fails the server's restart" (`:warning`)

**Property.** A process module M (`process_behaviour_module`) has an exported `start_link/1` that itself starts a server (a GenServer, `:gen_server`, gen_statem, GenStateMachine, GenStage, Agent or Supervisor start), and on that function's own stack (`SameProcessReach`: not in what it spawns or the server runs) a `:ets.new/2` with `:named_table` runs, which none of M's own callbacks, `init/1` included, reach. `start_link` runs in whoever starts the server, its supervisor when M is a child, so the table belongs to the supervisor, not to M's process. It outlives M's crash, and the restart calls `start_link` again in the same supervisor: `:ets.new/2` raises ArgumentError on a name that is still taken, the child cannot restart, and the supervisor retries until its restart intensity is spent and exits. Tests rarely restart a child, so the bug shows up in production at the first crash.

**Assumptions and limits.**
- The start function is recognised by name and shape (`start_link/1` of a process module that makes a server start), not by a child spec: a library's server is started by its users' supervisors, which the program does not contain (ex_uid2). A custom start function named otherwise, or a `start_link/2`, is missed.
- Not judged, each pinned by a quiet fixture beside the positive it differs from: a start function that asks first (`:ets.whereis/1` or `:ets.info/1` in the function that creates the table or in `start_link`: `EtsStart.AsksFirst`), one that rescues the ArgumentError at the call (`EtsStart.Rescues`), one that gives the table away (`EtsStart.GivesAway`), an unnamed table, which a second create does not collide with (`EtsStart.Unnamed`), and a module whose child spec says `restart: :temporary` (`EtsStart.Temporary`). The existence check is read per function, not as a decision on the create: a `whereis` anywhere in either function quiets the finding.
- A shorthand child spec's own restart is read from the module's `child_spec/1` (`child_spec_restart`); a restart overridden only in the parent's child list is not.
- A table made in `start_link` on purpose, to survive the server's restarts, needs the existence check to be correct; without it the second start fails the same way, so the shape is reported.
- The Plug variant, a table created in a plug's `init/1` that Plug.Builder runs at compile time, is not covered (lowendinsight, backlog).
- One finding per creation site, anchored at the `:ets.new/2` call, with the start function as a related frame.

**Fixtures.** Positive: `EtsStart.InStart` (ex_uid2's shape), `EtsStart.InHelper` (through a helper), `EtsStart.InSupervisorStart` (a supervisor's own start_link) (test/fixtures/ets_start_fixture.ex). Quiet: `EtsStart.InInit` (the fix), `EtsStart.AsksFirst`, `EtsStart.Rescues`, `EtsStart.GivesAway`, `EtsStart.Unnamed`, `EtsStart.Temporary`, `EtsStart.NotAServer` (same file). Asserted in test/analyses/ets_start_test.exs; each suppression was checked to fail its quiet fixture when removed.

**Corpus.** Fix pairs: `ex_uid2@69e7279` (market-ops/ex_uid2, b3e9fad → 69e7279, `ExUid2.Dsp`: the fix moves the call into `init/1`). Mined but not pairs: blockscout 4ab64a9 (a heavy umbrella), policr-mini 08fb3d8 (a 2021 Phoenix 1.5 tree), nostrum 834b6cd (does not build on OTP 28), joken_jwks d58ba59 (its `start_link` is written into users' modules by a `__using__` macro, so its own tree has no instance).

**Precision.** Over 30 large Elixir trees and OTP's ssl, inets, ssh, kernel, mnesia and stdlib it made one row, OTP's `ssl_dist_sup:start_link/0`, which creates `ssl_dist_opts` in its parent's process when `-ssl_dist_optfile` is set: a real instance of the class.

## effects

`effects` owns an effect where its context forbids it. There are two contracts. `@pure true` is a claim the author writes down, which the analysis reports as violated, unprovable or verified. `Repo.transaction/1` imposes a contract nobody writes down: the closure it runs must do only what the database can undo. Effects that a skipped `terminate/2` loses belong to `shutdown`, and effects that hold up `init/1` belong to `startup`.

### Effect in a function declared pure

`effect_in_context` · context=`pure_contract`
· titles: "#{short(func)} is declared pure but performs #{effect_phrase(category)}" (`:error`). The phrase is "I/O" (`io`), "a process operation" (`process`), "a process-dictionary access" (`process_dict`), "a shared-table operation" (`ets`), "a port or OS interaction" (`port`), "a distribution operation" (`node`), "a clock or counter read" (`time`), "a randomness draw" (`random`), "network I/O" (`network`), "runtime code loading" (`code_loading`), or the bare category name (`logging`).

**Property.** A function f carries `@pure true`, which argus reads from the beam's persisted `argus_pure` attribute. f, or some function f reaches over the call graph, performs an observable effect. The reachable functions include private helpers, applies whose module and function resolve, and closures f builds, because building a closure counts as a call. An observable effect is one of: a call the effect model classifies as impure in either mode (a write, or a read of a clock, the environment or the process dictionary); a `send` instruction; a `receive`; a spawn; an ETS operation or table creation; a port open; or a name registration. `via` names the function that performs the effect, and `site` names the instruction. At run time, the function's result depends on, or changes, state outside its arguments. A caller that memoizes the function, reorders calls to it, or relies on it being free of effects gets wrong behaviour.

**Assumptions and limits.**
- The call graph is complete except for dynamic calls. An unresolved dynamic call is reported as unprovable (next class), never assumed harmless.
- `Argus.Purity.Effects` is a table of module entries with per-function overrides. `Kernel` is deliberately unlisted. A function the table does not override takes its module's category, so some pure functions in impure modules are reported as violations: `:crypto.hash/2` (all of `:crypto` is `random`), `:io_lib.format/2` (all of `:io_lib` is `io`), and `:timer.seconds/1` (all of `:timer` is `process`).
- The purity extractor classifies remote calls, applies and the `bif` and `gc_bif` instructions a guard BIF compiles to. Of those only `self/0` (a process read), `node/0` (a distribution read) and `:erlang.get/1` (a process-dictionary read) are effects; `node/1` computes from its argument and is pure (the model's `classify/3` names pure arities), as are the arithmetic and type-test BIFs (`BifEffects`). Until round 2 no BIF instruction was read, and `:erlang.self/0` was pure by `:erlang`'s default even as a call.
- A call to another function that carries its own `@pure true` is trusted at the call site and checked at that function's definition (modular verification).
- Reach does not look at argument values. An effect that sits only in a clause the function's literal argument never enters still counts.
- One site can produce two findings with the same title. `:ets.insert/2`, `:ets.new/2`, `spawn`, `Port.open/2`, `System.cmd/2` and `Process.register/2` each produce one row from the effect model and one from a bytecode-level fact (`ets_op`, `ets_new`, `spawn_call`, `port_open`, `process_register`). The relation's key includes `api`, so both rows become findings.
- The two spellings of the process dictionary get different categories: `Process.put/2` is `process`, and `:erlang.put/2` is `process_dict`.
- When f also reaches an opaque call, the violation wins and f is not reported as unprovable.

**Fixtures.** Positive: `DirectEffects`, `IndirectEffects`, `EffectfulClosure`, `ResolvedApply` (`shout/1`) and `BifEffects` (`me/0`, `here/0`, `cached/1`), all under `Purity` (test/fixtures/purity_fixture.ex). Quiet: `Clean`, `ResolvedApply.reverse/1` and `BifEffects`'s `owner_node/1` and `head_size/2` (verified), and `Undeclared` (claims nothing, so nothing is reported). Test: test/analyses/effects_purity_test.exs.

**Corpus.** None.

**Precision.** Measured only by running the analysis on argus itself. In 79acf43, argus's annotated functions gave 11 verified, 0 violated and 6 unprovable. A deliberately false annotation on `Argus.Lines.from_facts_dir/1` was reported as violated on `File.read/1`. In c64cad5, `Argus.InstrId` gave six verified and two unprovable. No corpus measurement exists, because `@pure` comes from `Argus.Purity` and is not an annotation a corpus project would carry.

### Purity claim that cannot be checked

`purity_unprovable` · reason=`dynamic_call` | `protocol_dispatch` | `unclassified_call`
· titles: "#{short(func)} is declared pure but the claim cannot be checked" (`:warning`, `dynamic_call`); "#{short(func)} is declared pure but dispatches through a protocol" (`:warning`, `protocol_dispatch`); "#{short(func)} is declared pure but reaches an unclassified call" (`:warning`, `unclassified_call`)

**Property.** A function f carries `@pure true` and reaches no known effect. But f, or some function it reaches, makes a call the analysis cannot account for. `dynamic_call` covers three shapes: a call through a fun value (`call_fun`); an apply whose target does not resolve (`apply`); and `dot_dispatch`. `dot_dispatch` is Elixir's `x.field` on a value not proven to be a map, which compiles to `:elixir_erl_pass.no_parens_remote/2`, or a wrapper that runs what it is handed, such as `:timer.tc`. `protocol_dispatch` is a call into an open protocol: `String.Chars`, `Inspect`, `Enumerable`, `Collectable`, `List.Chars`, `Jason.Encoder`, `Phoenix.HTML.Safe`, `Ecto.Type`, `Kernel.inspect` or `Kernel.to_string`. `unclassified_call` is a remote call that has no entry in the effect model and whose target does not declare `@pure` itself. The claim may hold, but nothing verified it. A checker that let these calls pass would report "verified" for functions that can run arbitrary code. When f reaches neither an effect nor an opaque call, `purity_verified(f)` is emitted as an `:info` finding, "#{short(func)} is verified pure". That finding is not a defect: it tells a verified contract apart from one that was never checked.

**Assumptions and limits.**
- A higher-order pure function, one that calls a fun it is handed, is always unprovable at its definition. This holds even when every caller hands it a pure closure: the call-site check (next class) does not discharge the warning.
- A function is reported once per `(func, reason, detail)`, where `detail` is the call kind or the API. A pure function that reaches twenty unclassified APIs gets twenty warnings.
- The `unclassified_call` remedy is an entry in `Argus.Purity.Effects`. Until the entry exists, each new library call a pure function reaches makes the function unprovable.
- A BIF instruction is an effect or pure, never opaque: every guard BIF is in the model (previous class).

**Fixtures.** Positive: `Purity.Unprovable` (`applies/2` through `call_fun`, `dispatches/3` through `apply`). Quiet: `ResolvedApply.reverse/1`, whose literal apply target resolves and verifies. No fixture pins the `protocol_dispatch` or `unclassified_call` reasons, or the rule that a call to another `@pure` function is not opaque. Test: test/analyses/effects_purity_test.exs.

**Corpus.** None.

**Precision.** Running the analysis on argus (79acf43) gave six unprovable functions. Each reaches `Kernel.inspect/1` or `String.Chars.to_string/1`, which is the correct answer.

### Effectful closure handed to a pure function

`impure_closure_to_pure`
· titles: "#{short(caller)} passes an effectful closure to a function declared pure" (`:error`)

**Property.** A function g declared pure calls a fun it is handed, possibly inside a lifted closure such as `Enum.map(list, fn x -> f.(x) end)`: formally, g reaches a `call_fun`. A function c calls g at site s, c builds exactly one closure k, and k reaches an observable effect. The obligation that g's claim creates falls on its callers, so c is the function that breaks the contract. The finding anchors at s, and the effect inside k is a related frame. At run time, g performs c's effect under a contract that says g has none.

**Assumptions and limits.**
- The closure is tied to the call by containment, not by dataflow. When c builds two closures, nothing is reported. When c builds one closure that goes elsewhere (to `Enum.each`, say) while g receives a named capture, the finding blames the wrong closure. A literal external fun such as `&IO.puts/1` is not a built closure and is never checked.
- g counts as higher-order when it reaches any `call_fun`, including a call on a fun it built itself.

**Fixtures.** Positive: `BadCaller` (with `HigherOrder`). Quiet: `GoodCaller` (with `HigherOrder`). Both are under `Purity` (test/fixtures/purity_fixture.ex). Test: test/analyses/effects_purity_test.exs ("higher-order contracts").

**Corpus.** None.

**Precision.** Not measured.

### Effect a rollback cannot undo, inside a transaction

`effect_in_context` · context=`transaction`
· titles: "#{short(caller)} performs #{rollback_phrase(category)} inside a #{repo} transaction". The severity is `:error` for "network I/O" (`network`) and "an OS or port operation" (`port`). It is `:warning` for "a process operation" (`process`), "file I/O" (`io`), "a shared-table write" (`ets`) and "a distribution operation" (`node`).

**Property.** A function c calls `transaction` at site o on a module that implements `Ecto.Repo` (found by behaviour, not by name), or calls `Postgrex.transaction`. c builds exactly one closure b, and c opens transactions on no other repo. b, or some function b reaches over the call graph, makes a call that the effect model classifies as a write in one of the `durable_effect` categories: `io`, `network`, `process`, `ets`, `port` or `node`. The finding anchors at o, and the effect is a related frame. `scope` names the repo, and `via` names the function that performs the effect. At run time, a rollback leaves the effect behind, and a retry of the transaction repeats it. A network or port call also holds a pooled connection for the length of someone else's latency, which is how a slow dependency becomes pool exhaustion.

**Assumptions and limits.**
- Only writes in durable categories are reported. Logging, configuration and environment reads, clock reads and randomness do not escape the database.
- Only effect-model calls are reported. An Erlang `!` send instruction and a `receive` are not effects here, although purity counts them.
- The body is found by containment, not by dataflow. None of these is a body: a named fun (`Repo.transaction(&do_work/0)`), a fun built in another function and passed in, or an `Ecto.Multi.run/3` callback built outside the function that opens the transaction. In the other direction, a function that hands a Multi to the transaction but builds one unrelated closure has that closure taken as the body.
- A function that opens transactions on two repos has no body, because nothing says which repo runs the closure.
- Reach from the body is unbounded and does not look at argument values. It enters the repo's own code, and its dependencies' code when their beams are in the run. It also follows a fun into another process: a `Task.start/1` in the body is reported with the network call it makes, along with the connection-holding prose.
- The effect model has gaps here too. `:io_lib.format/2` is an `io` write and reads as "file I/O". `:timer.seconds/1` is a `process` write. `Process.sleep/1` is reported, which is intended, because it holds the connection. But its finding says "The message has already been delivered, or the process already spawned", and the connection note appears only for `network` and `port`.

**Fixtures.** Positive: `Unsafe`, `UnsafeIndirect` and `Sleeps` (with `FakeRepo`). Quiet: `LogsOnly`, `ReadsConfig`, `EffectOutside`, and `TwoRepos` (with `AuditRepo`). All are under `Transaction` (test/fixtures/transaction_fixture.ex). Test: test/analyses/effects_transaction_test.exs.

**Corpus.** None.

**Precision.** Commit a72e6be recorded that the first run reported 37 findings on one project, most of them reads (`Process.get/2`, `Application.get_env/2`, `GenServer.whereis/1`). That run motivated the read/write mode. With the mode in place, the corpus gave four findings, each read against source and each real:
- teslamate: a 60-second transaction sleeps 1.5 s per chunk and calls a geocoder.
- sequin: a 90-second transaction runs a retry loop against a customer database.
- keila: a CSV import runs inside one transaction, with `File` I/O and progress sends.
- realtime: a send inside a subscription transaction.

The same commit notes that teslamate's geocoder is behind a module attribute, a dynamic dispatch the rule does not follow.

## unsafe_input

`unsafe_input` owns attacker-shaped data reaching a sink, and processes an outside party can create without limit. There are four sinks: atom creation, deserialization, one-shot decompression and code execution. Each sink site is reported once, with how exposed it is:
- `flow`: request data provably reaches the sink's argument.
- `direct`, `adjacent` or `transitive`: a call path runs from a request surface to the sink.
- The sink is reachable only from the program's own API.

The program's own secrets flowing out belong to `exposure`. Races between the many processes that request entries run belong to `races`, which reads the same `request_entry` vocabulary.

### Unbounded atom creation from untrusted input

`sink_reachable` · sink=`atom`; `sink_without_request_path` · sink=`atom`
· titles: "Unbounded atom creation #{reached(proximity)} #{surface(kind)}". `reached` is "fed by request data from" (`flow`), "directly inside" (`direct`), "one call from" (`adjacent`) or "transitively reachable from" (`transitive`). `surface` is "a Plug (HTTP request)", "a Phoenix controller action (HTTP request)", "a LiveView callback", "a LiveComponent event", "a Phoenix Channel (websocket)", "an Oban job" or "a Broadway pipeline message". Severity is `:error` for `flow` and `direct`, `:warning` for `adjacent` and `:info` for `transitive`. With priors on, an `adjacent` or `transitive` row whose function reads storage, configuration, internal state or a constant drops one step and is marked heuristic. With no request path, the title is "Dynamic atom creation reachable from an exported function" (`:warning`); with priors on, a no-request row whose value `prior_value_source` puts at 0.9 or more away from outside data (a configured name, the program's code, its stored data, its cluster, an operator's input) drops to `:info`, marked heuristic.

**Property.** A call at site s in function g to `String.to_atom/1`, `:erlang.binary_to_atom/1,2` or `:erlang.list_to_atom/1` takes an argument the program does not bound. Bounded means one of the following holds on every path to s:
- the argument is compared equal to a literal (a clause head, a guard's `in`, a `case` arm);
- it is found in a literal list, on the branch where the membership test holds;
- it is built from such a value and literals, or converted from one by a pure conversion (`Integer.to_string/1`, `String.Chars.to_string/1`, `++`, ...);
- it is an integer tested between two ends at most 1,024 values apart (`n in 1..8`, `is_integer(n) and n >= 1 and n <= 8`);
- at an atom sink, it is made of atoms that exist: an atom `is_atom/1` tested, or an atom's name (`Atom.to_string/1`, `atom_to_list/1`), with literals and bounded values;
- it is found in a list parameter that every caller fills with a literal list.

The site is then reported in one of two ways.
- **A request reaches it.** Some request entry e reaches g. The entries are: a Plug's `call/2`; a Phoenix controller's actions; a LiveView's `mount/3`, `handle_params/3` or `handle_event/3`; a LiveComponent's `handle_event/3`; a Channel's `handle_in/3`; an Oban worker's `perform/1`; a Broadway `handle_message/3` or `handle_batch/4`; a ThousandIsland handler's `handle_data/3`; a WebSock handler's `handle_in/2`. The proximity is `flow` when one of e's request-carrying parameters reaches the argument through the per-function derivation summaries: destructuring, tuple and binary building, the known propagators, and an element handed to the closure of a higher-order call. Otherwise it is `direct` (g is e), `adjacent` (e calls g) or `transitive`.
- **No request reaches it.** Some exported function reaches g, and the argument is made of a parameter of an exported function that nothing in the program calls. Process callbacks, Broadway's `process_name/2` and protocol implementations do not count as such functions.

At run time, the atom table is fixed-size (1,048,576 atoms by default) and never garbage collected. Every distinct value an attacker supplies takes a slot for good, until the node aborts and takes every process on it down.

**Assumptions and limits.**
- Request entries are recognised by `@behaviour` plus callback name and arity. Only some parameters carry the request: the conn; a controller action's conn and params; a LiveView event's name and params; `handle_params`' params and URI; `mount/3`'s params but not its session, which the endpoint signs; a component's event and params; a channel's event and payload; an Oban job; Broadway messages; the bytes a ThousandIsland handler reads and the frame a WebSock handler is handed.
- A Phoenix controller's actions are entries of their own (kind `controller`): the call graph enters them only through Phoenix's `action/2`, which applies an action name read from the conn at run time, and argus follows an apply only when its target resolves. A controller is a Plug that defines `phoenix_controller_pipeline/2`; every exported arity-2 function of it other than `call`, `action` and the pipeline counts, routed or not (a function plug the pipeline calls also takes the conn). A Plug that is not a controller has no such entries (`Taint.PlainPlugHelpers`). Until round 2 (2026-09-25) the actions were reachable from no entry, and a sink in one was at best "reachable from an exported function".
- A cookie fetched with `Plug.Conn.fetch_cookies/2` is the server's: the options name the cookies to verify (`signed:`, `encrypted:`), and the propagator table does not carry the conn through that call (`Taint.CookieController`: a signed cookie decoded is quiet, one fetched with `fetch_cookies/1` is a flow). The price is the rest of that conn: its params read after the call are no flow.
- A Channel's `join/3` and a Socket's `connect/3` are not request entries, although their topic, payload and params come from the client.
- The flow summaries do not follow some shapes. A value returned from a local helper, a fun not built at the call, an argument past the fourth, and a value passed through a callee missing from the propagator table all stay a path. A missing flow row is therefore not evidence that the data comes from elsewhere.
- The path proximities do not look at argument values, which is why `transitive` is `:info`. The prior re-tier (`prior_reads` at 0.7 and above) marks only path rows and never removes one. The no-request rows have their own prior (`prior_value_source`, what the converted value is, at 0.9 and above), which also only re-tiers.
- Bounds are checked in the sink's own function. A guard in the request handler, followed by a call to a helper that converts the value, does not bound it. The only bound that crosses a call is a list parameter, and only when every caller fills it with a literal list.
- A range needs both ends and the integer test: `n >= 1 and n <= 8` alone admits every float between. A range wider than 1,024 values bounds nothing.
- An atom made of atoms is one more atom per atom that exists, not one per string a caller sends. A program that feeds the atoms it makes back into the same site grows by a suffix at a time, and is not told apart. The bound is a count only: a deserialization of an atom's name is still reported.
- The no-request arm counts data through any call (`call_arg_reads`), so a caller's input reaching the atom may be over-counted. It excludes configuration, literals, allowlists, a server's own messages and a value that the function's only caller names.
- A site is one finding. A `flow` row replaces the path rows for its site. A later call of the same API on the same source line of one function folds into the first call, unless the first is bounded. That covers both a compiler copy (a body shared by two clause heads) and two conversions written on one line.
- `String.to_existing_atom/1` and a literal argument are not sinks.
- Evidence frames: `sink_endpoint` names the HTTP route (verb and path) from Phoenix's `__routes__/0`. It cannot say whether the route is authenticated, because `pipe_through` is not in the route table. `sink_export` names up to three exported functions within six calls for the no-request arm.

**Fixtures.**
- Positive, `flow`: `DirectPlug`, `AdjacentLiveView` and `TransitiveWorker` under `RequestSurface` (test/fixtures/request_surface_fixture.ex). Also `Controller` (`show/2`, a controller action no call reaches), `FlowLiveView`, `FlowTransitive`, `FlowClosureEnv`, `HofElement`, `OpenAllowlist` (with `Allow`) and `SameLine` (one finding for two sinks on a line) under `Taint` (test/fixtures/taint_fixture.ex).
- Positive, path proximities (never `flow`): `StoreSourcedPlug` (direct), `StoreSourcedAdjacent` (adjacent) and `StoreSourcedWorker` (transitive), plus `SocketOnly` and `SessionOnly` (direct), all under `Taint`.
- Positive, no request path: `UnsafeAtomCreation`, `AtomSources` (`input/1` and the closure in `keys/1`) and `ExportedSinkCaller`, all in test/fixtures/atom_safety_fixture.ex. The no-request path also covers `RequestSurface.NotAnEntryPoint`.
- Positive beside the bounds: `AtomBounds`' `between/1` (no integer test), `from/1` (one end), `wide/1` (100,000 values), `numbered/2` (an atom beside an unbounded integer) and `named/1` (no atom test), and `decode/1`, a deserialization of an atom's name (atom_safety_fixture.ex).
- Quiet: `RequestSurface.SafeCallback`; `Taint.Controller.index/2` (to_existing_atom) and `Taint.PlainPlugHelpers` (a plug's exported helper is no action, and is reported only on the no-request arm); `Taint.LiteralAtom`, `ExistingAtom`, `GuardAllowlist`, `BodyAllowlist` and `ParamAllowlist`; `AtomSources.env_level/0` and `name/1`; `AtomBounds`' `phrase/1` (capriccio's `n in 1..8`), `explicit/1`, `within/1`, `suffixed/1`, `renamed/1` and `renamed_list/1`; `AtomFromMessages` and `AtomProcessName` (atom_safety_fixture.ex); and `Quiet.StoreSourcedSink` (test/fixtures/quiet_shapes_fixture.ex), which must never be a `flow`.
- Tests: test/analyses/unsafe_input_test.exs, test/analyses/quiet_shapes_test.exs, test/evidence_frames_test.exs (`sink_export`, `sink_endpoint`), and test/priors/priors_test.exs (both prior re-tiers); test/priors/value_source_answers_test.exs pins Jev's recorded answers for eight real modules.

**Corpus.** Fix pairs:
- `phoenix_storybook@96d5246` (phenixdigital/phoenix_storybook, 56ab846 → 96d5246, `PhoenixStorybook.Story.Playground`: "Unbounded atom creation fed by request data from a LiveComponent event").
- `phoenix_storybook@96d5246 (StoryLive)` (same commits, `PhoenixStorybook.StoryLive`: "... from a LiveView callback").
- `absinthe_federation#133` (DivvyPayHQ/absinthe_federation, c53bb3b → c3838cd, `Absinthe.Federation.Schema.EntitiesField`).
- `tesla:GHSA-h74c-q9j7-mpcm` (elixir-tesla/tesla, bb1a2c3 → 4699c3c, `Tesla.Adapter.Mint`).
- `membrane_mp4_plugin#135` (membraneframework/membrane_mp4_plugin, 6a7458b → 56373d1, `Membrane.MP4.Container.Header`).
- `nerves_hub_web#2942` (nerves-hub/nerves_hub_web, 0bb6b5c → 3c4bcf5, `NervesHubWeb.API.DeviceController`: "... fed by request data from a Phoenix controller action (HTTP request)"; the devices API's `sort_direction` query param through `String.to_atom/1`, found by round 2 once controller actions were entries).

The absinthe_federation, tesla and membrane pairs pin "Dynamic atom creation reachable from an exported function".

**Precision.**
- In 6448ef4 the no-request title went from 261 rows to 65 over the evaluation programs (four apps, the Phoenix stack, and OTP's kernel, stdlib and mnesia). Before that, a reviewer sampled eight of the 261 rows, and all eight were false. Seven of those leave; logflare's Wobserver `string_to_module/1` stays.
- The 65 are still "mostly library API doing what it is for", with a few real finds (lib/argus/analysis/sets.ex): the vulnerable tesla Mint adapter, logflare's `Ecto.UUID.Atom.cast/1`, and a realtime LiveDashboard page (CHANGELOG unsafe_input).
- In 7bd8963, logflare's SearchLV and hexpm's `safe_to_atom/2` stopped being reported as fed by request data, and livebook's LiveMarkdown.Import guards stopped being reported as transitive. Both were false positives.
- Integer ranges and atoms made of atoms took 13 rows from the no-request title over the evaluation programs and ejabberd and rabbitmq (all of unsafe_input: 323 to 310), each read and bounded: twelve atoms made of atoms (Ecto's `validate_confirmation/3`, logflare's pipeline `name/1` behind `is_atom/1`, erl_lint's `is_` tests, ejabberd's `_sup`, `_cache` and backend names, rabbit's pool supervisors) and erl_scan's `list_to_atom([C])` under a 0..255 guard. encore's capriccio `play/2` (`n in 1..8`) is quiet again.
- `prior_value_source` over the same programs: 232 no-request rows (atoms, deserializations, code execution) read by hand, 212 not outside data; at 0.9 it re-tiers 68% of those at 98% precision and leaves 17 of the 20 outside-data rows, among them tesla's Mint adapter (0.85), OTP's distribution handshake and boot server, and ejabberd's web admin; the three it moves are Livebook's editor completion and git client, its own user's input (lib/argus/priors/questions/value_source.ex).
- The request tiers were calibrated by hand when the request-surface analysis was added (CHANGELOG, request_surface entry). Every `direct` finding was real. `adjacent` was mixed: one real unvalidated URL parameter and one database primary key. Every `transitive` hit examined took its data from storage.
- Controller actions as entries (round 2, 2026-09-25), over the corpus tally: 2 new `flow` rows, both nerves_hub_web's `DeviceController.index/2` (real; the fix pair above); 8 path rows relabelled from a LiveView, a LiveComponent or the no-request arm to the controller (the finding keeps the least entry kind), none new. Over changelog.com, firezone, sentry and exq: 1 new `adjacent` row (changelog's `NewsIssueController.template_for_issue/1`, `String.to_atom("show_#{NewsIssue.layout(issue)}")` of a stored record's layout: a path from storage, the adjacent tier's known false shape), and firezone's six signed-cookie decodes, which read as `flow` until `fetch_cookies/2` stopped carrying the conn (then path rows, as before).

### Unbounded decompression of network bytes

`sink_reachable` · sink=`decompression`; `sink_without_request_path` · sink=`decompression`
· titles: "Unbounded decompression #{reached(proximity)} #{surface(kind)}", severity by proximity as for atoms (`:error` for `flow` and `direct`, `:warning` for `adjacent`, `:info` for `transitive`); with no request path, "Unbounded decompression of a caller's input" (`:warning`).

**Property.** A call at site s in function g to a one-shot decompression, `:zlib.gunzip/1`, `:zlib.unzip/1`, `:zlib.uncompress/1` or `:zlib.inflate/2,3` (`unsafe_decompression`, whose `data_pos` is the compressed data's argument: 0, or 1 for `inflate(Z, Data)`), returns the whole output of its input before anything can look at its size. The site is reported as for atoms: a request entry reaches g (`flow` when one of the entry's request-carrying parameters reaches the data argument, else a path), or, with no request path, the data argument is made of a parameter of an exported function (`outside_api`, the library's users' input: an HTTP client middleware's response body). At run time, a few hundred bytes of layered gzip inflate to gigabytes in the process's heap and the node runs out of memory (Bandit's GHSA-frh3-6pv6-rc8j, Tesla's GHSA-mc85-72gr-vm9f, Req's GHSA-655f-mp8p-96gv).

**Assumptions and limits.**
- The streaming forms that hand back a bounded chunk, `:zlib.safeInflate/2` and `inflateChunk/1,2`, are the fix and no sink (`BoundedFrameHandler`); whether a loop over them checks a cap is not asked.
- Only the data argument is followed (`sink_data_arg`): `inflate/2`'s zstream lives in the handler's state and carries no request.
- No bound the program writes quiets a site: there is no allowlist of compressed blobs. Data the program compressed itself from literals has no parameter to come from and is quiet (`OwnData`).
- A ThousandIsland handler's `handle_data/3` and a WebSock handler's `handle_in/2` are request entries (kinds `socket`, `websocket`), for every sink. Frames parsed out of the socket's bytes through local helpers' returns are a path, not a flow (Bandit's pair is `transitive`, `:info`).
- `:zip` and `:erl_tar` extraction, to memory or to disk, are not sinks yet; neither is an Elixir wrapper the program writes around `:zlib` beyond what the flow summaries follow.
- The no-request arm asks only that a caller's parameter reaches the data, not that the caller's data comes from the network: a library that decompresses what its users hand it is reported, whether they hand it a response body or a file of their own (OTP's `raw_file_io_inflate`, Oban's notifier payloads).

**Fixtures.** Positive: `FrameHandler` (socket, `flow`), `GzipBodyPlug` (plug, `flow`) and `ClientMiddleware` (no request path, its `call/3`'s body) under `Decompression` (test/fixtures/decompression_fixture.ex). Quiet: `BoundedFrameHandler` (safeInflate) and `OwnData` (a literal the program compressed). Tests: test/analyses/unsafe_input_test.exs ("decompression"), test/extractors/atom_safety_test.exs.

**Corpus.** Fix pairs: `tesla:GHSA-mc85-72gr-vm9f` (elixir-tesla/tesla, db963db → 340f75b, `Tesla.Middleware.Compression`: "Unbounded decompression of a caller's input"; the fix streams through safeInflate under a required `:max_body_size`), `bandit:GHSA-frh3-6pv6-rc8j` (mtrudel/bandit, fc3cf61 → 8156921, `Bandit.WebSocket.PerMessageDeflate`: "... transitively reachable from a ThousandIsland handler (socket data)"; the fix inflates with safeInflate under `max_inflate_ratio`). Req's advisory (automatic decompression by default) is not a pair: its sink stays behind an opt-in.

**Precision.** Round 2 (2026-09-25), read against source. Corpus tally: 10 rows, all no-request: Tesla's middleware in four checkouts before its fix (8, gunzip and unzip, real) and Oban's `Notifier.decode/1` (2, the payloads of its own Postgres notifications: false). Beyond the tally: changelog.com's `UrlKit.get_body/1` (gunzip of an arbitrary URL's response, reached from an Oban job, `transitive`: real), EMQX's rule-engine `gunzip/1`, `unzip/1` and `zip_uncompress/1` (SQL functions over MQTT payloads a client publishes: real), hex_hub's `RegistryFormat.decode_etf/1` (plausible), hexpm's `DownloadGeoip` mix task (a trusted URL: false), and OTP's `code:try_decompress/1`, `raw_file_io_inflate` (two) and `erl_tar:open1/4` (local files: false). About half the no-request rows are libraries decompressing what the caller hands them from a source of its own.

### Untrusted deserialization

`sink_reachable` · sink=`deserialization`; `sink_without_request_path` · sink=`deserialization` · safety=`unsafe` | `atoms_only` | `dynamic`
· titles: when a request reaches the call, "#{deserialization_title(safety)} #{reached(proximity)} #{surface(kind)}", with the proximity severities of the atom class. `deserialization_title` is "binary_to_term without :safe" (`unsafe`), "binary_to_term with [:safe] and no shape check" (`atoms_only`) or "binary_to_term with options not known statically" (`dynamic`). With no request path, the title is the bare `deserialization_title`: "binary_to_term without :safe" (`:error`), "binary_to_term with [:safe] and no shape check" (`:warning`), "binary_to_term with options not known statically" (`:error`).

**Property.** A call at site s to `:erlang.binary_to_term/1,2` takes a data argument the program does not bound. No option list clears the call. The `safety` column records what the options were:
- `unsafe`: `binary_to_term/1`, or a literal option list without `:safe`.
- `atoms_only`: a literal option list that includes `:safe`.
- `dynamic`: options computed at run time.

The site is reported by request proximity as for atoms. When no request reaches it, it is reported unconditionally, with no condition on reachability. `Plug.Crypto.non_executable_binary_to_term` and `Plug.Crypto.safe_binary_to_term` walk the decoded term and are never sinks. At run time, untrusted bytes intern unbounded atoms and create funs, ports and references. `[:safe]` blocks new atoms and references to unloaded modules. It does not block a fun that references a module already loaded, and that fun runs as soon as the term is enumerated or called (Paginator CVE-2020-15150).

**Assumptions and limits.**
- With no request path, every deserialization is reported, including one that reads the program's own trusted bytes: a cache file it wrote, or a term it stored itself. No caller-input test applies here, unlike the atom sink. With priors on, such a row whose bytes `prior_value_source` puts at 0.9 or more away from outside data (dets, disk_log and message-store files, an Ecto type's stored term, a Redis the cluster writes) drops to `:warning`, marked heuristic: 71 of the 87 no-request rows over the evaluation programs, ejabberd and rabbitmq.
- The option class comes from a literal. A list computed at run time is `dynamic` and `:error`.
- The request-surface and flow limits of the atom class apply unchanged.
- Severity is inverted between the two relations. An `unsafe` call that a request reaches transitively is `:info`, while the same call with no request path is `:error`.

**Fixtures.** Positive: `UnsafeDeserialization` (`decode_unsafe/1`, `decode_atoms_only/1`). Quiet: `UnsafeDeserialization.decode_validated/1` and `SafeModule.safe_decode/1`. All are in test/fixtures/atom_safety_fixture.ex. The request-reachable and `dynamic` titles are pinned only by the `finding/2` unit tests. Test: test/analyses/unsafe_input_test.exs.

**Corpus.** Fix pairs:
- `paginator#16` (duffelhq/paginator, 3142b9f → 01ed029, `Paginator.Cursor`: "binary_to_term without :safe", which the `[:safe]` fix clears).
- `paginator:non-executable-binary-to-term` (duffelhq/paginator, 24237ba → b4945c6, `Paginator.Cursor`: "binary_to_term with [:safe] and no shape check").

**Precision.**
- The 2026-07-17 audit of the OTP-library corpus (maintainer notes) checked the predecessor analysis. It found libcluster's Gossip `binary_to_term` real and exploitable over the network, and swarm's real but in dead code.
- With 143a233, a `[:safe]` call no longer carries the false title "without :safe".
- A reported `flow` hit is sequin's `HttpPushSqsPipeline.handle_message/3`, which decodes Broadway message data with `[:safe]` (maintainer notes). It is listed there without a judgement.

### Dynamic code execution

`sink_reachable` · sink=`code`; `sink_without_request_path` · sink=`code`
· titles: "Dynamic code execution #{reached(proximity)} #{surface(kind)}" (proximity severities as for atoms); "Dynamic code execution reachable from exports" (`:error`)

**Property.** Function g calls one of: `Code.eval_string/1,2,3`, `Code.compile_string/1,2`, `:os.cmd/1,2`, `System.shell/1,2`, or `System.cmd/2,3`. For `System.cmd/2,3`, the command must be non-literal, or a literal shell or interpreter (`sh`, `bash`, `python`, `erl`, `elixir` and the like) whose arguments are not literal. The call is reported by request proximity as for atoms. Otherwise it is reported when some exported function reaches g. At run time, if caller data reaches the argument, arbitrary code runs inside the node with all of the VM's privileges.

**Assumptions and limits.**
- A code sink has no bound, no flow requirement and no caller-input test. `:os.cmd(~c"uname -a")` or `Code.eval_string` on a literal is reported. The no-request arm asks only whether the code is live. With priors on, a no-request row whose command `prior_value_source` puts at 0.9 or more away from outside data (a mix task's, a build step's, an admin command's) drops to `:warning`, marked heuristic: 11 of the 27 no-request rows over the evaluation programs, ejabberd and rabbitmq.
- A literal non-interpreter program is never a sink, whatever its arguments, because argv is not parsed by a shell. Injection through arguments to such a program, such as a `git` option, is not reported.
- `Code.eval_quoted`, `Code.eval_file`, `EEx.eval_string`, `:erl_eval` and `Port.open({:spawn, cmd}, ...)` are not sinks.
- `sink_endpoint` names routes for atom and deserialization sinks only. A code sink's finding never gets a route frame.

**Fixtures.** Positive: `CodeExecution` (`eval/1`, `os_cmd/1`, `system_cmd/2`). Quiet: `CodeExecution.static_system_cmd/0`, and `SafeModule`. Both are in test/fixtures/atom_safety_fixture.ex. The fixture also defines `static_command_dynamic_args/1`, `static_command_no_args/0` and `shell_with_dynamic_script/1`, which no test asserts on. Tests: test/analyses/unsafe_input_test.exs; the extraction is tested in test/extractors/atom_safety_test.exs.

**Corpus.** None.

**Precision.** Not measured. The only recorded correction is from the predecessor analysis: `System.cmd/2,3` with a literal command stopped being reported, and `System.cmd("free", [])` had been a false positive (CHANGELOG, `atom_safety`'s `code_injection_risk`).

### Unbounded process creation from a request

`unbounded_children_from_request`
· titles: "#{sup} starts #{child} without limit, on request" (`:error`)

**Property.** Function v starts a child on a supervisor s. The start is either `DynamicSupervisor.start_child/2`, or one of Task.Supervisor's `start_child`, `async`, `async_nolink`, `async_stream` or `async_stream_nolink`, in which case the child is recorded as `Task`. s is named by an atom, by a via name the extractor resolves, or by the enclosing supervisor module when the argument does not resolve. Some request entry reaches v over the call graph. No finite `max_children` is read from a `DynamicSupervisor.init/1` in s's own module. And s is not a dependency's transport supervisor that the endpoint leaves disabled: `Phoenix.Transports.LongPoll.Supervisor` is exempt unless some endpoint's literal socket options enable long polling. The finding anchors at v, with s as a related frame. At run time, the number of live children grows with the number of requests, with no ceiling. Each costs a pid, a mailbox and a heap, and the node runs out of memory in a way that looks like ordinary load.

**Assumptions and limits.**
- Reach does not look at argument values. A request that reaches v only on a branch it never takes, such as an admin-only event, is still reported, at `:error`.
- A supervisor held as a pid resolves to "dynamic" and is skipped. Process points-to does not follow `start_child`'s supervisor argument.
- The cap is read only from the supervisor module's own `DynamicSupervisor.init/1`. A cap given in an inline child spec (`{DynamicSupervisor, name: ..., max_children: n}`) or to a Task.Supervisor is not read, and counts as uncapped. So does an `init/1` that cannot be read. That is the deliberate choice for a resource bound, and it matches the default.
- The long-poll supervisor is the only dependency transport the rule knows.
- The finding's prose names `DynamicSupervisor.start_child/2` even for a Task.Supervisor start.
- There is one finding per `(sup, child)`.
- Tasks a function starts only through Task.Supervisor's `async_stream` or `async_stream_nolink` (`task_supervisor_start`) are not judged: the stream runs at most `max_concurrency` of them at a time for the process that enumerates it, and waits for each, so they live no longer than the request (`StreamLive`; supavisor's health-check endpoint). A function that also starts tasks another way keeps its row (`TaskLive`, `Task.Supervisor.start_child/2` from a request, still fires).
- A start whose caller then waits for the child to exit is still reported: Livebook's `UniqueTask.run/2` starts a child per key under a `DynamicSupervisor`, monitors it and blocks for its `:DOWN`, so the children live no longer than their requests; reached from a controller since round 2, it is 2 rows over the corpus (a false shape a wait on the start's `:DOWN` would discharge).

**Fixtures.** Positive: `PublicLive` (with `UncappedSup` and `Worker`), `TaskLive`. Quiet: `CappedLive` (with `CappedSup`), `Internal` and `StreamLive`. All are under `UnboundedChildren` (test/fixtures/unbounded_children_fixture.ex). Test: test/analyses/unsafe_input_test.exs ("unbounded children"). The disabled-transport arm has no analysis fixture; test/extractors/endpoint_test.exs pins the `socket_transport` extraction it reads.

**Corpus.** None.

**Precision.** At introduction (2d74381), every one of the 8 projects swept set no cap, and findings were few. The recurring one was Phoenix's long-poll transport, which starts a server per unauthenticated request. It was reported in three projects and enabled in one, which is why the disabled-transport exemption exists. Livebook's `SessionSupervisor` was reported from a LiveView. No sample has been judged since.

## exposure

`exposure` owns credentials that leave protection without anyone deciding they should. That happens in two ways: an Ecto schema field holding a secret that `inspect/1` prints in full, and a TLS connection that encrypts without authenticating the peer. The concern covers the program's own secrets going out; untrusted data coming in belongs to `unsafe_input`.

### Secret field printed by inspect/1

`unredacted_secret`
· titles: "#{mod}.#{String.trim_leading(field, ":")} is printed by inspect/1" (`:error` for kind `credential`; `:warning` for `password` and `token`)

**Property.** A module M's `__schema__/1` lists a persisted field F whose name contains one of thirteen fragments:
- `credential`: `api_key`, `apikey`, `secret`, `private_key`, `client_secret`, `smtp_password`, `access_key`.
- `password`: `password`, `passwd`.
- `token`: `access_token`, `refresh_token`, `auth_token`, `session_token`.

F's name must not end in a metadata suffix: `_at`, `_on`, `_date`, `_time`, `_count`, `_expires`, `_expiry`, `_expiration`, `_ttl`, `_set`, `_length` or `_version`. F must also not be hidden from `inspect/1`. When M's derived `Inspect` implementation (`Inspect.M`) is in the run, F is hidden only if that implementation does not show it, whatever `redact:` says, because Ecto ignores `redact: true` once a schema derives `Inspect` itself. Without a derived implementation, F is hidden only if it is in `__schema__(:redact_fields)`. A field that matches several kinds takes the most severe: credential, then password, then token. `aware` says whether M hides some other field, which makes the omission an oversight rather than an unfamiliar API. `via` says where the fix goes: `redact` for the field's `redact: true`, `derive` for the schema's own `@derive {Inspect, ...}` list. At run time, the value appears in full wherever the struct is inspected: Logger calls, changeset errors, LiveView debug output, crash reports, and error reporters.

**Assumptions and limits.**
- The field name is the only signal, matched as a substring. Names that refer to a secret without holding it (`access_key_id`, `api_key_id`) and boolean flags (`has_password`) are reported. The field's Ecto type is not consulted, although `schema_field` carries it.
- Only persisted fields (`__schema__(:fields)`) are read. A virtual field is never reported, including the plaintext `password` that phx.gen.auth declares `virtual: true`. A redacted virtual field still counts toward `aware` (the nerves_hub_web#2828 pair).
- A hand-written `defimpl Inspect` is not read. The schema keeps its `redact:` reading, so a field that such an implementation hides is reported unless the field is also `redact: true`.
- When a schema's derived `Inspect` module is not in the run, `redact: true` is taken at its word.
- Only Ecto schemas are read. Plain structs, process state and JSON encoders are out of scope.
- The finding anchors at `__schema__/1`, refined to the field's line through its name in the source.

**Fixtures.** Positive: `Exposed`, `PartlyRedacted` (the `aware` arm), `SecretMetadata` (only `:access_token`), `DerivedExcept`, `LeakyOnly` and `RedactOverridden` (all `via` = `derive`), and `EctoDerived` (`via` = `redact`). Quiet: `Redacted`, `Ordinary`, `DerivedOnly`, the metadata fields of `SecretMetadata`, and `RedactOverridden` run without its `Inspect` module. All are under `Secret` (test/fixtures/secret_fixture.ex). Test: test/analyses/exposure_secrets_test.exs.

**Corpus.** Fix pairs:
- `sequin@035ee6f` (sequinstream/sequin, ad46d68 → 035ee6f, `Sequin.Consumers.NatsSink`; the fix is a derive).
- `langchain#266` (brainlid/langchain, 3e02d6b → 38e957d, `LangChain.ChatModels.ChatAnthropic`).
- `supavisor#746` (supabase/supavisor, 0e85637 → 1bf7b4b, `Supavisor.Tenants.User`).
- `nerves_hub_web#2828` (nerves-hub/nerves_hub_web, 59ccadd → 3ab4e8c, `NervesHub.Accounts.User`; the `aware` arm).

**Precision.** At introduction (e4cd4ae) the analysis reported keila 7, sequin 24 and livebook 4, read against source; one example is Keila's `Mailings.Sender.Config`, which holds five providers' credentials. Once the derived `Inspect` was read (1665e72, CHANGELOG exposure), 23 sequin rows left: every one was a field its schema's derive excludes, and so a false positive of the redact-only rule. a2cf3c4 removed the metadata-suffix false positives; no count was recorded. No sampled precision rate exists.

### Secret field printed by inspect/1, named by a classifier

`unredacted_secret_inferred` (provenance `:heuristic`)
· titles: "#{mod}.#{String.trim_leading(field, ":")} is printed by inspect/1" (`:warning` for kind `credential`; `:info` for `password` and `token`: one step below the structural finding), with a help line "heuristic: a classifier names #{field} a secret, most likely a #{kind} (p=…)"

**Property.** This is the defect of the previous class, found by a different signal. A persisted field F of schema M matches none of the thirteen fragments. With priors on, `prior_sensitive` says F is a secret of some kind with total probability 0.9 or more, summed over credential, password and token. F is not hidden from `inspect/1`, by the same test as above. `kind` is the likeliest of the three, and `permille` is the summed probability. The runtime consequence is the same: the secret prints wherever the struct is inspected.

**Assumptions and limits.**
- Priors are off by default (`Argus.Priors`; `priors: :live` or `:cached_only`). With priors off the relation is empty, and structural rows are identical either way.
- A field the fragment table matches belongs to the table, whatever the model says. The metadata-suffix and type exclusions are left to the model.
- The classifier sees the field's name, its Ecto type and its sibling fields, and nothing else.

**Fixtures.** Positive: `Secret.Heuristic` (`totp_seed`) with a stub oracle. The quiet arms are: a probability of 0.85 changes nothing, priors only ever add findings, and fields the table names stay structural. Test: test/priors/priors_test.exs; the extraction arm is test/priors/extract_test.exs.

**Corpus.** None, because the corpus runs without priors. In `sequin@035ee6f`, `jwt` and `nkey_seed` are the prior's fields, not the table's.

**Precision.**
- The calibration spike measured 98% precision at 0.9 and above on its synthetic schemas (maintainer notes on the priors spike).
- With prompt version 2, across the priors hunt's 32 corpus checkouts, heuristic findings went from 20 (6 warnings, 2 of them secrets) to 16 (4 warnings, all 4 secrets). Residue includes blockster's `Hub.token`, a currency ticker reported wrongly at info level (CHANGELOG exposure).
- On the spike's labelled fields: 26 real fields, 100% coverage at 0.7 with 96% precision; 93 synthetic fields, 98% precision.

### TLS certificate verification turned off

`disables_verification`
· titles: "#{func} turns off TLS certificate verification" (`:error`)

**Property.** An instruction in function f of module M names the atom `:verify_none`, either as an operand or inside a literal. No instruction in any function of M names `:verify_peer`, so M offers its callers no way to get a verified connection. The mention does not configure a server (`tls_server_side`): its value is not made, in f, only into the options of a server's call (`:ssl.listen/2`, `:ssl.handshake/2,3`, a Ranch or Cowboy TLS listener, a Plug.Cowboy, Bandit or ThousandIsland server), where `verify_none` means the server asks its clients for no certificate. The finding anchors at the instruction that names `:verify_none`. At run time, anyone able to answer for the host (through DNS, ARP, a proxy or the network) can end the session with a certificate they made themselves, and both ends report success.

**Assumptions and limits.**
- Any mention of the atom counts, including one in a literal that is not a TLS option list, such as a list of accepted modes. A single literal that names both atoms records only `:verify_none`.
- The scope is the whole module, and it is generous: if M names `:verify_peer` anywhere, M is credited with offering verification, whether or not that branch is reachable. A false "insecure" on code that supports verification costs more than a miss.
- A `:verify_peer` that checks nothing is not detected: a `verify_fun` that accepts every certificate, or a hostname check turned off.
- A library's own spelling, such as hackney's `insecure: true`, is not recognised.
- A server's setting is recognised only where its value goes, in its own function, into a server's call and nowhere else: not into a client's connect, a return, a message or a field. A listener named in a supervisor's child list is data, not a call, and a wrapper whose role is in its options (ejabberd's `fast_tls:tcp_to_tls/2`, a server unless the options say `connect`) is not read; both stay reported.
- One finding per function.

**Fixtures.** Positive: `ForcesNone`; `ServesAndDials` (one option list for a listener and a client's connect) and `ReturnsOptions` (the listener's options also returned). Quiet: `OffersChoice`, `Verifies`, `DynamicOpts`; `Listener` (`:ssl.listen/2`) and `Accepts` (supavisor's handshake on an accepted socket). All are under `Tls` (test/fixtures/tls_fixture.ex). Test: test/analyses/exposure_tls_test.exs.

**Corpus.** None.

**Precision.** At introduction (e7ac7b4), the module-scope filter took sequin from 9 findings to 7. It dropped `Cldr.Http`, `WebSockex.Conn`, `TeslaMate.Mqtt` and `Kubereq.Step.TLS`, all of which support verification. Five survivors are first-party Sequin modules, read as real: both Redis sinks, the NATS and RabbitMQ connection caches, and `PostgresDatabase`, whose authors' TODO acknowledges the gap. The server's side took one row of 12 over the evaluation programs, ejabberd and rabbitmq: supavisor's `ClientHandler.handle_event/4`, a handshake on a Postgres client's accepted socket. ejabberd's `ejabberd_c2s:init/1` and `ejabberd_http:init/3` (fast_tls, a server by its options) stay, a role only the options' reader can tell.

### TLS verification left to the library default

`relies_on_default_verification`
· titles: "#{func} leaves TLS verification to the default" (`:warning`)

**Property.** Function f calls `:ssl.connect/3,4`, `:ssl.handshake/2,3` or `:ssl.listen/2`. The options argument is a literal proper list, namely the last literal moved into the options register before the call, and the list has no `:verify` key. Whatever the library defaults to applies. At run time, on OTP releases before 26, the `:ssl` client verified no peer at all. The connection's security then depends on the OTP release it runs on, and nothing at the call site shows it.

**Assumptions and limits.**
- Only literal option lists are read. A list built at run time is recorded as dynamic and never reported.
- Only `:ssl` is read. Mint, hackney, Finch, `:httpc` and database drivers reach TLS through their own options.
- The options position is fixed per API: `:ssl.connect/3` is read at position 2 (host, port, options). The socket-upgrade form `connect(socket, options, timeout)` therefore goes unread, and `:ssl.connect/2` is not listed at all.
- The server-side APIs, `listen/2` and `handshake/2,3`, are read but not reported (`tls_server_side`): on a server, a missing `:verify` means the server does not ask for client certificates, which is the usual configuration.
- The rule does not know which OTP release the code targets. From OTP 26 the client default is `:verify_peer`.

**Fixtures.** Positive: `Tls.DefaultsSilently`. Quiet: `Verifies`, `DynamicOpts`, `Listener.listen_default/1`. Test: test/analyses/exposure_tls_test.exs.

**Corpus.** None.

**Precision.** It found nothing on the corpus at introduction (e7ac7b4). Most code reaches TLS through Mint or hackney rather than a literal `:ssl.connect`. It was kept because it is exact and cheap.

## coverage

`coverage` measures argus, not the analyzed program: it records every place an extractor fell back to a "dynamic" placeholder, and it derives the shapes the extractors recognised but could not fill in, as the feedback loop for precision work on the extractors. It is opt-in (the `:all` set leaves it out), every row is `:info`, and it is the only analysis that turns on imprecision tracing during extraction. Its classes are meta classes: each names a place where argus lost information, not a defect in the program, and each is a recall gap for the analyses that read the relation concerned.

### Extractor fell back to a placeholder

`imprecision_event` · reason=`dynamic` | `unresolvable` | `skipped` | `missing`
· titles: "Extractor fell back to a placeholder" (`:info`)

**Property.** While extracting some function F, an extractor tried to resolve a value of some category (a call's target, a registered name, a supervisor's child module, a gen_statem's callback mode, an ETS table reference, a timeout) and could not. `dynamic` means the fact was emitted with a placeholder; `skipped` means no fact was emitted at all; `unresolvable` means a whole argument could not be read (an `:ets.new` option list built at runtime, so no option is known); `missing` means a callback the extractor needs did not resolve (a gen_statem's `callback_mode/0`, which decides whether states are read at all). One row per fallback site that fired. Every analysis reading that fact's relation sees less than the bytecode holds.

**Assumptions and limits.**
- Only fallbacks that an extractor instruments with a tracking call are recorded. A fallback with no such call is invisible here.
- Events are recorded at extraction, before process points-to runs. A call whose target the extractor left "dynamic" and points-to later resolved is still an event.
- The finding anchors at F; it names the category and the relation, not the instruction.

**Fixtures.** Positive: `CoverageDynamicCalls` (a `GenServer.call` to a runtime target, category `genserver_callee`, relation `sync_call`, reason `dynamic`) (`test/fixtures/coverage_fixture.ex`). Quiet: the same fixtures run under `ets` record no `imprecision` facts: tracing is off outside `coverage`. Asserted in `test/analyses/coverage_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not applicable. The 0.5.0 baseline on the fast tier (poolboy, phoenix_pubsub, plug, jason, bandit) was 95 events across 12 categories, led by `ets_table_ref_op` (30), `ignored_result_unknown_api` (22) and `genserver_callee` (19) (CHANGELOG 0.5.0, "Notes").

### Supervisor with no recovered children

`coverage_supervisor_no_children`
· titles: "Supervisor with no recovered children" (`:info`)

**Property.** A module the supervision extractor recorded as a supervisor (a Supervisor, DynamicSupervisor or ConsumerSupervisor module, or a function that defines a tree) has no child extracted, neither from its own child list nor from a `start_child` that names it. Its subtree is invisible to every analysis that reasons about the tree (`coupling`, `startup`, `shutdown`, `structure`), so none of their findings can involve it.

**Assumptions and limits.**
- A DynamicSupervisor whose children start only through calls argus cannot attribute to it is reported, correctly as a gap.
- A child list built from the supervisor's arguments (the specs arrive at runtime) is reported. There is nothing to recover statically.

**Fixtures.** Positive: `CoverageEmptySupervisor`, whose children are mapped from `init/1`'s argument (`test/fixtures/coverage_fixture.ex`). Quiet: None. Asserted in `test/analyses/coverage_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not applicable. There were 2 rows on the 0.5.0 fast-tier baseline (CHANGELOG 0.5.0, "Notes").

### GenServer with no observed traffic

`coverage_genserver_isolated`
· titles: "GenServer with no observed traffic" (`:info`)

**Property.** A module that behaves as a GenServer is never the target of a resolved call or cast by name. No call, cast or send that process points-to follows reaches a process started with its callbacks, and no supervisor starts it, statically or dynamically. Either nothing in the analyzed program talks to it, or call-site resolution missed the pattern. Every rule about who calls this server is silent on it.

**Assumptions and limits.**
- Only GenServers are asked. gen_statem, GenStage and other process behaviours are not.
- A supervised module is exempt even when nothing calls it, because the supervisor at least reaches it.
- A server called only from outside the analyzed modules (a library's public API with no caller in the program) is reported. That is a gap in the analysis scope, not in the extractor.

**Fixtures.** Positive: `CoverageIsolatedGenServer`. Quiet: `CoveragePidServer`, called through the pid its start returns, and `CoverageNamedByPid`, called through a `whereis` pid, both by `CoveragePidClient` (`test/fixtures/coverage_fixture.ex`). Asserted in `test/analyses/coverage_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not applicable. Exempting supervised modules took the fast tier from 11 rows to 8 (fd23c33). Counting traffic through pids removed 20 rows of this relation and the next across realtime, logflare, hexpm and OTP, such as hexpm's `Hexpm.Cache` and logflare's `Vault` (aa33ad5).

### ETS table with no observed operations

`coverage_ets_unused`
· titles: "ETS table with no observed operations" (`:info`)

**Property.** An `:ets.new/2` creates a table under a literal name, no ETS operation anywhere names that table, and the creating module performs no ETS operation of any kind. Most often every access to the table went through a reference the extractor could not name. The table is invisible to the `ets` and `races` rules about who reads and writes it.

**Assumptions and limits.**
- A module that creates a named table and also touches ETS through any unresolved reference is exempt, on the assumption that those operations are this table's. A module that owns two tables and names only one of them hides the other.
- Table identity is by name only. The table identity `races` and `ets` use (by name, by the creating `:ets.new` site, or by a map field) is not consulted.
- The finding carries no source location.

**Fixtures.** Positive: `CoverageDeadEts` (`:coverage_dead_cache`) (`test/fixtures/coverage_fixture.ex`). Quiet: None. Asserted in `test/analyses/coverage_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not applicable. Exempting modules with any ETS operation took the fast tier from 4 rows to 1 (fd23c33).

### Registered name with no traffic

`coverage_named_process_unreachable`
· titles: "Registered name with no traffic" (`:info`)

**Property.** A process implemented by module M is registered under a literal name N. No resolved call or cast names N, and no call, cast or send that process points-to follows reaches the process registered under N, through a `whereis` pid or a start's result. Rules that follow traffic by name see nothing reach this process.

**Assumptions and limits.**
- A name registered only so that other nodes, or code outside the analyzed modules, can reach it is reported.
- A name computed at runtime is not asked.

**Fixtures.** Positive: None. Quiet: `CoverageNamedByPid`, called through the pid `Process.whereis/1` returns (`test/fixtures/coverage_fixture.ex`). Asserted in `test/analyses/coverage_test.exs`.

**Corpus.** Fix pairs: None. Present-only: None.

**Precision.** Not applicable. Excluding placeholder names took the fast tier from 3 rows to 1 (fd23c33). A fix to partial register resolution removed two forged rows on phoenix_pubsub (CHANGELOG 0.5.0, "Fixed"). Counting pid traffic is part of the 20 rows in aa33ad5.

## Classes not yet covered

Round 1 of the mining (2026-09-25) classified 178 fixed bugs from
Elixir and Erlang projects: 54 in classes argus has, 97 in classes it
could formalize and does not, 15 that need a reader's judgement (prior
candidates) and 12 out of scope. Three of the uncovered classes became
entries above in round 1 (the close of a socket the server holds, a
socket call with no timeout inside a callback, a named table created in
a server's start function), and round 2 added the decompression sink.
The rest, ranked by how many projects fixed them, how badly they fail
and how directly the bytecode shows them, each with what stands in its
way:

1. **Socket messages a library leaves in its caller.** A server that
   calls hackney (HTTPoison, ExAws, Tesla's hackney adapter) in its own
   process receives a leaked `{:ssl_closed, _}`; with a partial
   handle_info/2 it crashes (hackney#464; fixed in a dozen applications
   by adding the clause). Mint in active mode and Plug.Test leave
   messages the same way. *Blocked on the library's version*: hackney
   stopped leaking in 2025, and nothing in the program's beams says which
   hackney it runs with. A sound rule needs a fact read from the
   dependency's `.app` (as the Specs extractor reads installed ebins) and
   a curated table of library, version range and leaked message, each
   row citing the fix; without it the rule reports every server that
   calls a modern hackney. Also a prior candidate (below).
2. **Unbounded decompression of network bytes.** *Covered in round 2*
   (see "Unbounded decompression of network bytes" above). `:zip` and
   `:erl_tar` extraction, to memory or to disk, remain.
3. **A resource released only on the success path.** A monitor, a
   checked-out socket or a started process that an error return or a
   raise in a caller's fun leaves behind (Finch, Mint, Ranch, ejabberd,
   Bitcask, ExUnit). *Needs path-sensitive resource facts*: which
   acquisition reaches which exit path unreleased, per function; the
   release-on-every-path walk (`awaits_down_after`'s) is the model.
4. **Leftovers in a caller's mailbox after a timed wait.** A function
   running in its caller sends a tagged request or links helpers, waits
   with `after`, and on the timeout path neither flushes the late reply
   nor drains the helpers' exits (mnesia, EMQX, brod). *Needs the
   request's tag tied to the receive that waits for it*, the way
   `awaits_down_after` ties a monitor's ref to its `:DOWN`.
5. **A periodic timer loop multiplied.** A second path arms the loop's
   message without cancelling the running one, so every event adds a loop
   (Realtime, nerves_hub_web, Livebook). *Blocked on clause-level facts*
   (round 2 tried it): Realtime's second arm is in another clause of the
   same handle_info/2, one headed by a map (no tag for `clause_call`), and
   its fix is a cancel in that clause, so the rule needs "this call is
   preceded by a timer cancel on every path" per call site; Livebook's
   second arm is a `send(self(), tag)`, and self-sent tags are not
   recorded (`call_tag` has calls and casts only); nerves_hub_web's arm is
   in a function `attach_hook(:handle_params)` registers, which no
   callback name reveals.
6. **An asserted lookup in a message handler.** A handler for a message
   carrying a key destructures a lookup that misses for a stale message
   (Oban, Horde).
7. **A named ETS table created at compile time.** A Plug's `init/1`
   runs when Plug.Builder compiles the pipeline, so a table it creates
   does not exist at runtime (lowendinsight): the compile-time twin of
   the start-function entry above. One sighting.
8. **A liveness check then an act.** `Process.alive?` or a pool lookup
   decides a call to the same pid with no exit catch (hackney, brod;
   grpc's remote pid raises). Formalizable over check_then_act.dl
   (check: the alive test; act: a peer call on the same value; quiet
   under a try taking `exit`), but every fix pair is a rebar3 tree the
   corpus harness cannot build.
9. **A deferred reply that is never sent** when the socket closes, or a
   grant for a caller that already timed out (eredis, poolex).
10. **Blocking work in a dynamic child's init/1**, which serializes the
    DynamicSupervisor (Phoenix channels, LiveView).
11. **A message taken only when it equals the current state**, so a
    stale instance crashes the server (DBConnection, Phoenix's
    `phx.gen.live` template).
12. **Port messages** (`{port, {:exit_status, n}}`) with no clause
    (vintage_net).
13. **Side effects inside a Mnesia transaction**, which retries the fun
    on conflict: the effects concern's transaction rule, for
    `:mnesia.transaction/1`.
14. **A multicall's bad nodes asserted empty** (round 2, from EMQX's
    audit, 1a23541): `{plugins, []} = proto:get_plugins(nodes)` crashes
    with a badmatch when any node is down. The multicall arm of the rpc
    rule reads only whether the pair is matched, which `{replies, _bad}`
    always is; this shape needs the bad-nodes element matched against
    `[]`.
15. **An rpc answer handed to a function that assumes success** (EMQX
    98804509: `hocon_pp:do(Conf, #{})` of an `rpc:call` answer). The
    result is passed on, which the rpc rule reads as handled; following
    it into the callee's clauses is the step.

The mining also found instances that existing classes miss as written.
Round 2 lifted four: rpc answers returned through wrappers are judged
where their caller matches them (EMQX's audit, emqx#18287), `trap_exit`
is keyed by the process that runs it, a process module's client API is
judged by `linked_in_library` (elixir-nodejs#45), and Phoenix controller
actions are request entries. Still open: callback timeouts outside
init/1, an unlinked `GenServer.start` not counted as a spawn, and
`insert_new` as the check of a missing-row race.

### Prior candidates

Questions a rule cannot answer from the bytecode and a reader answers
at a glance: each a candidate for a question type the priors round
(`Argus.Priors`) could ask, with the rule that would read the answer.

- *Does the data this function decompresses come from the network, or
  from a source the program trusts?* The decompression sink's
  no-request arm (Tesla's response body, yes; Oban's own notification
  payloads, OTP's compressed files, no).
- *Does this client library, at the version installed, leak socket
  messages to its caller?* Backlog item 1 (hackney before 2025).
- *Is this state a deliberate resting state?* `terminal_without_stop`,
  whose prose asks the reader to ignore one.
- *Does the caller of this start wait for the child to exit?* The
  unbounded-children rule (Livebook's `UniqueTask.run/2` monitors and
  blocks for the child's `:DOWN`).
- *Is this value one the server signed or encrypted?* A cookie or
  session value read through something other than
  `fetch_cookies/2`'s options (a custom verifier), which request flow
  still counts as the request's.
- *Does this branch treat a failure tuple as the safe answer?* The rpc
  boolean arm (rabbit's `is_booted/1` sends `{:badrpc, _}` to
  `_ -> false`).
- From round 1: is the pid this call targets a pooled or transient
  connection that may vanish (xandra); which pids inside a handle the
  process must monitor (broadway_rabbitmq); does a call transfer
  ownership of data to the callee (sequin); can a cast site fire faster
  than its receiver drains (electric); is an accumulator's growth
  bounded by something the peer does not control (bandit, mint); which
  error reasons of a call are transient per peer (thousand_island);
  does an API raise besides returning its error tuple (hexpm, Finch);
  does a port's executable exit when its stdin closes (file_system);
  does a receiver depend on X arriving before Y (syn); is a registrar
  meant to restart independently of its registrants (firezone); does a
  linked helper of another application touch that application's state
  in its terminate (opentelemetry-erlang); is a caller long-lived, so
  linked helpers it forgets accumulate (hologram); is a named process a
  per-node resource (grpc); does a callee do slow I/O inside a pool
  server, and does an `already_started` loser depend on the winner's
  init having finished.

## Consistency issues

Found while writing this catalog (each concern drafted from its rules,
builders, tests and history, then read against the others) and in a
review of the 2026-09-25 precision commits. A later round fixes them;
the few fixed in the round that wrote the catalog say so. Paths are
under `priv/dl/` unless they say otherwise.

### One concept, several definitions

1. **What a server's own process runs.** `server_side` and blocking's
   `answer_reach` walk with `ForwardIntraModuleReach`, which does not
   cut `runs_elsewhere`, so a closure a callback spawns counts as the
   server's code; mailbox's `spawned_reach` and `info_reach` use the
   same-process walks that do cut it. blocking's `process_code` and
   `callback_reaches` (one hop) and mailbox's `runs_in_server` are two
   more readings of the same idea; mailbox reads both `server_side` and
   `runs_in_server`.
2. **A wait bounded by its peer (L13).** startup's `bounded_receive` is
   `recv_down` ∪ `recv_signal` ∪ `flush_receive`; blocking's
   `receive_in_callback` reads `recv_down` alone (kind `down`) and
   reports a receive that pins a linked process's `:EXIT` as unbounded;
   mailbox's `waited_out` reads `recv_down` alone. One clientlib word in
   receive.dl would serve all three.
3. **The end of the init/1 phase (L12).** The cut at
   `:proc_lib.init_ack` (`start_acked`) applies only to startup's receive
   walk; `global_path`, startup's `rpc_reach` and connect and recv walks,
   blocking's `during_init` and `init_dep` all count code after the ack
   as init's.
4. **Side paths (L2).** `side_call` cuts calls.dl's dependency words and
   mailbox's `mailbox_reach`, but not startup's walks, mailbox's
   `info_reach` and `timed_wait`, or blocking's `answers_straight_away`
   and `fun_waits`, where a server that logs is never one that answers
   at once.
5. **Generated code (L3).** `macro_generated` (the first clause's
   metadata) and `macro_written` (every clause another module's macro
   wrote) are two words; only `late_message` reads `macro_written`.
   unhandled_info's "crash", the runtime and `task_nolink` sources,
   coupling's `dual_restart_authority`, failure's rescue and orphan
   rules and every shutdown rule judge a handler a library wrote as the
   program's own.
6. **A way in from outside the program.** Five spellings:
   concurrency.dl's `open_entry` (exported, uncalled, module called by
   no other module), unsafe_input's `outside_api` (exported, uncalled,
   not a runtime callback or protocol implementation), races'
   `table_from_outside` and `open_source`, failure's `exposed` roots
   (every export), and test_code.dl's `runs_outside_tests` roots. They
   disagree on whether an internal caller or a callback disqualifies.
7. **Made of the read.** mnesia's check-then-act asks `returns_reads`
   (what a function returns by data alone); the ETS rules' `carries_read`
   asks `returns_depends`, which also counts a return decided by the read.
8. **Who owns a table.** failure's `table_owner`/`in_owner`/`seeded_row`,
   ets.dl's `ets_owner_process` (any behaviour, module-level) and
   `owner_reaches` (`CallReach` from `process_entry`), races'
   `held_table`/`held_row`, and concurrency.dl's `entry_reaches` answer
   it four ways.
9. **The ranking of a check-then-act's reads and writes** is written
   twice, for ETS and for Mnesia, in races.dl.
10. **A table no view names.** races names a table a caller hands in by
    its parameter (`param N`); failure drops a site with no known target;
    ets.dl joins on the `:ets.new/2` atom with `name != "dynamic"` and
    does not use tables.dl's identities at all, so two unnamed tables
    made with one atom are one table there.
11. **Removing an ETS row.** Five lists with different members:
    clientlib `removal_api` (effects.dl, no `delete_all_objects`), ets.dl
    `ets_removal_op`, races' `removal` (no `match_delete`) and
    `removes_rows`, failure's `removes_row`. The ETS extractor classifies
    `match_delete` as `unknown`, so only the name-matching lists see it.
12. **An ETS operation that raises.** races' `raises_if_missing` (a
    missing row), ets.dl's `raising_read` and failure's
    `fails_on_missing_table` (a missing table).
13. **A table another process can touch.** Three readings in races.dl
    alone: vocabulary.dl's `public_table` (explicitly `:public`, by name;
    ets_check_act), `readable_elsewhere` (not private, by identity;
    publish order), `shared_table` (also any named table out of view;
    missing row). The three ETS race rules disagree about one table.
14. **Callback names.** callbacks.dl's `callback_name`, unsafe_input's
    `runtime_callback`/`process_callback` (adds `code_change/3`,
    `format_status/1,2`, `process_name/2`; lacks `handle_event`, `mount`,
    GenStage's), and blocking's `process_code` (adds a Channel's
    `join/3`, which `process_entry` therefore misses everywhere else).
15. **The handler that answers a call.** callbacks.dl's
    `handle_call_function` (GenServer only), mailbox's `answers_calls`
    (GenStage too), calls.dl's `tag_handler`, resolved_calls.dl and
    processes.dl each decide it; they disagree on GenStage and on
    whether a behaviour is required.
16. **A literal first argument and the clause it enters.** calls.dl's
    `literal_entry`/`site_clause` and global_reach.dl's
    `literal_first`/`clause_of` are one test written twice.
17. **A literal a caller passes a parameter.** calls.dl's
    `resolved_arg`, tables.dl's `name_at_param`, races'
    `table_at_param` and `table_at_record`, startup's
    `infinite_recv_param`, and this round's mailbox `socket_opts_at` and
    blocking `socket_infinity_at` are the same demand-driven fixpoint,
    typed apart (number positions in some, symbols in others).
18. **An rpc on init's stack.** blocking's `init_reach` and startup's
    `rpc_reach` are two `SameProcessReach` instances with one seed; the
    "init's finding or blocking's, never both" split depends on them
    staying identical. The lock half was lifted into global_reach.dl for
    that reason and the rpc half was not.
19. **A process that traps exits** is a module-level projection of
    `trap_exit` in shutdown (`traps_exits`), mailbox
    (`receives_runtime_messages`, `yield_linked`) and process.dl
    (`trap_exit_without_exit_clause`); a flag set in a client function or
    a spawned closure counts as the server's (L1).
20. **The Task API.** mailbox's `task_async_call`/`task_await_call`/
    `task_factory` and runs_elsewhere.dl's `async_start`/`task_wait`/
    `awaits_task` disagree on `async_nolink` and `Task.shutdown`.
21. **A timer's message and its flush.** mailbox's `armed_message` and
    `local_message` restate timer_flush.dl's `timer_message` and
    `flush_receive`; mailbox does not include timer_flush.dl.
22. **The closure a call runs.** effects pairs a transaction or pure
    call with `sole_closure` (the one closure a function builds), where
    `fun_handed`/`fun_handed_to` have named the call a fun is handed to
    since e27eb7e.
23. **Guarded by the callers.** failure's
    `guarded_site`/`guarded_by_callers`, races' `unguarded_path`/
    `called_unguarded` and ets.dl's function-wide `guarded` answer the
    same question at different granularities; ets_missing_row moved to
    site-level rescues (9406a24) for the false negative the
    function-wide form causes.
24. **A server that answers at once, or whose handler can block.**
    blocking's `answers_straight_away`/`call_waits` and startup's
    `handler_blocks`/`infinite_call_reach` are two definitions.
25. **An unknown `:global` retry count (L16).** blocking drops it
    (`retrying_lock`), startup assumes `:infinity` (`lock_until_granted`);
    a positive count over `[node()]` is quiet in startup and "Local
    :global lock without a retry bound" in blocking.
26. **A one-way wait across a start.** calls.dl's `reaches_async_dep`
    does not cut `runs_elsewhere`, unlike its synchronous siblings, so a
    cast in a task init/1 starts is init/1's.
27. **A gen_statem catch-all.** The event-clause walk counted a clause
    only if it tested nothing but the event type, where CallbackTag's
    `callback_total` takes a GenServer catch-all "whatever it demands of
    the state". Fixed in this round (391ecc6): the data, and
    handle_event/4's state, may be tested.

### A lesson applied in one analysis and not its siblings

The lessons are the ones the 2026-09 precision work applied: points-to identity (L1), side paths (L2),
generated code (L3), bounded values (L4), one finding per site (L5),
runs elsewhere (L6), test code (L7), anonymous functions are code (L8),
clause-aware reach (L9), aliases (L10), runs concurrently (L11), the
ack (L12), waits bounded by their peer (L13), accessor lifting (L14),
beliefs per target (L15), the quiet direction (L16), a real
interaction rather than reach (L17).

- **L1.** duplicate_process_name identifies by the registering module,
  not the process registered; ets_unprotected_owner and
  ets_unnamed_in_process by the creating module; reply_defect's
  `self_call` never asks the call's target; kills_monitored_child is
  module co-occurrence; rest_for_one_orphaned_children takes any
  function of the owner's module; coupling's `stateful_module_dep`
  keeps its inferred module-level clause (graded, but reported at full
  severity with priors off).
- **L5.** A later-sibling call from init/1 is two startup findings (the
  `:info` unknown-place note beside the deadlock); an rpc with no
  timeout in a callback is two blocking findings; a mutual
  handle_continue cycle is likely both "Synchronous call cycle" and
  "Mutual handle_continue deadlock"; one coupling dependency can be three
  findings; the purity check reports `:ets.insert`, `spawn`, `Port.open`,
  `System.cmd` and `Process.register` twice (effect model and bytecode
  facts); failure's belief counts compiler copies of one line; an
  ordered_set two modules write is n(n−1)/2 findings; an async_nolink
  handler gets both the `task_nolink` warning and the late-message note;
  registry_race's key merges a start row and an unregister row.
- **L6.** effects' `body_reach`, mailbox's `yield_linked` and
  `linked_in_library`, shutdown's `terminate_reach` and handler-stop
  walk, unsafe_input's request reach, startup's `config_reach` and
  ets.dl's `owner_reaches` follow edges into funs that run elsewhere;
  foreign_dynamic_children counts a linked `Task.Supervisor.async`.
- **L7.** Only mailbox reads test_code.dl, and by its own header only to
  choose among sites. Populations (failure's beliefs, fan-in,
  duplicate_process_name) count test support modules.
- **L9.** blocking's budget, cast and `:infinity` rules, startup's
  `continue_dep` and `handler_blocks`, check_then_act.dl's `acts_if`,
  effects' purity walks and mailbox's source walks are function-granular.
- **L11.** ets_missing_row and ets_publish_order ask `entry_reaches`
  directly, not `runs_apart_from`; the ETS concurrency hints ask for two
  modules, not two processes.
- **L14.** Only ets_check_act lifts an accessor's operation to its
  callers; ets_missing_row, mnesia_check_act and registry_race still meet
  through one-line helpers.
- **L16.** Unresolved `:ets.new/2` options leave no `ets_option` rows, so
  heir, named_table and the concurrency options look absent and four ETS
  rules fire (loud); terminal_without_stop reports extraction gaps as
  terminal states.
- **L17.** mailbox's `outlives_its_wait` accepts any timed receive in the
  function, not a wait on the monitor; failure's `exit_reach` is
  unbounded and value-insensitive.

### Naming drift

- The function column is `func`, `caller`, `f`/`g`/`h` or `witness`; the
  site column `id`, `site`, `call`, `recv` or `anchor`, first or last;
  the kind column `api_kind`, `kind`, `signal` or `how`. callbacks.dl
  orders (module, function) in half its words and (function, module) in
  the other half.
- `self_call` is two defects: mailbox's `reply_defect` kind (a call to
  the module's own server with a tag it has no clause for, usually from
  another process) and clientlib's `self_call` (a call provably to the
  calling process, blocking's `call_cycle` "self").
- `source` means who writes a message in `partial_handler` (and carries
  two process kinds) and how it arrives in `unhandled_info`.
  `partial_handler.missing` spells `catchall` where
  `unhandled_info.fallback` spells `catch_all`.
- `kind`, `via` and `sink` mean different things in different concerns;
  a table is `name` (the `:ets.new/2` atom) in ets_check_act and the ets
  concern, `table` or `published_in` elsewhere.
- coupling's `rest_for_one_orphaned_children.confidence`
  (`named`/`inferred`) and `sibling_dependency.basis`
  (`resolved`/`inferred`/`doubted`) are one idea.
- clientlib/startup.dl and clientlib/effects.dl share names with the
  analyses; clientlib/process.dl and processes.dl differ by a letter.
- Titles that interpolate a column (a depth, a caller count, a
  behaviour, a timeout, a table name, a state, a module, a field) cannot
  be pinned generically by a corpus pair or an encore golden.
- Title style: fragments beside sentences ("Async task never awaited");
  one lowercase title ("children started under another tree outlive
  their owner"); "Start result ignored" and "start_child result not
  checked" for one family; hyphenated and unhyphenated check-then-act
  titles.

### Severities that disagree for one risk

- A missing call reply: `dropped_from` `:error` (the caller waits five
  seconds) against `statem_unreplied` `:warning` (the caller waits
  forever).
- A crash on an unexpected message: "Timeout armed but never handled"
  `:error` against unhandled_info's `:warning`s; the runtime source
  `:info` against `statem_info` `:warning`.
- A read that raises in a caller because what it reads may be gone:
  ets_read_outside_owner `:info` (the concern's only fix pair) against
  ets_missing_row and ets_publish_order `:warning`.
- A permanent child that exits by design: structure's
  consumer_supervisor_permanent_child `:warning` against shutdown's
  permanent_child_stops_normally `:info`.
- Stopping a supervisor's child from a callback: failure's
  `orphan_process` kind `exit` `:info` against shutdown's handler stop
  `:warning`, with different identity methods.
- unsafe_input: a sink a request reaches transitively is `:info`, the
  same sink with no request path `:error`.
- coupling: `cached_pid`, proven through points-to, is `:info` beside
  `restart_isolation` on the same pair at `:warning`.

### Stale documentation

- Moduledoc signatures that lost columns: unsafe_input.ex
  (`sink_reachable` has ten columns), races.ex (`key_source` lacks
  `element N`), exposure.ex (no `unredacted_secret_inferred`),
  gen_statem.ex (`statem_state`). Those of blocking.ex, startup.ex,
  coupling.ex, shutdown.ex and mailbox.ex are fixed in this round.
- mailbox.dl and mailbox.ex still list a timed call as a late-message
  source (removed in 92f6404); `removal_api` claims sets, keyword lists
  and ETS tables and lists only maps.
- state_machine.dl's note that the initial state is guessed predates
  `statem_initial` (schema 6).
- startup.dl says a later-sibling call is reported once; it is reported
  twice (L5 above).
- "fifteen substrings" (the fragment table has thirteen) in
  exposure.dl, the README, the secret fixture and
  lib/argus/priors/questions/sensitivity.ex. The first three are fixed
  in this round; the last is left to the priors branch that owns it.
- The README said argus ships 13 analyses beside a table of 14. Fixed in
  this round.
- CHANGELOG 0.20.0-dev entries that a later entry of the same unreleased
  section reverses (fe48541 by 364e74b; the publish-order "Added" by
  5c40a43; a CHANGELOG line naming the removed `ProcessReach`).

### Suspected rule defects found while cataloguing

Round 1 found these while cataloguing. Round 2 took the first four,
confirmed each with a fixture before fixing it, and says so under the
item; 5 to 8 are still open.

1. **state_machine can barely report what it describes.** Every
   `keep_state`/`repeat_state` return is a transition from the state to
   itself, and both rules count it: unreachable_state misses a dead
   state with a keep-state catch-all, and terminal_without_stop can
   never report a recognised state function (its rows are extraction
   gaps). *Resolved in round 2*: confirmed by `ClosedForeverStatem`; a
   self-loop is neither a way in nor a way out, helpers' transitions
   and returned calls are read (see the two entries).
2. **startup's "handle_continue calls its own supervisor"** reads
   synchronous calls, but `Supervisor.which_children` and the other
   management calls are supervisor calls: its only fixture's shape is
   missed and no test asserts on it. *Resolved in round 2*: confirmed by
   a test on the fixture; management calls on the continue's own stack
   count, and the worker's last-child case is quiet.
3. **The purity check never reads BIF instructions**: `self/0`, `node/0`
   and Erlang's `get/1` are silently pure, in the one analysis that
   claims soundness. *Resolved in round 2*: confirmed by `BifEffects`;
   the extractor classifies `bif` and `gc_bif` instructions, and the
   model has `:erlang.self/0` and a pure `node/1`.
4. **Phoenix controller actions may be unreachable from request
   entries**: Phoenix reaches an action through `action/2`'s apply of a
   name read from the conn, which `resolved_apply` does not resolve, and
   no rule reads `http_route`'s `action` column. *Resolved in round 2*:
   confirmed on changelog.com's facts (`PostController:call/2` reaches
   `action/2` and an unresolved apply, never `index/2`) and by
   `Taint.Controller`; a controller's exported arity-2 functions are
   request entries of kind `controller`. Pair: nerves_hub_web#2942.
5. **structure's global_register_risk quiet fixture passes
   `&:global.random_exit_name/3`**, OTP's default resolver, which behaves
   as the flagged `/2` form.
6. **shutdown** reports a gen_event handler as never trapping exits,
   though its manager traps them and runs the handler's terminate/2;
   permanent_child_stops_normally and coupling's restart_policy ignore
   `child_spec_restart` for a shorthand child; the `SiblingStop` quiet
   fixture's coordinator is not a child of the supervisor it asks.
7. **mailbox's `process_opaque`** reads every `dynamic_call`, and the
   Purity extractor adds `dot_dispatch` rows, so unreceived_message can
   turn on which extractors ran.
8. **effects' model lacks `:telemetry`**, so a terminate/2 that emits
   telemetry is shutdown's `unclear` cleanup.

### Fixed in round 2

- The four suspected defects above (state_machine self-loops, startup's
  continue calling its supervisor, the purity check's BIFs, Phoenix
  controller actions), each with a positive fixture and, where it
  suppresses anything, a quiet one beside it.
- New suppressions, each beside a positive that still fires: a task
  stream a request enumerates (`StreamLive`, beside `TaskLive`), a
  signed cookie (`CookieController.session/2`, beside `prefs/2`), a
  multicall wrapper's pair and a predicate wrapper (the rpc wrapper arm,
  beside `RpcWrapperCaller`), a behaviour module that runs no process
  (`linked_in_library`, beside `PoolCallSupervisor`), a trap no process
  reaches (beside `TrapsThroughHelper`).
- Request entries gained Phoenix controller actions, ThousandIsland
  handlers and WebSock handlers.

### Fixed in round 1

- A gen_statem `:info` clause that asks anything of the data (or, in
  handle_event/4, the state) is a catch-all (391ecc6), the lesson
  CallbackTag already applied.
- An extractor row holding a non-string failed the whole module in the
  writer, recorded as the base's failure; a store kept the lost module
  under a key without the extractor's code and served it after the
  extractor was fixed. The row now fails the extractor's own step
  (4d2e543).
- The README's analysis count, the fragment count in three places, and
  the moduledoc signatures of nine relations in blocking, startup,
  coupling, shutdown and mailbox.
