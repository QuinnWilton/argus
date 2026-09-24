defmodule Argus.Analyses.FailureErrorTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Argus.Test.Fixtures.ExitSignals.Tree,
    Argus.Test.Fixtures.ExitSignals.Worker,
    Argus.Test.Fixtures.ExitSignals.Killer,
    Argus.Test.Fixtures.BareRescue,
    Argus.Test.Fixtures.FilteredRescue,
    Argus.Test.Fixtures.ReifyingRescue,
    Argus.Test.Fixtures.ReraisingRescue,
    Argus.Test.Fixtures.ExitingServer,
    Argus.Test.Fixtures.SelfCrashCallback,
    Argus.Test.Fixtures.ExitSignals.OwnHelper,
    Argus.Test.Fixtures.ExitCaller
  ]

  setup_all do
    %{batch: Batch.solve(:failure, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(%{batch: batch}, modules) do
    assert {:ok, results} = Batch.analyze(batch, modules)
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
    test "flags a bare rescue, not a filtered one", ctx do
      skip_without_souffle()

      results =
        analyze(ctx, [Argus.Test.Fixtures.BareRescue, Argus.Test.Fixtures.FilteredRescue])

      funcs = Enum.map(swallowed(results), fn [func | _] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "BareRescue"))
      refute Enum.any?(funcs, &String.contains?(&1, "FilteredRescue"))
    end

    test "does not flag a handler that reifies the exception into a value", ctx do
      skip_without_souffle()

      # catch kind, reason -> {:error, {kind, reason}} — the caller sees
      # the error; nothing is swallowed.
      results = analyze(ctx, [Argus.Test.Fixtures.ReifyingRescue])

      assert swallowed(results) == []
    end

    test "does not flag a handler that re-raises via raw_raise", ctx do
      skip_without_souffle()

      # :erlang.raise(kind, reason, __STACKTRACE__) compiles to the
      # raw_raise opcode, not a call to :erlang.raise/3.
      results = analyze(ctx, [Argus.Test.Fixtures.ReraisingRescue])

      assert swallowed(results) == []
    end
  end

  describe "orphan_process: exit" do
    test "flags an exit signal sent from a GenServer callback", ctx do
      skip_without_souffle()

      results = analyze(ctx, [Argus.Test.Fixtures.ExitingServer])

      assert Enum.any?(exits(results), fn [func, _target] ->
               String.contains?(func, "ExitingServer:handle_cast/2")
             end)
    end

    test "does not flag exit/1 (a self-crash), only exit signals to a target", ctx do
      skip_without_souffle()

      # exit(:impossible_state) raises in the current process — let-it-
      # crash, supervision-visible — not an imperative kill of another
      # process.
      results = analyze(ctx, [Argus.Test.Fixtures.SelfCrashCallback])

      assert exits(results) == []
    end

    test "an exit to a process the server started itself is its own to stop", ctx do
      skip_without_souffle()

      results = analyze(ctx, [Argus.Test.Fixtures.ExitSignals.OwnHelper])

      assert exits(results) == []
    end

    test "an exit to a supervisor's child names the child and its supervisor", ctx do
      skip_without_souffle()

      alias Argus.Test.Fixtures.ExitSignals

      mods = [ExitSignals.Tree, ExitSignals.Worker, ExitSignals.Killer]
      results = analyze(ctx, mods)

      assert [[func, target]] = exits(results)
      assert func =~ "Killer:handle_cast/2"
      assert target == inspect(ExitSignals.Worker)

      {:ok, findings} = Memo.run_analyses(mods, analyses: [:failure])
      [finding] = Enum.filter(findings.findings, &(&1.title =~ "Process.exit"))
      assert [%{label: label}] = finding.related
      assert label == "#{inspect(ExitSignals.Worker)} is #{inspect(ExitSignals.Tree)}'s child"
    end

    test "does not flag Process.exit outside process callbacks", ctx do
      skip_without_souffle()

      # ExitCaller is a plain module — exit calls there are not callback
      # hazards.
      results = analyze(ctx, [Argus.Test.Fixtures.ExitCaller])

      assert exits(results) == []
    end
  end
end
