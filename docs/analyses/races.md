# Shared-state races

[Bug-class catalog](../bug-classes.md)

A check and a later write are not enough to establish a race. Argus looks for a
competing operation that can run between them and a harmful result that neither
serial ordering would produce. Related frames identify checks, writes and rivals.

## Process-name claims and releases

`registry_race` · **warning**

A lookup controls a start or registration of the same name, but another process can
claim it first and the losing result is unhandled. Handle already-started or
already-registered outcomes, or use an operation whose result settles the claim.
Some named starts are harmless when the losing result is discarded and either
winner provides the same registered service.

The `unregister` variant checks a name and then releases it. Another caller or the
registered process's exit can remove it first, causing badarg. Scope and key matching
follow supported wrappers; a start_child's name can be hidden in its spec, so an
explicit nil check supplies weaker name evidence.

## ETS read-modify-write

`ets_check_act` · **warning**, except `stale_fill` is **info**

A read feeds or controls a non-atomic operation on the same shared row. The table
must be publicly writable or supplied by an external caller, and a rival must be
able to affect that row.

| Kind | Harm |
|---|---|
| `lost_update` | A write based on an old value overwrites an intervening update. |
| `clobber` | A replacement overwrites a counter, write-back or counter array. |
| `state_delete` | A decision based on old contents deletes renewed state. |
| `claim` | Both callers are told they acquired the same resource. |
| `take` | Both callers return the value intended for one consumer. |
| `guarded` | Competing updates pass a guard based on the same old value. |
| `minted` | Callers receive separately generated values for one logical row. |
| `decides_more` | The decision also sends, starts work or changes other shared state. |
| `stale_fill` | A delayed refill restores data invalidated or replaced by a rival. |

Harmless duplicate defaults and deletes are excluded when no harm is witnessed.
For counters and claims, prefer the appropriate atomic ETS operation. For larger
updates, make ownership or serialization explicit. A lock is useful only if every
competing path participates.

## Mnesia uniqueness races

`mnesia_check_act` with `kind=unique` · **warning**

A dirty index or pattern search finds no matching record, then a dirty write inserts
one. Concurrent callers can both pass the search and insert different keys that
violate the intended uniqueness constraint. Keep the relevant search and write in
a transaction with suitable locking or use a representation that enforces the key.

## Mnesia read-modify-write

`mnesia_check_act` · **warning**, except `fill` is **info**

Dirty reads and writes bypass transaction isolation. The modeled harms include
lost updates, guarded updates, duplicate claims, additional side effects
(`decides_more`) and deletes of renewed records. `fill` is a weaker finding: a
computed replacement can undo another writer's change.

Transactional writes and atomic counter operations can be rivals even though they
are not themselves the non-atomic pair. Table and key identities follow supported
record and parameter forwarding. A locally single writer can still have peers on
other nodes; this model does not prove cluster-wide serialization.

## Publishing a reference too early

`ets_publish_order` · **warning**

Code publishes a value in table A before creating the row keyed by it in table B.
A concurrent reader can follow the value and raise on the missing B row. The finding
requires ordered writes, distinct tables, a compatible reader and an escaping error.
Create the target row before publishing it, and account for any failed publication
when deciding how to clean up.

Unknown key origins can be treated as possible matches. The model does not establish
all application-level publication protocols.

## Using a row after a presence check

`ets_missing_row` · **warning**

A lookup or membership check establishes that a row exists, but another process can
remove it before lookup_element or update_counter requires it. The resulting badarg
escapes. A presence check does not reserve the row; use a suitable atomic operation,
default-taking API or explicit handling of removal where that matches the contract.

The remover can be a take, delete, bulk removal or table deletion. Key matching and
process reachability bound the analysis; unresolved identities can over-approximate
possible interference.

## Interference model

`CheckThenAct.meets` relates a read to an act it controls or supplies, translating
resource and key identities through parameters, returns and loops. A rival is
another execution of the pair or a compatible operation in another process.
Parameter-keyed writes are evaluated at their callers; an accessor used for several
literal keys must not become a writer to every row.

`PairCarries` follows this pair's read to its write. `MadeOfRead` asks whether a rival
writes back a read-derived value. Keeping those contexts separate avoids joining one
caller's read to another caller's decision.

### Row identity

`EtsTable` uses a literal name, allocation site or module field. Unknown external
parameters can match any compatible key. Distinct literals, incompatible shapes,
freshly minted keys and each process's own PID can separate rows. `held_row` also
treats tables whose creating writes all mint keys as per-holder storage.

These are approximations: a minted key can be shared, a computed key can equal a
literal the model treats as distinct, and extracted ETS keys assume the first tuple
element even when custom `keypos` changes it. Unknown refill sources are treated as
potentially changing; an effect missed in a supposedly pure helper can hide a refill
race.

### Concurrent execution

`RunsConcurrently` uses process entries, instance multiplicity, requests and external
callers. `single_process` needs one known instance and no competing caller path.
`runs_beside` asks whether another process can reach the rival while the pair runs;
`runs_beside_up` restricts that other process to work after startup. A helper called
by both the owner and a janitor belongs to both processes.

Startup-only writes are often treated as preceding normal work, but later sibling
initialization and independent restarts can violate that order. Dead exports and
mutually exclusive configurations can overstate concurrency. Local serialization
does not establish one Mnesia writer across nodes.

### Loader handoff

`handed_off` excludes overlap between a loader and server only when:

1. Initialization spawns one loader for this server incarnation.
2. The loader's last action sends a known report to that server.
3. No other producer can send that report tag.
4. Every server path to the operation waits for the report, directly or through a
   state gate only that report opens.

Unknown state writes, another gate-opening return or direct handler calls defeat
the gate proof. A callback-name helper is not necessarily a runtime callback.
Known request tags can exclude unreachable clauses; unknown messages remain possible
requests. The handoff does not rule out an old unlinked loader writing after restart.

### Serialization assumptions

A Mnesia pair can be treated as serialized when every visible table writer uses a
global transaction lock. The check does not compare lock identities, so different
locks can hide a real race. Unmodeled locks and application protocols can instead
cause false positives. A presence check or an individual atomic operation does not
reserve a row across a larger sequence.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/races.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/races.ex).
