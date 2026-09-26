defmodule Argus.Cache.RacesTest do
  @moduledoc """
  What a store's readers, writers and pruners do when another process
  acts between their steps. Each race is held open in a VM of its own
  by `Argus.Test.FileGate`: its stand-in for the file server acts at
  the step a race needs, so the interleaving happens on every run.
  """

  use ExUnit.Case, async: true

  alias Argus.Cache
  alias Argus.Test.FileGate

  @moduletag :tmp_dir

  defp key(char), do: String.duplicate(char, 64)

  # A VM of this one's code, whose file server a test may stand in for.
  defp peer! do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})
    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
    on_exit(fn -> quietly(fn -> :peer.stop(peer) end) end)
    peer
  end

  # A peer the test already stopped, or a stand-in already taken down,
  # is no failure of the test.
  defp quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  # `mfa` run in `peer` with `gates` in front of its file server: what
  # it returned, and each gate's action's result.
  defp gated(peer, gates, {module, function, args}) do
    :ok = :peer.call(peer, FileGate, :install, [gates])

    try do
      {:peer.call(peer, module, function, args, 60_000),
       :peer.call(peer, FileGate, :uninstall, [])}
    after
      quietly(fn -> :peer.call(peer, FileGate, :uninstall, []) end)
    end
  end

  # A pruner removing `path` the moment a gated process has asked the
  # file server about it.
  defp prune_at(path, ops, nth \\ 1),
    do: %{name: :prune, ops: ops, path: path, nth: nth, action: {File, :rm_rf, [path]}}

  describe "fetch/1" do
    test "never makes the entry a prune takes as it looks", %{tmp_dir: root} do
      entry = Path.join(root, "solves/p-#{key("a")}")
      File.mkdir_p!(entry)
      File.write!(Path.join(entry, "out.csv"), "x\n")

      # Whatever the fetch asks the file server first, the entry goes
      # right after: it was there when looked at, and is not when acted
      # on.
      gate = prune_at(entry, [:read_file_info, :read_link_info, :write_file_info])
      {fetched, %{prune: {:ok, _}}} = gated(peer!(), [gate], {Cache, :fetch, [entry]})

      assert fetched in [:miss, {:ok, entry}]
      assert File.lstat(entry) == {:error, :enoent}
    end

    test "misses an entry that is not there, and makes nothing", %{tmp_dir: root} do
      entry = Path.join(root, "solves/p-#{key("b")}")
      assert Cache.fetch(entry) == :miss
      assert File.lstat(entry) == {:error, :enoent}
    end
  end

  describe "prune/2" do
    @hour 60 * 60

    # A kept solve untouched for two hours, the only one of its program:
    # stale with `recent: 0`.
    defp stale_solve!(root) do
      entry = Path.join(root, "solves/p-#{key("a")}")
      File.mkdir_p!(entry)

      for name <- ["a.csv", "b.csv", ".argus-digests"],
          do: File.write!(Path.join(entry, name), "x\n")

      File.touch!(entry, System.os_time(:second) - 2 * @hour)
      entry
    end

    # A lookup touching `entry` the moment the pruner's `nth` look at it
    # has been answered.
    defp lookup_at(entry, nth),
      do: %{
        name: :lookup,
        ops: [:read_link_info],
        path: entry,
        nth: nth,
        action: {Cache, :fetch, [entry]}
      }

    test "keeps an entry a lookup touched after the prune found it stale", %{tmp_dir: root} do
      entry = stale_solve!(root)

      {removed, %{lookup: {:ok, ^entry}}} =
        gated(peer!(), [lookup_at(entry, 1)], {Cache, :prune, [root, [recent: 0]]})

      assert removed == []
      assert File.ls!(entry) |> Enum.sort() == [".argus-digests", "a.csv", "b.csv"]
    end

    test "puts back an entry a lookup touched as it was being taken", %{tmp_dir: root} do
      entry = stale_solve!(root)

      # The second look is the one just before the entry is renamed out
      # of its name: the touch lands after it.
      {removed, %{lookup: {:ok, ^entry}}} =
        gated(peer!(), [lookup_at(entry, 2)], {Cache, :prune, [root, [recent: 0]]})

      assert removed == []
      assert File.ls!(entry) |> Enum.sort() == [".argus-digests", "a.csv", "b.csv"]
      assert File.ls!(Path.dirname(entry)) == [Path.basename(entry)]
    end

    test "takes an entry whole: a reader sees all of it or none of it", %{tmp_dir: root} do
      entry = stale_solve!(root)

      # A reader listing the entry the moment the pruner first changes
      # anything under its name.
      reader = %{
        name: :reader,
        ops: [:delete, :del_dir, :rename],
        path: entry,
        prefix: true,
        action: {File, :ls, [entry]}
      }

      {removed, %{reader: listed}} =
        gated(peer!(), [reader], {Cache, :prune, [root, [recent: 0]]})

      assert removed == [entry]
      refute File.exists?(entry)

      case listed do
        {:error, :enoent} -> :ok
        {:ok, names} -> assert Enum.sort(names) == [".argus-digests", "a.csv", "b.csv"]
      end
    end

    test "a corpus checkout's store keeps an entry touched after it was found stale",
         %{tmp_dir: root} do
      entry = stale_solve!(Path.join(root, key("f")))

      {removed, %{lookup: {:ok, ^entry}}} =
        gated(
          peer!(),
          [lookup_at(entry, 1)],
          {Argus.Corpus, :prune_solves, [Path.join(root, "#{key("f")}/solves"), [recent: 0]]}
        )

      assert removed == []
      assert File.dir?(entry)
    end
  end

  describe "a kept solve" do
    # A program over `edge` with two outputs, and its facts: in a
    # directory for `Argus.Souffle.run/3`, and by hand for
    # `Argus.Cache.Facts.solve/3`.
    defp program!(dir) do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      rules = Path.join(dir, "two.dl")

      File.write!(rules, """
      .decl edge(x: symbol, y: symbol)
      .input edge
      .decl out(x: symbol)
      .output out
      .decl also(y: symbol)
      .output also
      out(x) :- edge(x, _).
      also(y) :- edge(_, y).
      """)

      facts_dir = Path.join(dir, "facts")
      File.mkdir_p!(facts_dir)
      File.write!(Path.join(facts_dir, "edge.facts"), "a\tb\n")
      {rules, facts_dir}
    end

    defp store_facts(store, facts_dir) do
      edge = Path.join(facts_dir, "edge.facts")
      {:ok, digest} = Cache.file_digest(edge)

      %Cache.Facts{
        store: store,
        group: "0123456789abcdef",
        relations: %{"edge.facts" => {digest, [edge]}}
      }
    end

    @solved %{"out" => [["a"]], "also" => [["b"]]}

    test "one pruned as a run reads it is solved again", %{tmp_dir: tmp} do
      {rules, facts_dir} = program!(tmp)
      solves = Path.join(tmp, "solves")
      opts = [solve_cache: solves]
      assert {:ok, @solved} = Argus.Souffle.run(facts_dir, rules, opts)

      {:ok, entry} =
        Argus.Souffle.Cache.entry(rules, Argus.Souffle.executable(), facts_dir, opts)

      # Found and touched, then gone before a file of it is read.
      gate = prune_at(entry, [:write_file_info])

      assert {{:ok, @solved}, %{prune: {:ok, _}}} =
               gated(peer!(), [gate], {Argus.Souffle, :run, [facts_dir, rules, opts]})

      assert File.dir?(entry)
    end

    test "one pruned as a store's run reads it is solved again", %{tmp_dir: tmp} do
      {rules, facts_dir} = program!(tmp)
      facts = store_facts(Path.join(tmp, "store"), facts_dir)
      assert {:ok, @solved, _} = Cache.Facts.solve(facts, rules, [])
      {:ok, entry} = Cache.Facts.entry(facts, rules, [])

      gate = prune_at(entry, [:write_file_info])

      assert {{:ok, @solved, _}, %{prune: {:ok, _}}} =
               gated(peer!(), [gate], {Cache.Facts, :solve, [facts, rules, []]})

      assert File.dir?(entry)
    end

    test "one missing an output its manifest names is solved again, never read short",
         %{tmp_dir: tmp} do
      {rules, facts_dir} = program!(tmp)
      opts = [solve_cache: Path.join(tmp, "solves")]
      facts = store_facts(Path.join(tmp, "store"), facts_dir)
      assert {:ok, @solved} = Argus.Souffle.run(facts_dir, rules, opts)
      assert {:ok, @solved, _} = Cache.Facts.solve(facts, rules, [])

      {:ok, run_entry} =
        Argus.Souffle.Cache.entry(rules, Argus.Souffle.executable(), facts_dir, opts)

      {:ok, facts_entry} = Cache.Facts.entry(facts, rules, [])

      # Damaged as a prune file by file used to leave an entry it was
      # taken from under a reader.
      for entry <- [run_entry, facts_entry], do: File.rm!(Path.join(entry, "also.csv"))

      assert {:ok, @solved} = Argus.Souffle.run(facts_dir, rules, opts)
      assert {:ok, @solved, _} = Cache.Facts.solve(facts, rules, [])

      # Written again whole, for the next run.
      for entry <- [run_entry, facts_entry] do
        assert File.read!(Path.join(entry, "also.csv")) == "b\n"
        assert {:ok, @solved} = Argus.Souffle.read_outputs(entry)
      end
    end

    test "one a run counts on as kept stays through a prune before it is read",
         %{tmp_dir: tmp} do
      {rules, facts_dir} = program!(tmp)
      store = Path.join(tmp, "store")
      facts = store_facts(store, facts_dir)
      assert {:ok, @solved, _} = Cache.Facts.solve(facts, rules, [])
      {:ok, entry} = Cache.Facts.entry(facts, rules, [])
      # Kept two hours ago, and not read since.
      File.touch!(entry, System.os_time(:second) - 2 * 60 * 60)

      # A prune the moment the fan-out's preparation has looked at the
      # entry and counted it kept, so placed nothing for it.
      prune = %{
        name: :prune,
        ops: [:read_file_info, :write_file_info],
        path: entry,
        action: {Cache, :prune, [store, [recent: 0]]}
      }

      {{:ok, prepared}, %{prune: pruned}} =
        gated(peer!(), [prune], {Cache.Facts, :prepare, [facts, [rules], []]})

      assert prepared.dir == nil
      assert pruned == []
      assert File.dir?(entry)
    end

    test "an output its manifest names and the entry lacks is an error naming it",
         %{tmp_dir: tmp} do
      entry = Path.join(tmp, "p-#{key("c")}")
      {:ok, staging} = Cache.staging(entry)
      File.write!(Path.join(staging, "out.csv"), "a\n")
      File.write!(Path.join(staging, "also.csv"), "")
      :ok = Argus.Souffle.Cache.install(staging, entry)
      File.rm!(Path.join(entry, "also.csv"))

      path = Path.join(entry, "also.csv")

      assert {:error, %Argus.MissingRelationError{relation: "also", path: ^path, reason: :enoent}} =
               Argus.Souffle.read_outputs(entry)
    end
  end

  describe "a kept shard" do
    test "one pruned as an extraction reads it is extracted again", %{tmp_dir: tmp} do
      store = Path.join(tmp, "store")
      assert {:ok, first} = Cache.Facts.extract([:lists], [], [], store)
      [name] = store |> Cache.dir(:shards) |> File.ls!()
      entry = Path.join(Cache.dir(store, :shards), name)

      # Found and touched, then gone before its manifest is read.
      gate = prune_at(entry, [:write_file_info])

      assert {{:ok, again}, %{prune: {:ok, _}}} =
               gated(peer!(), [gate], {Cache.Facts, :extract, [[:lists], [], [], store]})

      assert Map.new(again.relations, fn {n, {digest, _}} -> {n, digest} end) ==
               Map.new(first.relations, fn {n, {digest, _}} -> {n, digest} end)

      assert File.dir?(entry)
    end
  end

  describe "a specs environment's kept ebin digests" do
    # An ebin of one beam, written long enough ago that a stamp vouches
    # for it: its digests are kept in `cache`.
    defp ebin!(root) do
      ebin = Path.join(root, "app/ebin")
      File.mkdir_p!(ebin)
      beam = Path.join(ebin, "Elixir.Argus.Cache.beam")
      File.cp!(:code.which(Argus.Cache), beam)
      File.touch!(beam, System.os_time(:second) - 60)
      ebin
    end

    defp kept_entry(cache) do
      [name] = cache |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "app-"))
      Path.join(cache, name)
    end

    test "a fresh VM's hit pruned as it reads leaves no empty entry behind", %{tmp_dir: root} do
      ebin = ebin!(root)
      cache = Path.join(root, "ebins")
      digests = Argus.Specs.ebin_digests([ebin], cache: cache)
      entry = kept_entry(cache)

      gate = prune_at(entry, [:read_file, :write_file_info])

      {^digests, %{prune: {:ok, _}}} =
        gated(peer!(), [gate], {Argus.Specs, :ebin_digests, [[ebin], [cache: cache]]})

      # Gone, or written again whole by the miss the prune made.
      case File.read(entry) do
        {:error, :enoent} -> :ok
        {:ok, bytes} -> assert :erlang.binary_to_term(bytes) == digests[ebin]
      end
    end

    test "an entry that does not read as digests is written again", %{tmp_dir: root} do
      ebin = ebin!(root)
      cache = Path.join(root, "ebins")
      digests = Argus.Specs.ebin_digests([ebin], cache: cache)
      entry = kept_entry(cache)
      # What a touch racing a prune used to leave at an entry's name.
      File.write!(entry, "")

      assert :peer.call(peer!(), Argus.Specs, :ebin_digests, [[ebin], [cache: cache]]) == digests
      assert entry |> File.read!() |> :erlang.binary_to_term() == digests[ebin]
    end
  end
end
