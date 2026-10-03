defmodule Argus.Analyses.RegistryRaceTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Analyses.Races
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    C.OwnerSpawnsClaims,
    :registry_losers,
    C.WhereisThenStart,
    C.AgentWhereisThenStart,
    C.LookupThenStartChild,
    C.WhereisThenRegister,
    C.ManyInstances,
    C.LaterClauseName,
    C.HandlesAlreadyStarted,
    C.HandlesAlreadyRegistered,
    C.CallerHandlesAlreadyStarted,
    C.AgentHandlesAlreadyStarted,
    C.RescuesArgumentError,
    C.OwnerRegisters,
    C.OwnerSpawnsClaimer,
    C.UncheckedWhereisThenStart,
    C.DifferentNames,
    C.UnregisterIfPresent,
    C.RegisterIfUnlisted,
    C.UnregisterRescued,
    C.LookupHelper,
    C.StartHelper,
    C.DispatchHelper,
    C.AcrossModules,
    C.NameDirectory,
    C.NameStarter,
    C.HelperTakesLoser,
    C.HelperOtherName
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  defp races(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    for [_mod, func, lookup, create, _key_source, key, _check, _act] <- results["registry_race"],
        do: {func |> String.split(":") |> List.last(), lookup, create, key}
  end

  # {meeting function, lookup's function, act's function}
  defp sites(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    for [_mod, func, _lookup, _create, _key_source, _key, check, act] <- results["registry_race"],
        do: {short(func), short(check), short(act)}
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(".") |> List.last()

  test "the key_source field's doc names every source the rule reports", ctx do
    {:ok, results} = Batch.analyze(ctx.batch, @batched)

    {:key_source, :symbol, doc} =
      Races.output_relations()
      |> Enum.find(&(&1.name == :registry_race))
      |> Map.fetch!(:fields)
      |> List.keyfind(:key_source, 0)

    sources = for [_, _, _, _, source, _, _, _] <- results["registry_race"], do: source
    assert sources != []

    for source <- Enum.uniq(sources) do
      assert doc =~ String.replace(source, ~r/\d+$/, "N"), "#{source} is not in: #{doc}"
    end
  end

  describe "registry_race: processes a server starts" do
    test "a task the owner's handler starts per message is many processes", ctx do
      assert [{"claim/1", _, _, _}] = races(ctx, [C.OwnerSpawnsClaims])
    end
  end

  describe "registry_race: losers that are not a bug" do
    test "a register inside an Erlang catch takes its loser; a dropped start answer is moot",
         ctx do
      found = sites(ctx, [:registry_losers])
      meetings = found |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      refute Enum.any?(meetings, &(&1 =~ "server_init"))
      refute Enum.any?(meetings, &(&1 =~ "switch"))
      assert Enum.any?(meetings, &(&1 =~ "ensure"))
    end
  end

  describe "registry_race" do
    test "whereis, then a named start of the same parameter, in a plain API", ctx do
      assert [{"ensure/1", "whereis", "start_link", "0"}] = races(ctx, [C.WhereisThenStart])
    end

    test "whereis, then a named Agent start of the same name", ctx do
      assert [{"set/1", "whereis", "start_link", key}] = races(ctx, [C.AgentWhereisThenStart])
      assert key == inspect(C.AgentWhereisThenStart)
    end

    test "Registry.lookup, then start_child, the result returned untaken", ctx do
      assert [{"get_or_start/1", "registry_lookup", "start_child", "0"}] =
               races(ctx, [C.LookupThenStartChild])
    end

    test "whereis of a literal, then register of the same literal", ctx do
      assert [{"claim/0", "whereis", "register", ":leader"}] = races(ctx, [C.WhereisThenRegister])
    end

    test "a LiveView doing it runs once per socket", ctx do
      assert [{"handle_event/3", "registry_lookup", "start_child", _}] =
               races(ctx, [C.ManyInstances])
    end

    test "a later clause keeps its parameters across the first clause's return", ctx do
      assert [{"ensure/2", "whereis", "start_link", "1"}] = races(ctx, [C.LaterClauseName])
    end

    test "taking the loser's outcome, in the function or its caller, is the fix", ctx do
      assert races(ctx, [
               C.HandlesAlreadyStarted,
               C.HandlesAlreadyRegistered,
               C.CallerHandlesAlreadyStarted,
               C.AgentHandlesAlreadyStarted,
               C.RescuesArgumentError
             ]) == []
    end

    test "the owner deciding on its own registry from its own callbacks is one process", ctx do
      assert races(ctx, [C.OwnerRegisters]) == []
    end

    test "a worker init/1 spawns once is one process", ctx do
      assert races(ctx, [C.OwnerSpawnsClaimer]) == []
    end

    test "no branch on the lookup, or different names, is not the shape", ctx do
      assert races(ctx, [C.UncheckedWhereisThenStart, C.DifferentNames]) == []
    end

    test "whereis, then unregister", ctx do
      assert [{"release/1", "whereis", "unregister", "0"}] = races(ctx, [C.UnregisterIfPresent])
    end

    test "Process.registered/0 decides a register of any name", ctx do
      assert [{"claim/1", "registered", "register", ""}] = races(ctx, [C.RegisterIfUnlisted])
    end

    test "unregister's ArgumentError rescued is the loser's outcome taken", ctx do
      assert races(ctx, [C.UnregisterRescued]) == []
    end
  end

  describe "registry_race across functions" do
    test "a lookup helper's result decides the start in its caller", ctx do
      assert sites(ctx, [C.LookupHelper]) == [
               {"LookupHelper:ensure/1", "LookupHelper:lookup/1", "LookupHelper:ensure/1"}
             ]
    end

    test "the decision calls a helper that starts the name", ctx do
      assert sites(ctx, [C.StartHelper]) == [
               {"StartHelper:ensure/1", "StartHelper:ensure/1", "StartHelper:start/1"}
             ]
    end

    test "the lookup's result is an argument a multi-clause helper dispatches on", ctx do
      assert sites(ctx, [C.DispatchHelper]) == [
               {"DispatchHelper:ensure/1", "DispatchHelper:ensure/1",
                "DispatchHelper:do_ensure/2"}
             ]
    end

    test "the lookup and the start live in two other modules", ctx do
      assert sites(ctx, [C.AcrossModules, C.NameDirectory, C.NameStarter]) == [
               {"AcrossModules:ensure/1", "NameDirectory:whereis/1", "NameStarter:start/1"}
             ]
    end

    test "a helper that takes the loser's outcome, or starts another name, is quiet", ctx do
      assert sites(ctx, [C.HelperTakesLoser, C.HelperOtherName]) == []
    end
  end

  describe "finding" do
    @describetag souffle: false

    test "anchors the start, relates the lookup, and says what to do" do
      row = [
        "M",
        "M:ensure/1",
        "whereis",
        "start_link",
        "param",
        "0",
        "M:ensure/1#4",
        "M:ensure/1#9"
      ]

      f = Races.finding(:registry_race, row)
      assert f.severity == :warning
      assert f.title =~ "Lookup-then-start"
      assert f.at_label =~ "stale"
      assert [%{label: "the lookup it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "already_started"))
      refute f.detail =~ " in M."
    end

    test "says which argument holds the name, not a bare position" do
      row = [
        "M",
        "M:ensure/2",
        "whereis",
        "start_link",
        "param",
        "1",
        "M:ensure/2#4",
        "M:ensure/2#9"
      ]

      f = Races.finding(:registry_race, row)
      assert f.detail =~ "asks whether the name in its second argument is registered"

      for {source, key, said} <- [
            {"literal", ":cache", "asks whether :cache is registered"},
            {"field", ":name", "asks whether the name held under :name is registered"},
            {"local", "M:ensure/2#3", "asks whether the name is registered"},
            {"dynamic", "", "asks whether the name is registered"}
          ] do
        f =
          Races.finding(
            :registry_race,
            List.replace_at(List.replace_at(row, 4, source), 5, key)
          )

        assert f.detail =~ said
      end
    end

    test "names the helpers the lookup and the start sit in" do
      row = [
        "M",
        "M:ensure/1",
        "whereis",
        "start_link",
        "param",
        "0",
        "M:lookup/1#4",
        "M:start/1#9"
      ]

      f = Races.finding(:registry_race, row)

      assert f.detail =~ "whereis in M.lookup/1"
      assert f.detail =~ "in M.start/1"
      assert f.mfa == {M, :start, 1}
    end

    test "an unregister is its own race, with its own remedy" do
      row = [
        "M",
        "M:release/1",
        "whereis",
        "unregister",
        "param",
        "0",
        "M:release/1#7",
        "M:release/1#14"
      ]

      f = Races.finding(:registry_race, row)

      assert f.title =~ "Lookup-then-unregister"
      assert f.at_label =~ "unregister"
      assert Enum.any?(f.help, &(&1 =~ "ArgumentError"))
      refute Enum.any?(f.help, &(&1 =~ "already_started"))
    end
  end
end
