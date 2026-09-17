# Changelog

All notable changes to Argus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
