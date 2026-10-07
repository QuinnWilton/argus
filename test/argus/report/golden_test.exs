defmodule Argus.Report.GoldenTest do
  @moduledoc """
  What every frontend prints, pinned byte for byte over the depot fixture
  with every analysis on: the text report (frames and summary) of `mix
  argus`, its JSON, and the compiler's diagnostics (message, place and
  the plain frame in `details`); and `Argus.run_analyses/2` on the
  query graph, whose findings are the JSON's entries. `Argus.Report.ShapesTest` pins every
  shape a finding can take the same way.

  The goldens were recorded from scry's renderer before it moved into
  `Argus.Report`, with only the code prefix changed (`scry.` to
  `argus.`): the move is pinned to change nothing else. The JSON is
  compared decoded: scry wrote an object's keys in the order the VM's
  atom table held them, which no two VMs need share, and argus writes
  them in the schema's order (`Argus.Report.Json`). After a change to a
  finding's prose or to the renderer on purpose, record them again
  (`ARGUS_RECORD_GOLDENS=1 mix test test/argus/report/golden_test.exs
  --include project`) and read the diff.

  In this module's peer (`Argus.Test.Peer`): the Mix project stack, the
  working directory and ANSI are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO

  alias Argus.Test.{Fixture, Peer, ReportShapes}

  @moduletag timeout: 300_000
  @moduletag :flowlog

  @goldens Path.expand("depot", __DIR__)

  setup_all do
    peer = Peer.start!()
    copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "argus_golden_depot"), [], :depot)

    outputs =
      Fixture.in_peer(peer, copy, :depot, fn _log ->
        # Frames without color, whatever the terminal: the goldens are
        # the plain text a pipe gets.
        Application.put_env(:elixir, :ansi_enabled, false)
        {_status, diagnostics} = Fixture.compile!()

        text = capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["--all"]) end)
        json = capture_io(fn -> Mix.Task.rerun("argus", ["--all", "--format", "json"]) end)

        # The same program through the API, on the query graph: its
        # findings are what the report's entries say, place and prose.
        beams = Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam"))

        {:ok, found} =
          Argus.run_analyses(beams, analyses: Argus.Config.all_analyses())

        %{
          text: text,
          json: json,
          diagnostics: render(diagnostics),
          api: as_entries(found.findings, File.cwd!())
        }
      end)

    %{outputs: outputs}
  end

  # The findings as `Argus.Report.Json` writes entries, decoded: those
  # with a place in the program, each frame outside it left out.
  defp as_entries(findings, cwd) do
    for %{file: file} = finding <- findings, file != nil do
      %{
        "analysis" => Atom.to_string(finding.analysis),
        "severity" => Atom.to_string(finding.severity),
        "file" => Argus.Report.relative(file, cwd),
        "line" => finding.line,
        "end_line" => finding.end_line,
        "title" => finding.title,
        "at_label" => finding.at_label,
        "detail" => finding.detail,
        "help" => finding.help,
        "provenance" => Atom.to_string(finding.provenance),
        "confidence" => finding.confidence,
        "related" =>
          for %{file: file} = frame <- finding.related, file != nil do
            %{
              "label" => frame.label,
              "file" => Argus.Report.relative(file, cwd),
              "line" => frame.line,
              "end_line" => frame.end_line
            }
          end
      }
    end
  end

  defp render(diagnostics) do
    diagnostics
    |> Enum.filter(&(&1.compiler_name == "argus"))
    |> ReportShapes.render_diagnostics(&Path.basename/1)
  end

  test "the text report is byte-identical to its golden", %{outputs: outputs} do
    check!("report.txt", outputs.text, & &1)
  end

  test "the compiler's diagnostics are byte-identical to their golden", %{outputs: outputs} do
    check!("diagnostics.txt", outputs.diagnostics, & &1)
  end

  test "the JSON is its golden's, its keys in the schema's order", %{outputs: outputs} do
    check!("findings.json", outputs.json, &JSON.decode!/1)
    ReportShapes.assert_key_order!(outputs.json)
  end

  test "run_analyses on the graph finds what the JSON reports", %{outputs: outputs} do
    assert Enum.sort(outputs.api) == outputs.json |> JSON.decode!() |> Enum.sort()
  end

  defp check!(file, actual, read) do
    path = Path.join(@goldens, file)

    if System.get_env("ARGUS_RECORD_GOLDENS") == "1" do
      File.mkdir_p!(@goldens)
      File.write!(path, actual)
    else
      assert read.(actual) == read.(File.read!(path))
    end
  end
end
