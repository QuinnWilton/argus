defmodule Argus.Analyses.ShutdownSupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "permanent_child_stops_normally" do
    test "a permanent child that stops with :normal is reported; a transient one is not" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.QuitterSupervisor,
        Argus.Test.Fixtures.TransientQuitterSupervisor,
        Argus.Test.Fixtures.PermanentQuitter
      ]

      assert {:ok, results} = Memo.analyze(modules, :shutdown)

      assert [[sup, child, ":normal", site, _sup_site]] =
               results["permanent_child_stops_normally"]

      assert sup == "Argus.Test.Fixtures.QuitterSupervisor"
      assert child == "Argus.Test.Fixtures.PermanentQuitter"
      assert site =~ "PermanentQuitter:handle_call/3#"
    end

    test "a shorthand's restart is the one its child's own child_spec/1 states" do
      skip_without_souffle()

      alias Argus.Test.Fixtures.ChildSpecs, as: Specs

      modules = [
        Specs.RestartSup,
        Specs.TransientOwner,
        Specs.ProvisionerLike,
        Specs.PermanentStopper,
        Specs.InitStopper
      ]

      assert {:ok, results} = Memo.analyze(modules, :shutdown)

      # `use GenServer, restart: :transient` and a hand-written transient
      # child_spec/1 a list calls are not restarted after a normal stop;
      # the default is. An init/1 that stops fails its start: nothing to
      # restart.
      assert for([_sup, child | _] <- results["permanent_child_stops_normally"], do: child) ==
               [inspect(Specs.PermanentStopper)]
    end

    # Issue #4: a restart the extractor cannot read, or a default a start's
    # argument may override, is unknown; a permanent child is shown to be
    # one.
    test "the issue's repro: Keyword.get(opts, :restart, :transient) under {Repro.Worker, []}" do
      skip_without_souffle()

      alias Argus.Test.Fixtures.Issue4.Repro

      assert {:ok, results} = Memo.analyze([Repro.Worker, Repro.Supervisor], :shutdown)
      assert Map.get(results, "permanent_child_stops_normally", []) == []
    end

    test "a restart shown permanent is reported; one unknown or transient is not" do
      skip_without_souffle()

      alias Argus.Test.Fixtures.Issue4.{ListSup, Starter, Stoppers}

      modules = [
        Starter,
        ListSup,
        Stoppers.ExplicitPermanent,
        Stoppers.NoRestartKey,
        Stoppers.PermanentDefault,
        Stoppers.TransientDefault,
        Stoppers.UnreadRestart
      ]

      assert {:ok, results} = Memo.analyze(modules, :shutdown)

      reported =
        for [sup, child | _] <- results["permanent_child_stops_normally"],
            uniq: true,
            do: {sup, child |> String.split(".") |> List.last()}

      assert Enum.sort(reported) == [
               {inspect(ListSup), "TransientDefault"},
               {inspect(Starter), "ExplicitPermanent"},
               {inspect(Starter), "NoRestartKey"},
               {inspect(Starter), "PermanentDefault"},
               {inspect(Starter), "TransientDefault"}
             ]
    end
  end
end
