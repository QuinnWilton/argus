defmodule Argus.Analyses.CouplingTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "one_for_one_coupling.dl" do
    test "analyzes coupling under one_for_one supervisors" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :coupling)

      assert Map.has_key?(results, "one_for_one_coupling")
    end

    test "wrong_start_order ignores runtime-only call paths" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.RuntimeCallSupervisor,
        Argus.Test.Fixtures.RuntimeCallerWorker,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)

      # RuntimeCallerWorker calls WorkerA only from handle_call, not init.
      # wrong_start_order should be empty.
      assert results["wrong_start_order"] == []
    end

    test "linked coupled pairs are excluded (the hazard is mitigated)" do
      skip_without_souffle()

      # Hand-authored facts pin the negation exactly: A sync-calls its
      # sibling B under a one_for_one supervisor — coupling; adding a
      # process link between them removes the finding, because the exit
      # propagates and both restart together.
      base = %{
        supervisor: [["Sup", "one_for_one"]],
        # Anchor site split out of `supervisor` in schema v8.
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [["A:call_b/0", "A", "call_b", "0", "1", "1"]],
        sync_call: [["A:call_b/0", "B"]]
      }

      assert [[_sup, "A", "B", _site, _witness, _call_site, "call"]] = coupling_rows(base)

      linked = Map.put(base, :process_link, [["A", "B"]])
      assert coupling_rows(linked) == []
    end

    test "a cast-only dependency is graded as a one-way coupling" do
      skip_without_souffle()

      base = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [["A:cast_b/0", "A", "cast_b", "0", "1", "1"]],
        async_cast: [["A:cast_b/0", "B"]]
      }

      assert [[_sup, "A", "B", _site, "A:cast_b/0", _call_site, "cast"]] = coupling_rows(base)

      # One sync call anywhere along the dependency makes it a call coupling.
      both = Map.put(base, :sync_call, [["A:cast_b/0", "B"]])
      assert [[_, "A", "B", _, _, _, "call"]] = coupling_rows(both)
    end

    defp coupling_rows(facts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ofo_coupling_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      try do
        :ok = Argus.Pipeline.write_facts(facts, dir)
        assert {:ok, results} = Argus.Analysis.run_rules(dir, :coupling)
        results["one_for_one_coupling"] || []
      after
        File.rm_rf(dir)
      end
    end
  end
end
