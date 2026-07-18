defmodule Argus.Analyses.SupervisionTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "supervision.dl" do
    test "analyzes supervisor fixtures" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.BadOrderSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert Map.has_key?(results, "suspect_nonpermanent_dependency")
      assert Map.has_key?(results, "wrong_start_order")
    end
  end

  describe "suspect_nonpermanent_dependency" do
    # Hand-authored facts pin the rule exactly: P is a permanent child
    # that sync-calls its sibling S under the same supervisor. The
    # sibling's restart policy decides the verdict.
    defp base_facts(sibling_restart) do
      %{
        supervisor: [["Sup", "one_for_one", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "P", "permanent", "worker"],
          ["Sup", "1", "S", sibling_restart, "worker"]
        ],
        function_def: [["P:call_s/0", "P", "call_s", "0", "1", "1"]],
        sync_call: [["P:call_s/0", "S"]]
      }
    end

    test "flags a transient sibling dependency" do
      skip_without_souffle()

      assert [["Sup", "P", "S", "transient", _site, _witness]] =
               dependency_rows(base_facts("transient"))
    end

    test "flags a temporary sibling dependency" do
      skip_without_souffle()

      # Temporary is strictly worse than transient: never restarted,
      # not even after a crash.
      assert [["Sup", "P", "S", "temporary", _site, _witness]] =
               dependency_rows(base_facts("temporary"))
    end

    test "does not flag a permanent sibling dependency" do
      skip_without_souffle()

      # A permanent sibling is always restarted — the dependency is safe
      # from this rule's perspective.
      assert dependency_rows(base_facts("permanent")) == []
    end

    defp dependency_rows(facts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "supervision_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      try do
        :ok = Argus.Pipeline.write_facts(facts, dir)
        assert {:ok, results} = Argus.Analysis.run_rules(dir, :supervision)
        results["suspect_nonpermanent_dependency"] || []
      after
        File.rm_rf(dir)
      end
    end
  end
end
