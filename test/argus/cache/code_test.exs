defmodule Argus.Cache.CodeTest do
  @moduledoc """
  A producer's shard is keyed on the code it runs (`Argus.Cache.Code`).
  That the closures cover what each producer executes is
  `Argus.Cache.CodeClosureTest`'s.
  """
  use ExUnit.Case, async: true

  alias Argus.Cache.Code

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
    assert Argus.Extractors.ETS in dependence and Argus.Extractors.PidFlow in dependence
    assert base -- dependence == []

    for producer <- producers(),
        {:ok, closure} = Code.closure(producer),
        mod <- [
          Argus.Souffle,
          Argus.Souffle.Cache,
          Argus.Cache,
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

  test "schema: :recorded leaves the schema's modules out, and keys what they call" do
    {:ok, included} = Code.closure(:base)
    {:ok, recorded} = Code.closure(:base, schema: :recorded)
    included = Enum.map(included, &elem(&1, 0))
    recorded = Enum.map(recorded, &elem(&1, 0))

    # The concern modules are read at Argus.Schema's compile time: their
    # relations reach a key as its literals.
    assert Argus.Schema in included
    assert Enum.filter(included, &Code.schema_module?/1) == included -- recorded
    refute Enum.any?(recorded, &Code.schema_module?/1)

    # Walked through: what records their reads is code, and keyed.
    assert Argus.Schema.Reads in recorded

    {:ok, extractor} = Code.closure(Argus.Extractors.ETS, schema: :recorded)
    refute Enum.any?(extractor, fn {mod, _beam} -> Code.schema_module?(mod) end)

    assert {:ok, one} = Code.digest(:base)
    assert {:ok, other} = Code.digest(:base, schema: :recorded)
    assert one != other
    assert_raise ArgumentError, fn -> Code.digest(:base, schema: :other) end
  end

  test "digests differ between producers and are stable within a VM" do
    assert {:ok, base} = Code.digest(:base)
    assert {:ok, ets} = Code.digest(Argus.Extractors.ETS)
    assert base != ets
    assert {:ok, ^ets} = Code.digest(Argus.Extractors.ETS)
  end

  test "a producer compiled in memory has no key" do
    [{mod, _bin}] =
      Elixir.Code.compile_string("""
      defmodule Argus.Cache.CodeTest.InMemory do
        def extract(_data), do: %{}
      end
      """)

    assert {:error, {:no_beam, ^mod}} = Code.closure(mod)
    assert {:error, {:no_beam, ^mod}} = Code.digest(mod)
  end
end
