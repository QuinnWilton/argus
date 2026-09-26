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

  test "monitor_leak_frame: where a server drops the record of a process it still monitors" do
    assert [finding] =
             [Fixtures.MonitorLeak.NeverReleases]
             |> findings(:mailbox)
             |> Enum.filter(&(&1.title =~ "Entry dropped while its process stays monitored"))

    assert [frame] = finding.related
    assert frame.label == "the entry is dropped here, the monitor stays"
    assert frame.mfa == {Fixtures.MonitorLeak.NeverReleases, :handle_cast, 2}
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

  test "rpc_wrapped: the rpc whose answer a wrapper returns to the matching caller" do
    alias Fixtures.Hypothesized, as: H

    assert [finding] =
             [H.RpcProto, H.RpcFacade, H.RpcWrapperCaller]
             |> findings(:failure)
             |> Enum.filter(&(&1.mfa == {H.RpcWrapperCaller, :delete, 2}))

    assert [frame] = finding.related
    assert frame.label == "#{inspect(H.RpcFacade)}.delete/2 returns this rpc's answer"
    assert frame.module == H.RpcProto
    assert %InstrId{func: "delete", arity: 2} = frame.instr
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

  test "sink_export: a default-argument head is no frame beside the arity it calls" do
    # tag/0 reaches the sink only through tag/1, from the same def line:
    # its frame would repeat tag/1's and take one of the three frames.
    assert [finding] = findings([Fixtures.DefaultArgSinkCaller], :unsafe_input)
    assert finding.mfa == {Fixtures.DefaultArgSinkCaller, :to_tag, 1}

    assert [frame] = finding.related
    assert frame.mfa == {Fixtures.DefaultArgSinkCaller, :tag, 1}
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

  test "cleanup_site: every cleanup a supervisor shutdown skips, on one finding" do
    alias Fixtures.Shutdown.ReleasesAndWrites

    assert [finding] =
             [ReleasesAndWrites]
             |> findings(:shutdown)
             |> Enum.filter(&(&1.title =~ "Cleanup in terminate/2"))

    labels = finding.related |> Enum.map(& &1.label) |> Enum.sort()
    assert [write, insert] = labels |> Enum.sort_by(&(&1 =~ "insert"))
    assert write =~ "File.write!"
    assert insert =~ ":ets.insert"
    refute Enum.any?(labels, &(&1 =~ "demonitor" or &1 =~ "close"))

    assert Enum.all?(finding.related, fn frame ->
             frame.module == ReleasesAndWrites and
               match?(%InstrId{func: "terminate", arity: 2}, frame.instr)
           end)
  end
end
