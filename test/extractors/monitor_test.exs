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

    test "a ref that is stored, returned or waited on is not" do
      for mod <- [M.Leaks, M.NeverReleases, M.KillsMonitored, M.ClientSideMonitor] do
        refute Map.has_key?(extract(mod), :monitor_ref_dropped),
               "#{inspect(mod)} keeps its ref"
      end
    end
  end

  describe "awaits_down_after" do
    # The functions each row's call calls, by name, for the rows in `func`.
    defp awaited_calls(mod, func) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      instrs =
        Enum.find_value(data.functions, fn
          {:function, ^func, _arity, _entry, instrs} -> instrs
          _ -> nil
        end)

      for [_func, id] <- Map.get(Monitor.extract(data), :awaits_down_after, []),
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
