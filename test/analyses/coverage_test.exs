defmodule Argus.Analyses.CoverageTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  # The fixture set is kept small on purpose: each module in this list is
  # designed to trigger exactly one of the shape-gap relations, and no
  # other fixture in the set should satisfy the same relation. That
  # keeps the test assertions about "this module appears in this
  # relation" unambiguous without needing further filtering.
  @fixtures [
    Argus.Test.Fixtures.CoverageDynamicCalls,
    Argus.Test.Fixtures.CoverageEmptySupervisor,
    Argus.Test.Fixtures.CoverageDeadEts,
    Argus.Test.Fixtures.CoverageIsolatedGenServer
  ]

  describe "coverage.dl — shape-gap queries" do
    test "coverage_supervisor_no_children matches Enum.map-built children" do
      assert {:ok, results} = Memo.analyze(@fixtures, :coverage)

      sups = results["coverage_supervisor_no_children"] || []

      assert Enum.any?(sups, fn [mod] ->
               mod == "Argus.Test.Fixtures.CoverageEmptySupervisor"
             end)
    end

    test "coverage_ets_unused matches a named table with no ops" do
      assert {:ok, results} = Memo.analyze(@fixtures, :coverage)

      unused = results["coverage_ets_unused"] || []
      assert Enum.any?(unused, fn [name] -> name == ":coverage_dead_cache" end)
    end

    test "coverage_genserver_isolated matches a GenServer with no callers" do
      assert {:ok, results} = Memo.analyze(@fixtures, :coverage)

      isolated = results["coverage_genserver_isolated"] || []

      assert Enum.any?(isolated, fn [mod] ->
               mod == "Argus.Test.Fixtures.CoverageIsolatedGenServer"
             end)
    end
  end

  describe "coverage.dl — traffic through pids" do
    test "a server called through the pid its start returns or a whereis finds is reached" do
      mods = [
        Argus.Test.Fixtures.CoveragePidServer,
        Argus.Test.Fixtures.CoverageNamedByPid,
        Argus.Test.Fixtures.CoveragePidClient
      ]

      assert {:ok, results} = Memo.analyze(mods, :coverage)

      assert (results["coverage_genserver_isolated"] || []) == []
      assert (results["coverage_named_process_unreachable"] || []) == []
    end
  end

  describe "coverage.dl — imprecision passthrough" do
    test "imprecision_event fires for genserver_callee on dynamic targets" do
      assert {:ok, results} = Memo.analyze(@fixtures, :coverage)

      events = results["imprecision_event"] || []

      assert Enum.any?(events, fn [category, func, relation, reason] ->
               category == "genserver_callee" and
                 String.starts_with?(func, "Argus.Test.Fixtures.CoverageDynamicCalls:") and
                 relation == "sync_call" and
                 reason == "dynamic"
             end),
             "expected a genserver_callee imprecision event from CoverageDynamicCalls, got: #{inspect(events)}"
    end
  end
end
