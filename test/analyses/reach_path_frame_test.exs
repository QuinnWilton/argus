defmodule Argus.Analyses.ReachPathFrameTest do
  use ExUnit.Case, async: true

  alias Argus.Lines
  alias Argus.Souffle
  alias Argus.Test.Fixtures.ReachPath

  @source Path.expand("../fixtures/reach_path_fixture.ex", __DIR__)

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # The line of the fixture's own source that holds `text`, found by the
  # text so the fixture can move freely.
  defp line_of(text) do
    @source
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end

  defp findings(modules, analysis) do
    assert {:ok, %{findings: findings}} = Argus.run_analyses(modules, analyses: [analysis])
    findings
  end

  defp frame_line(modules, frame) do
    {:ok, facts} = Argus.Pipeline.extract(modules)
    Lines.resolve(Lines.from_facts(facts), frame.instr)
  end

  defp frame(finding, label) do
    Enum.find(finding.related, &(&1.label == label)) ||
      flunk("no #{inspect(label)} frame in #{inspect(finding.related)}")
  end

  test "a lock in a helper: init/1's frame is the call that starts the path" do
    skip_without_souffle()
    mods = [ReachPath.ClusterLock]

    [f] = Enum.filter(findings(mods, :startup), &(&1.title == "Cluster-wide lock during init"))
    frame = frame(f, "init/1 reaches it from here")

    assert frame.instr != nil, "the frame is init/1's head, not a call in it"
    assert frame_line(mods, frame) == line_of(":ok = lock(name)")
  end

  test "of two calls that both reach the lock, the frame is the earlier" do
    skip_without_souffle()
    mods = [ReachPath.TwoPaths]

    [f] = Enum.filter(findings(mods, :startup), &(&1.title == "Cluster-wide lock during init"))
    frame = frame(f, "init/1 reaches it from here")

    assert frame_line(mods, frame) == line_of(":ok = prepare(name)")
  end

  test "a receive in a helper: the init/1 frame is the call that reaches it" do
    skip_without_souffle()
    mods = [ReachPath.WaitsInInit]

    reached_from = fn f ->
      Enum.find(f.related, &String.starts_with?(&1.label, "reached from"))
    end

    [f] = Enum.filter(findings(mods, :startup), reached_from)
    frame = reached_from.(f)

    assert frame.instr != nil, "the frame is init/1's head, not a call in it"
    assert frame_line(mods, frame) == line_of(":ok = await_ready()")
  end

  test "a sibling called from a helper: terminate/2's frame is the call to the helper" do
    skip_without_souffle()
    mods = [ReachPath.Tree, ReachPath.Writer, ReachPath.Directory]

    [f] =
      Enum.filter(
        findings(mods, :shutdown),
        &(&1.title == "terminate/2 calls a sibling that may already be down")
      )

    frame = frame(f, "terminate/2 reaches it from here")
    assert frame_line(mods, frame) == line_of("      unregister()")
  end

  test "a sibling called in a closure written inside terminate/2 gets no head frame" do
    skip_without_souffle()
    mods = [ReachPath.EachTree, ReachPath.EachWriter, ReachPath.Directory]

    [f] =
      Enum.filter(
        findings(mods, :shutdown),
        &(&1.title == "terminate/2 calls a sibling that may already be down")
      )

    refute Enum.any?(f.related, &(&1.label == "terminate/2 reaches it from here")),
           "the anchor is already inside terminate/2's source: #{inspect(f.related)}"
  end
end
