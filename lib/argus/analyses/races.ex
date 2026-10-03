defmodule Argus.Analyses.Races do
  @moduledoc """
  Check-then-act races on shared state: a read decides a write of the same
  thing, nothing holds it between the two, and another process can write
  it in the window (Christakis and Sagonas, PADL 2010). The read and the
  write may sit in different functions: they meet where the read's result
  is born or returned to, through helpers, arguments and loops
  (`clientlib/check_then_act.dl`), and `func` is where they meet.

  - `registry_race(mod, func, lookup_api, create_api, key_source, key,
    check, act)` — a lookup of a process name decides a start,
    registration or unregistration of the same name, the losing outcome
    is taken nowhere, and a second claimant can act in the window: more
    than one process runs `func`, or another process claims the same
    name (two servers that each start one cache on first use): the
    lookup-then-start race, and its release twin,
    lookup-then-unregister. `key_source` says how `func` names the key
    (`literal`, `param`, `field`, `local`, `dynamic` or `any`).
  - `ets_check_act(mod, func, name, key, read, write, kind)` — an ETS read
    decides or feeds a plain write of the same key on a public table, a
    rival write can land on the row between the two (the pair itself in a
    second process, or another write of the row in a process other than
    the pair's), and what the rival and the write do together has a
    witness (`kind`): `lost_update` (the write stores what this read
    returned), `claim` (a first insert whose verdict the caller is told),
    `take` (a delete that hands out the row it removes), `guarded` (a
    guard on the row compared with the value written), `clobber` (a
    write over a row a rival counts in), `state_delete` (a delete made on
    what the row holds, over a row a rival made again), `minted` (a
    minted value handed out), `decides_more` (the decision also sends or
    writes elsewhere) or `stale_fill` (a refill landing after a rival
    removed or rewrote the row). No witness, no row: two racers writing
    the same default, a refill nothing makes stale, a delete made twice.
    A write is seen where its key is named, so an accessor's operation
    (`mnesia_lib:set/2`) is its callers', at the key each hands it: `read`
    or `write` is the meeting function's call to the accessor, or the
    operation itself when the function reaches the accessor only through
    another call. One row per write. A table the program's users hand
    in, which nothing in view names, is `name`d by the parameter it
    arrives in (`param 0`, counted from 0).
  - `mnesia_check_act(mod, func, table, key, read, write, op, kind)` — a
    dirty read decides or feeds a dirty write (`op`: `dirty_write`,
    `dirty_delete` or `dirty_delete_object`) of the same record, and
    another process can write the table. One row per write: `kind` says
    what the interleaving costs, each with its witness — `unique` (a
    search by index or pattern found nothing and a new record is
    inserted: both racers insert), `lost_update` (the write stores what
    this pair's read returned), `guarded` (the decision compares the
    record with the value written), `claim` (an insert-if-absent whose
    verdict the caller gets), `decides_more`, `delete` (made on what the
    record holds, over a record a rival wrote or made again, or one whose
    decision sends or hands the record out), or `fill` (a record computed
    afresh, over a rival's removal or write: the weakest, an `:info`). A
    table only one process writes is not reported; that process is one
    per node, so a table replicated to nodes that each run its owner is
    taken as having one writer.
  - `ets_race_frame(write, role, site, func)` — evidence for an ETS
    finding: the same race's other writes (`also_writes`), the other
    reads deciding the write (`read`), and the rival writes that witness
    its harm (`rival`).
  - `mnesia_race_frame(write, role, site, func)` — evidence for a
    Mnesia finding: the same race's other writes (`also_writes`), the
    other reads deciding the write (`read`), and, for a pair one process
    runs, the writers outside that process (`other_writer`).
  - `ets_publish_order(mod, func, published_kind, published_in,
    completed_kind, completed_in, publish, complete, reader)` — not a
    check-then-act but a race on the same stores: `func` writes a row of
    one table holding a value (`publish`), and only then the row another
    table keys by that value (`complete`). Between the two, a process
    that took the value from the first table and reads the second at it
    with a read that raises on a missing row (`reader`:
    `:ets.lookup_element/3`, `:ets.update_counter/3`) crashes with
    `badarg`. The two writes may be `func`'s own or its callees'.
  - `ets_missing_row(mod, func, table_kind, table, check, act, remover)` —
    a read decides that a row is there (`check`) and an operation that
    raises when it is not acts on it (`act`: `:ets.update_counter/3`,
    `:ets.lookup_element/3`), while `remover`, a take or delete of the
    table's rows, can run in another process between the two: the act
    crashes on the row the remover took.

  A table is what `clientlib/tables.dl` says an operation may touch:
  `named` and its name, `new` and the `:ets.new/2` site that made it
  (followed as process points-to follows a pid), or, where neither is
  known, `field` and the module and map path it is read under.

  Every check-then-act finding is a `:warning` anchored at the act, with
  the check as a related frame, but a Mnesia fill and an ETS stale fill,
  each an `:info`; a
  publish-order finding is a `:warning`
  anchored at the early write, with the completing write and the reader
  as related frames; a missing-row finding is a `:warning` anchored at the
  act, with the check and the remover as related frames.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :races

  @impl true
  def description,
    do:
      "check-then-act races on a process name, an ETS key or a Mnesia record that " <>
        "another process can write between the check and the act, ETS values " <>
        "published before the rows they point to, and ETS rows acted on after another " <>
        "process may have removed them"

  @impl true
  def rules_file, do: "analyses/races.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ETS,
      Argus.Extractors.Mnesia,
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.OTP,
      Argus.Extractors.Supervision,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.GenStatem,
      Argus.Extractors.CallArgs,
      Argus.Extractors.Dependence,
      Argus.Extractors.Specs,
      # Which calls mint a value (a random API, a unique integer, a ref):
      # a fill of one each racer returns is not both racers' answer.
      Argus.Extractors.Purity,
      # :global.trans, whose closures a cluster lock serializes.
      Argus.Extractors.ApiCalls,
      # The processes a spawn, a task or an agent starts: entries of their
      # own for RunsConcurrently (clientlib/concurrency.dl).
      Argus.Extractors.TermFlow,
      # A loader's handoff (clientlib/concurrency.dl, handed_off): the
      # clause of a handler a site is in (clause_call), and the field of
      # its state a site waits on and what the returns set it to
      # (state_excluded, state_return).
      Argus.Extractors.ClauseCall,
      Argus.Extractors.StateGate,
      Argus.Extractors.Tooling
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :registry_race,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function where the lookup's result meets the act"},
          {:lookup_api, :symbol, "whereis | registry_lookup | registered"},
          {:create_api, :symbol,
           "register | start_link | start | start_via | registry_register | start_child | unregister"},
          {:key_source, :symbol,
           "literal | param | element N (of a parameter) | field | local | dynamic | any"},
          {:key, :symbol,
           "the name, as func identifies it: the literal, a parameter's position, a field's key"},
          {:check, :symbol, "instruction ID of the lookup"},
          {:act, :symbol, "instruction ID of the start or registration"}
        ],
        key: [:func, :key],
        doc:
          "A lookup decides a start or release of the same name, and a second caller can act in the window."
      },
      %{
        name: :ets_check_act,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function where the read's result meets the write"},
          {:name, :symbol,
           "the table: its name, or `param N` for one func's callers outside the program hand in"},
          {:key, :symbol, "the key, as func identifies it"},
          {:read, :symbol, "instruction ID of the read"},
          {:write, :symbol, "instruction ID of the write it decides or feeds"},
          {:kind, :symbol,
           "lost_update | claim | take | guarded | clobber | state_delete | minted | " <>
             "decides_more | stale_fill"}
        ],
        key: [:write],
        doc:
          "A read decides a write of the same key on a public table, a rival write can land " <>
            "between the two, and the interleaving has a witnessed harm."
      },
      %{
        name: :ets_race_frame,
        fields: [
          {:write, :symbol, "the finding's write"},
          {:role, :symbol, "also_writes | read | rival"},
          {:site, :symbol, "instruction ID of the other write, the other read or the rival"},
          {:func, :symbol, "the function the site is reported from"}
        ],
        key: [:write, :role, :site],
        evidence: %{of: :ets_check_act, on: [:write], limit: 4},
        doc:
          "The same race's other writes, the other reads deciding the write, and the rival " <>
            "writes witnessing its harm, attached to its finding."
      },
      %{
        name: :mnesia_check_act,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function where the read's result meets the write"},
          {:table, :symbol, "the table"},
          {:key, :symbol, "the key, as func identifies it"},
          {:read, :symbol, "instruction ID of the dirty read"},
          {:write, :symbol, "instruction ID of the dirty write it decides or feeds"},
          {:op, :symbol, "dirty_write | dirty_delete | dirty_delete_object"},
          {:kind, :symbol,
           "unique | lost_update | guarded | claim | delete | decides_more | fill"}
        ],
        key: [:write],
        doc:
          "A dirty read decides or feeds a dirty write of the same record another process can write."
      },
      %{
        name: :mnesia_race_frame,
        fields: [
          {:write, :symbol, "the finding's dirty write"},
          {:role, :symbol, "also_writes | other_writer | read"},
          {:site, :symbol, "instruction ID of the other write, the outside writer or the read"},
          {:func, :symbol, "the function the site is reached from"}
        ],
        key: [:write, :role, :site],
        evidence: %{of: :mnesia_check_act, on: [:write], limit: 4},
        doc:
          "The same race's other writes, the other reads deciding the write, and the writers " <>
            "outside the one process a pair runs in, attached to its finding."
      },
      %{
        name: :ets_publish_order,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function making both writes"},
          {:published_kind, :symbol, "named | new | field: how the first table is known"},
          {:published_in, :symbol,
           "the first table: its name, the :ets.new/2 site, or the module and field path"},
          {:completed_kind, :symbol, "named | new | field: how the second table is known"},
          {:completed_in, :symbol, "the second table, likewise"},
          {:publish, :symbol, "instruction ID of the write that makes the value findable"},
          {:complete, :symbol, "instruction ID of the later write of the row keyed by it"},
          {:reader, :symbol, "instruction ID of a read of the second table that raises on a miss"}
        ],
        key: [:func, :publish, :complete],
        doc:
          "A value is published in one ETS table before the row another table keys by it exists."
      },
      %{
        name: :ets_missing_row,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function where the read's result meets the act"},
          {:table_kind, :symbol, "named | new | field"},
          {:table, :symbol, "the table, as table_kind spells it"},
          {:check, :symbol, "instruction ID of the read that decides the row is there"},
          {:act, :symbol, "instruction ID of the operation that raises when it is not"},
          {:remover, :symbol, "instruction ID of a take or delete another process can run"}
        ],
        key: [:func, :act],
        doc:
          "A read decides a row is there and a raising operation acts on it while another process can remove it."
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:registry_race, [mod, func, lookup_api, "unregister", key_source, key, check, act]) do
    Findings.new(
      :warning,
      "Lookup-then-unregister race on a process name",
      "#{func} asks whether #{describe_key(key_source, key)} is registered " <>
        "(#{lookup(lookup_api)}#{Findings.elsewhere(check, func)}) and unregisters it" <>
        "#{Findings.elsewhere(act, func)} when the answer is yes. The name can go " <>
        "between the two — its process exits and is unregistered with it, or another " <>
        "caller unregisters it first — and unregister/1 then raises ArgumentError, " <>
        "which nothing here rescues.",
      at: Findings.at_site(act, mod),
      at_label: "this unregister runs after the lookup has gone stale",
      related: [Findings.related("the lookup it depends on", Findings.at_site(check, mod))],
      help: [
        "unregister unconditionally and rescue `ArgumentError` (`catch error:badarg` in Erlang)",
        "or leave the name to the process holding it: a registered name goes when its process exits"
      ]
    )
  end

  def finding(:registry_race, [mod, func, lookup_api, create_api, key_source, key, check, act]) do
    Findings.new(
      :warning,
      "Lookup-then-start race on a process name",
      "#{func} asks whether #{describe_key(key_source, key)} is registered " <>
        "(#{lookup(lookup_api)}#{Findings.elsewhere(check, func)}) and " <>
        "#{create(create_api)}#{Findings.elsewhere(act, func)} when the answer is no. " <>
        "Nothing holds the name between the two: a second caller that asks in the same " <>
        "window gets the same answer, and one of the two starts loses — " <>
        "{:error, {:already_started, pid}} from a start, an ArgumentError from " <>
        "register/2 — which is taken nowhere.",
      at: Findings.at_site(act, mod),
      at_label: "this start runs after the lookup has gone stale",
      related: [Findings.related("the lookup it depends on", Findings.at_site(check, mod))],
      help: [
        "make the start the check: start unconditionally and treat " <>
          "`{:error, {:already_started, pid}}` as `{:ok, pid}`",
        "for a Registry, `Registry.register/3` and its `{:error, {:already_registered, pid}}` " <>
          "replace the lookup",
        "if the decision must span both, serialise it through one process — the owner, or " <>
          "`:global.trans/2`"
      ]
    )
  end

  def finding(:ets_check_act, [mod, func, name, _key, read, write, "stale_fill"]) do
    {table, _shared} = ets_table_prose(name)

    Findings.new(
      :info,
      "ETS row refilled on a stale read",
      "#{func} reads a key of #{table}#{Findings.elsewhere(read, func)} and, on what it " <>
        "found, writes a value a call or another store computed#{Findings.elsewhere(write, func)}. " <>
        "Another process can remove the row or write a value of its own between the two, and " <>
        "the fill, computed before that write, lands after it: the stale value stays until " <>
        "something clears it again.",
      at: Findings.at_site(write, mod),
      at_label: "this fill may land over a newer write",
      related: [Findings.related("the read it depends on", Findings.at_site(read, mod))],
      help: [
        "fill only what is still absent: `:ets.insert_new/2`, so a newer row wins",
        "or invalidate after the source is written and have fills check a version the " <>
          "invalidation bumps"
      ]
    )
  end

  def finding(:ets_check_act, [mod, func, name, _key, read, write, kind]) do
    {table, shared} = ets_table_prose(name)

    Findings.new(
      :warning,
      "Read-then-write race on an ETS key",
      "#{func} reads a key of #{table}#{Findings.elsewhere(read, func)} and " <>
        "#{ets_act(kind)}#{Findings.elsewhere(write, func)}. #{shared} another process can " <>
        "write the row between the two, and #{ets_loss(kind)}.",
      at: Findings.at_site(write, mod),
      at_label: "this write was decided by a read that may be stale",
      related: [Findings.related("the read it depends on", Findings.at_site(read, mod))],
      help: [
        "make the check and the write one operation: `:ets.insert_new/2`, " <>
          "`:ets.update_counter/4` with a default, `:ets.take/2`, or `:ets.select_replace/2`",
        "or route writes to #{table} through its owner process and make the table `:protected`"
      ]
    )
  end

  def finding(:mnesia_check_act, [mod, func, table, _key, read, write, _op, "unique"]) do
    Findings.new(
      :warning,
      "Uniqueness check-then-insert race on a Mnesia table",
      "#{func} searches #{table} with a dirty read#{Findings.elsewhere(read, func)} — by an " <>
        "index or a pattern, not by the record's key — and, finding nothing, inserts a new " <>
        "record with a dirty write#{Findings.elsewhere(write, func)}. Dirty operations bypass " <>
        "Mnesia's transactions: two callers that search in the same window both find " <>
        "nothing and both insert, each under a key of its own — the duplicate the search " <>
        "was there to prevent, which neither write overwrites.",
      at: Findings.at_site(write, mod),
      at_label: "this insert runs after a search that may be stale",
      related: [
        Findings.related("the search that found nothing", Findings.at_site(read, mod))
      ],
      help: [
        "search and insert in one `:mnesia.transaction/1` (`:mnesia.index_read/3` or " <>
          "`:mnesia.match_object/1` there, then `:mnesia.write/1`), so the second " <>
          "insert waits for the first and sees it",
        "or key the record by the value that must be unique, so a second insert is " <>
          "the same record"
      ]
    )
  end

  def finding(:mnesia_check_act, [mod, func, table, _key, read, write, op, "fill"]) do
    Findings.new(
      :info,
      "Dirty write fills a Mnesia record on a stale read",
      "#{func} reads a record of #{table} with a dirty read#{Findings.elsewhere(read, func)} " <>
        "and, on what it found, writes a record it computed afresh with a dirty write" <>
        "#{Findings.elsewhere(write, func)}. The table is written back from reads elsewhere, " <>
        "or the decision does more than fill it: a write another process makes between the " <>
        "two is overwritten by a value computed before it. Weaker than a lost update — the " <>
        "fill is what a racer would compute too — but it can undo an update.",
      at: Findings.at_site(write, mod),
      at_label: "this #{String.replace(op, "_", " ")} may overwrite a newer record",
      related: [Findings.related("the dirty read it depends on", Findings.at_site(read, mod))],
      help: [
        "read and write in one `:mnesia.transaction/1`, with `:mnesia.read/1` and " <>
          "`:mnesia.write/1`",
        "or fill only what is still absent, inside the transaction"
      ]
    )
  end

  def finding(:mnesia_check_act, [mod, func, table, _key, read, write, op, kind]) do
    Findings.new(
      :warning,
      "Read-then-write race on a Mnesia record",
      "#{func} reads a record of #{table} with a dirty read#{Findings.elsewhere(read, func)} " <>
        "and #{record_act(kind, op)}#{Findings.elsewhere(write, func)}. Dirty operations " <>
        "bypass Mnesia's transactions: another process can write the record between the " <>
        "two, and #{record_loss(kind)}.",
      at: Findings.at_site(write, mod),
      at_label: "this #{String.replace(op, "_", " ")} acts on a read that may be stale",
      related: [Findings.related("the dirty read it depends on", Findings.at_site(read, mod))],
      help: [
        "read and write in one `:mnesia.transaction/1`, with `:mnesia.read/1` and " <>
          "`:mnesia.write/1`",
        "for a counter, `:mnesia.dirty_update_counter/3` is atomic"
      ]
    )
  end

  def finding(:ets_publish_order, [
        mod,
        func,
        published_kind,
        published_in,
        completed_kind,
        completed_in,
        publish,
        complete,
        reader
      ]) do
    first = describe_table(published_kind, published_in)
    second = describe_table(completed_kind, completed_in)
    row_in = label_table(completed_kind, completed_in)

    Findings.new(
      :warning,
      "ETS row published before the row it points to",
      "#{func} writes a value into #{first}#{Findings.elsewhere(publish, func)}, " <>
        "and only then writes the row of #{second} keyed by that value" <>
        "#{Findings.elsewhere(complete, func)}. Both tables are shared: between the two " <>
        "writes another process can find the value in #{first} and read #{second} at it" <>
        "#{Findings.elsewhere(reader, func)}, with a read that raises ArgumentError " <>
        "(badarg) when the row is not there yet.",
      at: Findings.at_site(publish, mod),
      at_label: "this publishes the value before its row in #{row_in} exists",
      related: [
        Findings.related("the row it points to is written here", Findings.at_site(complete, mod)),
        Findings.related(
          "a read that raises if the row is not there yet",
          Findings.at_site(reader, mod)
        )
      ],
      help: [
        "write the row of #{second} first, then publish the value in #{first}; " <>
          "if publishing can lose (`:ets.insert_new/2`), delete the row the loser wrote",
        "or read with a default: `:ets.lookup_element/4` (OTP 26), or `:ets.lookup/2` " <>
          "and handle `[]`"
      ]
    )
  end

  def finding(:ets_missing_row, [mod, func, kind, table, check, act, remover]) do
    name = describe_table(kind, table)

    Findings.new(
      :warning,
      "ETS row acted on after another process may have removed it",
      "#{func} reads a key of #{name}#{Findings.elsewhere(check, func)} and, finding the " <>
        "row, acts on it with an operation that raises when the row is missing" <>
        "#{Findings.elsewhere(act, func)}. Another process can take or delete the row " <>
        "between the two#{Findings.elsewhere(remover, func)}, and the act then raises " <>
        "ArgumentError (badarg) in a process that meant only to update the row.",
      at: Findings.at_site(act, mod),
      at_label: "this raises if the row was removed after the read",
      related: [
        Findings.related("the read that decided the row was there", Findings.at_site(check, mod)),
        Findings.related(
          "another process can remove the row here",
          Findings.at_site(remover, mod)
        )
      ],
      help: [
        "make the act one step that tolerates a missing row: `:ets.update_counter/4` with a " <>
          "default object, or `:ets.lookup_element/4` (OTP 26)",
        "or rescue `ArgumentError` around the act, as a row that went away is an expected outcome"
      ]
    )
  end

  @impl true
  def evidence(frame, [_write, "also_writes", site, func])
      when frame in [:ets_race_frame, :mnesia_race_frame] do
    Findings.related("the same race writes here too", Findings.at_site_in_func(site, func))
  end

  def evidence(:mnesia_race_frame, [_write, "other_writer", site, func]) do
    Findings.related(
      "written here too, outside the one process the pair runs in",
      Findings.at_site_in_func(site, func)
    )
  end

  def evidence(:ets_race_frame, [_write, "rival", site, func]) do
    Findings.related(
      "another process can write the row here, from " <> Findings.call_name(func),
      Findings.at_site_in_func(site, func)
    )
  end

  def evidence(:ets_race_frame, [_write, "read", site, func]) do
    Findings.related(
      "also decided by this read, where it meets the write in " <> Findings.call_name(func),
      Findings.at_site_in_func(site, func)
    )
  end

  def evidence(:mnesia_race_frame, [_write, "read", site, func]) do
    Findings.related(
      "also decided by this dirty read, where it meets the write in " <>
        Findings.call_name(func),
      Findings.at_site_in_func(site, func)
    )
  end

  # What an ETS check-then-act does with the row, and what the
  # interleaving costs, by the harm its rival witnesses.
  defp ets_act("lost_update"), do: "writes back a value made of what it read"
  defp ets_act("claim"), do: "makes the row when it found none, and tells its caller so"
  defp ets_act("take"), do: "deletes the row it found and hands out what it held"
  defp ets_act("guarded"), do: "compares the row with the value it then writes, and writes it"
  defp ets_act("clobber"), do: "writes a value of its own over the row"
  defp ets_act("state_delete"), do: "deletes the row, on what the row held"
  defp ets_act("minted"), do: "stores a value it minted, and hands that value out"

  defp ets_act(_decides_more),
    do: "writes the row, on a decision that also sends or writes elsewhere"

  defp ets_loss("lost_update"), do: "one of the two updates is lost"

  defp ets_loss("claim"),
    do: "two callers can both find none, both write, and both be told they won"

  defp ets_loss("take"), do: "two callers can both take the one row"

  defp ets_loss("guarded"),
    do: "two updates can both pass the check, and the older can land last"

  defp ets_loss("clobber"),
    do: "the counts another process added to the row since the read are lost"

  defp ets_loss("state_delete"),
    do:
      "the delete can take the row another process made since the read, which the decision " <>
        "never saw"

  defp ets_loss("minted"),
    do: "each caller hands out its own value, and only one of them is stored"

  defp ets_loss(_decides_more),
    do: "both callers can take the decision, and both make the rest of it"

  # What a Mnesia check-then-act does with the record, and what the
  # interleaving loses, by kind.
  defp record_act("lost_update", op),
    do: "writes back a record made of what it read, with a #{String.replace(op, "_", " ")}"

  defp record_act("guarded", _op),
    do:
      "compares the record with the value it then writes, and writes that value with a " <>
        "dirty write"

  defp record_act("claim", _op),
    do: "writes the record when it found none, and tells its caller so, with a dirty write"

  defp record_act("decides_more", _op),
    do:
      "writes the record with a dirty write, on a decision that also makes another write " <>
        "or sends"

  defp record_act(_delete, op), do: "deletes it with #{op}, as the read decided"

  defp record_loss("lost_update"), do: "one of the writes is lost"

  defp record_loss("guarded"),
    do: "two updates can both pass the check and the older can land last"

  defp record_loss("claim"),
    do: "two callers can both find none, both write, and both be told they won"

  defp record_loss("decides_more"),
    do:
      "two callers can both take the decision, and both make the rest of it: an " <>
        "idempotency marker both set, and both charge"

  defp record_loss(_delete),
    do:
      "the delete can remove a record another process wrote back or made again in between, " <>
        "or two callers can both take the one record"

  # The table an ETS check-then-act touches, and why another process can
  # write it: a public table by its name, or one its callers outside the
  # program hand in, by the parameter it arrives in.
  defp ets_table_prose("param " <> position = name) do
    case Integer.parse(position) do
      {n, ""} when n in 0..9 ->
        {"the table in its #{ordinal(n)} argument",
         "The table is its callers', and each writes it from its own process, " <>
           "which only a public table allows:"}

      _ ->
        {name, "The table is public and"}
    end
  end

  defp ets_table_prose(name), do: {name, "The table is public and"}

  # A "field" table is spelled with its module, which the prose has.
  defp describe_table("field", ident), do: "the table held under #{field_path(ident)}"
  defp describe_table("new", site), do: "the table made at #{site}"

  # A handed-in table is spelled "param P of F" (clientlib/tables.dl): the
  # table the program's users pass F there.
  defp describe_table("handed_in", ident) do
    with ["param", position, "of", way_in] <- String.split(ident, " ", parts: 4),
         {n, ""} when n in 0..9 <- Integer.parse(position) do
      "the table callers pass #{way_in} as its #{ordinal(n)} argument"
    else
      _ -> "the table callers hand in (#{ident})"
    end
  end

  defp describe_table(_named, name), do: name

  # A label sits beside the code, which shows the map the table is read
  # from, so it names a field table by its path alone (`:reverse`), as it
  # names a named table by its name.
  defp label_table("field", ident), do: field_path(ident)
  defp label_table(kind, ident), do: describe_table(kind, ident)

  defp field_path(ident), do: ident |> String.split(" ", parts: 2) |> List.last()

  # The name as the function sees it. A parameter's key is its position,
  # which reads as a number only to the facts.
  defp describe_key("literal", key) when key != "", do: key
  defp describe_key("field", key) when key != "", do: "the name held under #{key}"

  defp describe_key("param", position) do
    case Integer.parse(position) do
      {n, ""} when n in 0..9 -> "the name in its #{ordinal(n)} argument"
      _ -> "the name"
    end
  end

  defp describe_key(_local_dynamic_or_any, _key), do: "the name"

  # An argument's place, counted from 0.
  defp ordinal(n),
    do: Enum.at(~w(first second third fourth fifth sixth seventh eighth ninth tenth), n)

  defp lookup("whereis"), do: "whereis"
  defp lookup("registry_lookup"), do: "Registry.lookup"
  defp lookup("registered"), do: "Process.registered"
  defp lookup(other), do: other

  defp create("register"), do: "registers it"
  defp create("registry_register"), do: "registers it in the Registry"
  defp create("start_child"), do: "starts a child"
  defp create("start_via"), do: "starts a process under it"
  defp create(_start), do: "starts a process named by it"
end
