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
    is taken nowhere, and more than one process can run `func`: the
    lookup-then-start race, and its release twin,
    lookup-then-unregister. `key_source` says how `func` names the key
    (`literal`, `param`, `field`, `local`, `dynamic` or `any`).
  - `ets_check_act(mod, func, name, key, read, write)` — an ETS read
    decides or feeds a plain write of the same key on a public table
    another process can write. A delete, a refill every racer computes
    alike, and a write whose decision never leaves the function are not
    lost updates, unless the program also writes the table back from a
    read or counts in it. Nor is an update or a delete of a row only its
    holder writes: every row the table gets is made at a key minted there
    (a reference, a monitor, a unique integer) and handed to one process,
    and the others' writes that reach it only remove it.
  - `mnesia_check_act(mod, func, table, key, read, write, op)` — a dirty
    read decides or feeds a dirty write (`op`: `dirty_write`,
    `dirty_delete` or `dirty_delete_object`) of the same record, and
    another process can write the table. A table only one process
    writes is not reported; that process is one per node, so a table
    replicated to nodes that each run its owner is taken as having one
    writer.
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
  the check as a related frame; a publish-order finding is a `:warning`
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
      # a refill of one each racer returns is not both racers' answer.
      Argus.Extractors.Purity,
      # :global.trans, whose closures a cluster lock serializes.
      Argus.Extractors.ApiCalls,
      # The processes a spawn, a task or an agent starts: entries of their
      # own for RunsConcurrently (clientlib/concurrency.dl).
      Argus.Extractors.PidFlow
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
          {:key_source, :symbol, "literal | param | field | local | dynamic | any"},
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
          {:name, :symbol, "the table"},
          {:key, :symbol, "the key, as func identifies it"},
          {:read, :symbol, "instruction ID of the read"},
          {:write, :symbol, "instruction ID of the write it decides or feeds"}
        ],
        key: [:func, :name, :key],
        doc: "A read decides a write of the same key on a public table another process can write."
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
          {:op, :symbol, "dirty_write | dirty_delete | dirty_delete_object"}
        ],
        key: [:func, :table, :key],
        doc:
          "A dirty read decides or feeds a dirty write of the same record another process can write."
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
      }
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

  def finding(:ets_check_act, [mod, func, name, _key, read, write]) do
    Findings.new(
      :warning,
      "Read-then-write race on an ETS key",
      "#{func} reads a key of #{name}#{Findings.elsewhere(read, func)} and writes it" <>
        "#{Findings.elsewhere(write, func)} as the read says to. The table is public and " <>
        "another process can write it between the two, so the write acts on a row that " <>
        "may have changed — the read-decide-write race that the ETS built-ins are " <>
        "documented not to protect against.",
      at: Findings.at_site(write, mod),
      at_label: "this write was decided by a read that may be stale",
      related: [Findings.related("the read it depends on", Findings.at_site(read, mod))],
      help: [
        "make the check and the write one operation: `:ets.insert_new/2`, " <>
          "`:ets.update_counter/4` with a default, or `:ets.select_replace/2`",
        "or route writes to #{name} through its owner process and make the table `:protected`"
      ]
    )
  end

  def finding(:mnesia_check_act, [mod, func, table, _key, read, write, op]) do
    {acts, what} =
      case op do
        "dirty_write" ->
          {"writes it back with a dirty write", "one of the writes is lost"}

        _delete ->
          {"deletes it with #{op}",
           "the delete can remove a record another process wrote back in between"}
      end

    Findings.new(
      :warning,
      "Read-then-write race on a Mnesia record",
      "#{func} reads a record of #{table} with a dirty read#{Findings.elsewhere(read, func)} " <>
        "and #{acts}#{Findings.elsewhere(write, func)} decided by, " <>
        "or computed from, what it read. Dirty operations bypass Mnesia's transactions: " <>
        "another process can write the record between the two, and #{what}.",
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

  # A "field" table is spelled with its module, which the prose has.
  defp describe_table("field", ident), do: "the table held under #{field_path(ident)}"
  defp describe_table("new", site), do: "the table made at #{site}"
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
      {n, ""} when n in 0..9 ->
        ordinal = Enum.at(~w(first second third fourth fifth sixth seventh eighth ninth tenth), n)
        "the name in its #{ordinal} argument"

      _ ->
        "the name"
    end
  end

  defp describe_key(_local_dynamic_or_any, _key), do: "the name"

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
