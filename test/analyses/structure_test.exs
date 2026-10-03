defmodule Argus.Analyses.StructureTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes
  alias Argus.Test.Memo

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :structure)
    results
  end

  describe "supervisor registered as a worker" do
    @sup_mods [
      Argus.Test.Fixtures.SupAsWorker,
      Argus.Test.Fixtures.SupShorthand,
      Argus.Test.Fixtures.SubSupervisor
    ]

    defp as_worker do
      assert {:ok, r} = Memo.analyze(@sup_mods, :structure)
      r |> Map.get("supervisor_registered_as_worker", []) |> Enum.map(&hd/1)
    end

    test "an explicit type: :worker on a supervisor child is reported" do
      assert Enum.any?(as_worker(), &String.contains?(&1, "SupAsWorker"))
    end

    test "the shorthand is not, because child_spec/1 gets it right" do
      # supervisor_child.type is a DEFAULT for {Module, args} and bare
      # Module — those state nothing and `use Supervisor` generates
      # type: :supervisor. A version of this rule without the form join
      # reported 26 modules on the corpus, all of them this artefact.
      refute Enum.any?(as_worker(), &String.contains?(&1, "SupShorthand"))
    end
  end

  describe "supervisor registered as a worker, by a map that says no type" do
    alias Argus.Test.Fixtures.ChildSpecs, as: Specs

    @typeless [
      Specs.TypelessSup,
      Specs.PoolSup,
      Specs.TenantSup,
      Specs.TypedTenantSup,
      Specs.SuperTenantSup,
      Specs.TypelessWorker,
      Specs.Tenants,
      Specs.ShorthandTenants
    ]

    setup do
      {:ok, r} = Memo.analyze(@typeless, :structure)
      %{r: r}
    end

    test "a map spec with no :type registers the supervisor it starts as a worker", %{r: r} do
      # TypelessSup's `%{id: :pool, start: {PoolSup, ...}}`; its warmup map,
      # whose start function is the parent's own, starts what that
      # function starts, and the shorthand beside it states nothing.
      assert Map.get(r, "supervisor_registered_as_worker", []) ==
               [[inspect(Specs.TypelessSup), inspect(Specs.PoolSup), "0"]]
    end

    test "a supervisor whose own child_spec/1 says no type, wherever a shorthand names it", %{
      r: r
    } do
      # supavisor 6b77121: started by DynamicSupervisor.start_child/2 and
      # listed by the shorthand. The fixed map, overrides over the
      # generated child_spec/1, `use Supervisor`'s own and a worker's
      # typeless map are quiet.
      rows = r |> Map.get("own_spec_registered_as_worker", []) |> Enum.sort()

      {:ok, found} = Memo.run_analyses(@typeless, analyses: [:structure])

      assert {:error, {Specs.TenantSup, :child_spec, 1}} in for(
               f <- found.findings,
               f.title == "Supervisor registered as a worker",
               do: {f.severity, f.mfa}
             )

      assert rows == [
               [inspect(Specs.TenantSup), inspect(Specs.ShorthandTenants), ""],
               [
                 inspect(Specs.TenantSup),
                 inspect(Specs.TenantPool),
                 "#{inspect(Specs.Tenants)}:start_tenant/1"
               ]
             ]
    end
  end

  describe "ConsumerSupervisor templates" do
    test "a ConsumerSupervisor with a permanent template is reported; a temporary one is not" do
      {:ok, r} =
        Memo.analyze(
          [Shapes.PermanentConsumers, Shapes.TemporaryConsumers, Shapes.EventWorker],
          :structure
        )

      sups = Enum.map(Map.get(r, "consumer_supervisor_permanent_child", []), &hd/1)
      assert sups == ["Argus.Test.Fixtures.SupervisionShapes.PermanentConsumers"]
    end

    test "a shorthand template's restart is its module's own child_spec/1's" do
      {:ok, r} =
        Memo.analyze(
          [
            Shapes.ShorthandConsumers,
            Shapes.ShorthandPermanentConsumers,
            Shapes.EventWorker,
            Shapes.Conn
          ],
          :structure
        )

      # `[EventWorker]` is temporary by `use GenServer, restart:
      # :temporary`; `{Conn, []}` states none and is permanent.
      sups = Enum.map(Map.get(r, "consumer_supervisor_permanent_child", []), &hd/1)
      assert sups == [inspect(Shapes.ShorthandPermanentConsumers)]
    end
  end

  describe "duplicate_process_name" do
    test "flags the same name registered by two modules" do
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
      # ProcessRegisterer registers :my_process and :my_erlang_proc —
      # different names, no conflict.
      results = analyze([Argus.Test.Fixtures.ProcessRegisterer])

      assert results["duplicate_process_name"] == []
    end
  end

  describe "global_register_risk" do
    test "flags register_name/2 but not register_name/3 with a resolver" do
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
