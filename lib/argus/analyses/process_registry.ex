defmodule Argus.Analyses.ProcessRegistry do
  @moduledoc """
  Process registry and naming analysis.

  Detects naming issues: duplicate process name registration, TOCTOU races
  on `whereis`, and potential name collisions.

  ## Output relations

  - `duplicate_process_name(name, mod1, mod2)` — same atom name registered by multiple modules.
  - `whereis_race(func, name)` — `Process.whereis` without nil check (TOCTOU risk).
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :process_registry

  @impl true
  def description, do: "Process naming: duplicate names, whereis races, registry collisions"

  @impl true
  def rules_file, do: "analyses/process_registry.dl"

  @impl true
  def extractors, do: [Argus.Extractors.ProcessRegistry, Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :duplicate_process_name,
        fields: [
          {:name, :symbol, "registered name"},
          {:mod1, :symbol, "first registering module"},
          {:mod2, :symbol, "second registering module"}
        ],
        doc: "Same atom name registered by multiple modules."
      },
      %{
        name: :whereis_race,
        fields: [
          {:func, :symbol, "function calling whereis"},
          {:name, :symbol, "process name"}
        ],
        doc: "Process.whereis without nil check (TOCTOU risk)."
      }
    ]
  end
end
