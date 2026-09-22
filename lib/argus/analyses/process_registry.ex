defmodule Argus.Analyses.ProcessRegistry do
  @moduledoc """
  Process registry and naming analysis.

  Detects naming issues: duplicate process name registration, TOCTOU races
  on `whereis`, and potential name collisions.

  ## Output relations

  - `duplicate_process_name(name, mod1, mod2)` — same atom name registered by multiple modules.
  - `whereis_race(id, func, name)` — `Process.whereis` without nil check (TOCTOU risk), anchored at the call instruction.

  ## Finding severities

  - `duplicate_process_name` — `:error`. Name registration is exclusive;
    whichever process registers second crashes at runtime.
  - `whereis_race` — `:warning`. The looked-up process can die between
    lookup and use; whether that window matters depends on the call site.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :process_registry

  @impl true
  def description, do: "Process naming: duplicate names, whereis races, registry collisions"

  @impl true
  def rules_file, do: "analyses/process_registry.dl"

  @impl true
  def extractors,
    do: [Argus.Extractors.ProcessRegistry, Argus.Extractors.OTP, Argus.Extractors.ApiCalls]

  @impl true
  def output_relations do
    [
      %{
        name: :whereis_race,
        fields: [
          {:id, :symbol, "instruction ID of the whereis call"},
          {:func, :symbol, "function calling whereis"},
          {:name, :symbol, "process name"}
        ],
        doc: "Process.whereis without nil check (TOCTOU risk)."
      }
    ]
  end

  @impl true
  def finding(:whereis_race, [id, func, name]) do
    Findings.new(
      :warning,
      "whereis result used without a nil check",
      "#{func} looks up #{name} with Process.whereis and uses the result " <>
        "without handling nil. The target can die (or not yet be registered) " <>
        "between lookup and use — the classic time-of-check/time-of-use race. " <>
        "Send to the registered name directly, or handle nil explicitly.",
      at: Findings.at_instr(id)
    )
  end
end
