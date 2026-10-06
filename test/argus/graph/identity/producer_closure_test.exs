defmodule Argus.Graph.Identity.ProducerClosureTest do
  @moduledoc """
  A producer's rows are kept in each module's pack under the digest of
  the code it runs (`Argus.Graph.Code.closure/1`): every module it
  executes must be in its closure, or an edit to that module would leave
  stale rows in place. The closures are read from import tables; this
  runs each producer with call counting on and checks the reading
  against what executed, over a spread of the fixtures
  (`Argus.Test.FixtureSpread.spread/0`): a module a producer executes
  only for a fixture outside it goes unchecked. The producers are split
  three ways, each part in a VM of its own, so the parts run side by
  side.

  The base runs afresh, keeping the bases (`Argus.Pipeline.Base`), and
  each extractor runs over them, within its closure and without the
  emitter — a kept base holds the decoded facts, read back for the
  extractors that read them (`Argus.Pipeline.typed_readers/0`), and one
  missing from that list computes them again. An extractor run afresh is
  not counted apart: it is handed the data it is handed over a kept base
  (`Argus.Pipeline.BaseTest`), so it runs the code it runs there, beside
  the base's own, which is in every closure (`Argus.Pipeline` roots each
  one) and is counted in the base's run. (A register walk answered from
  the reaching solutions the fresh base solved, and over a kept base
  solved again, runs `Argus.Instr.Reaching`: the base's code too.)

  The closures leave the schema's modules out: a producer executes
  those outside its code key, and is keyed on the entries it read of
  them instead — which every export records
  (`Argus.Graph.Identity.SchemaReadsTest`).
  """
  use ExUnit.Case,
    async: true,
    parameterize: for(part <- 0..2, do: %{part: part, parts: 3})

  use Argus.Test.Peer

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  alias Argus.Graph.Code
  alias Argus.Graph.Reads
  alias Argus.Test.CallCount
  alias Argus.Test.Peer

  test "every module a producer executes is in its closure", %{part: part, parts: parts} do
    beams = Argus.Test.FixtureSpread.beams(Argus.Test.FixtureSpread.spread())

    producers =
      for {producer, i} <- Enum.with_index(Argus.Graph.Extraction.producers()),
          rem(i, parts) == part,
          do: producer

    # Call counts are VM-wide, and this VM runs other tests beside this.
    peer = Peer.start!(code_path: :this)

    executed =
      Peer.run(peer, fn ->
        {:ok, _} = Application.ensure_all_started(:argus_beam)
        executed(beams, producers)
      end)

    for producer <- producers do
      {:ok, closure} = Code.closure(producer)
      closure = MapSet.new(closure, &elem(&1, 0))
      ran = Map.fetch!(executed, producer)

      assert ran != [], "#{inspect(producer)} executed nothing"

      outside = Enum.reject(ran, &(MapSet.member?(closure, &1) or Reads.schema_module?(&1)))
      assert outside == [], "#{inspect(producer)} runs code its key does not cover"

      refute producer != :base and Argus.Pipeline.Emit in ran,
             "#{inspect(producer)} computes the decoded facts over a kept base: " <>
               "add it to Argus.Pipeline's @typed_readers"
    end
  end

  # Runs in the peer: the modules each producer executes, the base
  # afresh and each extractor over the bases it kept, uncounted.
  defp executed(beams, producers) do
    bases = Map.new(beams, &{&1, extract!(&1, producers: [:base], keep_base: true).base})

    CallCount.counting(fn ->
      Map.new(producers, fn producer ->
        opts = fn
          _beam when producer == :base -> [keep_base: true]
          beam -> [base: bases[beam]]
        end

        {_, calls} =
          CallCount.calls(fn ->
            for beam <- beams,
                do:
                  extract!(beam, [producers: [producer], trace_imprecision: true] ++ opts.(beam))
          end)

        {producer, CallCount.modules(calls)}
      end)
    end)
  end

  defp extract!(beam, opts) do
    {:ok, %{status: :ok} = extraction} = Argus.Pipeline.extract_module(beam, opts)
    extraction
  end
end
