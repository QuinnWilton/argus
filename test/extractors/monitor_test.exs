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
end
