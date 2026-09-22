defmodule Argus.Analyses.CouplingTest do
  use ExUnit.Case

  alias Argus.Analyses.Coupling
  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "sibling_dependency: restart_isolation" do
    test "analyzes coupling under one_for_one supervisors" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :coupling)

      assert Map.has_key?(results, "sibling_dependency")
    end

    test "wrong_start_order ignores runtime-only call paths" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.RuntimeCallSupervisor,
        Argus.Test.Fixtures.RuntimeCallerWorker,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)

      # RuntimeCallerWorker calls WorkerA only from handle_call, not init:
      # no later-sibling row.
      assert Rows.where(results, :startup, "blocks_on_peer", ordering: "later") == []
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

      assert [[_sup, "A", "B", "restart_isolation", "call", _site, _witness, _call_site | _]] =
               coupling_rows(base)

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

      assert [[_sup, "A", "B", "restart_isolation", "cast", _site, "A:cast_b/0", _call_site | _]] =
               coupling_rows(base)

      # One sync call anywhere along the dependency makes it a call coupling.
      both = Map.put(base, :sync_call, [["A:cast_b/0", "B"]])
      assert [[_, "A", "B", "restart_isolation", "call", _, _, _ | _]] = coupling_rows(both)
    end

    test "a dependency inferred from reaching a sibling with a call somewhere is marked, and a prior can doubt it" do
      skip_without_souffle()

      # A's handler reaches B's pure/1; B's ask/0 calls a server. No
      # resolved call from A to B: the module-level clause alone couples
      # them, and the row says so.
      base = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [
          ["A:h/0", "A", "h", "0", "1"],
          ["B:pure/1", "B", "pure", "1", "1"],
          ["B:ask/0", "B", "ask", "0", "1"]
        ],
        remote_call: [["A:h/0#1", "A:h/0", "B", "pure", "1"]],
        sync_call: [["B:ask/0", "C"]]
      }

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "inferred", "0"]] =
               coupling_rows(base)

      doubted = Map.put(base, :prior_talks_to_process, [["B", "120"]])

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "doubted", "120"]] =
               coupling_rows(doubted)

      # At 0.7 the model thinks B is a process after all: the inference stands.
      confirmed = Map.put(base, :prior_talks_to_process, [["B", "700"]])

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "inferred", "0"]] =
               coupling_rows(confirmed)

      # A resolved call is never doubted, whatever the prior says.
      resolved =
        base
        |> Map.put(:sync_call, [["A:h/0", "B"], ["B:ask/0", "C"]])
        |> Map.put(:prior_talks_to_process, [["B", "50"]])

      assert [[_, "A", "B", "restart_isolation", "call", _, _, _, "resolved", "0"]] =
               coupling_rows(resolved)
    end

    test "a doubted row is the same finding a severity step down, labelled and heuristic" do
      row = [
        "Sup",
        "A",
        "B",
        "restart_isolation",
        "call",
        "Sup:init/1#3",
        "A:h/0",
        "A:h/0",
        "doubted",
        "120"
      ]

      finding = Coupling.finding(:sibling_dependency, row)
      assert finding.severity == :info
      assert finding.provenance == :heuristic
      assert finding.confidence == 880
      assert finding.at_label =~ "does not talk to a process (p=0.88)"
      assert finding.title == "Coupled children under one_for_one"

      plain =
        Coupling.finding(:sibling_dependency, List.replace_at(row, 8, "inferred"))

      assert plain.severity == :warning and plain.provenance == :structural
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
        results["sibling_dependency"] || []
      after
        File.rm_rf(dir)
      end
    end
  end
end
