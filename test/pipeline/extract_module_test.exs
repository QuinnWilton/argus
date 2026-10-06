defmodule Argus.Pipeline.ExtractModuleTest do
  @moduledoc """
  One module's extraction, each producer's rows apart
  (`Argus.Pipeline.extract_module/2`): what the query graph keeps per
  module and producer (`Argus.Graph.Pack`). That a producer's rows are
  its own, whichever others run and over a kept base too, is
  `Argus.Graph.Identity.ProducersTest`'s.
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :tmp_dir

  defp extract!(module, producers, opts \\ []) do
    {:ok, extraction} = Pipeline.extract_module(module, [producers: producers] ++ opts)
    extraction
  end

  test "a module that outlives the timeout is lost, its one row the base's, asked or not" do
    for producers <- [[:base, Argus.Extractors.Specs], [Argus.Extractors.Specs]] do
      assert %{status: :lost, facts: facts} =
               extract!(Argus.Test.Fixtures.Specs, producers, timeout: 0)

      assert %{extraction_error: base} = facts[:base]
      assert IO.iodata_to_binary(base) =~ "Argus.Test.Fixtures.Specs\tpipeline\t"
      assert facts[Argus.Extractors.Specs] == %{}
    end
  end

  test "reports what each producer read of the schema: the base's reads and its own" do
    producers = [:base, Argus.Extractors.ETS, Argus.Extractors.Dependence]
    %{reads: reads, base: base} = extract!(:gen_server, producers, keep_base: true)

    # The pipeline decodes the relations the in-process passes read,
    # by their columns, and nothing else of the schema.
    typed = MapSet.new(Pipeline.typed_relations(), &"columns #{&1}")
    assert reads[:base] != []
    assert Enum.all?(reads[:base], &MapSet.member?(typed, &1))
    assert reads[Argus.Extractors.ETS] == reads[:base]
    assert :ordsets.subtract(reads[:base], reads[Argus.Extractors.Dependence]) == []

    # Over a kept base, what computed it is the caller's to add: a base
    # read back reads nothing of the schema.
    assert is_binary(base)
    %{reads: over} = extract!(:gen_server, [Argus.Extractors.ETS], base: base)
    assert over[Argus.Extractors.ETS] == []
  end

  test "names the modules whose installed specs it read" do
    assert GenServer in extract!(Argus.Test.Fixtures.Specs, [Argus.Extractors.Specs]).installed
    assert extract!(:lists, [:base]).installed == []
  end

  test "a producer named that made no rows is there, empty" do
    assert %{facts: %{Argus.Extractors.ETS => %{}}} = extract!(:lists, [Argus.Extractors.ETS])
  end

  test "an input that cannot be read is an error" do
    assert {:error, _} = Pipeline.extract_module("/nonexistent/Nope.beam", producers: [:base])
  end

  describe "run/3" do
    test "a relation with several producers keeps each module's rows by producer",
         %{tmp_dir: tmp} do
      # `dynamic_call`: in each module, the emitter's `call_fun`/`apply`
      # rows, then Purity's `dot_dispatch` ones.
      modules = Argus.Test.FixtureSpread.spread()
      {:ok, _} = Pipeline.run(modules, tmp, extractors: [Argus.Extractors.Purity])
      rows = tmp |> Path.join("dynamic_call.facts") |> File.read!() |> Argus.Tsv.decode()
      assert Enum.any?(rows, &(List.last(&1) == "dot_dispatch"))

      # Each module's rows in input order, as extracting it alone gives
      # them: the emitter's first, then Purity's.
      each =
        for module <- modules do
          {:ok, facts} = Pipeline.extract([module], extractors: [Argus.Extractors.Purity])
          facts |> Map.get(:dynamic_call, []) |> Enum.reverse()
        end

      assert rows == Enum.concat(each)
    end
  end
end
