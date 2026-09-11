defmodule Argus.Analyses.CallbackReceiveTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.CallbackReceive

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp run(modules) do
    assert {:ok, results} = Argus.analyze(modules, :callback_receive)

    {Map.get(results, "blocking_receive_in_callback", []),
     Map.get(results, "receive_in_callback", [])}
  end

  defp funcs(rows), do: Enum.map(rows, fn [_id, func, _cb, _beh, _prox] -> func end)

  describe "detection" do
    test "a blocking receive in a callback is reported" do
      skip_without_souffle()

      {blocking, bounded} = run([CallbackReceive.BlockingInCallback])

      assert [[_id, func, callback, "GenServer", "direct"]] = blocking
      assert func =~ "handle_call/3"
      assert callback =~ "handle_call/3"
      assert bounded == []
    end

    test "a bounded receive is reported separately, not as blocking" do
      skip_without_souffle()

      {blocking, bounded} = run([CallbackReceive.BoundedInCallback])

      assert blocking == []
      assert [[_id, func, _cb, "GenServer", "direct"]] = bounded
      assert func =~ "handle_cast/2"
    end

    test "an Erlang-spelled behaviour is a callback loop too" do
      skip_without_souffle()

      # `@behaviour :gen_statem` inspects as ":gen_statem"; matching the
      # declared string against "GenStateMachine" found nothing.
      {blocking, _} = run([CallbackReceive.StatemBlockingInInit])

      assert [[_id, func, callback, "GenStateMachine", "direct"]] = blocking
      assert func =~ "StatemBlockingInInit:init/1"
      assert callback =~ "init/1"
    end

    test "a receive one call from the callback is reported as a helper" do
      skip_without_souffle()

      {blocking, _} = run([CallbackReceive.BlockingInHelper])

      assert [[_id, func, callback, "GenServer", "helper"]] = blocking
      assert func =~ "wait_for_it/1"
      assert callback =~ "handle_info/2"
    end
  end

  describe "suppressions" do
    # Both of these contain a blocking receive and neither is a bug. They
    # are the reason this analysis is worth trusting: without them its
    # entire output on a real project was two false positives.

    test "a receive inside a spawned closure runs elsewhere and is not reported" do
      skip_without_souffle()

      {blocking, bounded} = run([CallbackReceive.SpawnedReceive])

      assert blocking == [], "attributed a spawned process's receive to its parent callback"
      assert bounded == []
    end

    test "the cancel_timer flush idiom is not reported" do
      skip_without_souffle()

      {blocking, _} = run([CallbackReceive.TimerFlush])

      assert blocking == [],
             "flagged the documented flush idiom, where cancel_timer/1 returning " <>
               "false guarantees the message is already in the mailbox"
    end

    test "a blocking receive outside any OTP behaviour is not reported" do
      skip_without_souffle()

      {blocking, bounded} = run([CallbackReceive.PlainProcess])

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
        run([
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
