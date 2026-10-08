defmodule Argus.Analyses.FailureErrorTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

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
    Argus.Test.Fixtures.ExitCaller,
    Argus.Test.Fixtures.SharedKill,
    Argus.Test.Fixtures.BoundaryRescue,
    Argus.Test.Fixtures.BoundaryClient,
    Argus.Test.Fixtures.LogicRescue,
    Argus.Test.Fixtures.FailureLogReport,
    Argus.Test.Fixtures.FailureLogWork
  ]

  setup_all do
    %{batch: Batch.solve(:failure, [@batched])}
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
    do:
      Rows.where(results, :failure, "orphan_process",
        kind: "exit",
        drop: [:site, :kind, :callback]
      )

  describe "unhandled_failure: rescue" do
    test "flags a bare rescue, not a filtered one", ctx do
      results =
        analyze(ctx, [Argus.Test.Fixtures.BareRescue, Argus.Test.Fixtures.FilteredRescue])

      funcs = Enum.map(swallowed(results), fn [func | _] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "BareRescue"))
      refute Enum.any?(funcs, &String.contains?(&1, "FilteredRescue"))
    end

    test "a catch-all around what another process or a name decides is not flagged", ctx do
      results =
        analyze(ctx, [
          Argus.Test.Fixtures.BoundaryRescue,
          Argus.Test.Fixtures.BoundaryClient,
          Argus.Test.Fixtures.LogicRescue
        ])

      funcs =
        results
        |> swallowed()
        |> Enum.map(fn [func | _] -> func |> String.split(".") |> List.last() end)
        |> Enum.sort()

      assert funcs == [
               "LogicRescue:apply_and_log/1",
               "LogicRescue:apply_and_log_result/1",
               "LogicRescue:ask_and_match/1",
               "LogicRescue:notify_decoded/2",
               "LogicRescue:safe_count/1"
             ],
             "a send, a call, a supervisor query, a named :ets.new and a log line alone are " <>
               "the peer's, the name's or the logger's to fail; a match, arithmetic or a " <>
               "helper beside them, or work whose result is logged, is not"
    end

    test "a catch-all around one Elixir Logger call is the logger's; work beside it is not",
         ctx do
      results =
        analyze(ctx, [
          Argus.Test.Fixtures.FailureLogReport,
          Argus.Test.Fixtures.FailureLogWork
        ])

      funcs =
        results
        |> swallowed()
        |> Enum.map(fn [func | _] -> func |> String.split(".") |> List.last() end)
        |> Enum.sort()

      # Logger's macros gate the line on the level (`__should_log__/2`,
      # then `__do_log__/4` when it is not nil): the gate is the log
      # call's, as `Exception.format_banner/2` building its message is.
      assert funcs == ["FailureLogWork:apply_and_log/1", "FailureLogWork:log_applied/1"]
    end

    test "a catch-all an OTP header wrote into a generated parser is OTP's" do
      assert {:ok, results} = Memo.analyze([:header_catchall], :failure)
      funcs = results |> swallowed() |> Enum.map(&hd/1) |> Enum.sort()

      # Positive: the module's own catch-all, and one in a header of the
      # program's own, are the program's.
      assert funcs == [":header_catchall:from_own_header/1", ":header_catchall:own/1"]
    end

    test "does not flag a handler that reifies the exception into a value", ctx do
      # catch kind, reason -> {:error, {kind, reason}} — the caller sees
      # the error; nothing is swallowed.
      results = analyze(ctx, [Argus.Test.Fixtures.ReifyingRescue])

      assert swallowed(results) == []
    end

    test "does not flag a handler that re-raises via raw_raise", ctx do
      # :erlang.raise(kind, reason, __STACKTRACE__) compiles to the
      # raw_raise opcode, not a call to :erlang.raise/3.
      results = analyze(ctx, [Argus.Test.Fixtures.ReraisingRescue])

      assert swallowed(results) == []
    end
  end

  describe "orphan_process: exit" do
    test "flags an exit signal sent from a GenServer callback", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.ExitingServer])

      assert Enum.any?(exits(results), fn [func, _target] ->
               String.contains?(func, "ExitingServer:handle_cast/2")
             end)
    end

    test "an exit is one finding at its call, whichever callbacks run it", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.SharedKill])

      funcs =
        results
        |> exits()
        |> Enum.map(fn [func, _target] -> func |> String.split(":") |> List.last() end)
        |> Enum.uniq()
        |> Enum.sort()

      assert funcs == ["handle_info/2", "reconnect/1"],
             "the helper's exit once, and handle_info/2's own exit once"

      {:ok, findings} = Memo.run_analyses([Argus.Test.Fixtures.SharedKill], analyses: [:failure])
      exits = Enum.filter(findings.findings, &(&1.title =~ "Process.exit"))
      assert length(exits) == 2

      shared = Enum.find(exits, &match?({_, :reconnect, 1}, &1.mfa))
      assert %{instr: %Argus.InstrId{func: "reconnect"}} = shared
      assert [%{label: "a callback that runs it"}] = shared.related
    end

    test "does not flag exit/1 (a self-crash), only exit signals to a target", ctx do
      # exit(:impossible_state) raises in the current process — let-it-
      # crash, supervision-visible — not an imperative kill of another
      # process.
      results = analyze(ctx, [Argus.Test.Fixtures.SelfCrashCallback])

      assert exits(results) == []
    end

    test "an exit to a process the server started itself is its own to stop", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.ExitSignals.OwnHelper])

      assert exits(results) == []
    end

    test "an exit to a supervisor's child names the child and its supervisor", ctx do
      alias Argus.Test.Fixtures.ExitSignals

      mods = [ExitSignals.Tree, ExitSignals.Worker, ExitSignals.Killer]
      results = analyze(ctx, mods)

      assert exits(results) == []

      assert [[func, target]] =
               Rows.where(results, :failure, "orphan_process",
                 kind: "exit_supervised",
                 drop: [:site, :kind, :callback]
               )

      assert func =~ "Killer:handle_cast/2"
      assert target == inspect(ExitSignals.Worker)

      # A stop the supervisor will undo: :warning, where an exit to a
      # process known only as a value is :info.
      {:ok, findings} = Memo.run_analyses(mods, analyses: [:failure])
      [finding] = Enum.filter(findings.findings, &(&1.title =~ "Process.exit"))
      assert finding.severity == :warning
      assert [%{label: label}] = finding.related
      assert label == "#{inspect(ExitSignals.Worker)} is #{inspect(ExitSignals.Tree)}'s child"
    end

    test "does not flag Process.exit outside process callbacks", ctx do
      # ExitCaller is a plain module — exit calls there are not callback
      # hazards.
      results = analyze(ctx, [Argus.Test.Fixtures.ExitCaller])

      assert exits(results) == []
    end
  end
end
