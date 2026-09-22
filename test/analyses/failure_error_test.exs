defmodule Argus.Analyses.FailureErrorTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :failure)
    results
  end

  defp swallowed(results),
    do:
      Rows.where(results, :failure, "unhandled_failure",
        kind: "rescue",
        drop: [:site, :kind, :shape]
      )

  defp exits(results),
    do: Rows.where(results, :failure, "orphan_process", kind: "exit", drop: [:site, :kind])

  describe "unhandled_failure: rescue" do
    test "flags a bare rescue, not a filtered one" do
      skip_without_souffle()

      results =
        analyze([Argus.Test.Fixtures.BareRescue, Argus.Test.Fixtures.FilteredRescue])

      funcs = Enum.map(swallowed(results), fn [func] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "BareRescue"))
      refute Enum.any?(funcs, &String.contains?(&1, "FilteredRescue"))
    end

    test "does not flag a handler that reifies the exception into a value" do
      skip_without_souffle()

      # catch kind, reason -> {:error, {kind, reason}} — the caller sees
      # the error; nothing is swallowed.
      results = analyze([Argus.Test.Fixtures.ReifyingRescue])

      assert swallowed(results) == []
    end

    test "does not flag a handler that re-raises via raw_raise" do
      skip_without_souffle()

      # :erlang.raise(kind, reason, __STACKTRACE__) compiles to the
      # raw_raise opcode, not a call to :erlang.raise/3.
      results = analyze([Argus.Test.Fixtures.ReraisingRescue])

      assert swallowed(results) == []
    end
  end

  describe "orphan_process: exit" do
    test "flags an exit signal sent from a GenServer callback" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.ExitingServer])

      assert Enum.any?(exits(results), fn [func, _target] ->
               String.contains?(func, "ExitingServer:handle_cast/2")
             end)
    end

    test "does not flag exit/1 (a self-crash), only exit signals to a target" do
      skip_without_souffle()

      # exit(:impossible_state) raises in the current process — let-it-
      # crash, supervision-visible — not an imperative kill of another
      # process.
      results = analyze([Argus.Test.Fixtures.SelfCrashCallback])

      assert exits(results) == []
    end

    test "does not flag Process.exit outside process callbacks" do
      skip_without_souffle()

      # ExitCaller is a plain module — exit calls there are not callback
      # hazards.
      results = analyze([Argus.Test.Fixtures.ExitCaller])

      assert exits(results) == []
    end
  end
end
