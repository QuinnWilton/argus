defmodule Argus.Report.ShapesTest do
  @moduledoc """
  Every shape of a placed finding (`Argus.Test.ReportShapes`) through
  every renderer, pinned against goldens recorded from scry's renderer
  before it moved into `Argus.Report` (the code prefix changed from
  `scry.` to `argus.`, nothing else): the text frames and summary, the
  compiler's diagnostics, the JSON (compared decoded, and its keys in the
  schema's order: see `Argus.Report.GoldenTest`) and the notices.

  After a change to the renderer on purpose, record them again
  (`ARGUS_RECORD_GOLDENS=1 mix test test/argus/report/shapes_test.exs`)
  and read the diff.
  """

  use ExUnit.Case, async: true

  alias Argus.Report
  alias Argus.Test.ReportShapes

  @goldens Path.expand("shapes", __DIR__)

  setup_all do
    cwd = ReportShapes.root()
    config = Argus.Config.load(ReportShapes.config())

    result = %Argus.Driver.Result{
      located: ReportShapes.located(),
      notices: ReportShapes.notices(),
      changed?: true
    }

    %{
      cwd: cwd,
      config: config,
      result: result,
      entries: Report.build(result.located, config, cwd)
    }
  end

  test "the text frames and summary", %{entries: entries, cwd: cwd} do
    check!("report.txt", Report.Text.format(entries, [], cwd, color: :never), & &1)
  end

  test "the compiler's diagnostics", %{entries: entries, cwd: cwd} do
    diagnostics =
      entries
      |> Argus.Mix.Diagnostics.build(cwd)
      |> Enum.map(& &1.diagnostic)
      |> ReportShapes.render_diagnostics(&Path.relative_to(&1, cwd))

    check!("diagnostics.txt", diagnostics, & &1)
  end

  test "the JSON", %{entries: entries, cwd: cwd} do
    json = Report.Json.encode(entries, cwd) <> "\n"
    check!("findings.json", json, &JSON.decode!/1)
    ReportShapes.assert_key_order!(json)
  end

  test "the notices, in one wording", %{result: result, config: config, cwd: cwd} do
    notices = Report.Notice.from_result(result, config, cwd)

    assert [%{kind: :engine_unavailable, severity: :info}, %{kind: :degraded} | rest] = notices

    assert Enum.map(rest, & &1.kind) ==
             [:extraction_error, :extraction_error, :extraction_error, :duplicate]

    # Every notice but the solver's is scry's wording.
    golden =
      @goldens |> Path.join("notices.txt") |> File.read!() |> String.split("\n", trim: true)

    assert Enum.sort(Enum.map(tl(notices), & &1.message)) == Enum.sort(golden)
  end

  test "a finding or frame outside the program, or in an ignored file, is left out", %{
    entries: entries
  } do
    titles = Enum.map(entries, & &1.title)
    refute "Placed outside the program" in titles
    refute "In an ignored file" in titles

    [coupled] = Enum.filter(entries, &(&1.analysis == :coupling))
    refute Enum.any?(coupled.related, &(&1.label == "outside"))
  end

  defp check!(file, actual, read) do
    path = Path.join(@goldens, file)

    if System.get_env("ARGUS_RECORD_GOLDENS") == "1" do
      File.write!(path, actual)
    else
      assert read.(actual) == read.(File.read!(path))
    end
  end
end
