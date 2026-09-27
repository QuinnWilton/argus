defmodule Argus.LocatedTest do
  @moduledoc """
  The source's last step on a placed finding (`Argus.Located.refine/1`),
  which every frontend's report and `Argus.run_analyses/2` share:
  `{guard}` filled with the keyword the source shows, the span closed
  at the guard's end, and a finding outside the program left as the
  bytecode placed it. `Argus.Report.ShapesTest` pins every shape as the
  renderers show it.
  """

  use ExUnit.Case, async: true

  alias Argus.Located
  alias Argus.Test.ReportShapes

  defp shape(analysis, title) do
    {:ok, placed} = Map.fetch!(ReportShapes.located(), analysis)
    Enum.find(placed, &(&1.finding.title == title))
  end

  test "a guard's prose names its keyword, and its span closes at the guard's end" do
    located = shape(:mailbox, "A call whose {guard} swallows the exit")
    refined = Located.refine(located)

    assert refined.finding.title == "A call whose rescue swallows the exit"
    assert refined.finding.at_label == "the rescue guards this call"
    assert refined.finding.detail == "The rescue clause takes every exit."
    assert refined.finding.help == ["narrow the rescue"]
    # The frame sits in another guard, a `catch`: its own keyword.
    assert [%{label: "the catch here"}] = refined.finding.related
    assert refined.end_line != nil and refined.end_line > refined.line
    assert [%{end_line: frame_end}] = refined.related
    assert frame_end != nil

    # Written into the finding as `Argus.run_analyses/2` returns it.
    finding = Located.to_finding(refined)
    assert finding.line == refined.line and finding.end_line == refined.end_line
  end

  test "a finding outside the program keeps the bytecode's place" do
    located = shape(:coupling, "Placed outside the program")
    refined = Located.refine(located)

    assert refined.file == nil and refined.line == located.line
    assert refined.finding == located.finding
    # Its frame in the program is refined all the same.
    assert [%{file: file}] = refined.related
    assert file != nil
  end
end
