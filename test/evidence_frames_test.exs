defmodule Argus.EvidenceFramesTest do
  @moduledoc """
  Every evidence relation reaches its finding as related frames, end to
  end: solved from fixtures, joined, and rendered by `run/2`. The unit
  tests of `evidence/2` call the builder directly; these pin the join
  columns and the frames' anchors as a reader sees them.
  """

  use ExUnit.Case, async: true

  alias Argus.InstrId
  alias Argus.Souffle
  alias Argus.Test.Fixtures
  alias Argus.Test.Memo

  setup do
    unless Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  defp findings(modules, analysis) do
    assert {:ok, %{findings: findings, degraded: []}} =
             Memo.run_analyses(modules, analyses: [analysis])

    findings
  end

  test "monitored_entry_removal: where a server that never demonitors drops an entry" do
    assert [finding] =
             [Fixtures.MonitorLeak.NeverReleases]
             |> findings(:mailbox)
             |> Enum.filter(&(&1.title =~ "monitors but never demonitors"))

    assert [frame] = finding.related
    assert frame.label == "an entry is removed here, its monitor left live"
    assert frame.module == Fixtures.MonitorLeak.NeverReleases
    assert %InstrId{func: "handle_cast", arity: 2} = frame.instr
  end

  test "task_yield_site: where a linked task is collected with Task.yield" do
    assert [finding] =
             [Fixtures.YieldsLinkedTask]
             |> findings(:mailbox)
             |> Enum.filter(&(&1.title =~ "Task.yield on a linked task"))

    assert [frame] = finding.related
    assert frame.label == "collected with Task.yield here"
    assert frame.module == Fixtures.YieldsLinkedTask
    assert %InstrId{func: "fan_out", arity: 1} = frame.instr
  end

  test "exit_target_owner: the supervisor that owns an exit signal's target" do
    alias Fixtures.ExitSignals

    assert [finding] =
             [ExitSignals.Tree, ExitSignals.Worker, ExitSignals.Killer]
             |> findings(:failure)
             |> Enum.filter(&(&1.title =~ "Process.exit inside"))

    assert [frame] = finding.related
    assert frame.label == "#{inspect(ExitSignals.Worker)} is #{inspect(ExitSignals.Tree)}'s child"
    assert frame.module == ExitSignals.Tree
    assert %InstrId{func: "init", arity: 1} = frame.instr
  end

  test "init_reaches_recv: the init/1 callbacks that reach an unbounded receive" do
    assert [finding] =
             [Fixtures.InitRecv.Blocking]
             |> findings(:startup)
             |> Enum.filter(&(&1.title =~ "waits on a socket with no timeout"))

    assert [frame] = finding.related
    assert frame.label == "reached from #{inspect(Fixtures.InitRecv.Blocking)}.init/1"
    assert frame.mfa == {Fixtures.InitRecv.Blocking, :init, 1}
  end

  test "sink_export: the exported functions a sink no request reaches is reachable from" do
    assert [finding] = findings([Fixtures.ExportedSinkCaller], :unsafe_input)
    assert finding.mfa == {Fixtures.ExportedSinkCaller, :to_tag, 1}

    assert [frame] = finding.related
    assert frame.label =~ "tag/1, which is exported"
    assert frame.mfa == {Fixtures.ExportedSinkCaller, :tag, 1}
  end

  test "sink_endpoint: the HTTP routes a request-reachable sink sits behind" do
    live_view = Fixtures.RequestSurface.AdjacentLiveView

    assert [finding] =
             [Fixtures.Router, live_view]
             |> findings(:unsafe_input)
             |> Enum.filter(&(&1.module == live_view))

    assert [frame] = finding.related
    assert frame.label == "reachable from GET /orders/:field"
    assert frame.module == live_view
  end
end
