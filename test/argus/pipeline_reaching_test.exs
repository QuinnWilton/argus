defmodule Argus.PipelineReachingTest do
  @moduledoc """
  The pipeline computes reaching definitions once per module, with the
  parameters as sources, and derives def_use from them. The parameter
  pseudo-definitions must not change which instructions' writes reach a
  read: def_use is what `Dataflow.def_use_edges/1` says it is.
  """
  use ExUnit.Case, async: true

  alias Argus.Dataflow
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
  alias Argus.Pipeline.Disassemble

  @modules [
    Argus.Test.Fixtures.CheckThenAct.WhereisThenStart,
    Argus.Test.Fixtures.CheckThenAct.PublicCache,
    Argus.Test.Fixtures.ParamFlow.Shapes
  ]

  defp data(module) do
    {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(module)))
    data
  end

  test "def_use is the instruction-to-instruction part of the shared set" do
    {:ok, facts} = Argus.Pipeline.extract(@modules, extractors: [])

    expected =
      for module <- @modules,
          {d, u} <- Dataflow.def_use_edges(Helpers.typed(data(module))),
          into: MapSet.new(),
          do: [InstrId.format(d), InstrId.format(u)]

    assert MapSet.new(facts.def_use) == expected
    assert MapSet.size(expected) > 20
  end

  test "reaching/1 takes what the pipeline attached, even when it is nil" do
    assert Helpers.reaching(%{reaching: nil, typed: %{}}) == nil
    assert Helpers.reaching(%{reaching: MapSet.new([:x])}) == MapSet.new([:x])
  end

  test "reaching/1 computes the set for bare disassembly" do
    data = data(Argus.Test.Fixtures.ParamFlow.Shapes)

    assert Helpers.reaching(data) ==
             Dataflow.reaching_uses(Helpers.typed(data), params: true)
  end
end
