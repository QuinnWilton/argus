defmodule Argus.Graph.Identity.ProducersTest do
  @moduledoc """
  Each producer's rows are its own: extracting one producer of a module
  alone gives the rows it gives beside every other producer, and over
  the module's kept base (`Argus.Pipeline.Base`) the rows it gives over
  a base computed afresh. That is what lets the query graph keep each
  producer's rows apart in a module's pack and, after an extractor
  edit, run that extractor alone over the kept base
  (`Argus.Graph.Pack`). The modules are a spread of the fixtures
  (`Argus.Test.FixtureSpread.spread/0`).
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  defp producers, do: Argus.Graph.Extraction.producers()

  defp extract!(module, producers, opts) do
    opts = [producers: producers, trace_imprecision: true] ++ opts
    assert {:ok, %{status: :ok} = extraction} = Pipeline.extract_module(module, opts)
    extraction
  end

  test "a producer extracted alone gives the rows it gives beside the others, over a kept base too" do
    producers = producers()
    modules = Argus.Test.FixtureSpread.spread()

    wrote =
      modules
      |> Task.async_stream(
        fn module ->
          together = extract!(module, producers, keep_base: true)
          assert is_binary(together.base)

          for producer <- producers do
            alone = extract!(module, [producer], [])

            assert alone.facts[producer] == together.facts[producer],
                   "#{inspect(producer)} on #{inspect(module)} alone differs from its rows among the others"

            # The base's own rows are the emitter's: it never runs over a
            # kept base, and computes its own.
            if producer != :base do
              over = extract!(module, [producer], base: together.base)

              assert over.facts[producer] == together.facts[producer],
                     "#{inspect(producer)} on #{inspect(module)} over a kept base differs"
            end
          end

          for {producer, facts} <- together.facts, facts != %{}, do: producer
        end,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, wrote} -> wrote end)
      |> MapSet.new()

    # Every producer is exercised: none of them wrote nothing.
    assert producers -- MapSet.to_list(wrote) == []
  end
end
