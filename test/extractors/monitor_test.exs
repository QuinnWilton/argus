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
