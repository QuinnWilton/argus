defmodule Argus.Report.PentimentLabelsTest do
  @moduledoc """
  Labels on one span of one file render as one label: a call cycle's
  anchor and the frame for the edge it starts sit on the same call.
  """

  use ExUnit.Case, async: true

  alias Argus.Report.{Entry, Pentiment}

  @moduletag :tmp_dir

  @source """
  defmodule A do
    def handle_call(:ask_b, _from, state) do
      result = GenServer.call(B, :ping)
      {:reply, result, state}
    end

    def handle_call(:ask_a, _from, state) do
      result = GenServer.call(A, :ping)
      {:reply, result, state}
    end
  end
  """

  setup %{tmp_dir: dir} do
    file = Path.join(dir, "a.ex")
    File.write!(file, @source)
    %{path: file, dir: dir}
  end

  defp entry(file, related) do
    %Entry{
      file: file,
      line: 3,
      end_line: nil,
      severity: :error,
      analysis: :blocking,
      title: "Synchronous call cycle",
      detail: "A and B synchronously call each other.",
      at_label: "one direction of the cycle",
      help: [],
      related: related,
      provenance: :structural,
      confidence: nil
    }
  end

  defp details(file, dir, related),
    do: Pentiment.format(entry(file, related), dir)

  test "a frame on the primary's span joins the primary label", %{path: file, dir: dir} do
    details =
      details(file, dir, [
        %{label: "cycle edge A → B", file: file, line: 3, end_line: nil},
        %{label: "return path", file: file, line: 8, end_line: nil},
        %{label: "cycle edge B → A", file: file, line: 8, end_line: nil}
      ])

    # One underline per call, each with one tail carrying both messages.
    assert length(Regex.scan(~r/─┬─/, details)) == 2
    assert details =~ "╰── one direction of the cycle; cycle edge A → B"
    assert details =~ "╰── return path; cycle edge B → A"
  end

  test "frames on different spans stay separate labels", %{path: file, dir: dir} do
    details = details(file, dir, [%{label: "return path", file: file, line: 8, end_line: nil}])

    assert details =~ "╰── one direction of the cycle\n"
    assert details =~ "╰── return path\n"
  end

  test "a frame on an unlabelled primary gives the primary its message", %{path: file, dir: dir} do
    details =
      Pentiment.format(
        %{
          entry(file, [%{label: "the edge", file: file, line: 3, end_line: nil}])
          | at_label: nil
        },
        dir
      )

    assert length(Regex.scan(~r/─┬─/, details)) == 1
    assert details =~ "╰── the edge"
  end
end
