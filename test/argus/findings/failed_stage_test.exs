defmodule Argus.Findings.FailedStageTest do
  # Not async: the failing engine is a cache root of its own
  # (`Argus.Test.FailingEngine`), named by a VM-wide variable.
  use ExUnit.Case, async: false

  alias Argus.Findings

  @moduletag :tmp_dir

  # The stage's failure is a warning as well as the degradation.
  @tag :flowlog
  @tag :capture_log
  test "a failed points-to stage degrades only the analyses that read it", %{tmp_dir: dir} do
    # A store of its own: a stage kept by another run would not run the
    # failing engine at all.
    Argus.Test.FailingEngine.with("points_to.dl", fn ->
      assert {:ok, %Findings{ran: ran, degraded: degraded}} =
               Findings.run([:lists],
                 analyses: [:startup, :effects],
                 store: Path.join(dir, "store")
               )

      assert [%{analysis: :effects}] = ran

      assert [
               %{
                 analysis: :startup,
                 reason: {:points_to, {:flowlog_engine_exit, 1, log}},
                 detail: detail
               }
             ] = degraded

      assert log =~ "injected failure"
      assert detail =~ "points_to.dl"
    end)
  end
end
