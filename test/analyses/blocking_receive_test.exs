defmodule Argus.Analyses.BlockingReceiveTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.CallbackReceive
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    CallbackReceive.BlockingInCallback,
    CallbackReceive.BoundedInCallback,
    CallbackReceive.StatemBlockingInInit,
    CallbackReceive.ReceiveInEach,
    CallbackReceive.BlockingInHelper,
    CallbackReceive.SpawnedReceive,
    CallbackReceive.TimerFlush,
    CallbackReceive.TimerFlushArmed,
    CallbackReceive.TimerFlushAfterZero,
    CallbackReceive.CancelThenBoundedWait,
    CallbackReceive.CancelThenWait,
    CallbackReceive.PlainProcess
  ]

  setup_all do
    %{batch: Batch.solve(:blocking, [@batched])}
  end

  # A set that shares a module with another test's is about what the
  # modules do together: it is solved on its own (`:alone`), and the
  # batch holds only disjoint sets.
  defp solve(:alone, modules), do: Argus.analyze(modules, :blocking)
  defp solve(%{batch: batch}, modules), do: Batch.analyze(batch, modules)

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp run(source, modules) do
    assert {:ok, results} = solve(source, modules)

    {Rows.where(results, :blocking, "receive_in_callback", bounded: "false", drop: [:bounded]),
     Rows.where(results, :blocking, "receive_in_callback", bounded: "true", drop: [:bounded])}
  end

  defp funcs(rows), do: Enum.map(rows, fn [_id, func, _cb, _beh, _prox] -> func end)

  describe "detection" do
    test "a blocking receive in a callback is reported", ctx do
      skip_without_souffle()

      {blocking, bounded} = run(ctx, [CallbackReceive.BlockingInCallback])

      assert [[_id, func, callback, "GenServer", "direct"]] = blocking
      assert func =~ "handle_call/3"
      assert callback =~ "handle_call/3"
      assert bounded == []
    end

    test "a bounded receive is reported separately, not as blocking", ctx do
      skip_without_souffle()

      {blocking, bounded} = run(ctx, [CallbackReceive.BoundedInCallback])

      assert blocking == []
      assert [[_id, func, _cb, "GenServer", "direct"]] = bounded
      assert func =~ "handle_cast/2"
    end

    test "an Erlang-spelled behaviour is a callback loop too", ctx do
      skip_without_souffle()

      # `@behaviour :gen_statem` inspects as ":gen_statem"; matching the
      # declared string against "GenStateMachine" found nothing.
      {blocking, _} = run(ctx, [CallbackReceive.StatemBlockingInInit])

      assert [[_id, func, callback, "GenStateMachine", "direct"]] = blocking
      assert func =~ "StatemBlockingInInit:terminate/3"
      assert callback =~ "terminate/3"
    end

    test "a blocking receive in init/1 is startup's finding, reported there once", ctx do
      skip_without_souffle()

      {blocking, _} = run(ctx, [CallbackReceive.StatemBlockingInInit])
      refute Enum.any?(blocking, fn [_, func | _] -> func =~ "init/1" end)

      {:ok, startup} = Argus.analyze([CallbackReceive.StatemBlockingInInit], :startup)
      assert [[_mod, "receive", func, _site]] = startup["unbounded_effect_in_init"]
      assert func =~ "StatemBlockingInInit:init/1"
    end

    test "a receive in a closure handed to Enum.each is the callback's own", ctx do
      skip_without_souffle()

      {blocking, _} = run(ctx, [CallbackReceive.ReceiveInEach])

      assert [[_id, func, callback, "GenServer", "helper"]] = blocking
      assert func =~ "-handle_call/3-fun-0-"
      assert callback =~ "handle_call/3"
    end

    test "a receive one call from the callback is reported as a helper", ctx do
      skip_without_souffle()

      {blocking, _} = run(ctx, [CallbackReceive.BlockingInHelper])

      assert [[_id, func, callback, "GenServer", "helper"]] = blocking
      assert func =~ "wait_for_it/1"
      assert callback =~ "handle_info/2"
    end
  end

  describe "suppressions" do
    # Both of these contain a blocking receive and neither is a bug. They
    # are the reason this analysis is worth trusting: without them its
    # entire output on a real project was two false positives.

    test "a receive inside a spawned closure runs elsewhere and is not reported", ctx do
      skip_without_souffle()

      {blocking, bounded} = run(ctx, [CallbackReceive.SpawnedReceive])

      assert blocking == [], "attributed a spawned process's receive to its parent callback"
      assert bounded == []
    end

    test "the cancel_timer flush idiom is not reported", ctx do
      skip_without_souffle()

      {blocking, _} = run(ctx, [CallbackReceive.TimerFlush])

      assert blocking == [],
             "flagged the documented flush idiom, where cancel_timer/1 returning " <>
               "false guarantees the message is already in the mailbox"
    end

    test "the flush idiom in the module that arms the timer is not reported", ctx do
      skip_without_souffle()
      {blocking, _} = run(ctx, [CallbackReceive.TimerFlushArmed])
      assert blocking == []
    end

    test "the zero-timeout flush after a cancel is not reported as a bounded receive", ctx do
      skip_without_souffle()
      {blocking, bounded} = run(ctx, [CallbackReceive.TimerFlushAfterZero])
      assert blocking == []
      assert bounded == [], "flagged `receive :tick -> :ok after 0 -> :ok end` after a cancel"
    end

    test "a bounded receive after a cancel that waits for something else is still reported",
         ctx do
      skip_without_souffle()
      {blocking, bounded} = run(ctx, [CallbackReceive.CancelThenBoundedWait])
      assert blocking == []
      assert [[_id, func, _cb, "GenServer", "direct"]] = bounded
      assert func =~ "CancelThenBoundedWait:handle_cast/2"
    end

    test "a cancel does not excuse a receive that waits for something no timer sends", ctx do
      skip_without_souffle()
      {blocking, _} = run(ctx, [CallbackReceive.CancelThenWait])
      assert [[_id, func, _cb, "GenServer", "direct"]] = blocking
      assert func =~ "CancelThenWait:handle_call/3"
    end

    test "a blocking receive outside any OTP behaviour is not reported", ctx do
      skip_without_souffle()

      {blocking, bounded} = run(ctx, [CallbackReceive.PlainProcess])

      assert blocking == []
      assert bounded == []
    end
  end

  describe "the suppressions are not blanket" do
    test "a real bug is still found when analysed alongside every suppressed shape" do
      skip_without_souffle()

      # Guards the failure mode where a suppression is written too broadly
      # and silences the analysis: all six fixtures at once must yield
      # exactly the three genuine placements.
      {blocking, bounded} =
        run(:alone, [
          CallbackReceive.BlockingInCallback,
          CallbackReceive.BlockingInHelper,
          CallbackReceive.BoundedInCallback,
          CallbackReceive.SpawnedReceive,
          CallbackReceive.TimerFlush,
          CallbackReceive.PlainProcess
        ])

      blocking_funcs = funcs(blocking)
      assert length(blocking_funcs) == 2
      assert Enum.any?(blocking_funcs, &(&1 =~ "BlockingInCallback"))
      assert Enum.any?(blocking_funcs, &(&1 =~ "wait_for_it"))

      refute Enum.any?(blocking_funcs, &(&1 =~ "SpawnedReceive"))
      refute Enum.any?(blocking_funcs, &(&1 =~ "TimerFlush"))
      refute Enum.any?(blocking_funcs, &(&1 =~ "PlainProcess"))

      assert length(bounded) == 1
    end
  end

  describe "recv_start facts" do
    test "blocking is decided by following the fail label, on real OTP code" do
      # gen_server's own loop uses wait_timeout; timer's interval loop uses
      # a bare wait. If this ever collapses to one value the analysis
      # silently becomes "every receive".
      {:ok, facts} = Argus.Pipeline.extract([:gen_server, :timer])
      rows = Map.get(facts, :recv_start, [])

      blocking = for [_id, caller, "1", _fail] <- rows, do: caller
      bounded = for [_id, caller, "0", _fail] <- rows, do: caller

      assert blocking != []
      assert bounded != []
      assert Enum.any?(blocking, &String.contains?(&1, ":timer:"))
      assert Enum.any?(bounded, &String.contains?(&1, ":gen_server:"))
    end
  end
end
