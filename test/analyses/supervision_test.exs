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

  describe "wrong_start_order" do
    test "flags a child whose init sync-calls a later-started sibling" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ProcessDepSupervisor,
        Argus.Test.Fixtures.InitProcessCaller,
        Argus.Test.Fixtures.InitDepWorker
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert Enum.any?(results["wrong_start_order"], fn [_sup, child, dep | _] ->
               String.contains?(child, "InitProcessCaller") and
                 String.contains?(dep, "InitDepWorker")
             end)
    end

    test "does not flag init calling only a pure function in the sibling's module" do
      skip_without_souffle()

      # The Horde.RegistryImpl -> NodeListener.make_members shape: init
      # reaches a function DEFINED in the dependency's module, but it is a
      # pure function — no dependency on the dependency's process, so no
      # start-order hazard.
      modules = [
        Argus.Test.Fixtures.PureDepSupervisor,
        Argus.Test.Fixtures.InitPureCaller,
        Argus.Test.Fixtures.InitDepWorker
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      refute Enum.any?(results["wrong_start_order"], fn [_sup, child, _dep | _] ->
               String.contains?(child, "InitPureCaller")
             end)
    end
  end

  describe "suspect_nonpermanent_dependency" do
    # Hand-authored facts pin the rule exactly: P is a permanent child
    # that sync-calls its sibling S under the same supervisor. The
    # sibling's restart policy decides the verdict.
    defp base_facts(sibling_restart) do
      %{
        supervisor: [["Sup", "one_for_one"]],
        # Anchor site split out of `supervisor` in schema v8.
        supervisor_site: [["Sup", "Sup:init/1#3"]],
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

  describe "supervisor registered as a worker" do
    @sup_mods [
      Argus.Test.Fixtures.SupAsWorker,
      Argus.Test.Fixtures.SupShorthand,
      Argus.Test.Fixtures.SubSupervisor
    ]

    defp as_worker do
      assert {:ok, r} = Argus.analyze(@sup_mods, :supervision)
      r |> Map.get("supervisor_registered_as_worker", []) |> Enum.map(&hd/1)
    end

    test "an explicit type: :worker on a supervisor child is reported" do
      skip_without_souffle()
      assert Enum.any?(as_worker(), &String.contains?(&1, "SupAsWorker"))
    end

    test "the shorthand is not, because child_spec/1 gets it right" do
      skip_without_souffle()

      # supervisor_child.type is a DEFAULT for {Module, args} and bare
      # Module — those state nothing and `use Supervisor` generates
      # type: :supervisor. A version of this rule without the form join
      # reported 26 modules on the corpus, all of them this artefact.
      refute Enum.any?(as_worker(), &String.contains?(&1, "SupShorthand"))
    end
  end
end
