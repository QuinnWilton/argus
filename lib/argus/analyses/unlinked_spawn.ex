defmodule Argus.Analyses.UnlinkedSpawn do
  @moduledoc """
  Unlinked spawn detection.

  Flags calls to `erlang:spawn/*` (without `_link` or `_monitor`) that create
  processes with no supervision or failure propagation link. These "orphan"
  processes silently disappear on crash.

  Uses only layer 1 facts (spawn_call with variant field).

  ## Output relations

  - `unlinked_spawn(func, id)` — function and instruction where a bare spawn occurs.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :unlinked_spawn

  @impl true
  def description, do: "unlinked (orphan) process spawn detection"

  @impl true
  def rules_file, do: "analyses/unlinked_spawn.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :unlinked_spawn,
        fields: [
          {:func, :symbol, "function containing the spawn"},
          {:id, :symbol, "instruction ID of the spawn call"}
        ],
        doc: "Bare erlang:spawn call without link or monitor."
      }
    ]
  end
end
