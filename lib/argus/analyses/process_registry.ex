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
  def extractors, do: [Argus.Extractors.ProcessRegistry, Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :duplicate_process_name,
        fields: [
          {:name, :symbol, "registered name"},
          {:mod1, :symbol, "first registering module"},
          {:mod2, :symbol, "second registering module"},
          {:site1, :symbol, "registration instruction in mod1"},
          {:site2, :symbol, "registration instruction in mod2"}
        ],
        key: [:name, :mod1, :mod2],
        doc: "Same atom name registered by multiple modules."
      },
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
  def finding(:duplicate_process_name, [name, mod1, mod2, site1, site2]) do
    Findings.new(
      :error,
      "Process name registered by two modules",
      "Both #{mod1} and #{mod2} register the name #{name}. Name registration " <>
        "is exclusive — whichever process registers second crashes with " <>
        "ArgumentError (or its start_link returns {:error, {:already_started, " <>
        "pid}}). At most one of these can ever run at a time.",
      at: Findings.at_site(site1, mod1),
      related: [Findings.related("other registrant", Findings.at_site(site2, mod2))]
    )
  end

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
