defmodule Argus.Analyses.Coverage do
  @moduledoc """
  Coverage and precision meta-analysis.

  Measures the extractor pipeline itself rather than the analyzed code.
  Every fallback to a "dynamic" placeholder is recorded as an
  `imprecision` fact, and passive Datalog rules derive "recognized shape
  but no detail extracted" findings from the existing Layer 2 fact base.

  Running this analysis tells Argus developers exactly where the
  extractors are losing information — the raw feedback loop for
  iterative precision work. It's a developer-facing meta-analysis, not
  a correctness check, and is excluded from the default correctness set.

  ## How it's different from other analyses

  Unlike every other analysis in Argus, `coverage` opts the pipeline
  into imprecision tracing. `Argus.Analysis.run/3` sets
  `trace_imprecision: true` automatically when it sees this analysis
  name, so the per-process flag in `Argus.Extractor.Helpers` flips on
  inside each extractor worker. No other analysis populates the
  `imprecision` relation.

  ## Output relations

  - `imprecision_event(category, func, relation, reason)` — raw
    fallback events emitted by the extractors. One row per
    `track_dynamic`/`track_imprecision` call site that fired.
  - `coverage_supervisor_no_children(sup)` — supervisor recognized but
    no static or dynamic children recovered.
  - `coverage_genserver_isolated(mod)` — GenServer module with zero
    observed sync_call/async_cast traffic.
  - `coverage_ets_unused(name)` — named ETS table with no observed
    read or write operations.
  - `coverage_statem_no_transitions(mod)` — gen_statem with states but
    no transitions extracted.
  - `coverage_named_process_unreachable(name, mod)` — registered name
    with no sync or async traffic targeting it.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :coverage

  @impl true
  def description,
    do: "extractor coverage and imprecision meta-analysis"

  @impl true
  def rules_file, do: "analyses/coverage.dl"

  alias Argus.Findings

  @impl true
  def extractors do
    # Every Layer 2 extractor, since coverage spans the whole pipeline.
    # Listing them explicitly (rather than discovering at runtime) keeps
    # the analysis reproducible and makes the dependency explicit in
    # `mix argus info coverage`.
    [
      Argus.Extractors.AtomSafety,
      Argus.Extractors.Distributed,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.ETS,
      Argus.Extractors.GenEvent,
      Argus.Extractors.GenStatem,
      Argus.Extractors.OTP,
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.Supervision
    ]
  end

  @impl true
  def output_relations do
    [
      %{
        name: :imprecision_event,
        fields: [
          {:category, :symbol, "what the extractor was trying to resolve"},
          {:func, :symbol, "function ID where the fallback occurred"},
          {:relation, :symbol, "fact relation that received the dynamic placeholder"},
          {:reason, :symbol, "dynamic | unresolvable | skipped | missing"}
        ],
        doc: "Raw imprecision event emitted by an extractor fallback site. One row per firing."
      },
      %{
        name: :coverage_supervisor_no_children,
        fields: [{:sup, :symbol, "supervisor module"}],
        doc:
          "Supervisor recognized but neither static (supervisor_child) nor dynamic (dynamic_child) children were extracted."
      },
      %{
        name: :coverage_genserver_isolated,
        fields: [{:mod, :symbol, "GenServer module"}],
        doc: "GenServer module with zero observed sync_call or async_cast traffic in the corpus."
      },
      %{
        name: :coverage_ets_unused,
        fields: [{:name, :symbol, "table name"}],
        doc:
          "ETS table created with a concrete name but no read or write operations observed against it."
      },
      %{
        name: :coverage_statem_no_transitions,
        fields: [{:mod, :symbol, "gen_statem module"}],
        doc:
          "gen_statem module with recognized states but no transitions extracted — the return-tuple scanner is missing a shape."
      },
      %{
        name: :coverage_named_process_unreachable,
        fields: [
          {:name, :symbol, "registered name"},
          {:mod, :symbol, "registering module"}
        ],
        doc:
          "Named process with no sync or async traffic targeting the registered name in the corpus."
      }
    ]
  end

  # Coverage measures the extractor pipeline, not the analyzed code, so
  # every finding is `:info` — these are developer-facing observations,
  # not defect reports. Excluded from `Argus.run_analyses/2`'s `:all`
  # selection; request it by name to get these.
  @impl true
  def finding(:imprecision_event, [category, func, relation, reason]) do
    Findings.new(
      :info,
      "Extractor fell back to a placeholder",
      "While resolving #{category} in #{func}, the #{relation} fact received " <>
        "a dynamic placeholder (#{reason}). Analyses consuming that relation " <>
        "see less than the bytecode contains.",
      at: Findings.at_func(func)
    )
  end

  def finding(:coverage_supervisor_no_children, [sup]) do
    Findings.new(
      :info,
      "Supervisor with no recovered children",
      "#{sup} is recognized as a supervisor, but no static or dynamic child " <>
        "specs were extracted — its subtree is invisible to every " <>
        "supervision-aware analysis.",
      at: Findings.at_module(sup)
    )
  end

  def finding(:coverage_genserver_isolated, [mod]) do
    Findings.new(
      :info,
      "GenServer with no observed traffic",
      "#{mod} implements GenServer but no sync_call or async_cast traffic " <>
        "targeting it was extracted — either nothing in the corpus talks to " <>
        "it, or the call-site resolution missed the pattern.",
      at: Findings.at_module(mod)
    )
  end

  def finding(:coverage_ets_unused, [name]) do
    Findings.new(
      :info,
      "ETS table with no observed operations",
      "Table #{name} is created with a concrete name, but no reads or writes " <>
        "against it were extracted from the corpus."
    )
  end

  def finding(:coverage_statem_no_transitions, [mod]) do
    Findings.new(
      :info,
      "gen_statem with no extracted transitions",
      "#{mod} has recognized states but zero extracted transitions — the " <>
        "return-tuple scanner is missing a shape this module uses.",
      at: Findings.at_module(mod)
    )
  end

  def finding(:coverage_named_process_unreachable, [name, mod]) do
    Findings.new(
      :info,
      "Registered name with no traffic",
      "#{mod} registers #{name}, but no sync or async traffic targeting that " <>
        "name was extracted from the corpus.",
      at: Findings.at_module(mod)
    )
  end
end
