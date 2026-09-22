defmodule Argus.Analyses.StructureTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :structure)
    results
  end

  describe "supervisor registered as a worker" do
    @sup_mods [
      Argus.Test.Fixtures.SupAsWorker,
      Argus.Test.Fixtures.SupShorthand,
      Argus.Test.Fixtures.SubSupervisor
    ]

    defp as_worker do
      assert {:ok, r} = Argus.analyze(@sup_mods, :structure)
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

  describe "ConsumerSupervisor templates" do
    test "a ConsumerSupervisor with a permanent template is reported; a temporary one is not" do
      skip_without_souffle()

      {:ok, r} =
        Argus.analyze(
          [Shapes.PermanentConsumers, Shapes.TemporaryConsumers, Shapes.EventWorker],
          :structure
        )

      sups = Enum.map(Map.get(r, "consumer_supervisor_permanent_child", []), &hd/1)
      assert sups == ["Argus.Test.Fixtures.SupervisionShapes.PermanentConsumers"]
    end
  end

  describe "duplicate_process_name" do
    test "flags the same name registered by two modules" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.ProcessRegisterer,
          Argus.Test.Fixtures.DuplicateRegisterer
        ])

      assert Enum.any?(results["duplicate_process_name"], fn
               [":my_process", mod1, mod2, _site1, _site2] ->
                 String.contains?(mod1, "DuplicateRegisterer") and
                   String.contains?(mod2, "ProcessRegisterer")

               _ ->
                 false
             end)
    end

    test "a single module's distinct names are not duplicates" do
      skip_without_souffle()

      # ProcessRegisterer registers :my_process and :my_erlang_proc —
      # different names, no conflict.
      results = analyze([Argus.Test.Fixtures.ProcessRegisterer])

      assert results["duplicate_process_name"] == []
    end
  end

  describe "global_register_risk" do
    test "flags register_name/2 but not register_name/3 with a resolver" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.GlobalRegisterModule])
      funcs = Enum.map(results["global_register_risk"], fn [func, _name, _site] -> func end)

      # register/1 wraps :global.register_name/2 — the race-prone default.
      assert Enum.any?(funcs, &String.contains?(&1, "register/"))

      # register_with_resolve/2 wraps register_name/3, which supplies an
      # explicit conflict-resolution function — the fixed form.
      refute Enum.any?(funcs, &String.contains?(&1, "register_with_resolve"))
    end
  end
end
