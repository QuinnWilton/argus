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
callbacks (`start_callback`: `init/1`, `handle_continue/2`, a Channel's
`join/3`, a LiveView's `mount/3`) and what they run on A's own stack. That
means the same process and no side path (`side_call`), including a peer's
client API that A calls. It runs again only when A restarts.

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
  name, by client API, by points-to, or by message tag.
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

Beside them are the quiet shapes:
- the per-use call
- the field reset to its initial value
- the read-only request, in a keeper with no other clause and in one
  whose other clause writes
- the linked pair
