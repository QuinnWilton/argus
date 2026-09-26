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
