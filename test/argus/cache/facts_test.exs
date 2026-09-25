defmodule Argus.Cache.FactsTest do
  @moduledoc """
  Facts through a store: each producer's shard is kept apart and
  extracted only when missing, a run's facts materialize to exactly
  `Argus.Pipeline.run/3`'s directory, and a solve is read back while
  the content of what it reads is unchanged — downstream of a stage
  whose output came out the same, too.
  """
  use ExUnit.Case, async: true

  alias Argus.Cache
  alias Argus.Cache.Facts
  alias Argus.Pipeline

  # They test the store, which ARGUS_NO_CACHE turns off.
  @moduletag :cache
  @moduletag :tmp_dir

  @modules [
    Argus.Test.Fixtures.EtsBounded,
    Argus.Test.Fixtures.MissingRow,
    Argus.Test.Fixtures.PidFlow.ConnSup,
    Argus.Test.Fixtures.Specs,
    :gen_server
  ]

  @extractors [Argus.Extractors.CallArgs, Argus.Extractors.ETS, Argus.Extractors.Specs]

  defp shards(store), do: store |> Cache.dir(:shards) |> File.ls!() |> Enum.sort()

  defp contents(dir) do
    for name <- dir |> File.ls!() |> Enum.sort(), into: %{} do
      {name, File.read!(Path.join(dir, name))}
    end
  end

  describe "extract/4" do
    test "extracts each producer once, and after that reads it", %{tmp_dir: store} do
      assert {:ok, first} = Facts.extract(@modules, @extractors, [], store)
      kept = shards(store)
      assert length(kept) == 4

      assert Enum.map(kept, &hd(String.split(&1, "-"))) |> Enum.sort() ==
               Enum.sort(["base" | Enum.map(@extractors, &inspect/1)])

      assert {:ok, again} = Facts.extract(@modules, @extractors, [], store)
      assert again.relations == first.relations
      assert shards(store) == kept

      # Every file the facts name is a kept shard's.
      for {_name, {_digest, paths}} <- again.relations, path <- paths do
        assert Path.dirname(Path.dirname(path)) == Cache.dir(store, :shards)
      end
    end

    test "an extractor new to the set is the only one extracted", %{tmp_dir: store} do
      assert {:ok, _} = Facts.extract(@modules, @extractors, [], store)
      before = shards(store)

      assert {:ok, _} =
               Facts.extract(@modules, @extractors ++ [Argus.Extractors.Mnesia], [], store)

      assert [added] = shards(store) -- before
      assert String.starts_with?(added, "Argus.Extractors.Mnesia-")
    end

    test "extractors extracted again keep the bases, and the next ones run over them",
         %{tmp_dir: tmp} do
      store = Path.join(tmp, "store")
      bases = fn -> store |> Cache.dir(:bases) |> File.ls() |> then(&elem(&1, 1)) end

      # The base's own shard extracted: no bases kept.
      assert {:ok, _} = Facts.extract(@modules, @extractors, [], store)
      assert bases.() == :enoent

      # Extractors alone: the bases computed are kept.
      assert {:ok, _} =
               Facts.extract(@modules, @extractors ++ [Argus.Extractors.Mnesia], [], store)

      assert [kept] = bases.()
      entry = Path.join(Cache.dir(store, :bases), kept)
      File.touch!(entry, System.os_time(:second) - 3600)

      assert {:ok, facts} =
               Facts.extract(@modules, @extractors ++ [Argus.Extractors.Monitor], [], store)

      # Read back (a hit touches it), not computed and kept again.
      assert bases.() == [kept]
      assert File.stat!(entry, time: :posix).mtime > System.os_time(:second) - 60

      fresh = Path.join(tmp, "fresh")
      assert {:ok, _} = Pipeline.run_shards(@modules, [{Argus.Extractors.Monitor, fresh}])

      for {name, {_digest, [path]}} <- facts.relations,
          String.contains?(path, "Argus.Extractors.Monitor-") do
        assert File.read!(path) == File.read!(Path.join(fresh, name))
      end

      # The options that shape rows do not key a base.
      assert {:ok, _} =
               Facts.extract(
                 @modules,
                 [Argus.Extractors.Monitor],
                 [trace_imprecision: true],
                 store
               )

      assert bases.() == [kept]
    end

    test "a run of extractors alone that lost a module keeps neither shards nor bases",
         %{tmp_dir: store} do
      assert {:ok, _} = Facts.extract(@modules, [], [], store)
      assert [base] = shards(store)

      assert {:ok, facts} = Facts.extract(@modules, @extractors, [timeout: 1], store)
      Facts.release(facts)
      refute File.exists?(Cache.dir(store, :bases))
      assert shards(store) == [base]
    end

    test "the options that shape rows key the shards", %{tmp_dir: store} do
      assert {:ok, _} = Facts.extract(@modules, @extractors, [], store)
      assert {:ok, _} = Facts.extract(@modules, @extractors, [trace_imprecision: true], store)
      assert length(shards(store)) == 8

      staged = Argus.Schema.names() -- Argus.Schema.in_process_only()
      assert {:ok, _} = Facts.extract(@modules, @extractors, [relations: staged], store)
      assert length(shards(store)) == 12

      # Named by what is left out, the same rows key otherwise: a relation
      # added to the schema moves no key of the extraction's.
      except = {:except, Argus.Schema.in_process_only()}
      assert {:ok, _} = Facts.extract(@modules, @extractors, [relations: except], store)
      assert length(shards(store)) == 16
    end

    test "the beams key the shards, by content", %{tmp_dir: store} do
      assert {:ok, one} = Facts.extract([:lists], [], [], store)
      assert {:ok, two} = Facts.extract([:maps], [], [], store)
      assert one.group != two.group
      assert length(shards(store)) == 2
    end

    test "materialized, the facts are run/3's directory byte for byte", %{tmp_dir: tmp} do
      store = Path.join(tmp, "store")
      opts = [trace_imprecision: true, relations: Argus.Schema.names() -- [:instruction]]

      assert {:ok, facts} = Facts.extract(@modules, @extractors, opts, store)
      assert {:ok, facts} = Facts.materialize(facts)

      monolithic = Path.join(tmp, "run")
      assert {:ok, _} = Pipeline.run(@modules, monolithic, [extractors: @extractors] ++ opts)

      try do
        assert contents(facts.dir) == contents(monolithic)

        assert Facts.extraction_errors(facts) ==
                 File.read!(Path.join(monolithic, "extraction_error.facts"))
      after
        Facts.release(facts)
      end

      refute File.exists?(facts.work)
    end

    test "a module compiled in memory is extracted, and its read of a fixture's specs recorded",
         %{tmp_dir: store} do
      [{_mod, caller}] =
        Code.compile_string("""
        defmodule Argus.Cache.FactsTest.Caller do
          def go, do: Argus.Test.Fixtures.Specs.total()
        end
        """)

      assert {:ok, facts} = Facts.extract([caller], [Argus.Extractors.Specs], [], store)
      {_digest, [spec_return]} = Map.fetch!(facts.relations, "spec_return.facts")
      assert File.read!(spec_return) =~ "Argus.Test.Fixtures.Specs:total/0\ttotal\tinstalled"

      # The fixture's beam is what the shard read; a shard that recorded
      # another reading of it is stale.
      [entry] =
        for name <- shards(store), name =~ "Specs", do: Path.join(Cache.dir(store, :shards), name)

      manifest = Path.join(entry, ".argus-shard")
      recorded = manifest |> File.read!() |> :erlang.binary_to_term()

      assert [{"Elixir.Argus.Test.Fixtures.Specs", {:beam, _digest}}] = recorded.reads

      File.chmod!(manifest, 0o644)

      File.write!(
        manifest,
        :erlang.term_to_binary(%{
          recorded
          | reads: [{"Elixir.Argus.Test.Fixtures.Specs", {:beam, "old"}}]
        })
      )

      assert {:ok, _} = Facts.extract([caller], [Argus.Extractors.Specs], [], store)
      recorded = manifest |> File.read!() |> :erlang.binary_to_term()
      assert [{"Elixir.Argus.Test.Fixtures.Specs", {:beam, digest}}] = recorded.reads
      assert digest != "old"
    end

    test "a read of a module this VM has never named still holds", %{tmp_dir: store} do
      assert {:ok, _} = Facts.extract([:lists], [Argus.Extractors.Specs], [], store)

      [entry] =
        for name <- shards(store), name =~ "Specs", do: Path.join(Cache.dir(store, :shards), name)

      manifest = Path.join(entry, ".argus-shard")
      recorded = manifest |> File.read!() |> :erlang.binary_to_term()

      # The analyzed program's own modules are absent from this VM's code
      # path, and their names are no atoms here.
      unknown = "Elixir.Argus.Cache.FactsTest.Never#{System.unique_integer([:positive])}"
      File.chmod!(manifest, 0o644)
      File.write!(manifest, :erlang.term_to_binary(%{recorded | reads: [{unknown, :absent}]}))
      %File.Stat{inode: inode} = File.stat!(entry)

      assert {:ok, _} = Facts.extract([:lists], [Argus.Extractors.Specs], [], store)
      assert File.stat!(entry).inode == inode
    end
  end

  describe "solve/3" do
    # A stage that writes `node.facts` from `edge`, and a program reading
    # only `node`.
    defp programs!(dir) do
      stage = Path.join(dir, "stage.dl")
      down = Path.join(dir, "down.dl")

      File.write!(stage, """
      .decl edge(x: symbol, y: symbol)
      .input edge
      .decl node(x: symbol)
      .output node(filename="node.facts")
      node(x) :- edge(x, _).
      """)

      File.write!(down, """
      .decl node(x: symbol)
      .input node
      .decl out(x: symbol)
      .output out
      out(x) :- node(x).
      """)

      {stage, down}
    end

    defp facts(store, edge_file) do
      {:ok, digest} = Cache.file_digest(edge_file)

      %Facts{
        store: store,
        group: "0123456789abcdef",
        relations: %{"edge.facts" => {digest, [edge_file]}}
      }
    end

    defp solved(store) do
      store
      |> Cache.dir(:solves)
      |> File.ls!()
      |> Enum.map(&hd(String.split(&1, "-")))
      |> Enum.frequencies()
    end

    test "a stage whose output is unchanged re-solves nothing after it", %{tmp_dir: tmp} do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      {stage, down} = programs!(tmp)
      store = Path.join(tmp, "store")
      edge = Path.join(tmp, "edge.facts")

      File.write!(edge, "a\tb\n")
      facts = facts(store, edge)
      assert {:ok, %{}, staged} = Facts.solve(facts, stage, [])
      assert {:ok, %{"out" => [["a"]]}, _} = Facts.solve(staged, down, [])
      assert solved(store) == %{"stage" => 1, "down" => 1}

      # A new edge from the same node: the stage solves again, and its
      # output is the same, so the program after it is read back.
      edge2 = Path.join(tmp, "edge2.facts")
      File.write!(edge2, "a\tc\n")
      facts = facts(store, edge2)
      assert {:ok, %{}, staged} = Facts.solve(facts, stage, [])
      assert {:ok, %{"out" => [["a"]]}, _} = Facts.solve(staged, down, [])
      assert solved(store) == %{"stage" => 2, "down" => 1}

      # A new node moves both.
      edge3 = Path.join(tmp, "edge3.facts")
      File.write!(edge3, "d\tc\n")
      assert {:ok, %{}, staged} = Facts.solve(facts(store, edge3), stage, [])
      assert {:ok, %{"out" => [["d"]]}, _} = Facts.solve(staged, down, [])
      assert solved(store) == %{"stage" => 3, "down" => 2}

      Facts.release(staged)
    end

    test "a stage's output replaces what a materialized directory held", %{tmp_dir: tmp} do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      {stage, _down} = programs!(tmp)
      store = Path.join(tmp, "store")
      edge = Path.join(tmp, "edge.facts")
      File.write!(edge, "a\tb\n")

      {:ok, facts} = Facts.materialize(facts(store, edge))

      try do
        assert {:ok, _, facts} = Facts.solve(facts, stage, [])
        assert File.read!(Path.join(facts.dir, "node.facts")) == "a\n"
        {digest, [kept]} = Map.fetch!(facts.relations, "node.facts")
        assert {:ok, ^digest} = Cache.file_digest(kept)
        assert File.stat!(kept).access == :read
      after
        Facts.release(facts)
      end
    end

    test "a solve that misses places what it reads, as links; materialize/1 makes the rest",
         %{tmp_dir: tmp} do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      {stage, down} = programs!(tmp)
      store = Path.join(tmp, "store")
      edge = Path.join(tmp, "edge.facts")
      File.write!(edge, "a\tb\n")

      facts = facts(store, edge)
      facts = %{facts | relations: Map.put(facts.relations, "call_edge.facts", {"x", [edge]})}

      assert {:ok, %{}, staged} = Facts.solve(facts, stage, [])
      assert File.ls!(staged.dir) == ["edge.facts"]
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(staged.dir, "edge.facts"))

      # The stage's output is placed when a solve reads it.
      assert {:ok, %{"out" => [["a"]]}, solved} = Facts.solve(staged, down, [])
      assert solved.dir == staged.dir
      assert Enum.sort(File.ls!(solved.dir)) == ["edge.facts", "node.facts"]

      # The whole directory: every relation and schema file, and no
      # symbolic link left to outlive the store's entries.
      assert {:ok, full} = Facts.materialize(solved)

      try do
        names = File.ls!(full.dir)
        assert "call_edge.facts" in names
        assert "instruction.facts" in names
        assert File.read!(Path.join(full.dir, "node.facts")) == "a\n"

        for name <- names do
          assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(full.dir, name))
        end
      after
        Facts.release(full)
      end

      refute File.exists?(full.work)
    end

    test "release removes the directory, a file the facts do not name included",
         %{tmp_dir: tmp} do
      edge = Path.join(tmp, "edge.facts")
      File.write!(edge, "a\tb\n")

      assert {:ok, facts} =
               Facts.materialize(facts(Path.join(tmp, "store"), edge), ["edge.facts"])

      File.write!(Path.join(facts.dir, "stray.facts"), "")
      assert :ok = Facts.release(facts)
      refute File.exists?(facts.work)
      assert File.read!(edge) == "a\tb\n"
    end

    test "prepare places what the solves not kept read, and nothing once they are kept",
         %{tmp_dir: tmp} do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      {stage, _down} = programs!(tmp)
      store = Path.join(tmp, "store")
      edge = Path.join(tmp, "edge.facts")
      File.write!(edge, "a\tb\n")
      facts = facts(store, edge)

      assert {:ok, prepared} = Facts.prepare(facts, [stage], [])
      assert File.ls!(prepared.dir) == ["edge.facts"]
      assert {:ok, %{}, solved} = Facts.solve(prepared, stage, [])
      assert solved.work == prepared.work
      Facts.release(solved)

      assert {:ok, kept} = Facts.prepare(facts, [stage], [])
      assert kept.dir == nil
    end

    test "a failed solve is reported and not kept", %{tmp_dir: tmp} do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      store = Path.join(tmp, "store")
      bad = Path.join(tmp, "bad.dl")
      File.write!(bad, "not datalog\n")
      edge = Path.join(tmp, "edge.facts")
      File.write!(edge, "a\tb\n")

      assert {:error, _} = Facts.solve(facts(store, edge), bad, [])
      refute File.exists?(Cache.dir(store, :solves))
    end
  end
end
