# Races by their harm

A design note for the check-then-act classes of `races` —
"Read-then-write race on an ETS key" (`ets_check_act`), "ETS row
refilled on a stale read" (its `stale_fill` kind), the Mnesia twins
(`mnesia_check_act`), "Lookup-then-start race on a process name"
(`registry_race`) — and for the vocabulary they rest on:
`clientlib/check_then_act.dl` (`PairCarries`, `DecisionSends`) and
`clientlib/concurrency.dl` (`RunsConcurrently`). It replaces a rule that
reported every pair and then subtracted the ones it judged harmless
(`harmless_race`, `harmless_record_race`, `unlifted` and their atoms),
the first item of the exclusion census (`exclusions.md`).

## What the rows said

The races rules made 118 distinct rows over the 39 evaluation sets (the
eight applications, the Phoenix stack, OTP's kernel, stdlib and mnesia,
emqx and the 26 live projects) and the 140 checkouts of the closed-issue
corpus, counting one row per project where several checkouts carry it.
Removing the census's patches (`harmless_race`, `harmless_record_race`,
`unlifted`, `held_row`, `serialized_by_lock`) and the `runs_apart_from`
hole showed 60 more rows those patches kept quiet. Every one of the 178
was read against its source by five agents, with two questions: can two
processes run between the read and the write on the same row, and what
does the interleaving cost (the rubric is in the session's scratch
`races2/RUBRIC.md`).

**The 118 reported: 56 true, 62 false.** The true rows:
- 28 lost updates: the write stores what the read returned (ejabberd's
  `mod_fail2ban` counts failed logins N+1 from every c2s process, so a
  brute force from one address gets more guesses; blockster's
  per-user balances, campaign shares and multipliers; mnesia_lib's
  `add/2` and `del/2`, which a spawned loader and the controller run on
  one `{Tab, where_to_write}`; Hammer's ETS buckets; sequin's test
  messages; supavisor's older circuit breaker).
- 9 duplicate claims: both racers see the slot free and both act
  (elvengard_ecs's insert-if-absent, blockster's referral earnings
  inserted twice under fresh UUIDs, one solved ejabberd captcha accepted
  twice, tesla#768's mock agent, rabbit_ff_controller's
  `{ok, Pid} = start_link()` on a lost start).
- 6 decisions that do more: both racers send, charge or sync (blockster's
  `claim_sync_slot`, two weekly-movers articles).
- 6 clobbers: a blind first insert over a row another writer counts in
  (Hammer's atomic buckets, hammer#94, ztlp's serial store).
- 4 deletes of a row made again, 2 stale fills, 1 missing row (sequin's
  `DebouncedLogger`, whose timer takes the bucket `log/4` counts into).

The false rows:
- 21 one process at the row: the writes are serialized in one server, or
  by a handoff the facts do not show — vernemq's two trie servers queue
  every update while the loader their `init/1` spawns runs, and the
  loader hands over with a message (11 rows).
- 8 the same value either way (a protocol version written back
  unchanged, a status both racers set).
- 6 fills of a value that cannot differ: a default both racers write, a
  copy a pure function computes.
- 5 deletes that lose nothing: an invalidation, an expired entry that
  cannot come back, a `delete_object`.
- 5 different rows (mnesia_recover's `serial` against removers of other
  keys; Ecto's repo registry, whose row goes only with its repo).
- 6 dead or development-only code; 4 startup-only code; 2 losers that are
  handled; 2 rows keyed by one holder's key; 3 others.

**The 60 hidden: 15 true, 45 false.** `harmless_race` hid six stale
fills — blockster's settings cache refilled from Postgres after
`emergency_stop!` invalidated it, nerves_hub's health profiles, rabbit's
connection tracking — and two decisions that do more (supavisor's
circuit breaker telling every node, mongooseim's IQ callback taken
twice). `harmless_record_race` hid three deletes of a record made again
(ztlp's re-registered names, mongooseim's resumed stream-management
session, ejabberd's roster purge). `unlifted` hid two mnesia lost
updates, and the `runs_apart_from` hole two more (mongooseim's
deprecation log, mnesia's `add_list/2`). The 45 false were, as above,
mostly one process at the row (28, 16 of them vernemq's tries), then
fills and deletes that lose nothing (9) and rows one holder keys (4).

So a pair is harmful when the interleaving makes the write undo or
duplicate something, and harmless when every order of the two ends the
same way. The patches tried to recognise the harmless shapes one by one;
the rows they missed and the rows they hid are the same mistake. The
harm is **what a rival write and the pair's write do to the row
together**, and a rival must be a real one.

## The model

A pair is a check-then-act meeting (`CheckThenAct.meets`, unchanged): a
read decides or feeds a write of the same thing, through helpers,
arguments and loops, and `func` is where they meet. It is a race when a
**rival** can land between the read and the write and the two leave a
**harm** no serial order would.

### The rival

A rival is a write that can land on the pair's row between its read and
its write (`rival(f, r, w, w2, h)`):

- **the pair itself, in a second process**: `f` runs in more than one
  process (`RunsConcurrently`) and two of them can be at one row — not a
  row keyed by the process's own pid, nor one only its holder writes
  (`held_row`, below);
- **another write of the row**, in a function `h` that runs, after its
  process has started, in a process other than the pair's: any process
  when `f` runs in more than one, otherwise one `runs_apart_from` the
  process `f` runs in.

A write is seen **where its key is named** (`rival_write(w, h, name, ks,
k)`). A write whose key is its function's parameter is its callers'
write, at the key each passes, carried up through `call_arg`,
`call_arg_forward`, `call_arg_tuple` and `call_arg_element`:
mnesia_lib's `set/2`, called with a hundred keys, is a hundred writes,
each at its own row and in its own caller's process, and
`set(:count, n)` writes the `:count` row wherever it is called. A
function callers outside the program call (`outside_caller`), or whose
parameter no call in view fills (a closure handed to `Enum.each`),
writes whatever key it is handed. The pair's own write, seen at a
function that runs the pair's function, is the pair; seen at a function
the pair's function runs, it is a rival where another process runs that
function too (the owner's `set_count/1`, which a resetter's timer also
calls).

Two keys name different rows (`keys_apart`) when both are literals that
differ; when one is a tuple and the other a literal that is not; when one
is a process's own pid and the other a literal or another process's own
pid; and when one was minted where the row was made (`make_ref`, a
monitor, a unique integer, a random value — a row no one could have read
before). A literal row and a row keyed by what the program computes are
taken to be two rows, whichever side is the pair's (an assumption,
below).

### The harm

What the rival and the pair's write do to the row together
(`ets_harm_by(f, r, w, kind, w2, h)`, one rule per witness). The first
four need a rival that changes the row:

- **lost_update**: the write stores what *this pair's* read returned, or
  a value made of it, on the pair's own path (`PairCarries`, below), and
  the rival changes the row: its change is lost. A rival that removes
  the row loses to a write that makes it again, not to an
  `update_element`, which finds no row.
- **clobber**: a write of a value of its own lands on a row the rival
  counts in — `update_counter`, a write-back, an `:atomics` or
  `:counters` array the row holds (which each racer makes of its own, so
  the pair itself is the rival there).
- **stale_fill**: the write stores a copy of a source that can change —
  a read of another store, or a call whose answer is not known to be a
  function of its arguments (`reads_state`: it reads a process, a table,
  a file, the process dictionary, or calls code the effect model has no
  word for, such as an Ecto query) — and the rival removes the row or
  writes it with a value of its own: the copy made before lands after.
  A copy a pure function of the key computes is the same whenever it is
  made, and cannot be stale.
- **state_delete**: the write deletes the row on what the row holds (its
  owner, its expiry: `tests_row_fields`), and the rival makes the row
  again with a value of its own, or counts in it: the delete takes a row
  its decision never saw. A delete on the row's presence alone ends as
  the rival's write followed by the delete would. A row a refill makes
  is a cached copy, and losing it is a miss.

The next five need a rival that makes the same decision — the pair
itself in a second process, or another pair's write (`decides_too`);
the guard needs any rival:

- **claim**: a write that makes the row, whose decision leaves the
  function as a verdict, not as the row: what it returns depends on the
  read by control alone (`verdict_escapes`), to a caller that branches
  on it or out of the program. Both racers are told they won. A
  get-or-create that answers with the row, and a cache-aside that
  returns its value, answer with data and are no claims.
- **take**: a delete made on the row's presence, whose function hands
  out what the row held: both racers take the one row.
- **decides_more**: the decision, on the pair's own path, also sends,
  calls a peer, makes an outside effect, or writes shared state other
  than the pair's table: both racers do it. The same table's other
  writes under the decision are the race's own (its other branch).
- **guarded**: the decision compares a field of the row with the value
  the write stores (`[{^k, cur}] when cur < new`): both pass, and the
  older can land last. Over a refill the guard orders copies of one
  source, and which lands last matters only when the source changed: the
  stale fill's witness.
- **minted**: the write stores a value minted per call that the function
  hands out: each racer hands out its own, and only one is stored.

No witness, no race: two racers that write the same default, a refill
nothing makes stale, a delete made twice, a marker set twice.

Every question about the decision — what it tests, what it compares,
what it sends, where it escapes — is asked on **the pair's own path**
(`pair_path`): the meeting function and the helpers below it that return
the read up to it. An accessor's lookup that ten functions share is ten
pairs, each with a decision of its own. `PairCarries` asks "made of the
read" the same way: of this read, on the way from the meeting function
down to the write, not of any read by any caller (`MadeOfRead`, which
stays for rivals that write back).

A finding carries the strongest harm among its race's writes
(`ets_harm_rank`), anchored at the first; the rival writes that witness
it are related frames (`ets_race_frame` role `rival`).

### Mnesia

The same model, over records (`record_race_kind`): `unique` (a search
found nothing, both racers insert under keys of their own),
`lost_update` (`PairCarries`), `guarded`, `claim` (a verdict, as for
ETS), `decides_more`, `delete` (made on what the record holds, over a
record a rival wrote back, counts in or made again; or one whose
decision sends or hands the record out), and `fill` (a record computed
afresh, over a rival's removal or write). The rival is
`record_rival`, a write of the table at a key that can be the pair's, in
a process other than the pair's; two writes whose keys are different
literals, or one of them minted, name different records.

### The registry

A lookup-then-start pair needs a second claimant in the window
(`claimants`): the pair's function runs in more than one process, or
another process claims the same name — a start, registration or
unregistration naming it as a literal, where it is made or where a
caller hands a claiming helper the literal (`claims_name`), in a
function `runs_apart_from` the pair's process. Two servers that each
start one cache on first use race, each with its own copy of the check.

### Which processes run a function

`RunsConcurrently` (`clientlib/concurrency.dl`) is the vocabulary every
rule above asks:

- `single_process(f)`: exactly one process runs `f` — one entry reaches
  it on its own stack, that entry has one instance, no request entry
  reaches it, and no caller outside the program does.
- `runs_apart_from(m, g)`: a process other than entry `m`'s runs `g`:
  another entry reaches it, whether or not `m` does too, or a caller
  outside the program does. That `m` also runs `g` changes nothing: a
  `reset/1` the owner's callbacks and a janitor both call runs in the
  janitor as well. (It was `!entry_reaches(m, g)`, which took "the owner
  runs it" for "only the owner runs it".)
- `outside_caller(c)`: an exported function of a module no other module
  of the program calls (`library_face`), that the runtime does not call
  in a process of its own — no callback, and no process body a start of
  the program runs. A library's `reset/1` its own server also calls is
  its users' too.

The missing-row remover and the publish-order reader ask the same
question (they asked `!entry_reaches(m, f)` of the pair's function).

### What it assumes

- **Keys the program computes.** A literal row and a row keyed by a
  value the program computes where it calls the write (a local, a map
  field, an element of a parameter) are two rows, in either direction: a
  `:__hits__` counter beside the cached rows, `mnesia_status` beside the
  `{Tab, where_to_write}` keys mnesia's callers build. A computed key
  that happens to equal the literal is not seen. What a caller outside
  the program passes, and a parameter no call in view fills, is any key.
- **Changing sources.** Whether a fill's source can change is read from
  the effect model: a call to code it knows nothing of counts as
  changing, one it knows to be pure does not. A pure-looking helper that
  reads state through a mechanism the model misses is taken as pure.
- **The decision's effects.** "Does more" sees sends, peer calls and
  casts, the effect model's outside effects, and writes of other shared
  state, on the pair's path and one call down for messages.
  Erlang's `:supervisor` is not in the effect model (Elixir's
  `Supervisor` is), so hackney's `stop_pool/1`, which terminates the old
  pool and then deletes the name the new one may hold, is not seen.
- **Startup.** A write only an `init/1` or an Application's `start/2`
  makes runs while its own process starts, which an ordered supervisor
  start runs before the pair's process (`writes_after_start`). A later
  sibling's `init/1`, or a restart of the writer alone, re-running it
  while the pair runs, is not seen.
- **Rows only their holder writes** (`held_row`). A table whose every
  row-making write mints its key hands each row to one holder: the pair
  in many processes is many holders at their own rows, and is not its
  own rival (Postgrex.Parameters). A minted key handed to several
  processes is not seen.
- **A cluster lock every writer takes** (`serialized_by_lock`): a Mnesia
  pair in a closure `:global.trans/2` runs is serialized when every
  writer of its table runs under such a lock; the lock's identity is not
  compared.

### What it deliberately does not claim

- **Serialization the facts do not show.** A handoff (vernemq's loader,
  whose owner queues updates until the loader reports back), a unique
  index in another database (blockster's `locked_x_user_id`), a
  protocol that orders two events (a connection's created and closed
  handlers): the pair is reported as the processes allow.
- **Semantic sameness.** Two racers that write the same value because of
  what the program means (a protocol version read and written back, two
  retries of one share writing the same status) are reported when a
  witness holds.
- **Dead code.** A function nothing calls in an application is taken as
  its users' way in.

## What it replaces, and what it subsumes

Deleted (16 of the census's 27 races patch atoms, and the machinery that
defined them):

- `harmless_race` (both ETS clauses, n391, n394) and its five rules, with
  `stores_state` (n373), `filled`, `recomputed`, `writes_back`,
  `write_back`, `carries_read` and `pair_key_of`'s role in them: a pair
  is reported by its witness, not kept by the absence of an excuse.
- `harmless_record_race` (n421) and its two rules, with
  `record_writes_back` and `record_carries_read`.
- `unlifted`, `hands_literal`, `meets_on_literal` and `ets_meets`
  (n351–n354): an accessor's literal key is a key like any other. The
  mnesia_lib rows `unlifted` was added for are trips — a constant written
  on a path the read decides, with no rival that counts in the row once
  `set/2`'s writes are seen at the keys their callers name.
- `upsert`, `record_recomputed`, `answers_with_read` and
  `same_table_writes` (n440–n442): a claim is a verdict by definition,
  and "answers with the record" is the definition's other half
  (`PairCarries.answers`), not an excuse.
- `other_writer`, `written_apart`, `removal`, `pair_makes_rows` and
  `removal_loses_nothing`: the rival and the harm matrix.
- `may_share_table` (n397): the completing row is keyed by the published
  value, so two writes are two rows even in one table; in such a table a
  reader must take the value from the table (a key from outside may be
  the published row's own, which is written first).
- `runs_apart_from`'s two `!entry_reaches(m, g)` (n675, n676), and the
  open-entry half of `writes_after_start` (n364): `outside_caller`.
- `record_path_param`, `record_value`, `returns_record` and
  `record_maps_param`, moved into `PairCarries` for both stores.

Kept, and restated inside the model:

- `held_row` and its table-level definition (n386–n388, n390): a self
  rival needs two holders of one row. The census's constructive
  replacement — follow each minted value to the processes it reaches —
  is a points-to question left for later.
- `serialized_by_lock` (n415–n420): a rival must be able to interleave.
  Inert on every evaluation set.
- `writes_after_start`'s `!startup_callback(c)` (n363): the startup
  assumption above.

Added, each following from the model: the self rival's `!held_row` and
key-kind conditions; `!writer_walk.reaches` (a function on the pair's
own stack is the pair); `!keys_apart` (two keys that cannot be one
row); the key-kind fallbacks (`!op_key`, `!minted_key`,
`!param_filled`); the harm matrix's complements (`!removes_row` splits
removals from rewrites, `!refill_row` separates a cached copy from a
row's own value, `!tests_row_fields` makes a take a presence decision,
`!fills` hands a guard over refills to the stale fill); the claim's
"control alone" (`!answers`); the one-table reader (`!ets_table`);
`other_state_write`'s non-ETS write (`!ets_op`); and `outside_caller`'s
`!process_entry` and `!process_start`. Net, `races.dl` has 75 negated
atoms, down from 95.

## Soundness

`test/soundness/races_test.exs` (fixtures in
`test/fixtures/soundness/races_witness_fixture.ex`) pins, each solved
alone:

- the census's four counter-examples: `incr = set_count(count() + 1)`
  over literal-key accessors; a counter's `reset/1` shared with a
  janitor; two servers each looking a name up and registering it; a
  Mnesia lease released on its owner while a transaction takes it over;
- each harm still reported (a default over a counted row, a take, a
  claim, a serial guard, an ETS lease release over a takeover, a delete
  that sends, a stale Mnesia copy);
- keys named where they are written (a library's any-key `bump/1`, a
  closure's keys, a literal rival, a setter a resetter also calls);
- another process running the rival (a direct janitor, a timer's
  `apply_after`, a library's users);
- deletes on what the row holds or handing it out (a dirty lease
  acquire, a resumed session, a Mnesia take);
- stale fills from a server's answer, a file, and an update that writes
  the cache;
- a second claimant (a library's `ensure/0`, a task per message);
- a one-table map read through the table, inline, through a helper and
  through `lookup/2`;
- and three quiet controls: a counter only its own process writes, a
  default nothing else writes, a pure refill.

The fixture suites that pinned the retired patches moved with them:
`CacheRefill`'s `setting/1` (a copy of a Mnesia record, invalidated) is
now a stale fill, and `get/1` (a pure copy) stays quiet;
`MnesiaExpire`'s store mints its state, as blockster's does, which is
what made its delete harmless; `GvarAccessors` gains its callers
(`GvarUsers`, building tuple keys as mnesia's do), and `maybe_work/0`
answers `:ok`, the trip `unlifted` was written for; the census's
Prerender warmer, which tells its caller `:hit` or `:miss`, is a claim.

## Measured

Solved over the 39 evaluation sets and the 140 corpus checkouts; every
row read (the 178 above, and the two rows the model adds that no
patch hid: two mnesia internals the schema lock and the dumper
serialize, false).

**Rows** (distinct, one per project):

| | true | false | precision |
|---|---|---|---|
| before | 56 | 60 | 48% |
| the harm model, old concurrency | 66 | 64 | 51% |
| after | 66 | 82 | 45% |

Twelve true rows are new — six stale fills (blockster's settings,
nerves_hub's profiles, rabbit's connection tracking), two deletes of a
record made again (ztlp, mongooseim's resumed session), two mnesia lost
updates, a take (mongooseim's IQ callback) and a duplicated deprecation
log — and two are lost: ejabberd's
`stop_module_keep_config/2` and hackney's `stop_pool/1`. Both delete a
module's or a pool's row by name after acting on the old row through
calls the model does not see as effects (a helper that deregisters the
old hooks; Erlang's `:supervisor`), and were reported before only
because another function's decision on the same accessor read leaked
into theirs. Eight false rows go (mnesia's defaults and protocol
version, an invalidation, deletes of expired records no write makes
again). The harm model alone takes precision from 48% to 51% with ten
more true rows.

The concurrency fix (`runs_apart_from`, outside callers) closes the
census's janitor holes and adds 18 false rows and no true one on the
evaluation data: 14 of vernemq's trie servers, whose loader (a process
their `init/1` spawns) is a second writer the owner serializes with a
handoff; sequin's benchmark stats (2); blockster's promo engine (2).

**Findings** over the 39 evaluation sets (the full pipeline, one finding
per write):

| title | before | after |
|---|---|---|
| Read-then-write race on an ETS key | 17 / 28 | 22 / 47 |
| ETS row refilled on a stale read | — | 4 / 1 |
| Read-then-write race on a Mnesia record | 19 / 18 | 20 / 20 |
| Uniqueness check-then-insert race on a Mnesia table | 2 / 1 | 2 / 1 |
| Dirty write fills a Mnesia record on a stale read | 1 / 3 | 1 / 2 |
| Lookup-then-start race on a process name | 3 / 3 | 3 / 3 |
| ETS row acted on after another process may have removed it | 1 / 3 | 1 / 3 |
| total (true / false) | 43 / 56 (43%) | 53 / 77 (41%) |

Outside vernemq's two trie servers, 43 / 45 (49%) before and 53 / 51
(51%) after; the tries go from 11 false findings to 26.

Every credited race holds: hammer#94 and hammer#129 (and quiet at their
fixes), tesla#768, ztlp's serial store and registration limiter,
elvengard_ecs's insert-if-absent (quiet at its fix), blockster's
`claim_sync_slot/2` and double-credited referral earnings, ejabberd's
`mod_fail2ban`, sequin's `DebouncedLogger` (ets_missing_row), vernemq's
`vmq_config` refill and webhook cache, and rabbit_ff_controller's
start. The census's four counter-examples fire.

## What's next

- **Serialization the facts do not show.** Most false rows left are one
  process at the row: a loader its owner waits for, a lock in another
  store, a protocol. A handoff has a shape — a process `init/1` spawns
  that ends by messaging its starter, and a starter whose callbacks
  queue while a state field says so — that a happens-before relation
  over messages could read.
- **Per-holder keys.** `held_row` is table-level; following each minted
  value to the processes it reaches (process points-to over refs, as
  over pids) would make it per row and see a key handed to several.
- **Effects of the decision.** Erlang's `:supervisor` belongs in the
  effect model beside Elixir's `Supervisor`; a decision's data handed to
  a helper that writes other state (ejabberd's deregistration) is "does
  more" two calls down.
- **A pinned match's key.** `[{^id, v}]` makes the write's key the row's
  element, not the parameter the pin compared, and the pair does not
  meet: the key identity could carry the pin.
