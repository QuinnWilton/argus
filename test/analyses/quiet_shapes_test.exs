defmodule Argus.Analyses.QuietShapesTest do
  @moduledoc """
  The nearest non-bug neighbour of each rule from the 2026-09 issue-mining
  pass stays quiet. A positive test shows a rule fires; this shows where
  it stops, which is what a precision regression breaks first.
  """

  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.Quiet
  alias Argus.Test.Fixtures.ShutdownSiblings, as: Sib
  alias Argus.Test.Rows

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
    shutdown: [
      {"teardown_touches_sibling", phase: "terminate"},
      "foreign_dynamic_children",
      {"cleanup_defect", kind: "never_runs"}
    ],
    mailbox: [
      {"reply_defect", kind: "statem_unreplied"},
      {"partial_handler", source: "statem_timeout"},
      {"task_result_defect", kind: "linked_in_library"},
      {"task_result_defect", kind: "yield_linked"},
      {"partial_handler", source: "late_message"}
    ],
    structure: ~w(consumer_supervisor_permanent_child),
    coupling: ~w(dual_restart_authority),
    blocking: ~w(partial_noproc_catch),
    failure: [{"unhandled_failure", kind: "erpc_transport"}],
    ets: ~w(ets_read_outside_owner),
    startup: [{"unbounded_effect_in_init", kind: "recv"}, "post_start_initialization"]
  }

  # An entry is a relation name, or `{relation, where}` for the rows of a
  # merged relation that one rule produces.
  defp label({relation, where}),
    do: "#{relation}=#{Enum.map_join(where, ",", fn {_, v} -> v end)}"

  defp label(relation), do: relation

  defp quiet_rows(results, analysis, {relation, where}),
    do: Rows.where(results, analysis, relation, where)

  defp quiet_rows(results, _analysis, relation), do: Map.get(results, relation, [])

  for {analysis, relations} <- @expect_quiet do
    names =
      Enum.map_join(relations, ", ", fn
        {relation, where} -> "#{relation}=#{Enum.map_join(where, ",", fn {_, v} -> v end)}"
        relation -> relation
      end)

    test "#{analysis}: #{names} stay quiet on the near-miss shapes" do
      skip_without_souffle()

      {:ok, results} = Argus.analyze(@modules, unquote(analysis))

      for relation <- unquote(Macro.escape(relations)) do
        assert quiet_rows(results, unquote(analysis), relation) == [],
               "#{label(relation)} fired on a shape that must stay quiet"
      end
    end
  end

  test "a sibling call from terminate/2 guarded by catch :exit is not reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze([Sib.Sup, Sib.Producer, Sib.Watchman, Sib.GuardedWatchman], :shutdown)

    mods =
      r
      |> Rows.where(:shutdown, "teardown_touches_sibling", phase: "terminate")
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    assert mods == ["Argus.Test.Fixtures.ShutdownSiblings.Watchman"]
  end
end
