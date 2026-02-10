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
  """

  @behaviour Argus.Analysis

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
end
