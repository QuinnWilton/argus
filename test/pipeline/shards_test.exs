defmodule Argus.Pipeline.ShardsTest do
  @moduledoc """
  Each producer's rows are its own: extracting one producer alone gives
  the rows it gives beside every other, and the producers' directories,
  joined in order, are `Argus.Pipeline.run/3`'s directory byte for byte.
  That is what lets a store keep each producer's rows apart and re-extract
  one of them after an edit (`Argus.Cache.Facts`).
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline
  alias Argus.Pipeline.Shards

  @moduletag :tmp_dir

  # A spread of the fixtures, the ones a few extractors need (named, so
  # that a fixture added elsewhere cannot move them out of the spread), and
  # some runtime modules for shapes the fixtures do not have: every
  # extractor emits rows for some of them (the test checks). The spread is
  # one in twenty by a portable hash of the name, so adding a fixture does
  # not move the others in or out (every twentieth by sorted name did).
  @modules for(
             mod <- Application.spec(:panoptes, :modules),
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
      defmodule Argus.Pipeline.ShardsTest.Endpoint do
        def __sockets__, do: [{"/live", Phoenix.LiveView.Socket, [websocket: [], longpoll: []]}]
      end
      """)

    %{modules: @modules ++ [endpoint]}
  end

  defp extractors do
    {:ok, all} = Argus.Analysis.set(:all)

    Enum.uniq(
      [Argus.Extractors.CallArgs] ++
        Enum.flat_map(all ++ [:coverage], fn name ->
          {:ok, mod} = Argus.Analysis.fetch_module(name)
          mod.extractors()
        end)
    )
  end

  defp contents(dir) do
    for name <- dir |> File.ls!() |> Enum.sort(),
        String.ends_with?(name, ".facts"),
        into: %{},
        do: {name, File.read!(Path.join(dir, name))}
  end

  defp shard_dirs(root, producers),
    do: Enum.map(producers, &{&1, Path.join(root, inspect(&1))})

  describe "run_shards/3" do
    test "a producer extracted alone writes the rows it writes beside the others, over kept bases too",
         %{tmp_dir: tmp, modules: modules} do
      producers = [:base | extractors()]
      together = shard_dirs(Path.join(tmp, "together"), producers)
      opts = [trace_imprecision: true]

      assert {:ok, %{lost: [], bases: bases}} =
               Pipeline.run_shards(modules, together, [keep_bases: true] ++ opts)

      assert length(bases) == length(modules)
      assert Enum.all?(bases, &is_binary/1)

      # Several extractions at once: each is mostly the base's work, which
      # leaves cores idle on a set this small.
      together
      |> Task.async_stream(
        fn {producer, dir} ->
          [{^producer, alone}] = shard_dirs(Path.join(tmp, "alone"), [producer])
          [{^producer, over}] = shard_dirs(Path.join(tmp, "over_bases"), [producer])
          result = Pipeline.run_shards(modules, [{producer, alone}], opts)
          over_bases = Pipeline.run_shards(modules, [{producer, over}], [bases: bases] ++ opts)
          {producer, dir, alone, over, result, over_bases}
        end,
        timeout: :infinity
      )
      |> Enum.each(fn {:ok, {producer, dir, alone, over, result, over_bases}} ->
        assert {:ok, %{lost: []}} = result
        assert {:ok, %{lost: []}} = over_bases

        assert contents(alone) == contents(dir),
               "#{inspect(producer)} extracted alone differs from its rows among the others"

        # The base's own rows are the emitter's: it never runs over a
        # kept base, and computes its own.
        assert contents(over) == contents(dir),
               "#{inspect(producer)} extracted over kept bases differs from its rows computed afresh"
      end)

      # Every extractor is exercised: none of them wrote nothing.
      for {producer, dir} <- together do
        assert contents(dir) != %{}, "#{inspect(producer)} wrote no rows over the fixtures"
      end
    end

    test "joined in producer order, the directories are run/3's",
         %{tmp_dir: tmp, modules: modules} do
      extractors = extractors()
      staged = Argus.Schema.names() -- Argus.Schema.in_process_only()
      opts = [extractors: extractors, relations: staged, trace_imprecision: true]

      monolithic = Path.join(tmp, "run")
      assert {:ok, ^monolithic} = Pipeline.run(modules, monolithic, opts)

      dirs = shard_dirs(Path.join(tmp, "shards"), [:base | extractors])
      assert {:ok, _info} = Pipeline.run_shards(modules, dirs, opts)

      joined = Path.join(tmp, "joined")
      File.mkdir_p!(joined)
      Pipeline.write_facts(%{}, joined)
      parts = dirs |> Enum.map(&elem(&1, 1)) |> Shards.parts()
      assert :ok = Shards.assemble(parts, joined, :link)

      assert contents(joined) == contents(monolithic)
      assert File.ls!(monolithic) |> Enum.reject(&String.ends_with?(&1, ".facts")) == []
    end

    test "names the modules whose installed specs it read", %{tmp_dir: tmp} do
      dirs = shard_dirs(tmp, [Argus.Extractors.Specs])

      assert {:ok, %{installed: installed}} =
               Pipeline.run_shards([Argus.Test.Fixtures.Specs], dirs)

      assert GenServer in installed
      assert {:ok, %{installed: []}} = Pipeline.run_shards([:lists], shard_dirs(tmp, [:base]))
    end
  end

  describe "extract_shards/3" do
    # Each producer's rows as its directory holds them: by file name, the
    # rows in order.
    defp rows_by_file(facts) do
      Map.new(facts, fn {relation, rows} -> {"#{relation}.facts", rows} end)
    end

    defp decoded(dir),
      do: Map.new(contents(dir), fn {name, text} -> {name, Argus.Tsv.decode(text)} end)

    test "each producer's rows are the rows run_shards/3 writes for it",
         %{tmp_dir: tmp, modules: modules} do
      producers = [:base | extractors()]
      opts = [trace_imprecision: true]
      dirs = shard_dirs(tmp, producers)
      assert {:ok, %{lost: []}} = Pipeline.run_shards(modules, dirs, opts)

      assert {:ok, facts, %{lost: [], installed: installed}} =
               Pipeline.extract_shards(modules, producers, opts)

      assert Map.keys(facts) |> Enum.sort() == Enum.sort(producers)
      assert GenServer in installed

      for {producer, dir} <- dirs do
        assert rows_by_file(facts[producer]) == decoded(dir),
               "#{inspect(producer)}'s rows differ from its directory"
      end
    end

    test "a producer named alone has the rows it has among the others; the base is optional",
         %{modules: modules} do
      producers = [:base, Argus.Extractors.ETS, Argus.Extractors.Specs]
      assert {:ok, together, _info} = Pipeline.extract_shards(modules, producers)

      assert {:ok, %{Argus.Extractors.ETS => ets}, _info} =
               Pipeline.extract_shards(modules, [Argus.Extractors.ETS])

      assert ets == together[Argus.Extractors.ETS]
      assert ets != %{}

      # A producer named that made no rows is there, empty.
      assert {:ok, %{Argus.Extractors.ETS => %{}}, _info} =
               Pipeline.extract_shards([:lists], [Argus.Extractors.ETS])
    end

    test "interned rows materialize to the raw ones", %{modules: modules} do
      symbols = Argus.Symbols.new()
      producers = [:base, Argus.Extractors.Specs]
      assert {:ok, raw, _} = Pipeline.extract_shards(modules, producers)

      assert {:ok, interned, _} =
               Pipeline.extract_shards(modules, producers, format: :interned, symbols: symbols)

      for producer <- producers do
        assert Argus.Facts.materialize(interned[producer], symbols) == raw[producer]
      end

      assert_raise ArgumentError, ~r/symbols/, fn ->
        Pipeline.extract_shards(modules, producers, format: :interned)
      end
    end

    test "a module that outlives the timeout is lost, its one row the base's" do
      assert {:ok, facts, %{lost: ["Argus.Test.Fixtures.Specs"]}} =
               Pipeline.extract_shards(
                 [Argus.Test.Fixtures.Specs],
                 [:base, Argus.Extractors.Specs],
                 timeout: 0
               )

      assert %{extraction_error: [["Argus.Test.Fixtures.Specs", "pipeline", _reason]]} =
               facts[:base]

      assert facts[Argus.Extractors.Specs] == %{}
    end

    test "an input that cannot be read is an error" do
      assert {:error, _} = Pipeline.extract_shards(["/nonexistent/Nope.beam"], [:base])
    end
  end

  describe "run/3" do
    test "a relation with several producers keeps each producer's rows together",
         %{tmp_dir: tmp} do
      # `dynamic_call`: the emitter's `call_fun`/`apply` rows, then
      # Purity's `dot_dispatch` ones, each in module order.
      {:ok, _} = Pipeline.run(@modules, tmp, extractors: [Argus.Extractors.Purity])

      kinds =
        tmp
        |> Path.join("dynamic_call.facts")
        |> File.read!()
        |> Argus.Tsv.decode()
        |> Enum.map(&List.last/1)
        |> Enum.dedup_by(&(&1 == "dot_dispatch"))

      assert Enum.count(kinds, &(&1 == "dot_dispatch")) == 1
      assert List.last(kinds) == "dot_dispatch"
    end
  end

  describe "place/3" do
    test "a linked relation is never written through", %{tmp_dir: tmp} do
      part = Path.join(tmp, "part.facts")
      File.write!(part, "a\tb\n")
      target = Path.join(tmp, "target.facts")
      File.write!(target, "stale\n")

      assert :ok = Shards.place([part], target, :link)
      assert File.read!(target) == "a\tb\n"

      # Replacing the target again replaces the link, not the part.
      other = Path.join(tmp, "other.facts")
      File.write!(other, "c\td\n")
      assert :ok = Shards.place([other, part], target, :link)
      assert File.read!(target) == "c\td\na\tb\n"
      assert File.read!(part) == "a\tb\n"
    end

    test "a lone part is placed as a symbolic link to it, replacing what is there",
         %{tmp_dir: tmp} do
      part = Path.join(tmp, "part.facts")
      File.write!(part, "a\tb\n")
      target = Path.join(tmp, "target.facts")
      File.write!(target, "stale\n")

      assert :ok = Shards.place([part], target, :symlink)
      assert File.read!(target) == "a\tb\n"
      assert {:ok, ^part} = File.read_link(target)
      assert tmp |> File.ls!() |> Enum.sort() == ["part.facts", "target.facts"]
    end

    test "no parts is an empty file; a moved part leaves its place", %{tmp_dir: tmp} do
      target = Path.join(tmp, "target.facts")
      File.write!(target, "stale\n")
      assert :ok = Shards.place([], target, :move)
      assert File.read!(target) == ""

      part = Path.join(tmp, "part.facts")
      File.write!(part, "a\n")
      assert :ok = Shards.place([part], target, :move)
      assert File.read!(target) == "a\n"
      refute File.exists?(part)
      assert tmp |> File.ls!() |> Enum.sort() == ["target.facts"]
    end
  end
end
