defmodule Argus.Report.GoldenTest do
  @moduledoc """
  What every frontend prints, pinned byte for byte over the depot fixture
  with every analysis on: the text report (frames and summary) of `mix
  argus`, its JSON, and the compiler's diagnostics (message, place and
  the plain frame in `details`). `Argus.Report.ShapesTest` pins every
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
  @moduletag :souffle

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

        %{text: text, json: json, diagnostics: render(diagnostics)}
      end)

    %{outputs: outputs}
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
