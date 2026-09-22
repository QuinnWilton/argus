defmodule Argus.Analyses.QuietShapesTest do
  @moduledoc """
  The nearest non-bug neighbour of each rule from the 2026-09 issue-mining
  pass stays quiet. A positive test shows a rule fires; this shows where
  it stops, which is what a precision regression breaks first.
  """

  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.Quiet
  alias Argus.Test.Fixtures.ShutdownSiblings, as: Sib

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
  end

  @modules [
    Quiet.SharedService,
    Quiet.Server,
    Quiet.ServiceClient,
    Quiet.PostponingStatem,
    Quiet.ServerAwaits,
    Quiet.TransientConsumers,
    Quiet.CleanupManager,
    Quiet.OwnStateAfterStart,
    Quiet.CatchesEveryExit,
    Quiet.ErpcRescueAll,
    Quiet.RescueAllReader,
    Quiet.BoundedReceive,
    Quiet.TimerWithCatchAll,
    Quiet.UnrelatedMonitorRestarter,
    Quiet.GenericTimeoutStatem,
    Quiet.ClockInTerminate
  ]

  @expect_quiet %{
    shutdown_safety: ~w(terminate_calls_sibling foreign_dynamic_children cleanup_never_runs),
    gen_statem: ~w(call_never_replied statem_timeout_unhandled),
    unsafe_task: ~w(linked_task_in_library yield_on_linked_task),
    supervision:
      ~w(consumer_supervisor_permanent_child dual_restart_authority post_start_initialization),
    error_handling: ~w(partial_noproc_catch handle_info_partial),
    distributed: ~w(erpc_transport_unhandled),
    ets: ~w(ets_read_outside_owner),
    startup: ~w(blocking_recv_in_init)
  }

  for {analysis, relations} <- @expect_quiet do
    test "#{analysis}: #{Enum.join(relations, ", ")} stay quiet on the near-miss shapes" do
      skip_without_souffle()

      {:ok, results} = Argus.analyze(@modules, unquote(analysis))

      for relation <- unquote(relations) do
        assert Map.get(results, relation, []) == [],
               "#{relation} fired on a shape that must stay quiet"
      end
    end
  end

  test "a sibling call from terminate/2 guarded by catch :exit is not reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze([Sib.Sup, Sib.Producer, Sib.Watchman, Sib.GuardedWatchman], :shutdown_safety)

    mods = r |> Map.get("terminate_calls_sibling", []) |> Enum.map(&hd/1) |> Enum.uniq()
    assert mods == ["Argus.Test.Fixtures.ShutdownSiblings.Watchman"]
  end
end
