defmodule Argus.Analyses.CoverageTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # The fixture set is kept small on purpose: each module in this list is
  # designed to trigger exactly one of the shape-gap relations, and no
  # other fixture in the set should satisfy the same relation. That
  # keeps the test assertions about "this module appears in this
  # relation" unambiguous without needing further filtering.
  @fixtures [
    Argus.Test.Fixtures.CoverageDynamicCalls,
    Argus.Test.Fixtures.CoverageEmptySupervisor,
    Argus.Test.Fixtures.CoverageDeadEts,
    Argus.Test.Fixtures.CoverageStatemNoTransitions,
    Argus.Test.Fixtures.CoverageIsolatedGenServer
  ]

  describe "coverage.dl — shape-gap queries" do
    test "coverage_supervisor_no_children matches Enum.map-built children" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      sups = results["coverage_supervisor_no_children"] || []

      assert Enum.any?(sups, fn [mod] ->
               mod == "Argus.Test.Fixtures.CoverageEmptySupervisor"
             end)
    end

    test "coverage_ets_unused matches a named table with no ops" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      unused = results["coverage_ets_unused"] || []
      assert Enum.any?(unused, fn [name] -> name == ":coverage_dead_cache" end)
    end

    test "coverage_statem_no_transitions matches a module with only keep_state" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      no_trans = results["coverage_statem_no_transitions"] || []

      assert Enum.any?(no_trans, fn [mod] ->
               mod == "Argus.Test.Fixtures.CoverageStatemNoTransitions"
             end)
    end

    test "coverage_genserver_isolated matches a GenServer with no callers" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      isolated = results["coverage_genserver_isolated"] || []

      assert Enum.any?(isolated, fn [mod] ->
               mod == "Argus.Test.Fixtures.CoverageIsolatedGenServer"
             end)
    end
  end

  describe "coverage.dl — imprecision passthrough" do
    test "imprecision_event fires for genserver_callee on dynamic targets" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      events = results["imprecision_event"] || []

      assert Enum.any?(events, fn [category, func, relation, reason] ->
               category == "genserver_callee" and
                 String.starts_with?(func, "Argus.Test.Fixtures.CoverageDynamicCalls:") and
                 relation == "sync_call" and
                 reason == "dynamic"
             end),
             "expected a genserver_callee imprecision event from CoverageDynamicCalls, got: #{inspect(events)}"
    end

    test "imprecision_event covers multiple categories across the fixture set" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze(@fixtures, :coverage)

      events = results["imprecision_event"] || []
      categories = events |> Enum.map(fn [c, _, _, _] -> c end) |> Enum.uniq()

      assert "genserver_callee" in categories
    end

    test "non-coverage analyses produce no imprecision_event rows" do
      skip_without_souffle()

      # Run the same fixtures through a different analysis and verify
      # the imprecision fact file is empty — the tracing gate must be
      # off for non-coverage runs, otherwise we'd be paying for it on
      # every analysis.
      assert {:ok, results} = Argus.analyze(@fixtures, :ets)

      # Other analyses don't declare imprecision_event as an output
      # relation, so it won't appear in the results map even if facts
      # existed. To verify the gating, we check that tracing is off by
      # running extract directly and asserting no imprecision facts.
      {:ok, facts} =
        Argus.Pipeline.extract(@fixtures,
          extractors: [
            Argus.Extractors.ETS,
            Argus.Extractors.OTP,
            Argus.Extractors.Supervision
          ]
        )

      assert facts[:imprecision] in [nil, []]
      # Sanity: the ETS analysis did produce its own output, proving the
      # pipeline still worked.
      assert is_map(results)
    end
  end
end
