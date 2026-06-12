defmodule Argus.Analyses.Ets do
  @moduledoc """
  ETS table analysis.

  Detects ETS usage patterns and potential issues: tables without proper
  concurrency options, unprotected owners, unnamed tables in processes,
  and ordered_set contention across modules.

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
  def description, do: "ETS table ownership, concurrency, and lifecycle analysis"

  @impl true
  def rules_file, do: "analyses/ets.dl"

  @impl true
  def extractors, do: [Argus.Extractors.ETS, Argus.Extractors.OTP, Argus.Extractors.Supervision]

  @impl true
  def output_relations do
    [
      %{
        name: :ets_unprotected_owner,
        fields: [{:name, :symbol, "table name"}, {:mod, :symbol, "owner module"}],
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
          {:mod2, :symbol, "second accessor module"}
        ],
        doc: "Ordered_set table accessed by multiple modules."
      },
      %{
        name: :ets_unnamed_in_process,
        fields: [{:name, :symbol, "table name"}, {:mod, :symbol, "owner module"}],
        doc: "Unnamed table created in a process."
      }
    ]
  end

  @impl true
  def finding(:ets_unprotected_owner, [name, mod]) do
    Findings.new(
      :warning,
      "ETS table dies with its owner",
      "#{mod} owns table #{name} with no heir, and the owner is not a " <>
        "permanent supervisor child. ETS tables are deleted when their owner " <>
        "exits — one crash and the data is gone. Set an heir or move " <>
        "ownership to a supervised process that rebuilds the table.",
      at: Findings.at_module(mod)
    )
  end

  def finding(:ets_missing_read_concurrency, [name]) do
    Findings.new(
      :info,
      "Table without read_concurrency",
      "Table #{name} is created without read_concurrency: true. Concurrent " <>
        "readers of a read-heavy table serialize on its lock; if this table " <>
        "is read from many processes, the option is close to free speedup."
    )
  end

  def finding(:ets_missing_write_concurrency, [name]) do
    Findings.new(
      :info,
      "Table without write_concurrency",
      "Table #{name} is created without write_concurrency: true. Concurrent " <>
        "writers serialize on a single lock; for write-heavy tables the " <>
        "option reduces contention at the cost of slightly costlier reads."
    )
  end

  def finding(:ets_ordered_set_contention, [name, mod1, mod2]) do
    Findings.new(
      :info,
      "ordered_set shared across modules",
      "The ordered_set table #{name} is accessed by both #{mod1} and " <>
        "#{mod2}. ordered_set operations are O(log n) and contend harder " <>
        "than hash-based tables under concurrent access — worth checking " <>
        "that the ordering is actually needed.",
      at: Findings.at_module(mod1),
      related: [Findings.related("other accessor", Findings.at_module(mod2))]
    )
  end

  def finding(:ets_unnamed_in_process, [name, mod]) do
    Findings.new(
      :info,
      "Unnamed table held by a process",
      "#{mod} creates table #{name} without :named_table inside a process. " <>
        "The table is reachable only through its reference — if the owner " <>
        "loses or never shares it, nothing else can read or clean up the " <>
        "table.",
      at: Findings.at_module(mod)
    )
  end
end
