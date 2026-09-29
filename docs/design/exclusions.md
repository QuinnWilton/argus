# The exclusions in the analyses

A census of every negated atom in argus's Souffle programs, what each one
does to the findings, and a ranked plan for the ones that patch false
positives rather than follow from the bug. It is the companion of
`restart-state.md`, whose coupling rewrite is the template for the plan:
a call-based rule and its carve-outs became a witness model ("what a
restart loses"), and the class went from about 11% to 86% precision.

## What counts as an exclusion

An exclusion is a negated atom (`!rel(...)`) in a rule body. It stops a
row from being derived. The census sorts every one into three kinds:

- **Definitional (D).** It follows from what the bug is. A race needs two
  processes, so `!runs.single_process(f)` is part of the race. So is the
  complement inside a constructive definition ("no path from the arm to the
  cancel that takes the message"), a fallback that anchors a finding at its
  function when it has no site, and a preference that keeps one row per
  finding.
- **Patch (P).** It silences a specific false-positive shape: a library
  idiom, a module list, "a module with any handle_info collects every
  reply". The excluded rows would still satisfy the bug's own definition,
  or the atom stands in for a witness the rules do not derive. These are
  the candidates for a constructive rewrite.
- **Redundant (R).** It cannot change the rule's output. The rule's other
  atoms imply it, a sibling rule derives every row it blocks, or the
  relation it negates never holds for these bindings.

## How it was taken

**The atoms.** A small parser read every `.dl` file under `priv/dl`:
statements, component scopes, rule heads and bodies, and every `!` that is
not `!=`. There are 822 negated atoms: 599 in the 14 analysis programs,
219 in `clientlib/` and 4 in the stage programs (`stage0.dl`,
`points_to.dl`). The programs' own transformed AST (`souffle
--show=transformed-ast`) gave, for each atom, the output relations its rule
feeds.

**Reading them.** Each atom was classified by reading the rule, its
comments, the bug class in `bug-classes.md` and the commit that introduced
it (`git log -S` on the atom, not blame, which mostly finds refactors).

**Measuring them.** For an atom `!n(...)` in the rule `H :- B` the program
was instrumented with two nullary relations:

```
__nx() :- (B with the atom replaced by true), !H.
__na() :- (B with the atom made positive).
```

If `__nx` is empty on a dataset, removing the atom changes nothing there:
the program's model already satisfies the rule without the atom, and a
rule that only lost a body atom derives at least what it did. So one
instrumented solve per program and dataset says, for every atom at once,
where it can matter. Where `__nx` held, the program was solved again with
the atom replaced by `true`, and every output relation was diffed against
the baseline. The datasets:

- the 143 checkouts of the closed-issue corpus (their stores);
- 39 evaluation programs: eight applications (logflare, realtime,
  sequin, supavisor, blockster, hexpm, nerves_hub, livebook), the Phoenix
  stack, OTP kernel, stdlib and mnesia, and 27 open-source projects
  (emqx, rabbitmq, ejabberd, vernemq, mongooseim, ash, partisan, zotonic
  and the rest of the live set);
- the 474 fixture sets the suite solves (a logged run of `mix test`),
  including the 20 hand-built fact sets of rule tests.

That is 4,098 instrumented solves and 9,197 removal solves. The
points-to stage was measured the same way, in its exact mode, over the
558 datasets that run it.

## Counts

| program | atoms | D | P | R | deleted | changes output | head only | inert |
|---|---|---|---|---|---|---|---|---|
| clientlib + stages | 223 | 182 | 26 | 15 | 11 | 106 | 59 | 58 |
| mailbox | 139 | 112 | 21 | 6 | 2 | 99 | 14 | 26 |
| races | 118 | 67 | 25 | 26 | 23 | 69 | 25 | 24 |
| ets | 53 | 41 | 8 | 4 | 2 | 38 | 1 | 14 |
| blocking | 50 | 41 | 6 | 3 | 3 | 33 | 5 | 12 |
| startup | 47 | 37 | 6 | 4 | 4 | 26 | 4 | 17 |
| failure | 45 | 38 | 2 | 5 | 2 | 29 | 4 | 12 |
| shutdown | 41 | 31 | 8 | 2 | 2 | 30 | 8 | 3 |
| unsafe_input | 38 | 22 | 16 | 0 | 0 | 25 | 4 | 9 |
| exposure | 18 | 14 | 2 | 2 | 2 | 13 | 0 | 5 |
| coupling | 15 | 14 | 1 | 0 | 0 | 12 | 1 | 2 |
| coverage | 14 | 10 | 4 | 0 | 0 | 2 | 0 | 12 |
| state_machine | 11 | 7 | 4 | 0 | 0 | 8 | 1 | 2 |
| effects | 9 | 7 | 1 | 1 | 1 | 4 | 3 | 2 |
| structure | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 1 |
| **total** | **822** | **623** | **131** | **68** | **52** | **494** | **129** | **199** |

"Changes output" means removing the atom adds or drops an output row on
some dataset; "head only" means it adds rows to its rule's head that no
output sees (a later atom or rule masks them; sampled on up to 30
datasets each); "inert" means it adds no head row anywhere. The counts
are of main at ea9bdbff, before the partial-handler round rewrote the
unhandled-info rules; "deleted" is what this round removed.

Most exclusions are definitional. The patches cluster: 25 in races, 21 in
mailbox (9 of them in the `partial_handler` family another rewrite
retires), 16 in unsafe_input, and 23 atoms spread across the analyses
that all read one module list (`side_call`).

## What was deleted

Every deletion below leaves every output relation of every program
byte-identical on all 656 datasets (3,440 solves of the final tree), and
the suite passes.

**An edge a function calls is on its stack (13 atoms).** Every clause of
`runs_elsewhere(f, g)` requires `!call_instr(f, g, _)`, so
`!runs_elsewhere(f, g)` beside `call_instr(f, g, _)` is always true. It
was asked in `blocking` (`handler_inferred`, `timed_wait_site`),
`startup` (`init_wait_site`, both `init_recv_step` rules), `calls.dl`
(two `site_request` rules), `global_reach.dl` (two `global_path` rules),
`reach.dl` (`BackwardUnguardedSameProcess`), `timer_flush.dl`
(`helper_cancels_field`) and `races` (both `same_stack_site` rules, whose
`local_call`/`remote_call` into a defined function is a stage-0
`call_site` and so a `call_instr`). `runs_elsewhere.dl` now says so.

**A sibling rule derives what the atom blocks (11 atoms).**
- `blocking`: the second "down" `receive_in_callback` rule's
  `!down_bounded(id)`; the first rule derives the row whenever it holds.
- `startup`: the third `init_effect(_, "down", ...)` rule's
  `!peer_bounded(id)`, likewise.
- `effects`: `!body_reach.reaches(body, via)` in the second
  `escapes_transaction` rule; `started_reach` includes `body_reach`, whose
  rows the first rule has.
- `ets`: `may_hold_table`'s `!function_def(func, mod, ...)` (a named table is
  never handed back, so the first rule has the owner's own module's rows),
  and `read_misses`'s `!read_through_caller(s)` (its second rule covers
  those reads with fewer conditions).
- `failure`: both `!ets_removes_every_key(op)` in `removes_row`; the third
  rule names every literal key of a cleared table.
- `calls.dl`: the by-uniqueness `tag_resolved_site` rule's
  `!referred_handler(...)`; with one handler in the program the
  by-evidence rule derives the same row.
- `processes.dl` (points-to stage): both `!fresh_return(h, x)` in
  `returns_pts`; the unconditional fresh-return rule derives them.
- `runs_elsewhere.dl`: the fourth clause's `!started_handed(f, g)`; the
  second clause derives every row it blocked. `started_handed` went with
  it.

**Implied by the same rule (2 atoms).** `exposure`'s "unaware" rules asked
both `!hidden_from_inspect(mod, field)` and `!schema_redacts_something(mod)`;
the second implies the first.

**Nothing the facts hold trips them (2 atoms).**
`shutdown`'s `foreign_dynamic_children` asked `!match("via:.*", sup)`, but
`dynamic_child`'s supervisor is never spelled that way (the Supervision
extractor names a registry-named supervisor `Oban.Registry.via(Foreman)`,
which is no tree member). `unhandled_exit_signal`'s `!statem_process(mod)`
beside `gen_server_like(mod)`: a statem is a loop module, which
`gen_server_like` already leaves out, unless the module also declares
GenServer's behaviour (none in any dataset does, and the table then
takes it for the gen_server it says it is).

**Mnesia race kinds as witnesses (21 atoms).** `record_race_kind` made its
kinds a partition: "guarded" was `!carries ∧ !searches ∧ guards`, "fill" was
four rules of four negations each. `read_rank` reports each read at its
strongest kind, so the partition was never needed: every row an atom kept
out had a stronger kind on the same (function, read, write). Each kind is
now its own evidence, the three extra fill rules went (the first one, with
no negation, subsumes them), and only "unique"'s `!record_pair_carries_read`
and "claim"'s three stay (they decide which kind, not whether).

**A component nothing instantiates.** `ForwardSameProcessReach` in
`reach.dl` (its test now uses the Cut form with no cut).

**Two unsound atoms no dataset exercised.** They could only hide real bugs,
and removing them changes no row on any dataset:
- `mailbox`'s local-timer rule of "Timer cancelled without flushing its
  message" asked `!handles_that_message(cancel_site, message)`. That
  excuse is the kept key's: there the clause cancels the timer whose
  message it is handling. A local timer is armed after the handled message
  arrived, so what it delivers is always left behind (a `:poll` clause
  that arms a `:poll` watchdog around a blocking fetch polls twice).
- `mailbox`'s third `second_arm` rule asked `!tick_clause(c, e, lit)`. The
  loop's clause arms on every path, so its call back into itself arms a
  second timer beside its own re-arm (a `:drain` clause that runs itself
  again while a backlog is left adds a loop per tick).

Both are pinned by positive fixtures in `test/exclusions/mailbox_test.exs`.

## Redundant atoms kept on purpose

Twenty R atoms stay. Each is redundant only because of what an
extractor or a library emits, not because of the rules, and deleting it
would make the rule depend silently on that. They are candidates for
deletion together with a test of the property they rest on:

- `calls.dl`: `sync_site`'s `!match("via:.*", m)` on a wrapper's literal
  target (it comes from `call_arg`, which spells a via tuple "dynamic"),
  two on `sync_request_at` (a via target always has a site), and the
  same two on its cast twin `async_request_at` (added 2026-09-26, kept
  alike so the two read as one vocabulary).
- `global_reach.dl`: the site-less `global_path` rule's `!acked_edge(f, g)`,
  which only a stdlib `enter_loop` reaches.
- `ets`: `read_can_be`'s `!unnamed_site(id)` and `read_misses`'s
  `!read_operand_open(s)` (`resolve_table` names a read only when every
  arm agrees). Both went when ets.dl moved onto the one table identity
  (clientlib/tables.dl): a read is joined to the tables it touches, and
  no longer to an atom it then has to rule out.
- `failure`: `rpc_wrapper`'s `!predicate_function(g)` (the extractor emits
  no `result_tested` for a `?` function), `names_a_process`'s
  `!match("[{].*", t)` (the target is never a tuple), and
  `init_always_runs`'s `!runs_elsewhere(f, g)` (an unconditional edge to a
  defined function is a call site, except a BIF edge into a program that
  defines `erlang`).
- `races`: `harmless_race`'s `delete_object` clause (`!writes_back`,
  `!decision_sends`: the ETS extractor keys no `delete_object`, so the
  clause is unsatisfiable) and `held_row`'s `!makes_row(w)`.
- `mailbox` (not edited here): `self_arm_tag`'s `!timer_tag` and
  `!match("[{].*", lit)`, and four atoms of the family the partial-handler
  branch owns.

The `side_call` atoms that no dataset exercises (they rest on the side
modules having no client API and taking no `:global` lock) are counted
with the patch they read, below.

The monitor-leak round, merged after the census was taken, added the
first pattern again: `mailbox.dl`'s third `monitor_clause` rule asked
`!runs_elsewhere(h, g)` beside `call_instr(h, g, c)`. Issue #3's
follow-up removed `monitor_clause`: the record is where the monitor's
ref or pid is kept (`monitor_kept`), followed through the functions that
hand it back.

## Exclusions no dataset exercises

199 atoms never blocked a head row on any dataset: 53 redundant (above),
101 definitional and 45 patches. A second reading wrote a program for
each of the others outside coverage and the bounded stage, and 114 turned
out to guard a real shape the datasets happen not to contain. Most need a
rare combination: a site after `:proc_lib.init_ack`, a helper that makes
the table the start function asks about, prior rows, the bounded
points-to stage.

`test/exclusions/<analysis>_test.exs` pins 78 of them with 77 tests. Each
solves a fixture of the shape beside a twin the analysis reports, and
fails when its atom is removed (each was checked that way). Left out are
the ones that need priors (12), stand-in copies of third-party modules
(3), the points-to stage (10) or the two mailbox families being rewritten
(7). Four of the 114 hide real bugs rather than guard correct code: the
two mailbox timer atoms deleted above (now positives in the same suite),
and the `init/1` watchdog and the task factory keyed on its owner (plan
groups 9 and 5), which a fixture would pin as quiet.

## Soundness surprises

Twenty-one suspected holes were written up as programs and run through
argus. Each program is the real bug; argus is quiet on it, its twin
without the tripping shape is reported, and removing the named atom
reports it (or, where noted, a missing rule does). The programs are the
census's; the bugs are in the plan below.

| class | the program | what hides it |
|---|---|---|
| races, ETS read-then-write | `incr/0 = set_count(count() + 1)` over literal-key `get/1`/`put/2` accessors on a public named table | `ets_meets`'s `!unlifted` (both atoms) |
| races, ETS read-then-write | a counter's `handle_call` does lookup-then-insert; a public `reset/1` is called by the counter's own `handle_info` and by a janitor | `runs_apart_from`'s `!entry_reaches(m, g)` |
| races, registry | two different servers each `whereis(:cache) == nil -> register(...)` in their own callback | `registry_race`'s `!runs.single_process(f)`, with no "another claimer elsewhere" clause as the ETS and Mnesia rules have |
| races, registry | the shared ensure helper has an unrelated `rescue ArgumentError`, or a caller matches another server's `{:already_started, _}` | `registry_race`'s `!loser_taken(f, act)` reads the whole function and every caller |
| races, Mnesia | a lease release `[{t, ^lock, ^me, _}] -> dirty_delete` while acquire takes over expired leases | `racing_record_pair`'s `!harmless_record_race` (the ETS twin is reported) |
| ets, dies with owner | `use GenServer, restart: :temporary` makes a named table, started by `DynamicSupervisor.start_child` | `!ets_permanent_owner(name, mod)`, whose dynamic-child clause ignores the child's restart |
| ets, read outside owner | a computed-name table read by a helper both callers and the owner's `handle_call` run | the computed-name clause's `!owner_reaches` (restated for named tables only) |
| ets, created in start_link | `:ets.info(:config_table)` anywhere in `start_link` quiets the unguarded create of another table | `!asks_first`, `!gives_table_away` (any op on any table) |
| blocking, call cycle | three servers calling each other by name, A → B → C → A | chains stop at cycle clauses; `call_cycle` knows only pairs |
| blocking, :noproc catch | a child catches `{:noproc, _}` and `{:shutdown, _}`; its parent stops `{:shutdown, :redirect}` (phoenix_live_view#4359) | the catch facts cannot tell `{:shutdown, _}` from `{{:shutdown, _}, _}`; the quiet fixture `CatchShapes.NoprocAndShutdown` is this bug |
| mailbox, task never awaited | `handle_cast` starts `Task.async` and never awaits it; the server's `handle_info` takes only `:tick` | `!mailbox_handler(mod)`; worse, `use GenServer` injects `handle_info/2`, so the rule can never fire for an Elixir GenServer |
| mailbox, self-sent tag | `bump/1` casts to `Audit`, then calls its own server with a tag it does not handle | `!proxies(sender)` is per function, not per call site |
| mailbox, stale timer | a watchdog armed and cancelled in `init/1`; its message stops the server from `handle_info` | the local rule's `!init_function(mod, cancel)` |
| startup, unknown place | `Application.start/2` starts a tree, then `Config.start_link` itself; the tree's `Cache.init/1` calls `Config` | disjoint trees are taken as "already running" |
| startup, deadlock | `init/1` runs `Task.async(fn -> GenServer.call(Config, :cfg) end) \|> Task.await()`, Config a later sibling | `reaches_sync_dep` does not step into awaited tasks |
| shutdown, kills a monitored child | a job killed by `terminate_child` whose `:DOWN` restarts it; an unrelated `demonitor` elsewhere | `!module_demonitors(mod)` |
| coupling, two restart authorities | a `restart: :temporary` module started with a map spec that has no `:restart` (so permanent under that supervisor) | `dual_restart_authority`'s `!child_spec_restart(child, "temporary")` reads the module's own `child_spec`, not the spec the start used |
| unsafe_input, atoms | a protocol implementation `to_key(s) = String.to_atom(s)` users call through the protocol | `outside_api`'s `!function_def(_, m, "__impl__", 1, _)` |
| unsafe_input, atoms | an Erlang list comprehension that recurses on `list_to_atom(Parent ++ "." ++ C)` | the `-lc$` name pattern in `atoms_fed_back` |
| failure, boolean rpc | a `?` function returning a wrapper's `:rpc.call` answer; also any Elixir `if :rpc.call(...)` | the extractor records no `result_tested` for a `?` callee, and reads a `select_val` on false/nil as "matched", never "boolean" |
| exposure, TLS | one module listens with `:verify_peer` and dials with `:verify_none` | `!module_can_verify(mod)` |

### Fixed in the census-holes round

Every hole above but the races' is fixed where its root cause was (the
races rows are that analysis's own rewrite). Each census program is a
positive fixture in `test/soundness/<concern>_test.exs` with at least two
adversarial neighbours and a quiet control, one `describe` per hole
(fixtures in `test/fixtures/soundness/<concern>_census.ex`).

| hole | root cause | fix |
|---|---|---|
| ets, temporary dynamic owner | coarse fact: `dynamic_child_restart` had no row for a permanent map spec, and the excuse ignored the restart | the fact states every explicit spec's restart; `dynamic_restart` (supervision.dl) reads it or the shorthand's `child_spec/1`; the excuse asks for `permanent` |
| coupling, map spec | the same fact, read through the module's own `child_spec/1` | `dynamic_restart(..., r), r != "temporary"` replaces both negations |
| ets, computed-name read | exclusion (`!owner_reaches`) | computed reads go through `reader_outlives`; an outside caller is a reader that outlives (`called_from_outside`: a library-face export, or an owner-module export no process in view runs) |
| ets, unrelated `:ets.info` | exclusion over any table (`!asks_first`, `!gives_table_away`) | new fact `ets_made_when_absent` (the make only past the `:undefined` side of the same table's lookup); give-away of the same table |
| blocking, cycles > 2 | missing construct | `cycle_ring`/`after_reach`: cycles of any length, found once from their least module, no path enumeration |
| blocking, `{:shutdown, _}` catch | coarse fact | `catch_inner_tag`: each register's place in the reason; the rule asks for a self-stop shape (`{:normal, _}` or `{{:shutdown, _}, _}`); `CatchShapes.NoprocAndShutdown` flipped |
| mailbox, task never awaited | exclusion (`!mailbox_handler`) | `reply_taken`: a clause headed by a reference, a handle_info/2 that collects a task, or, on the starting server's stack, an open 2-tuple clause |
| mailbox, self-sent tag | exclusion per function (`!proxies`) | `to_own_server`, per call site: the site resolves to the module's server, or to nothing and names no other |
| mailbox, `init/1` watchdog | exclusion (`!init_function`) | a second rule: init/1's leftover counts when a handle_info/2 clause takes it |
| startup, disjoint trees | missing witness | `after_tree_dep`: the start function starts D after the tree holding C (`post_start_call`) |
| startup, awaited task | missing construct | `reaches_sync_dep`/`reaches_sync_request`/`reaches_tag_dep` step into a task the caller awaits (`awaits_task`) |
| shutdown, unrelated demonitor | exclusion (`!module_demonitors`) and a missing tie | PidFlow's `stop` signal; the kill must be of the monitored process (points-to), and only a demonitor on the kill's way releases it |
| unsafe_input, protocol | exclusion (`__impl__`) | the program's own protocol relays its users' data into each implementation (`implements_protocol`) |
| unsafe_input, comprehension | exclusion (the `-lc$` name) | only the comprehension's self-edge is its loop (`comprehension_loop`) |
| failure, `if :rpc.call` | coarse fact, missing rule | a select over `false`/`nil` is a truthiness test; a predicate returning a wrapper's answer is a boolean use |
| exposure, TLS | exclusion (`!module_can_verify`) | a client connect's own literal `:verify_none` has no choice |

Measured over the 26 live projects and 13 evaluation sets (39 programs,
all analyses but coverage, against main at d2a1d3ad): 11 rows added,
none removed, and none in effects, state_machine or races. Six are true
or of their class's already-reported kind: sentry's `SpanStorage.remove_child_spans/2`, elixir-ls's
`Tracer.delete_*_by_file/1` (read by the compiler's tracer calls),
partisan's `add_timestamp/1` (read by the broadcast process's `claim/2`),
vernemq's `vmq_reg_trie:fanout_entries/4` (read while the owner may be
restarting); Livebook's `NodeManager.start_runtime_server/2` (`if pid =
:rpc.call(...)`: a gone node's `{:badrpc, _}` is monitored and raises).
Five are false:
- realtime's `WorkerSupervisor` tables (2): a temporary owner whose only
  readers are its children, who end with it. "Dies with its owner" needs
  its reader (plan item 6).
- Livebook's `RuntimeServer` kills (2): the kill's way drops the record
  the `:DOWN` clause looks up, so the `:DOWN` finds nothing. The class
  needs its harm witness: the `:DOWN` clause for that monitor acts as for
  a crash, and the kill's way does not clear what it pins.
- OTP's `net_kernel:request/1` (1): the peer's only self-stops are crash
  reasons. The catch rule's peer is not resolved; reading the peer's
  `{:stop, reason, _}` returns would decide it.

encore's canon and fugue each gain one: the workload, a module nothing
else calls, reads a table the owner's own `handle_call/3` or its later
siblings also read (canon's `Ledger.balance/1`, fugue's `Config.get/1`),
and runs in a process no restart of the owner ends. True by the class;
re-pinned in encore with a dated note.

Three definitions need the constructive treatment to go further:
- **Peer call catches :noproc** — which stops the peer makes. Resolve the
  peer (a literal name, points-to, tag attribution) and read its `{:stop,
  reason, _}` returns, with `callback_stop_reason` spelling `{:shutdown,
  …}` apart from `:shutdown` and a computed reason as `dynamic` (it now
  records both as `:shutdown`, and a computed one not at all); a catch is
  then reported when a stop its peer makes is not taken, and the
  unresolved peer keeps today's reading.
- **Server terminates a process it still monitors** — the harm. The
  `:DOWN` clause that takes this monitor's `:DOWN` (by the ref it pins, or
  the collection it looks the pid up in) acts as for a crash (restarts,
  reconnects, reports), and the kill's way does not clear that ref or
  entry first (mailbox's `monitor_record`/`record_drop` are the
  vocabulary, and would move to a clientlib).
- **init/1 blocks on a peer of unknown place** — the start order across
  trees. `init_safe_cross_supervisor` still takes two trees as running for
  each other when nothing orders them. The witnesses are: a shared tree's
  `boots_before`; the start function's own order (`post_start_call` reads
  only a `Supervisor.start_link/2` in the start function, not a module
  supervisor's `start_link` beside another start); and the applications'
  dependencies (the `.app` files, which no extractor reads).

Found and fixed during the measurement: six catch rows that take the
peer's normal stop (the first restatement demanded the nested shape of
every catch), the vmq_queue_sup loop read through its sys callbacks
(now its own process's roots), Phoenix.Presence's task reply collected
by a handle_info/2 that shuts the task down, and Phoenix.Tracker's
`pool_size/1`, a true row the unified computed-name rule first lost (its
callers are Phoenix.Presence's functions, run by the library's users).

Two suspicions were only partly borne out: two sinks of one kind on one
line are lost only when they sit on exclusive branches or neither reads a
parameter (`repeated_site`), and a shared ETS lookup helper is missed by
the consistency rule because `reached_by_other` counts only other
modules' process entries (a missing clause, not the atom).

## The plan

The census-holes round ("Fixed in the census-holes round", above) did
parts of it: group 5's `!mailbox_handler` (the factory and
`!behaviour_module` atoms are left), group 6's permanent-owner restart
(the reader is left), group 8 whole, group 9's `init/1` watchdog, and
from the table below the cycle finding, the kill-and-monitor tie (its
harm witness is left), the TLS choice per connect, protocol dispatch,
atom feedback through a comprehension and the reply per call site.

Each group gathers the P atoms one constructive definition would subsume.
It is ranked by `atoms × potential / effort`, potential 3/2/1 for
high/medium/low (what the rows they touch are worth, and whether a
confirmed hole hides behind them) and effort 1/2/3 for small/medium/large.
"Rows" is how many output rows removing the group's atoms adds or drops
over the 39 evaluation programs and the corpus: how much each patch is
holding back, true and false together.

The `partial_handler` family (48 atoms: 35 D, 9 P, 4 R) and the monitor
leak family (23 atoms, all D) of `mailbox.dl` are left out: they are being
rewritten on their own branches.

### 1. Races: a pair is reported by its harm witness (12 atoms, score 18)

**Done** (docs/design/races.md): the harm witnesses replace
`harmless_race`, `harmless_record_race`, `unlifted` and the claim
atoms; a rival is judged at the key it names; `may_share_table` became
row distinctness. The census's four races holes below fire. Group 3's
concurrency atoms went with it (`runs_apart_from`).

`races.dl`: `harmless_race`'s `!stores_state(name)`, `ets_race`'s two
`!harmless_race`, `racing_record_pair`'s `!harmless_record_race`;
`unlifted` and the atoms defining it (`!op_key(op, "param", _)`,
`!hands_literal`, `ets_meets`'s two `!unlifted`); the claim rule's
`!upsert`, `!record_recomputed`, `!answers_with_read`; `publishes_early`'s
`!may_share_table`. Rows: 84 live, 27 corpus.

Today an ETS pair is reported unless it is "harmless", a subtraction with
its own list of excuses, and a read-modify-write through the module's own
accessors is dropped when the key reaches them as a literal handed in
somewhere else (`unlifted`, mnesia_lib's `val`/`set` idiom; it also drops
the confirmed accessor race). The Mnesia side already has the right shape:
`record_race_kind` names what each pair loses.

**Definition.** Report a check-then-act pair when a harm witness holds on
its path:
- *lost update*: the write stores a value made of the read;
- *clobber*: a write-back on the pair's key;
- *guarded*: the row is compared with the value written;
- *claim*: the caller is told who won (the return depends on the read by
  control only, not made of it);
- *decides more*: the decision also sends, writes elsewhere or starts
  work, here or one call down;
- *minted refill*: a key minted per holder is handed out;
- *state delete*: a delete decided by what the row holds, on a table
  whose rows are state (a value not a function of the key).

A pair with no witness is quiet by construction: two racers writing the
same default, a cache recomputed from the key. `unlifted` goes, because an
accessor's literal key is a key like any other. The rows it was added for
(mnesia_lib's `val(mnesia_status)` deciding `set(mnesia_status,
stopping)`, 34 OTP rows down to 4) are trips, a constant written on a path
the read decides; they stayed loud only because `add/2`'s parameter-keyed
write-back was taken to reach every row. `written_apart` learns key shapes
(a tuple key every caller builds never equals an atom), so that write-back
is exact and the trips have no witness. The Mnesia
lock release becomes a *state delete* (its ETS twin is reported today).
**Effort** M: the witnesses exist as relations; the change is to require
one instead of subtracting their absence. **Soundness:** the accessor
race and the lease release.

### 2. The side-path module list (23 atoms, score 15.3)

`calls.dl`'s `side_call` is `!side_api(fm)` over a fixed list
(`:logger`, `:error_logger`, `Logger`, `:telemetry`), and 22 atoms
across `blocking`, `startup`, `calls.dl`, `global_reach.dl` and the
`...Cut` reach instances stop at its edges. It came from OTP servers that
log from `handle_call` (global, supervisor, dets and disk_log servers,
mnesia) showing up as chains, `:infinity` hops and cycles through
`logger_server` and `logger_olp`. Rows: 1,169 live (the OTP and dependency
sets), none in the corpus.

**Definition.** Derive what the list asserts:
- a *leaf service* is a server whose request clauses make no request of
  another program process; a wait on it ends a chain there and closes no
  cycle, whatever module it is;
- a monitor or timer a library call takes and consumes before it returns
  (`gen:call`'s) is no late message;
- `:logger.add_handler/3` or `:telemetry.attach/4` with a literal
  module or fun is an edge to that handler, run in the emitting process.
  That also covers the documented miss: a program's own handler that
  waits.

**Effort** L. It matters only where the logging machinery itself is
analyzed, but the list is the largest single patch by atom count.

### 3. Which processes run a function (5 atoms, score 10)

**Partly done** with item 1: `runs_apart_from` counts a second entry
whether or not the owner's process also runs the function, and a caller
outside the program is any exported function of a library-face module
that is no callback and no process body (`outside_caller`,
clientlib/concurrency.dl). The handoff round made it `runs_beside`:
what another process writes only while it starts is asked one process
at a time, and a loader handed off to the server is ordered before it
(`handed_off`, docs/design/races.md). The ETS computed-name `owner_reaches` and
`process_root`'s `!own_start` are the ets analysis's, left to it.

`concurrency.dl`'s two `runs_apart_from` atoms `!entry_reaches(m, g)`;
`ets.dl`'s computed-name `!owner_reaches(p, owner, reader)` and
`process_root`'s `!own_start(g, m)`; `ways_in.dl`'s
`!called_by_other_module(m)`. Rows: 127 live, 50 corpus (the concurrency
atoms), 33 and 90 (the ETS one).

Each asks "does the owner's own process reach this function?" and takes
yes for "only the owner runs it". A helper both the owner's callbacks and
another process call is then the owner's alone: the restart-state note
retired exactly this for named ETS reads. The same hole sits, as D atoms
with narrow relations, in `failure`'s `reached_by_other` and `mailbox`'s
`server_side`.

**Definition.** A function runs in process P when some entry of P reaches
it on P's stack; it runs in *another* process when some entry `m2 ≠ m`
reaches it, or when an outside caller does: an export of a library-face
module that is not a process callback. Deleting the atoms wholesale is
wrong (a counter only its own process writes would be reported); the
witness has to be the second process. `reader_outlives` already has the
shape for reads. **Effort** S–M. **Soundness:** the janitor counter and
the computed-name shard.

### 4. Two sinks on one line (5 atoms, score 6.7)

`unsafe_input.dl`'s four `!repeated_site(id)` and `!bounded_first(first)`.
The extractor marks a later sink call of the same kind on the same line as
a copy, and every copy is dropped before evidence is gathered. Rows: 84
live, 57 corpus.

**Definition.** Every call is a sink; the finding is keyed on its source
site, and evidence combines over the calls there (the best proximity, the
caller input any call reads, the worst safety class). **Effort** S–M.
**Soundness:** a one-line `if` that converts an environment value on one
branch and the caller's on the other.

### 5. Tasks nobody collects (4 atoms, score 6)

`mailbox.dl`'s `task_result_defect` atoms `!mailbox_handler(mod)` and
the two `!task_factory`, and `runs_in_callers`'s `!behaviour_module(mod)`.
Rows: 35 live, 84 corpus.

"Never awaited" is excused by any `handle_info/2` in the module, and `use
GenServer` defines one, so the rule cannot fire for an Elixir GenServer.
"Linked in library" is excused by module kind rather than by who runs the
function.

**Definition.** A task's reply is collected when the task starts on the
server's own stack and a `handle_info` clause headed by its reference
takes `{ref, _}` (or it is awaited, yielded or shut down on the path). A
task returned to a caller is followed back through `collected_by_callers`
until a caller awaits it or drops it. A library function is judged by
who runs it: a process that traps exits (ecto#2246), or callers outside
the program. The factory excuse is keyed on the start, not the owner.
**Effort** M.

### 6. A table that dies with its owner needs a reader (4 atoms, score 6)

`ets.dl`'s `may_hold_table` `!handed_back(id, p)` and the three D atoms it
carries (`ets_permanent_owner`, the private excuse,
`ets_application_owner`). The class is at about 7% precision (ETS rows
round), and its false positives were tables only their owner uses.

**Definition.** Report "dies with its owner" when a reader can meet the
table gone: a named read where `reader_outlives` holds, or an unnamed
table whose reference reaches an operation in another process root
(`site_table`, points-to); and nothing recreates it. The excuses become
cases of "no such reader". The permanent-owner excuse reads the child's
restart (`child_restart`, `dynamic_child_restart`). **Effort** M.
**Soundness:** the temporary dynamic owner.

### 7. Coverage: a server nothing asks (3 atoms, score 6)

`coverage.dl`'s `coverage_genserver_isolated` excuses a supervised child
(`!supervisor_child`, `!dynamic_child`, `!added_child`), standing in for
"expects no requests". **Definition.** Report a GenServer with
`handle_call`/`handle_cast` clauses no resolved request reaches; a
timer-driven server drops out whether supervised or not. **Effort** S.
Only measured on the two fixture sets that run coverage.

### 8. A named table created in start_link (5 atoms, score 5)

`ets.dl`'s `ets_created_in_start`: `!asks_first` and `!gives_table_away`
for the start function and its helper, and `!made_by_server(n, m)`. Any
`whereis`, `info` or `give_away` of any table, anywhere in the function,
quiets the create. **Definition.** A create is guarded when every path to
its `:ets.new/2` passes the `:undefined` side of a lookup of the same
table (the mirror of `ets_read_when_present`), and a give-away counts
when it hands this site's table to the pid the start returns; the start's
own run of a shared maker is judged as the start's. **Effort** M.
**Soundness:** the unrelated `:ets.info`.

### 9. Timers and subscriptions: which clause, which path (5 atoms, score 5)

**Not yet; measured** (docs/design/runs.md, "Once by the state"): the
once-by-state witness (`gated_once_site`: a gate on a field of the
state, closed by the handler's own run, opened again by no return) sits
beside `!state_decided(id)`, and reads 1 of the 43 rows it suppresses
over the 44 evaluation sets (27 monitors, 16 subscriptions). The rest
are the keyed kind this item's definition names (a stored pid compared,
a membership test), nested or message-set fields, and gates a handler
opens again: the keyed witness is still what lets the atom go.

`mailbox.dl`'s `same_clause` `!has_clause` (two), `repeat_reach.seed`'s
`!state_decided(id)`, `repeated_subscription`'s `!entry_unsubscribes(e)`,
and the local-timer rule's `!init_function(mod, cancel)`. Rows: 12 live,
26 corpus. **Definition.** Place each call site in its clause by the
control-flow graph (the clause-entry block that dominates it), not by a
shared tag; a state test tracks a subscription only when the field it
reads is one the subscribing path writes; an unsubscribe excuses a
subscribe only when it precedes it on the same path; a stale message
counts whichever clause takes it (an `init/1` watchdog's message is taken
by `handle_info`). **Effort** M.

### 10. The rest

| group | atoms | rows (live / corpus) | definition | potential | effort | score |
|---|---|---|---|---|---|---|
| startup: assumed-running callee (`init_safe_cross_supervisor`, `!shares_supervisor`) | 4 | 145 / 26 | a witness that D is up before C's `init/1`: `boots_before` in a shared tree, D's tree started first by the same `Application.start/2`, or D's application a dependency of C's | M | M | 4 |
| unsafe_input: children that outlive the request (`stream_only`, `awaits_child_exit`) | 4 | 3 / 11 | a start is reported when some path from it to the function's return (or into a detached process) never joins the child | M | M | 4 |
| races: per-holder keys (`names_rows` ... `held_row`) | 5 | 27 / 22 | two processes can hold the same key: follow minted values (`make_ref`, `unique_integer`, `self()`) as tables are followed | M | L | 3.3 |
| races: lock serialization (`serialized_by_lock` chain) | 6 | 5 / 5 | Eraser-style locksets: the `:global.trans` resource ids on each writer's stack; a writer sharing no id with the pair races it | L | M | 3 |
| blocking: chains stop at cycles (`!chain_cycle_clause`, 3) | 3 | 2 / 0 | chains as simple request paths; a cycle finding over cycles of any length | M | M | 3 |
| shutdown: kill and monitor not tied (`!module_demonitors`, 2) | 2 | 21 / 36 | the killed pid is one the server monitors (points-to), no demonitor of that ref precedes the kill, the `:DOWN` clause restarts | M | M | 2 |
| calls: tag attribution by list (`!generic_tag`, `!info_tag`) | 2 | 0 / 0 | attribute a pid call only with a witness the pid is m's (points-to, a reference, a field written with m's start result) | M | M | 2 |
| exposure: TLS choice by module (`!module_can_verify`) | 1 | 19 / 35 | `:verify_none` reaching a client connect whose `verify` option no other definition sets to `:verify_peer` | M | M | 1 |
| exposure: secrets by name (`!secret_metadata`) | 1 | 3 / 1 | `may_hold_secret(type)` from the schema field's Ecto type | M | S | 2 |
| state_machine: initial state guessed, remote returns (4) | 4 | 1 / 0 | read `init/1`'s returns through helpers and `enter_loop`; record transitions for any program function a state returns | L | M | 2 |
| races: startup ordering (`!startup_callback`, 2) | 2 | 0 / 0 | another start callback is a writer unless every start of it precedes P's and its restart ends P (`ends_with`) | L | M | 1 |
| shutdown: wait sites (`!call_instr`, `!catches_exit`) | 2 | 0 / 0 | a wait site is every instruction that runs the sibling's API (direct, handed fun, resolved apply) | L | S | 2 |
| unsafe_input: name-insensitive dispatch (`!template_function`, `!template_dispatch`) | 2 | 30 / 0 | flow follows clause selection: a literal selector enters only the clauses that match it | L | M | 1 |
| unsafe_input: config-gated entry (`!disabled_transport`, `!socket_transport`) | 2 | 1 / 2 | a dependency's transport is a request entry only when the program's endpoint mounts it | L | S | 2 |
| unsafe_input: atom feedback (the `-lc$` name pattern) | 1 | 26 / 0 | a result summary showing the made atom reaches the site's own argument | M | M | 1 |
| unsafe_input: protocol dispatch (`!function_def(_, m, "__impl__", 1, _)`) | 1 | 0 / 0 | protocol dispatch followed as a relay into each implementation | M | M | 1 |
| unsafe_input: evidence frames by arity (`!forwards_to_listed_arity`) | 1 | 752 / 300 | frames chosen by function name, not arity (frames only, no finding moves) | L | S | 1 |
| coverage: unused table by module (`!ets_module_has_ops`) | 1 | 0 / 0 | resolve each operation's table (`tables.dl`); only unresolved operations are wildcards | M | S | 2 |
| mailbox: reply per call site (`!proxies`) | 1 | 4 / 31 | judge each call site by its own target | L | S | 1 |
| points-to: a get-or-start helper (`source_pts`'s `!fresh_return(g, x)`) | 1 | 0 / 0 | a helper that both hands its parameter back and returns a fresh start keeps both answers: the caller's value resolves to the start it was handed, not only to a per-call instance | L | M | 0.5 |
| startup: connect retried somewhere (`!deferral_path(mod, _)`) | 1 | 12 / 30 | a connect in `init/1` is reported when `init/1`'s failure depends on its result (a raising match, a `{:stop, _}` arm) | M | M | 1 |
| blocking: the cancel-timer flush (`!flush_poll(id)`) | 1 | 26 / 1 | a callback receive is reported when a clause can take a message the loop is owed (a gen request, a system message, a catch-all, one a `handle_info` clause takes); one whose clauses pin a ref the function holds takes only its own | L | M | 0.5 |
| failure: library-written try (`!library_written(func)`) | 1 | 24 / 0 | a library-written `try` is reported when its protected region reaches code the program wrote, anchored at the `use` | L | M | 0.5 |
| failure: macro-written votes (`!macro_written(owner)`) | 1 | 0 / 0 | a belief counts decisions, keyed by writer and source line: a macro's expansions are one vote | L | M | 0.5 |
| effects: transaction body (`!transaction_on_another_repo`) | 1 | 0 / 0 | a transaction's body is the closure whose value reaches its argument, directly or through an `Ecto.Multi` | L | M | 0.5 |
| structure: spec type by path (`!child_spec_type(child, "supervisor")`) | 1 | 0 / 0 | each `child_spec/1` return carries its start module; a typeless return that starts a supervisor is reported | L | S | 1 |
| shutdown: structural calls (`!structural_call(api)`) | 1 | 6 / 12 | the effect model classifies Kernel's data-structure functions as pure and Access as dispatch, so `unknown_call` carries only calls that can do work | L | S | 1 |
| shutdown: children torn down (`!terminate_stops_children`) | 1 | 0 / 0 | a `terminate/2` path that runs on `:shutdown`, in a process that traps exits, stops the children it started, or they are linked to it | L | M | 0.5 |
| shutdown: drain state (`!drain_flag_read`) | 1 | 1 / 1 | walk `handle_demand/2` with the state `prepare_for_draining/1` returns | L | M | 0.5 |
| shutdown: statem entries (`!statem_process` in `trap_loop_candidate`) | 1 | 0 / 0 | every state function of a statem is a process entry, so its own trap is on its stack | L | S | 1 |
| coupling: the sole earlier sibling of a kind (`!other_earlier_sibling_of_kind`) | 1 | 0 / 0 | points-to follows a supervisor management call's supervisor argument; the holder is the process it points to | L | M | 0.5 |

## Definitional atoms without a stated reason

Sixty-four D atoms had no adjacent comment saying why, in terms of the
bug. This round adds one to each of 59 (`start_acked` and `acked_edge` in
startup, the via idiom in `calls.dl`, the `_or_empty` anchor fallbacks,
the proxy and timeout rules in `calls.dl`, the cut components, and the
rest, four of them in mailbox rules outside the two families). The
partial-handler family's five (`partial_handler`, `info_message`) are
left to that rewrite.

## Found on the way

- `bug-classes.md`: "Start-order deadlock" and "unknown place" still say a
  later sibling is reported twice (abff116f removed the duplicate); the
  socket entry says the walk does not stop at the ack (b918a331 made it);
  "Infinite wait on a hop" still counts a logging call as a wait
  (f7388526); `:erpc.call` is listed as a boundary operation that
  `boundary.ex` excludes.
- `restart-state.md` says `reaches_sync_caller_in` was deleted from
  `calls.dl`; it is still there, feeding `genserver_sync_api`.
- PidFlow emits no `process_start` for `:erlang.spawn/1` of a fun it
  cannot resolve, so a `spawn(fun)` helper is no `fun_sink "start"`.
- `restart_state.dl`'s `cast_tag(g, "any")` holds beside every real tag,
  so the check matches every handler clause.
- `entries.dl`: an `init/1` that acks counts only `sync_site` waits, so a
  tag-attributed call before the ack is not seen holding the start.
- `ets.dl`: `read_operand_open`'s literal-with-path clause is dead.

## What the measurement does not cover

- Coverage is not in `:all`; it was solved only on the two fixture sets
  that ask for it.
- Priors are off on every dataset, so atoms that only act on `prior_*`
  rows read as inert (6 in unsafe_input, 3 in exposure, 3 in blocking and
  startup). Their census fixtures inject prior rows; they are not in the
  suite.
- The points-to stage ran in its exact mode; the bounded stage's atoms
  (`pervasive.dl`) read as inert, and were checked by solving the bounded
  stage by hand over a few large programs.
- Removal was solved on every dataset for P atoms and for atoms whose
  first samples changed an output; atoms that only added head rows were
  sampled on up to 30 datasets each.
