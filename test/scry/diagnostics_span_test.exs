defmodule Scry.DiagnosticsSpanTest do
  @moduledoc """
  A finding or frame with an end line brackets the lines between; one
  without underlines its line.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @source """
  defmodule Guarded do
    def checkout(pid) do
      :gen_statem.call(pid, :checkout, 5_000)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end

    def bare(pid), do: :gen_statem.call(pid, :cleanup, 5_000)
  end
  """

  setup %{tmp_dir: dir} do
    file = Path.join(dir, "guarded.ex")
    File.write!(file, @source)
    %{path: file, dir: dir}
  end

  test "the span is a bracket from the anchor to the end line", %{path: file, dir: dir} do
    entry = %{
      file: file,
      line: 8,
      end_line: nil,
      severity: :info,
      code: "failure",
      title: "call/3 called bare where every other call site guards it",
      detail: "Guarded:bare/1 calls :gen_statem.call/3 outside a try.",
      at_label: "the one site that disagrees",
      help: [],
      related: [
        %{label: "guarded by this catch", file: file, line: 3, end_line: 5}
      ],
      provenance: :structural,
      confidence: nil
    }

    [%{diagnostic: d}] = Scry.Diagnostics.build(%{file => [entry]}, Scry.Config.load([]), dir)

    assert d.details =~ "╰── guarded by this catch"
    assert d.details =~ "the one site that disagrees"
    # Bracketed lines carry the bar; the tail sits under the last of them.
    assert d.details =~
             ~r/4 │ │   catch\n 5 │ │     :exit, \{:timeout, _\} -> \{:error, :timeout\}\n   • ╰── guarded/

    # The bracket covers the catch clause, which a one-line frame never showed.
    assert d.details =~ ":exit, {:timeout, _}"
  end

  test "without an end line, or one no later than the start, the label is inline", %{
    path: file,
    dir: dir
  } do
    entry = %{
      file: file,
      line: 3,
      end_line: 3,
      severity: :warning,
      code: "blocking",
      title: "T",
      detail: "D.",
      at_label: "the call",
      help: [],
      related: [],
      provenance: :structural,
      confidence: nil
    }

    [%{diagnostic: d}] = Scry.Diagnostics.build(%{file => [entry]}, Scry.Config.load([]), dir)
    refute d.details =~ "│ │"
    assert d.details =~ "╰── the call"
  end
end
