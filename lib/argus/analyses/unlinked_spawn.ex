defmodule Argus.Analyses.UnlinkedSpawn do
  @moduledoc """
  Unlinked spawn detection.

  Flags calls to `erlang:spawn/*` (without `_link` or `_monitor`) that create
  processes with no supervision or failure propagation link. These "orphan"
  processes silently disappear on crash.

  Uses only layer 1 facts (spawn_call with variant field).

  ## Output relations

  - `unlinked_spawn(func, id)` — function and instruction where a bare spawn occurs.

  ## Finding severities

  - `unlinked_spawn` — `:warning`. The spawned process may be deliberately
    fire-and-forget, but its crashes are invisible: no link, no monitor,
    no supervisor ever observes them.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

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

  @impl true
  def finding(:unlinked_spawn, [func, id]) do
    Findings.new(
      :warning,
      "Unlinked process spawned",
      "#{func} spawns a process with bare spawn — no link, no monitor. If the " <>
        "process crashes, nothing observes it: no restart, no log, no cleanup. " <>
        "Use spawn_link, spawn_monitor, or a Task/Supervisor so failures " <>
        "propagate somewhere.",
      at: Findings.at_instr(id)
    )
  end
end
