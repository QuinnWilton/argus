defmodule Argus.Graph.CodeTest do
  @moduledoc """
  A producer's rows are kept under the digest of the code it runs
  (`Argus.Graph.Code`'s `producer_code`). That the closures cover what
  each producer executes is `Argus.Graph.Identity.ProducerClosureTest`'s.
  """
  use ExUnit.Case, async: true

  alias Argus.Graph.Code
  alias Argus.Graph.Reads

  defp producers do
    {:ok, all} = Argus.Analysis.set(:all)

    extractors =
      Enum.flat_map(all ++ [:coverage], fn name ->
        {:ok, mod} = Argus.Analysis.fetch_module(name)
        mod.extractors()
      end)

    [:base | Enum.uniq([Argus.Extractors.CallArgs | extractors])]
  end

  test "an extractor's closure is its own code and the base's; the solver and stores are in none" do
    {:ok, base} = Code.closure(:base)
    {:ok, ets} = Code.closure(Argus.Extractors.ETS)
    base = Enum.map(base, &elem(&1, 0))
    ets = Enum.map(ets, &elem(&1, 0))

    assert Argus.Pipeline.Emit in base
    assert Argus.Instr in base
    assert Argus.Pipeline.Writer in base
    assert Argus.Tsv in base
    assert BeamSpy.BeamFile in base
    refute Argus.Extractors.ETS in base

    assert Argus.Extractors.ETS in ets
    assert base -- ets == []

    # What an extractor reaches beyond the base, through the others it
    # calls, is its own.
    {:ok, dependence} = Code.closure(Argus.Extractors.Dependence)
    dependence = Enum.map(dependence, &elem(&1, 0))
    assert Argus.Extractors.ETS in dependence and Argus.Extractors.TermFlow in dependence
    assert base -- dependence == []

    for producer <- producers(),
        {:ok, closure} = Code.closure(producer),
        mod <- [
          Argus.FlowLog,
          Argus.Analysis,
          Argus.Analysis.Sets,
          Argus.Analysis.Catalog,
          Argus.Findings,
          Argus.Corpus
        ] do
      refute List.keymember?(closure, mod, 0), "#{inspect(mod)} moves #{inspect(producer)}'s key"
    end

    assert Code.reads_installed?(Argus.Extractors.Specs)
    refute Code.reads_installed?(:base)
    refute Code.reads_installed?(Argus.Extractors.ETS)
  end

  test "the schema's modules are left out, and what they call is walked" do
    {:ok, base} = Code.closure(:base)
    base = Enum.map(base, &elem(&1, 0))

    refute Argus.Schema in base
    refute Enum.any?(base, &Reads.schema_module?/1)

    # Walked through: what records their reads is code, and in it.
    assert Argus.Schema.Reads in base
    refute Reads.schema_module?(Argus.Schema.Reads)
    assert Reads.schema_module?(Argus.Schema.Processes)

    {:ok, extractor} = Code.closure(Argus.Extractors.ETS)
    refute Enum.any?(extractor, fn {mod, _beam} -> Reads.schema_module?(mod) end)
  end

  test "a producer's roots are the pipeline's, and the extractor's own" do
    assert Code.producer_roots(:base) == [Argus.Pipeline]
    assert Code.producer_roots(Argus.Extractors.ETS) == [Argus.Pipeline, Argus.Extractors.ETS]
  end

  test "a producer compiled in memory has no closure, and may read specs" do
    [{mod, _bin}] =
      Elixir.Code.compile_string("""
      defmodule Argus.Graph.CodeTest.InMemory do
        def extract(_data), do: %{}
      end
      """)

    assert {:error, {:no_beam, ^mod}} = Code.closure(mod)
    assert Code.reads_installed?(mod)
  end
end
