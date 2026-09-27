defmodule Argus.Graph.Identity.ProducersTest do
  @moduledoc """
  Each producer's rows are its own: extracting one producer of a module
  alone gives the rows it gives beside every other producer, and over
  the module's kept base (`Argus.Pipeline.Base`) the rows it gives over
  a base computed afresh. That is what lets the query graph keep each
  producer's rows apart in a module's pack and, after an extractor
  edit, run that extractor alone over the kept base
  (`Argus.Graph.Pack`).
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000
  @moduletag timeout: 600_000

  # A spread of the fixtures, the ones a few extractors need (named, so
  # that a fixture added elsewhere cannot move them out of the spread),
  # and some runtime modules for shapes the fixtures do not have: every
  # extractor emits rows for some of them (the test checks). The spread
  # is one in twenty by a portable hash of the name, so adding a fixture
  # does not move the others in or out.
  @modules for(
             mod <- Application.spec(:argus_beam, :modules),
             String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Test.Fixtures."),
             :erlang.phash2(mod, 20) == 0,
             do: mod
           )
           |> Enum.sort()
           |> Kernel.++([
             Argus.Test.Fixtures.SimpleStatem,
             Argus.Test.Fixtures.Specs,
             Argus.Test.Fixtures.Router,
             Argus.Test.Fixtures.Secret.Typed,
             Argus.Test.Fixtures.Tls.ForcesNone,
             Argus.Test.Fixtures.DerivedInspect.OneField,
             Inspect.Argus.Test.Fixtures.DerivedInspect.OneField,
             Mix.ArgusFixtures.Seed,
             Logger.Formatter,
             URI,
             :gen_server,
             :supervisor
           ])

  # A Phoenix endpoint's socket table, which no fixture compiles (the
  # Endpoint extractor reads it).
  setup_all do
    [{_mod, endpoint}] =
      Code.compile_string("""
      defmodule Argus.Graph.Identity.ProducersTest.Endpoint do
        def __sockets__, do: [{"/live", Phoenix.LiveView.Socket, [websocket: [], longpoll: []]}]
      end
      """)

    %{modules: @modules ++ [endpoint]}
  end

  defp producers, do: Argus.Graph.Extraction.producers()

  defp extract!(module, producers, opts) do
    opts = [producers: producers, trace_imprecision: true] ++ opts
    assert {:ok, %{status: :ok} = extraction} = Pipeline.extract_module(module, opts)
    extraction
  end

  test "a producer extracted alone gives the rows it gives beside the others, over a kept base too",
       %{modules: modules} do
    producers = producers()

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
