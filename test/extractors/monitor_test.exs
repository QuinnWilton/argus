defmodule Argus.Extractors.MonitorTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Monitor
  alias Argus.Test.Fixtures.MonitorLeak, as: M

  defp extract(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    Monitor.extract(data)
  end

  describe "monitor_ref_dropped" do
    test "a discarded ref is recorded at its monitor site" do
      facts = extract(M.DropsRef)

      assert [[site, func]] = facts[:monitor_ref_dropped]
      assert func == "Argus.Test.Fixtures.MonitorLeak.DropsRef:handle_call/3"
      assert [[^site, ^func, _target]] = facts[:monitor_call]
    end

    test "a ref a tail call returns is lost where every caller loses it" do
      assert [[_, func]] = extract(M.EachDropsRefs)[:monitor_ref_dropped]
      assert func =~ "-handle_call/3-fun-"

      assert [[_, func]] = extract(M.ForeachDropsRefs)[:monitor_ref_dropped]
      assert func =~ "-handle_call/3-fun-"

      assert [[_, func]] = extract(M.HelperDropsRef)[:monitor_ref_dropped]
      assert func =~ ":watch/1"

      for mod <- [M.MapsRefs, M.HelperKeepsRef] do
        refute Map.has_key?(extract(mod), :monitor_ref_dropped), "#{inspect(mod)} keeps its ref"
      end
    end

    test "a ref every return of the function answers is lost where a caller loses it" do
      # monitor_and_signal/1 returns its ref; stop/2 throws it away.
      assert [[_, func]] = extract(M.WaitsForAnotherRef)[:monitor_ref_dropped]
      assert func =~ "monitor_and_signal/1"

      # The same helper whose caller waits on the ref, or demonitors it.
      for mod <- [M.CollectedByRef, M.FlushedByCaller] do
        refute Map.has_key?(extract(mod), :monitor_ref_dropped), "#{inspect(mod)} keeps its ref"
      end
    end

    test "a ref that is stored, returned or waited on is not" do
      for mod <- [M.Leaks, M.NeverReleases, M.KillsMonitored, M.ClientSideMonitor] do
        refute Map.has_key?(extract(mod), :monitor_ref_dropped),
               "#{inspect(mod)} keeps its ref"
      end
    end
  end

  describe "monitor_released_after" do
    # The functions each row's call calls, by name, for the rows in `func`.
    defp awaited_calls(mod, func) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      instrs =
        Enum.find_value(data.functions, fn
          {:function, ^func, _arity, _entry, instrs} -> instrs
          _ -> nil
        end)

      for [_func, id] <- Map.get(Monitor.extract(data), :monitor_released_after, []),
          {:ok, %Argus.InstrId{func: name, idx: idx}} = Argus.InstrId.parse(id),
          name == Atom.to_string(func) do
        case Enum.at(instrs, idx) do
          {:call, _, {_mod, callee, _arity}} -> callee
          {:call_ext, _, {:extfunc, _mod, callee, _arity}} -> callee
        end
      end
      |> Enum.sort()
    end

    test "the call that monitors every child is followed by the wait for every :DOWN" do
      assert :monitor_children in awaited_calls(M.CollectedByCaller, :terminate_children)
    end

    test "a caller that never waits has no rows" do
      assert awaited_calls(M.ReturnsLive, :unlink_all) == []
    end

    test "a wait on one branch does not follow the call" do
      refute :filter in awaited_calls(M.WaitsOnOnePath, :stop_children)
    end

    test "a wait pinned to the ref the call returned follows it" do
      assert awaited_calls(M.CollectedByRef, :stop) == [:monitor_and_signal]
      assert awaited_calls(M.FlushedByCaller, :ping) == [:monitor_and_signal]
    end

    test "a wait pinned to another ref does not" do
      refute :monitor_and_signal in awaited_calls(M.WaitsForAnotherRef, :stop)
    end

    test "a monitor its own function releases on every way out follows itself" do
      # A demonitor with :flush after the wait, whatever the wait did.
      assert awaited_calls(M.Flushes, :wait) == [:monitor]
      # A timed wait with no demonitor leaves it live on the timeout.
      assert awaited_calls(M.Leaks, :wait) == []
    end

    test "a demonitor without :flush releases the monitor too" do
      assert awaited_calls(Argus.Test.Soundness.Monitors.PlainDemonitor, :ask) == [:monitor]
    end

    test "a helper handed the ref releases it when it does on every way out" do
      # wait_loop/1 takes the ref's :DOWN, or flushes it on the timeout.
      assert awaited_calls(M.FlushesInHelper, :request) == [:monitor]
      # wait_loop/1 of LeaksThroughHelper returns on the timeout with it live.
      assert awaited_calls(M.LeaksThroughHelper, :request) == []
    end
  end

  describe "monitor_started" do
    test "a pid a start of another module answered, in its {:ok, pid}" do
      assert [[_, func, start]] = extract(M.MonitorsOwnWorker)[:monitor_started]
      assert func =~ "handle_cast/2"
      assert start =~ "MonitorsOwnWorker:handle_cast/2#"
    end

    test "the pid of an already-started answer is none" do
      # Either branch's pid is the answer's: the {:ok, pid} one's is fresh,
      # the {:error, {:already_started, pid}} one's is not, so the paths
      # disagree.
      refute Map.has_key?(extract(Argus.Test.Soundness.Monitors.StartOrFind), :monitor_started)
      refute Map.has_key?(extract(M.DropsRef), :monitor_started)
    end

    test "a start of another module is named, and the rules decide whose it is" do
      # Sessions.start_session/1 is the program's own: the rules do not take
      # it as a start (it may look the session up), only the call site.
      assert [[_, _, start]] = extract(Argus.Test.Soundness.Mailbox.Tracker)[:monitor_started]
      assert start =~ "Tracker:handle_call/3#"
    end
  end

  describe "recv_takes_down" do
    test "a receive with a clause whose head fixes the tag to :DOWN" do
      assert [[_, func]] = extract(M.Leaks)[:recv_takes_down]
      assert func =~ "Leaks:wait/1"

      # A receive whose clauses take other messages only is none.
      refute Map.has_key?(extract(M.NoMonitor), :recv_takes_down)
      refute Map.has_key?(extract(M.TaskPolls), :recv_takes_down)
    end
  end

  describe "recv_signal" do
    alias Argus.Test.Fixtures.InitRecv

    defp signals(mod) do
      for [_id, func, signal] <- Map.get(extract(mod), :recv_signal, []),
          do: {func |> String.split(":") |> List.last(), signal}
    end

    test "a pinned :DOWN, whatever the ref's origin, and a pinned port's :EXIT" do
      assert signals(InitRecv.AsksWithMonitor) == [{"ask/2", "down"}]

      assert Enum.sort(signals(InitRecv.AwaitsHandedDown)) == [
               {"await_down/2", "down"},
               {"run_aside/1", "down"}
             ]

      assert signals(InitRecv.ClosesPort) == [{"init/1", "exit"}]
    end

    test "a :DOWN is taken while the monitor is in place: a demonitor first is none" do
      alias Argus.Test.Fixtures.CallbackReceive, as: R

      assert signals(R.DemonitorsThenAwaits) == []
      # The demonitor after the reply cancels nothing the wait takes.
      assert signals(R.AwaitsReplyOrDown) == [{"handle_call/3", "down"}]
    end

    test "a loop's clause for its parent's exit, and an unpinned wait, are none" do
      assert signals(InitRecv.LoopsOnParent) == []
      assert signals(InitRecv.Waits) == []
    end
  end

  describe "recv_flush" do
    alias Argus.Test.Fixtures.InitRecv

    defp flushes(mod) do
      for [id, func, cancel] <- Map.get(extract(mod), :recv_flush, []) do
        [_, recv] = String.split(id, "#")
        [_, at] = String.split(cancel, "#")

        {func |> String.split(":") |> List.last(),
         String.to_integer(at) < String.to_integer(recv)}
      end
    end

    test "a receive on the false side of a test of the cancel's result" do
      assert flushes(InitRecv.FlushesTimer) == [{"init/1", true}]
      assert flushes(InitRecv.FlushesOnFalse) == [{"init/1", true}]
      assert flushes(InitRecv.FlushesUnlessCancelled) == [{"init/1", true}]
    end

    test "a cancel nothing tests, or a ref a caller handed with no test, is none" do
      assert flushes(InitRecv.FlushesUnchecked) == []
      assert flushes(InitRecv.CancelsHanded) == []
    end
  end

  describe "recv_down" do
    alias Argus.Test.Fixtures.CallbackReceive, as: R

    defp down(mod) do
      facts = extract(mod)
      monitors = for [id, _func, _target] <- Map.get(facts, :monitor_call, []), do: id
      {Map.get(facts, :recv_down, []), monitors}
    end

    test "a receive for the :DOWN of the monitor its function took names that monitor" do
      for mod <- [R.AwaitsOwnDown, R.AwaitsDoneOrDown, R.AwaitsReplyOrDown] do
        assert {[[recv, func, monitor]], [monitor]} = down(mod), inspect(mod)
        assert String.starts_with?(recv, func <> "#")
        assert String.starts_with?(monitor, func <> "#")
      end
    end

    test "a pinned ref tested with is_ne_exact is read as the same pin" do
      assert {rows, [monitor]} = down(R.KillsAfterGrace)
      assert [[_, _, ^monitor], [_, _, ^monitor]] = rows
    end

    test "the closure a comprehension lifts the wait into is the function that took the monitor" do
      assert {[[_recv, func, _monitor]], _} = down(R.AwaitsDoneOrDown)
      assert func =~ "-terminate/2-fun-"
    end

    test "a ref from elsewhere, a pinned reason, or a demonitor first is not a bound" do
      for mod <- [R.AwaitsAnotherDown, R.AwaitsNormalDown, R.DemonitorsThenAwaits] do
        assert {[], _} = down(mod), inspect(mod)
      end
    end

    test "a receive that takes other messages only is not one" do
      for mod <- [R.BlockingInCallback, R.BoundedInCallback, R.CancelThenWait] do
        assert {[], _} = down(mod), inspect(mod)
      end
    end
  end

  describe "monitor_type" do
    alias Argus.Test.Soundness.Witness, as: W

    test "Process.monitor/1 watches a process; :erlang.monitor/2 its literal type" do
      types = fn mod ->
        facts = extract(mod)
        sites = for [id, _func, _target] <- facts[:monitor_call], do: id
        for [id, type] <- facts[:monitor_type], id in sites, do: type
      end

      assert types.(W.DownOnlyNormal) == ["process"]
      assert types.(W.PortDownPinned) == ["port"]
      assert types.(Argus.Test.Fixtures.MonitorsPortTakingProcessDowns) == ["port"]
    end
  end

  describe "read through Argus.Instr" do
    alias Argus.Test.Fixtures.Instr, as: Fixture

    defp rows(relation, fragment) do
      for [_id, func | rest] <- Map.get(extract(Fixture), relation, []),
          String.contains?(func, fragment),
          do: rest
    end

    test "a ref the receive writes over before anything reads it is dropped" do
      assert rows(:monitor_ref_dropped, "monitor_then_receive/1") == [[]]
    end

    test "a pid is a started child only when every path to the monitor started it" do
      assert rows(:monitor_call, "monitor_started/2") == [["started_child"]]
      assert rows(:monitor_call, "monitor_either/3") == [["dynamic"]]
    end
  end
end
