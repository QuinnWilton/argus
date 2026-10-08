defmodule Argus.Test.ReportShapes do
  @moduledoc """
  Placed findings of every shape the renderer refines, over the sources
  in `test/argus/report/sources`: a line the source moves to a token
  (`at_source`), spans the source closes (`to_block` for a guard, a
  receive, a clause, a whole function) and one the bytecode closed
  (`end_line`), `{guard}` in the prose, related frames in the same file
  and in another, a frame on the finding's own span, frames and a
  finding outside the program, a file the config ignores, a severity the
  config overrides, a heuristic finding with its confidence, a finding
  in a file that is not source, and two findings a sort cannot tell
  apart. `Argus.Report.ShapesTest` pins what every renderer makes of
  them.
  """

  import ExUnit.Assertions

  @root Path.expand("../argus/report/sources", __DIR__)

  @doc "The directory the findings' paths are relative to."
  @spec root() :: Path.t()
  def root, do: @root

  @doc "The configuration the findings are rendered under."
  @spec config() :: keyword()
  def config do
    [
      analyses: [:coupling, :mailbox, :ets, :startup, :effects],
      severity: [ets: :error],
      ignore: [files: ["src/ignored/**"]]
    ]
  end

  @doc "The notices of the run, one of each kind."
  @spec notices() :: [Argus.Driver.Result.notice()]
  def notices do
    [
      :engine_unavailable,
      {:extraction_error,
       %{module: Shapes.Lost, name: "Shapes.Lost", step: "module", reason: "bad chunk"}},
      {:extraction_error,
       %{module: Shapes.Worker, name: "Shapes.Worker", step: "pipeline", reason: "timeout"}},
      {:extraction_error,
       %{
         module: Shapes.Other,
         name: "Shapes.Other",
         step: "Argus.Extractors.ETS",
         reason: "badarg"
       }},
      {:duplicate,
       %{
         module: Shapes.Worker,
         used: Path.join(@root, "_build/a/ebin/Elixir.Shapes.Worker.beam"),
         shadowed: [Path.join(@root, "_build/b/ebin/Elixir.Shapes.Worker.beam")]
       }}
    ]
  end

  @doc "Each analysis's placed findings, one analysis degraded."
  @spec located() :: %{atom() => {:ok, [Argus.Located.t()]} | {:error, term()}}
  def located do
    shapes = file("src/shapes.ex")
    other = file("src/other.ex")

    %{
      coupling: {:ok, [coupled(shapes, other), outside(other)]},
      mailbox: {:ok, [guarded(shapes), receiving(shapes), clauses(shapes), catching(shapes)]},
      ets: {:ok, [schema(shapes), ignored(), twin(shapes, "first"), twin(shapes, "second")]},
      startup: {:ok, [heuristic(other), not_source()]},
      effects: {:error, :flowlog_timeout}
    }
  end

  defp file(relative), do: Path.join(@root, relative)

  defp finding(analysis, severity, title, attrs) do
    Map.merge(
      %{
        analysis: analysis,
        concern: analysis,
        severity: severity,
        title: title,
        detail: "#{title}: the detail.",
        module: nil,
        mfa: nil,
        instr: nil,
        at_label: nil,
        at_source: nil,
        to_instr: nil,
        to_block: nil,
        help: [],
        related: [],
        provenance: :structural,
        confidence: nil
      },
      attrs
    )
  end

  defp frame(label, attrs \\ %{}),
    do: Map.merge(%{label: label, at_source: nil, to_block: nil}, attrs)

  defp place(file, line, end_line \\ nil), do: %{file: file, line: line, end_line: end_line}

  defp located(finding, file, line, end_line, related) do
    %Argus.Located{finding: finding, file: file, line: line, end_line: end_line, related: related}
  end

  # The primary anchor with a frame on its own span, one in the same
  # file, one in another, and one outside the program.
  defp coupled(shapes, other) do
    finding(:coupling, :warning, "Coupled children under one_for_one", %{
      at_label: "supervision tree defined here",
      help: ["put the pair under `rest_for_one`", "or monitor the sibling"],
      related: [
        frame("the same call"),
        frame("kept here"),
        frame("registers with the sibling here"),
        frame("outside")
      ]
    })
    |> located(shapes, 13, nil, [
      place(shapes, 13),
      place(shapes, 33),
      place(other, 4),
      Argus.Located.nowhere()
    ])
  end

  defp outside(other) do
    finding(:coupling, :warning, "Placed outside the program", %{related: [frame("f")]})
    |> located(nil, nil, nil, [place(other, 8)])
  end

  # `{guard}` filled from the source, the span closed at the guard's end.
  defp guarded(shapes) do
    finding(:mailbox, :warning, "A call whose {guard} swallows the exit", %{
      at_label: "the {guard} guards this call",
      detail: "The {guard} clause takes every exit.",
      help: ["narrow the {guard}"],
      to_block: :guard,
      related: [frame("the {guard} here", %{to_block: :guard})]
    })
    |> located(shapes, 13, nil, [place(shapes, 44)])
  end

  defp receiving(shapes) do
    finding(:mailbox, :info, "A receive with no timeout", %{
      at_label: "waits here",
      to_block: :receive
    })
    |> located(shapes, 22, nil, [])
  end

  defp clauses(shapes) do
    finding(:mailbox, :warning, "Every clause of the callback", %{
      at_label: "handled here",
      to_block: :function,
      related: [frame("one clause", %{to_block: :clause})]
    })
    |> located(shapes, 31, nil, [place(shapes, 37)])
  end

  # The bytecode closed this span itself.
  defp catching(shapes) do
    finding(:mailbox, :warning, "A span the bytecode closed", %{at_label: "from here"})
    |> located(shapes, 43, 46, [])
  end

  # The line moves to the whole token the finding names.
  defp schema(shapes) do
    finding(:ets, :warning, "A field the schema names", %{
      at_label: "the field",
      at_source: ":api_key",
      related: [frame("its twin", %{at_source: ":api_key_count"})]
    })
    |> located(shapes, 6, nil, [place(shapes, 6)])
  end

  defp ignored do
    finding(:ets, :warning, "In an ignored file", %{})
    |> located(file("src/ignored/gen.ex"), 3, nil, [])
  end

  # Two findings no sort key tells apart: the analysis's order stands.
  defp twin(shapes, which) do
    finding(:ets, :info, "Twins", %{at_label: which})
    |> located(shapes, 42, nil, [])
  end

  defp heuristic(other) do
    finding(:startup, :info, "A prior says this may block", %{
      provenance: :heuristic,
      confidence: 830
    })
    |> located(other, 8, nil, [])
  end

  # A beam path, the anchor when no source was recorded: the frame's
  # header, no excerpt.
  defp not_source do
    finding(:startup, :error, "Anchored at a beam", %{at_label: "here"})
    |> located(file("_build/a/ebin/Elixir.Shapes.Lost.beam"), 1, nil, [])
  end

  @doc """
  Compiler diagnostics as an editor gets them, one after another: the
  severity, the file (as `show` spells it) and position, the message,
  then the plain frame.
  """
  @spec render_diagnostics([Mix.Task.Compiler.Diagnostic.t()], (String.t() -> String.t())) ::
          String.t()
  def render_diagnostics(diagnostics, show) do
    Enum.map_join(diagnostics, "\n", fn diagnostic ->
      "#{diagnostic.severity} #{show.(diagnostic.file)}:#{inspect(diagnostic.position)} " <>
        "#{diagnostic.message}\n" <> (diagnostic.details || "") <> "\n"
    end)
  end

  @finding_keys ~w(analysis severity file line end_line title at_label detail help provenance confidence related)
  @frame_keys ~w(label file line end_line)

  @doc """
  Asserts every object of the JSON report has its keys in the schema's
  order (`Argus.Report.Json`), read as written rather than decoded into
  maps.
  """
  @spec assert_key_order!(String.t()) :: :ok
  def assert_key_order!(json) do
    ordered = %{
      object_push: fn key, value, acc -> [{key, value} | acc] end,
      object_finish: fn acc, old -> {{:object, Enum.reverse(acc)}, old} end
    }

    {findings, :ok, ""} = :json.decode(String.trim_trailing(json), :ok, ordered)

    for {:object, pairs} <- findings do
      assert Enum.map(pairs, &elem(&1, 0)) == @finding_keys
      {"related", frames} = List.keyfind(pairs, "related", 0)
      for {:object, frame} <- frames, do: assert(Enum.map(frame, &elem(&1, 0)) == @frame_keys)
    end

    :ok
  end
end
