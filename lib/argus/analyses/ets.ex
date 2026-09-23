defmodule Argus.Analyses.Ets do
  @moduledoc """
  ETS table analysis, and the shared-table races Mnesia's dirty operations
  share with it.

  Detects ETS usage patterns and potential issues: tables without proper
  concurrency options, unprotected owners, unnamed tables in processes,
  ordered_set contention across modules, and read-then-write races on a
  public table or a Mnesia record.

  Requires the ETS, OTP, and Supervision domain extractors for layer 2 facts
  about table creation, options, access patterns, and supervisor children.

  Tables owned by permanent supervisor children are suppressed from
  `ets_unprotected_owner` since the table is recreated on restart.

  ## Output relations

  - `ets_unprotected_owner(name, mod)` — table owner lacks heir protection (excludes permanent children).
  - `ets_missing_read_concurrency(name)` — table lacks read_concurrency option.
  - `ets_missing_write_concurrency(name)` — table lacks write_concurrency option.
  - `ets_ordered_set_contention(name, mod1, mod2)` — ordered_set accessed by multiple modules.
  - `ets_unnamed_in_process(name, mod)` — unnamed table created in a process.
  - `ets_check_act(mod, func, name, key, read, write)` — a read decides or feeds a plain write of the same key on a public table another process can write; the two may sit in different functions and meet in `func`.
  - `mnesia_check_act(mod, func, table, key, read, write)` — a dirty read decides or feeds a dirty write of the same record, and another process can write the table.

  ## Finding severities

  - `ets_unprotected_owner` — `:warning`. Data loss on owner crash is a
    correctness hazard.
  - `ets_missing_read_concurrency`, `ets_missing_write_concurrency`,
    `ets_ordered_set_contention` — `:info`. Performance tuning hints; the
    right setting depends on the table's actual access pattern.
  - `ets_unnamed_in_process` — `:info`. A common, often deliberate
    pattern; flagged because the table is unreachable if the owner loses
    the reference.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :ets

  @impl true
  def description,
    do:
      "ETS table ownership, concurrency options and lifecycle, and read-then-write races " <>
        "on ETS and Mnesia"

  @impl true
  def rules_file, do: "analyses/ets.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ETS,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Supervision,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.GenStatem,
      Argus.Extractors.CallArgs,
      Argus.Extractors.Mnesia,
      Argus.Extractors.Dependence
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :ets_read_outside_owner,
        fields: [
          {:name, :symbol, "the table, or 'dynamic' when its name is computed"},
          {:owner, :symbol, "the module whose callbacks create it"},
          {:reader, :symbol, "a function reading it that the owner's callbacks do not reach"},
          {:site, :symbol, "the read"},
          {:created, :symbol, "the :ets.new call"}
        ],
        key: [:owner, :reader],
        doc:
          "A table read from callers' processes with no heir and no rescue for the owner's restart window."
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
          {:write, :symbol, "instruction ID of the dirty write it decides or feeds"}
        ],
        key: [:func, :table, :key],
        doc:
          "A dirty read decides or feeds a dirty write of the same record another process can write."
      },
      %{
        name: :ets_unprotected_owner,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "owner module"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        key: [:name, :mod],
        doc: "Table owner lacks heir protection (excludes permanent children)."
      },
      %{
        name: :ets_missing_read_concurrency,
        fields: [{:name, :symbol, "table name"}],
        doc: "Table lacks read_concurrency option."
      },
      %{
        name: :ets_missing_write_concurrency,
        fields: [{:name, :symbol, "table name"}],
        doc: "Table lacks write_concurrency option."
      },
      %{
        name: :ets_ordered_set_contention,
        fields: [
          {:name, :symbol, "table name"},
          {:mod1, :symbol, "first accessor module"},
          {:mod2, :symbol, "second accessor module"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        key: [:name, :mod1, :mod2],
        doc: "Ordered_set table accessed by multiple modules."
      },
      %{
        name: :ets_write_only_table,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "owner module"},
          {:site, :symbol, "the :ets.new/2 instruction"}
        ],
        doc: "Named table inserted into outside init/1 and never deleted from: it only grows."
      },
      %{
        name: :ets_unnamed_in_process,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "owner module"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        key: [:name, :mod],
        doc: "Unnamed table created in a process."
      }
    ]
  end

  @impl true
  def finding(:ets_read_outside_owner, [name, owner, reader, site, created]) do
    table = if name == "dynamic", do: "a table", else: name

    Findings.new(
      :info,
      "ETS table read while its owner may be restarting",
      "#{owner} creates #{table} in its own process with no heir, and #{reader} " <>
        "reads it from whatever process calls it. While #{owner} is down — the " <>
        "moment it crashes until its restart reaches :ets.new again — the read " <>
        "raises ArgumentError in the caller instead of returning a value.",
      at: Findings.at_site(site, owner),
      at_label: "read outside the owner",
      related: [Findings.related("created here, with no heir", Findings.at_site(created, owner))],
      help: [
        "give the table a heir (a supervisor or a long-lived holder) so it survives the restart",
        "or rescue ArgumentError in the reader and return an error value"
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

  def finding(:mnesia_check_act, [mod, func, table, _key, read, write]) do
    Findings.new(
      :warning,
      "Read-then-write race on a Mnesia record",
      "#{func} reads a record of #{table} with a dirty read#{Findings.elsewhere(read, func)} " <>
        "and writes it back with a dirty write#{Findings.elsewhere(write, func)} decided by, " <>
        "or computed from, what it read. Dirty operations bypass Mnesia's transactions: " <>
        "another process can write the record between the two, and one of the writes is lost.",
      at: Findings.at_site(write, mod),
      at_label: "this dirty write acts on a read that may be stale",
      related: [Findings.related("the dirty read it depends on", Findings.at_site(read, mod))],
      help: [
        "read and write in one `:mnesia.transaction/1`, with `:mnesia.read/1` and " <>
          "`:mnesia.write/1`",
        "for a counter, `:mnesia.dirty_update_counter/3` is atomic"
      ]
    )
  end

  def finding(:ets_unprotected_owner, [name, mod, site]) do
    Findings.new(
      :warning,
      "ETS table dies with its owner",
      "#{mod} owns table #{name} with no heir, and the owner is not a " <>
        "permanent supervisor child. ETS tables are deleted when their owner " <>
        "exits — one crash and the data is gone.",
      at: Findings.at_site(site, mod),
      at_label: "created here with no heir",
      help: [
        "set an heir (`heir: {pid, data}`), or own the table from a supervised " <>
          "process that rebuilds it"
      ]
    )
  end

  def finding(:ets_missing_read_concurrency, [name]) do
    Findings.new(
      :info,
      "Table without read_concurrency",
      "Table #{name} is created without read_concurrency: true. Concurrent " <>
        "readers of a read-heavy table serialize on its lock; if this table " <>
        "is read from many processes, the option is close to free speedup.",
      help: ["add `read_concurrency: true` to the :ets.new/2 options"]
    )
  end

  def finding(:ets_missing_write_concurrency, [name]) do
    Findings.new(
      :info,
      "Table without write_concurrency",
      "Table #{name} is created without write_concurrency: true. Concurrent " <>
        "writers serialize on a single lock; for write-heavy tables the " <>
        "option reduces contention at the cost of slightly costlier reads.",
      help: ["add `write_concurrency: true` to the :ets.new/2 options"]
    )
  end

  def finding(:ets_ordered_set_contention, [name, mod1, mod2, site]) do
    Findings.new(
      :info,
      "ordered_set shared across modules",
      "The ordered_set table #{name} is accessed by both #{mod1} and " <>
        "#{mod2}. ordered_set operations are O(log n) and contend harder " <>
        "than hash-based tables under concurrent access — worth checking " <>
        "that the ordering is actually needed.",
      at: Findings.at_site(site, mod1),
      at_label: "ordered_set created here",
      related: [Findings.related("other accessor", Findings.at_module(mod2))],
      help: ["use a `set` (or `bag`) unless the ordering is needed"]
    )
  end

  def finding(:ets_write_only_table, [name, mod, site]) do
    Findings.new(
      :info,
      "ETS table #{name} only grows",
      "#{mod} creates #{name} and the code inserts into it outside init/1, " <>
        "but nothing ever deletes from it — no :ets.delete, delete_object, " <>
        "select_delete or take on this table anywhere. Every insert is " <>
        "permanent for the life of the owner, which for a supervised " <>
        "process is the life of the VM. If entries have a natural end — a " <>
        "request completing, a check-in resolving — this is a leak with a " <>
        "slow fuse.",
      at: Findings.at_site(site, mod),
      at_label: "this table has inserts and no deletes",
      help: [
        "delete entries when they are done with, or sweep the table on a " <>
          "timer; if the table is meant to be append-only, cap it or ignore this"
      ]
    )
  end

  def finding(:ets_unnamed_in_process, [name, mod, site]) do
    Findings.new(
      :info,
      "Unnamed table held by a process",
      "#{mod} creates table #{name} without :named_table inside a process. " <>
        "The table is reachable only through its reference — if the owner " <>
        "loses or never shares it, nothing else can read or clean up the " <>
        "table.",
      at: Findings.at_site(site, mod),
      at_label: "created without :named_table",
      help: [
        "name the table (`:named_table`), or hand its reference to whatever " <>
          "must read or delete it"
      ]
    )
  end
end
