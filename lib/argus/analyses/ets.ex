defmodule Argus.Analyses.Ets do
  @moduledoc """
  ETS table ownership, concurrency options and lifecycle.

  - `ets_unprotected_owner(name, mod, site)` — a process owns the table
    with no heir and is not a permanent supervisor child or an
    Application: one crash and the table is gone. `:warning`.
  - `ets_read_outside_owner(name, owner, reader, site, created)` — a
    table created in its owner's process is read from callers' processes,
    with no heir and no rescue for the window while the owner restarts.
    `:info`.
  - `ets_missing_read_concurrency(name, mod, site)`,
    `ets_missing_write_concurrency(name, mod, site)` — two modules read
    (write) the table and it lacks the option. `:info`: performance
    hints whose right setting depends on the access pattern.
  - `ets_ordered_set_contention(name, mod1, mod2, site)` — an ordered_set
    two modules write. `:info`.
  - `ets_write_only_table(name, mod, site)` — a named table inserted into
    outside init/1 and never deleted from. `:info`.
  - `ets_unnamed_in_process(name, mod, site)` — an unnamed table created
    in a process, reachable only through its reference. `:info`: often
    deliberate.
  - `ets_created_in_start(name, mod, site, start)` — a server's
    `start_link` (`start`) creates a named table: it runs in the starting
    process, the supervisor for a child, so the table outlives the
    server's crash and the restart's `:ets.new` raises on the taken name.
    `:warning`.

  `site` is the `:ets.new` call, where every finding but the read outside
  the owner anchors. Tables whose name is computed at runtime take part
  only where a rule says so. The read-then-write race on an ETS key or a
  Mnesia record is in `Argus.Analyses.Races`.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :ets

  @impl true
  def description,
    do: "ETS table ownership, concurrency options and lifecycle"

  @impl true
  def rules_file, do: "analyses/ets.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ETS,
      Argus.Extractors.OTP,
      Argus.Extractors.Supervision,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.GenStatem,
      Argus.Extractors.CallArgs,
      # Where a process starts (process_start): the same-process walk of
      # ets_created_in_start sets aside what a start runs (runs_elsewhere).
      Argus.Extractors.PidFlow
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
        name: :ets_unprotected_owner,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "the module of the process that runs the :ets.new/2"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        # One finding per creation: a helper's named table that several
        # processes may make first is one table, named by its least owner.
        key: [:name, :site],
        doc: "Table owner lacks heir protection (excludes permanent children)."
      },
      %{
        name: :ets_missing_read_concurrency,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "the module creating it"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        doc: "Table lacks read_concurrency option."
      },
      %{
        name: :ets_missing_write_concurrency,
        fields: [
          {:name, :symbol, "table name"},
          {:mod, :symbol, "the module creating it"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
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
          {:mod, :symbol, "the module of the process that runs the :ets.new/2"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"}
        ],
        key: [:name, :site],
        doc: "Unnamed table created in a process."
      },
      %{
        name: :ets_created_in_start,
        fields: [
          {:name, :symbol, "table name, or dynamic"},
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "instruction ID of the :ets.new/2 call"},
          {:start, :symbol, "the server's start_link, on whose stack the call runs"}
        ],
        key: [:site],
        doc: "A server's start_link creates a named table, which its restart cannot create again."
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

  def finding(:ets_missing_read_concurrency, [name, mod, site]) do
    Findings.new(
      :info,
      "Table without read_concurrency",
      "Table #{name} is created without read_concurrency: true. Concurrent " <>
        "readers of a read-heavy table serialize on its lock; if this table " <>
        "is read from many processes, the option is close to free speedup.",
      at: Findings.at_site(site, mod),
      at_label: "created here without read_concurrency",
      help: ["add `read_concurrency: true` to the :ets.new/2 options"]
    )
  end

  def finding(:ets_missing_write_concurrency, [name, mod, site]) do
    Findings.new(
      :info,
      "Table without write_concurrency",
      "Table #{name} is created without write_concurrency: true. Concurrent " <>
        "writers serialize on a single lock; for write-heavy tables the " <>
        "option reduces contention at the cost of slightly costlier reads.",
      at: Findings.at_site(site, mod),
      at_label: "created here without write_concurrency",
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

  def finding(:ets_created_in_start, [name, mod, site, start]) do
    table = if name == "dynamic", do: "a named table", else: "the named table #{name}"

    Findings.new(
      :warning,
      "Named ETS table created in start_link fails the server's restart",
      "#{Findings.call_name(start)} creates #{table}. start_link runs in whoever starts " <>
        "#{mod}'s server, its supervisor when it is a child, not in the server, so the " <>
        "table belongs to the supervisor and outlives the server. When the server " <>
        "crashes, the restart calls start_link again and :ets.new raises ArgumentError " <>
        "on a name that is still taken: the child cannot restart, and its supervisor " <>
        "retries until its restart intensity is spent and exits.",
      at: Findings.at_site(site, mod),
      at_label: "runs in the supervisor, once per start",
      related: [
        Findings.related("the start function the supervisor calls", Findings.at_func(start),
          to_block: :function
        )
      ],
      help: [
        "create the table in init/1, in the server's own process, so it goes with the " <>
          "server and comes back with its restart",
        "or, to keep it across restarts on purpose, create it once where it is owned for " <>
          "good (the application, or a supervisor's init/1) and make start_link skip it " <>
          "when `:ets.whereis/1` finds it"
      ]
    )
  end
end
