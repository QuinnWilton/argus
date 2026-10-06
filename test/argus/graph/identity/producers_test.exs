defmodule Argus.Graph.Identity.ProducersTest do
  @moduledoc """
  Each producer's rows are its own: extracting one producer of a module
  alone, over the module's kept base (`Argus.Pipeline.Base`), gives the
  rows it gives beside every other producer over a base computed
  afresh. That is what lets the query graph keep each producer's rows
  apart in a module's pack and, after an extractor edit, run that
  extractor alone over the kept base (`Argus.Graph.Pack`).

  One run checks both halves. Alone and afresh, a producer is handed the
  data it is handed alone over the kept base (`Argus.Pipeline.BaseTest`),
  so it gives these rows there too. The modules are a spread of the
  fixtures (`Argus.Test.FixtureSpread.spread/0`).
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline
  alias Argus.Test.FixtureSpread

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  defp extract!(beam, producers, opts) do
    opts = [producers: producers, trace_imprecision: true] ++ opts
    assert {:ok, %{status: :ok} = extraction} = Pipeline.extract_module(beam, opts)
    extraction
  end

  test "a producer extracted alone over a kept base gives the rows it gives beside the others" do
    producers = Argus.Graph.Extraction.producers()

    wrote =
      FixtureSpread.beams(FixtureSpread.spread())
      |> Task.async_stream(
        fn beam ->
          together = extract!(beam, producers, keep_base: true)
          assert is_binary(together.base)

          for producer <- producers do
            # The base's own rows are the emitter's: it never runs over a
            # kept base, and computes its own.
            opts = if producer == :base, do: [], else: [base: together.base]
            alone = extract!(beam, [producer], opts)

            assert alone.facts[producer] == together.facts[producer],
                   "#{inspect(producer)} on #{Path.basename(beam, ".beam")} alone differs " <>
                     "from its rows among the others"
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
