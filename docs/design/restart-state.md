# What a restart loses

A design note for the model behind coupling's "Coupled children under
one_for_one" (`sibling_dependency`, reason `restart_isolation`) and for the
vocabulary it rests on, `clientlib/restart_state.dl`. It replaces the
class's old definition, "one child depends on a sibling's process", which
reported every call between two branches of a `one_for_one` supervisor.

## What the rows said

The supervision round (2026-09-26) read many more child specs, and the
class grew by 44 "coupled" pairs and 72 "one-way" pairs over the 19
evaluation sets. Reading every row and the source behind it:

- **True, 19**: ejabberd modules whose `init/1` calls `ejabberd_hooks:add/4`
  (`acl`, `ejabberd_auth`, `ejabberd_sm`, `gen_mod`, ...). `ejabberd_hooks`
  keeps each hook as a row of the `hooks` table its `init/1` creates empty.
  When it restarts under `ejabberd_sup` (`one_for_one`), every hook is gone
  and no module registers again: its `init/1` does not run again. Hook
  runners read the empty table and do nothing, silently.
- **False, 25 coupled and 72 one-way**: calls made on each use, by
  registered name. `ejabberd_router:route/1`, `acl:match_rule/3`,
  `emqx_alarm:activate/1` from each monitor's check, supavisor's
  `Terminator` asking its `Manager`, hackney's pool and connection. Also
  `ejabberd_hooks:run/2`, which reads the table directly. After a restart,
  the next call reaches the new process by name, and the caller has
  nothing to repair.

Before this round, 13 coupled and 30 one-way rows existed in the same sets,
and the live projects add 50 coupled and 87 one-way rows (elixir-ls,
mongooseim, zotonic, sentry, ...). They have the same shape: a call on each
use.

The one fix pair (jackalope@8b7415f) and the July audit's true rows (Oban's
Sonar, Midwife and Stager) have a different shape. The caller's start makes
a request that the peer keeps:
- Hare's `handle_continue/2` subscribes through `TortoiseClient`.
- Each Oban plugin `listen`s on the notifier.
- The 19 ejabberd modules add hooks.

So the harm is not the call. It is **something one process put into
another, which the other's restart discards, and which nothing puts back.**

Two more rows of the round point the same way:
- "ETS table dies with its owner" now excuses `ejabberd_hooks` and
  `ejabberd_captcha` as permanent children. Round 1 judged those rows true
  because of the rows other modules wrote.
- `vmq_swc_store`'s start-time `register_gauge` and `group_initialized` go
  to siblings that keep them in their state.

## The model

Let A and B be children of a supervisor S, in different branches.

**Once code.** Code that runs once per incarnation of A: its start
callbacks (`start_callback`: `init/1`, a Channel's `join/3`, a LiveView's
`mount/3`), the clauses only their messages enter (a `handle_continue/2`
only `init/1` continues to, a clause for a message only `init/1` sends A;
docs/design/runs.md), and what they run on A's own stack. That means the
same process and no side path (`side_call`), including a peer's client
API that A calls. It runs again only when A restarts.

**A holds something in B** (`holds_in(A, B, func, tag, how, store)`) when:
- A's once code makes a request of B's process, a call or a cast with
  message tag `tag`, and
- B's handler clause for that tag keeps something of it in B's process.
  That clause is `handle_call/3` for a call and `handle_cast/2` for a cast,
  by tag where the clause head tells tags apart (`clause_call`) and every
  clause otherwise. "Keeps" means that the clause, or a helper it enters in
  B's module on B's stack, does one of these:
  - **table**: writes an ETS row.
  - **monitor**: monitors or links a process.
  - **dict**: writes its process dictionary.
  - **state**: returns a state that sets a field to a value B's `init/1`
    does not start it at, or that replaces the whole state with one whose
    fields it does not spell (a `maps:put/3` result). This covers Elixir
    maps and Erlang records, per clause (`returned_update`).
  - **handed**: hands the request to code outside the program that the
    effect model does not know. That code may keep it: a library's process
    that B started.

**Restart coupling.** Report A → B when all of these hold:
- S's strategy is `one_for_one`.
- A and B are in different branches.
- A holds something in B.
- No link joins them.
- A does not reach B only through an instance A started for itself
  (`private_module_dep`).

When B restarts alone, B's `init/1` builds B afresh without what A put
there. A does not run its once code again, so the registration is lost
while A runs on. If A restarts alone, its `init/1` registers a second time
beside the old incarnation's registration, and A has lost its own record of
the first. The fix is the same for both: `rest_for_one` with B first, or
`one_for_all`. The finding anchors at the tree definition. It has two
related frames: A's call (labelled "kept by the sibling") and what B keeps
(the store).

The reason `cached_pid` is the model's other half, unchanged. There, A's
`init/1` keeps B's pid, which B's restart makes stale.

### What it assumes

- The tree is what the supervision extractor reads (its entry in the
  vocabulary).
- A request is what `sync_request_at` and `async_dep` resolve: a target by
  name, by client API, by points-to, or by message tag. A client API of
  B's whose server is an argument or a name the extractor cannot read
  (eusapia's `Notifier.listen(server, channel)`) is B's by the tag B's
  own handler takes, for a call and for a cast.
- A handler clause is told apart by its first argument's tag
  (`clause_call`), as the chains of blocking are.

### What it deliberately does not claim

- **Code that runs again.** A request made on each use (a handler, a client
  function called per request) is made again after B's restart, and a
  caller that names B on every call re-resolves it. The model does not
  report either. A registration made in a handler for an event
  (re-registering on reconnect) is not once code and is not reported. That
  is a known false negative.
- **What B rebuilds.** B's `init/1` may read back what it kept, from disk
  or Mnesia (`Livebook.Storage`), or keep it where a restart does not reach
  (`emqx_alarm`'s Mnesia table through `mria`). The model reports these
  rows. Whether B rebuilds is a prior candidate.
- **A's own schedule.** A may repeat the request from a periodic callback
  (`emqx_os_mon`'s check re-raises its alarm). The model does not ask this.
  It is a prior candidate.
- **Requests the model does not see.** It does not see:
  - a send to B's `handle_info/2`
  - a gen_statem's call or cast
  - a request made in a process the once code spawns
  - a row A's once code writes into B's table directly rather than through
    B's API
  - a registration through a library registry the program starts as a
    sibling (`Registry`, `:pg`, `Phoenix.PubSub`)
  - the `init/1` of a module that declares no behaviour, which no analysis
    sees as a process (ejabberd's `ejabberd_sql_sup`, `inet_db`)

  These are false negatives, listed in the class entry.
- **A request with no tag.** A request whose message carries no tag the
  program sees enters every clause of the handler. A read then counts as
  kept when another clause keeps something. This errs loud.
- **`rest_for_one`.** Only `one_for_one` is judged, as before. Under
  `rest_for_one`, an earlier A holding something in a later B has the same
  loss, and it is not reported.

## What it replaces, and what it subsumes

- `restart_isolation` reads `holds_in` instead of `stateful_module_dep`.
  Three things go:
  - The module-level clause of `stateful_module_dep`: "reaches some
    function of B while B has a call somewhere", which gave the `inferred`
    and `doubted` bases.
  - The call/cast grading, `stateful_module_dep_kind`.
  - The "One-way coupling under one_for_one" title. That title existed to
    step per-use casts down to `:info`. A cast from once code that B keeps
    is as much a coupling as a call, and a per-use cast is none.

  `detail` now says how B keeps the request.
- `stateful_module_dep_kind`, `stateful_module_dep_call` and
  `reaches_sync_caller_in` are deleted from `calls.dl`: nothing else read
  them. `stateful_module_dep` and its `inferred`/`doubted` bases stay for
  `restart_policy`. There the harm is absence, not lost state: a
  transient or temporary sibling that never comes back fails every call,
  including per-use calls.
- The class's stated limit "a caller that names B by its registered name
  on every call is reported too" is gone. It was the false-positive class.
- The link exclusion and `private_module_dep` stay, and both follow from
  the model. A link restarts both, so nothing survives on one side. A
  private instance is A's own, not B's.
- The model adds one exclusion, and it follows from the model: a state
  field reset to the value `init/1` gives it (`initial_field`). A restart
  restores that value anyway. This is `ejabberd_access_permissions`'s
  `invalidate`, which sets its cached definitions back to `none`. It adds
  one loud allowance: code outside the program counts as keeping
  ("handed").
- **"ETS table dies with its owner"** keeps its permanent-child excuse.
  The class's property is that the *table* vanishes for its readers, and a
  permanent owner's restart makes it again. The rows other processes put
  there are the harm of this model, and coupling reports it. Coupling knows
  who put them there once, and whether the supervisor restarts that module
  with the owner. The ETS rule knows neither. The ejabberd_hooks loss is
  now 18 coupling rows. The 19th is `ejabberd_sql_sup`, a module that
  declares no behaviour, which is a structural gap. `ejabberd_captcha`'s rows are captchas in flight,
  made on each request: nothing is held across the restart.

The extractor change it needs is that `returned_update` reads Erlang
records, whole states and clauses (schema 130). It reads a field that `update_record` sets, as its 0-based tuple
position (`{2}`, PidFlow's spelling). It also reads every field of a state
a callback returns whole: the element after `ok`/`noreply`, after the reply
of `reply`, the last of `stop`, and a gen_statem's data. The compiler
builds a one-field record update afresh (`{noreply, {state, none}}`). A
state in that slot that is neither the parameter it was given nor one
these fields spell sets the whole state: key `*`, as MongooseIM's
`gen_hook` does with `maps:put/3`. Each row carries the tag of the clause
its return is in (`Dispatch.argument_tags/2`, as `clause_call` reads a
call's).

## Soundness

The nearest real-bug shapes are fixtures in `test/soundness/coupling_test.exs`:
- a registration kept in an Erlang record's state, with no monitor
- one kept by a cast
- one made from `handle_continue/2`
- one made by a helper `init/1` calls
- one a peer hands to a library
- one monitored
- one kept in the process dictionary
- one kept in a whole state that `Map.update/4` computes
- a keeper's writing clause beside a read clause that keeps nothing
- one made through a client API that takes the server as an argument,
  by a call from `handle_continue/2` and by a cast from `init/1`

Beside them are the quiet shapes:
- the per-use call
- the field reset to its initial value
- the read-only request, in a keeper with no other clause and in one
  whose other clause writes
- the linked pair
- a per-use notify through the client API a listener registers with
- a proxy's client function, whose tag its own handler does not take

## A table read while its owner is gone

The same lifetime model restates "ETS table read while its owner may be
restarting" (`ets_read_outside_owner`). A process that owns a table
takes the table with it when it ends. Another process that reads the
table harms itself only if it is still running then.

The old rule reported every read made in a function the owner's own
process does not run. It then subtracted cases:
- the owner's process running the function at all, even if other
  processes also ran it (`owner_reaches`)
- an owner whose end is the application's (`application_lifetime`)
- a rescue, a whereis test, or an operand that cannot name the table

The first subtraction was unsound. A helper that both the owner's
callbacks and a sibling call was taken as the owner's own.

Stated constructively, the rule reports a read at site R, in function F,
of table T, when all of these hold:

- **The table goes with its owner.** T is held by process P
  (`table_held`) and has no heir.
- **A reader outlives P** (`reader_outlives`). Some process Q that runs F
  goes on after P ends, or no process in view runs F, so its callers are
  outside the program's processes. Q does not outlive P when any of
  these hold:
  - Q is P.
  - P's end is the application's: P is the application's process or the
    root supervisor its start/2 starts.
  - P's supervisors end Q with it (`ends_with`, supervision.dl):
    - Q is in P's subtree, when P is a supervisor.
    - P is a direct child of a `:one_for_all` supervisor and Q is in
      another branch.
    - P is a direct child of a `:rest_for_one` supervisor and Q is in a
      later branch.
  - Q is spawned linked (`spawn_link`) by P or by a process that ends
    with P.
- **The read can meet T gone.**
  - It is not rescued.
  - It is not made only where T is there. The table is there past a
    whereis test that found it, and past an instruction that makes it on
    the reader's own path: its named `:ets.new/2`, or an ensure helper of
    the module. This is `ets_read_when_present`, widened.
  - Its operand can name T (`read_misses`).

What it subsumes and deletes:
- The separate `!owner_reaches` and `!application_lifetime` negations
  become cases of "a reader outlives P".
- The ETS rows round's lazy-ensure prior candidate becomes structural.
- The limit "a function both the owner's process and callers' processes
  call is taken to run in the owner" goes. That function's callers are
  readers that outlive.

What it assumes and does not claim:
- **Escalation.** A restart intensity the crash exhausts is not followed:
  mnesia's intensity-0 `one_for_all` chain stops the application, and
  the facts do not carry intensity.
- **Trapped exits.** A linked process that traps exits outlives its peer,
  and is taken as ended. That errs quiet.
- **Owners that cannot end.** A keeper that cannot crash, or a process
  whose exit halts the node (`application_controller`, `code_server`),
  remains a prior candidate, as the rubric's owner-lifetime clause says.
- **Alternative modules.** Two modules of which configuration runs only
  one are taken as both running: partisan's peer service managers.

Soundness fixtures, in test/soundness/ets_lifetime_test.exs. These still
fire:
- an earlier `:rest_for_one` sibling
- a `:one_for_one` sibling
- a `:one_for_all` sibling of a branch that restarts the owner alone
- an unlinked loader
- the shared helper
- an ensure on one branch, an ensure after the read, an ensure of another
  table, and an ensure that makes an unnamed table of the atom

These are quiet: the owner's supervised child, the `:one_for_all`
sibling, the later `:rest_for_one` sibling, the linked loader, and the two
safe ensures.
