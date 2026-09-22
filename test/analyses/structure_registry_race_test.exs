defmodule Argus.Analyses.StructureRegistryRaceTest do
  use ExUnit.Case

  alias Argus.Analyses.Structure
  alias Argus.Souffle
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(modules) do
    {:ok, results} = Argus.analyze(modules, :structure)

    for [_mod, func, lookup, create, key, _check, _act] <- results["registry_race"],
        do: {func |> String.split(":") |> List.last(), lookup, create, key}
  end

  describe "registry_race" do
    test "whereis, then a named start of the same parameter, in a plain API" do
      skip_without_souffle()
      assert [{"ensure/1", "whereis", "start_link", "0"}] = races([C.WhereisThenStart])
    end

    test "Registry.lookup, then start_child, the result returned untaken" do
      skip_without_souffle()

      assert [{"get_or_start/1", "registry_lookup", "start_child", "0"}] =
               races([C.LookupThenStartChild])
    end

    test "whereis of a literal, then register of the same literal" do
      skip_without_souffle()
      assert [{"claim/0", "whereis", "register", ":leader"}] = races([C.WhereisThenRegister])
    end

    test "a LiveView doing it runs once per socket" do
      skip_without_souffle()
      assert [{"handle_event/3", "registry_lookup", "start_child", _}] = races([C.ManyInstances])
    end

    test "a later clause keeps its parameters across the first clause's return" do
      skip_without_souffle()
      assert [{"ensure/2", "whereis", "start_link", "1"}] = races([C.LaterClauseName])
    end

    test "taking the loser's outcome, in the function or its caller, is the fix" do
      skip_without_souffle()

      assert races([
               C.HandlesAlreadyStarted,
               C.HandlesAlreadyRegistered,
               C.CallerHandlesAlreadyStarted,
               C.RescuesArgumentError
             ]) == []
    end

    test "the owner deciding on its own registry from its own callbacks is one process" do
      skip_without_souffle()
      assert races([C.OwnerRegisters]) == []
    end

    test "no branch on the lookup, or different names, is not the shape" do
      skip_without_souffle()
      assert races([C.UncheckedWhereisThenStart, C.DifferentNames]) == []
    end
  end

  describe "finding" do
    test "anchors the start, relates the lookup, and says what to do" do
      row = ["M", "M:ensure/1", "whereis", "start_link", "0", "M:ensure/1#4", "M:ensure/1#9"]
      f = Structure.finding(:registry_race, row)
      assert f.severity == :warning
      assert f.title =~ "Lookup-then-start"
      assert f.at_label =~ "stale"
      assert [%{label: "the lookup it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "already_started"))
    end
  end
end
