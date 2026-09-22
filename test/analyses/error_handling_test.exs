defmodule Argus.Analyses.ErrorHandlingTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :error_handling)
    results
  end

  describe "handle_info_partial" do
    test "a partial handle_info with a late-message source is a note, GenStage included" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.PartialInfoServer,
          Argus.Test.Fixtures.TotalInfoServer,
          Argus.Test.Fixtures.PartialInfoStage,
          Argus.Test.Fixtures.QuietPartialInfoServer,
          Argus.Test.Fixtures.AppliesPartialInfoServer,
          Argus.Test.Fixtures.SelfSendPartialInfoServer,
          Argus.Test.Fixtures.MonitorsWithoutCatchall
        ])

      partial = Enum.map(results["handle_info_partial"], fn [mod, _f] -> mod end) |> Enum.sort()

      assert partial == [
               "Argus.Test.Fixtures.AppliesPartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoStage",
               "Argus.Test.Fixtures.SelfSendPartialInfoServer"
             ]

      # The monitoring module keeps its warning-grade finding, not this one.
      assert Enum.map(results["handle_info_without_catchall"], fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end
  end

  describe "handle_info_without_catchall" do
    test "a monitoring GenServer with only a :DOWN clause is reported" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.MonitorsWithoutCatchall,
          Argus.Test.Fixtures.MonitorsWithCatchall
        ])

      mods = Enum.map(results["handle_info_without_catchall"], fn [mod, _f] -> mod end)

      assert mods == ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end

    test "a missing :EXIT clause is reported once, as the specific finding" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TrapsWithoutExitClause])

      assert results["handle_info_without_catchall"] == []
    end
  end

  describe "swallowed_error" do
    test "flags a bare rescue, not a filtered one" do
      skip_without_souffle()

      results =
        analyze([Argus.Test.Fixtures.BareRescue, Argus.Test.Fixtures.FilteredRescue])

      funcs = Enum.map(results["swallowed_error"], fn [func] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "BareRescue"))
      refute Enum.any?(funcs, &String.contains?(&1, "FilteredRescue"))
    end

    test "does not flag a handler that reifies the exception into a value" do
      skip_without_souffle()

      # catch kind, reason -> {:error, {kind, reason}} — the caller sees
      # the error; nothing is swallowed.
      results = analyze([Argus.Test.Fixtures.ReifyingRescue])

      assert results["swallowed_error"] == []
    end

    test "does not flag a handler that re-raises via raw_raise" do
      skip_without_souffle()

      # :erlang.raise(kind, reason, __STACKTRACE__) compiles to the
      # raw_raise opcode, not a call to :erlang.raise/3.
      results = analyze([Argus.Test.Fixtures.ReraisingRescue])

      assert results["swallowed_error"] == []
    end
  end

  describe "exit_in_callback" do
    test "flags an exit signal sent from a GenServer callback" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.ExitingServer])

      assert Enum.any?(results["exit_in_callback"], fn [func, _target] ->
               String.contains?(func, "ExitingServer:handle_cast/2")
             end)
    end

    test "does not flag exit/1 (a self-crash), only exit signals to a target" do
      skip_without_souffle()

      # exit(:impossible_state) raises in the current process — let-it-
      # crash, supervision-visible — not an imperative kill of another
      # process.
      results = analyze([Argus.Test.Fixtures.SelfCrashCallback])

      assert results["exit_in_callback"] == []
    end

    test "does not flag Process.exit outside process callbacks" do
      skip_without_souffle()

      # ExitCaller is a plain module — exit calls there are not callback
      # hazards.
      results = analyze([Argus.Test.Fixtures.ExitCaller])

      assert results["exit_in_callback"] == []
    end
  end
end
