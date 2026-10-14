defmodule Argus.Graph.PackTest do
  @moduledoc """
  A pack holds a small segment itself and names a large one by its
  blob's digest; either reads the same, and so does a pack written
  before small segments were held in it, which names every segment by
  digest. Where a segment is held never moves what a relation is named
  by, so finding identities and kept solves stay where they were.
  """

  use ExUnit.Case, async: true

  alias Argus.Graph.Pack
  alias Argus.Test.Files
  alias Roux.Blob

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    %{store: Blob.open!(Path.join(dir, "store"))}
  end

  # Bytes that do not compress, so a segment's stored size follows their
  # length: the same bytes on every run.
  defp noise(seed, length) do
    :rand.seed(:exsss, {seed, 0, 0})
    :rand.bytes(length)
  end

  defp stored_size(rows), do: rows |> Blob.encode_term() |> elem(1) |> byte_size()

  # Rows of one relation whose stored form is exactly `size` bytes.
  defp rows_of_size(relation, size) do
    base = stored_size(%{relation => ""})
    rows = %{relation => noise(size, size - base)}
    # A binary's length header grows past some lengths: settle it.
    rows = %{relation => noise(size, size - base - (stored_size(rows) - size))}
    assert stored_size(rows) == size
    rows
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)

  defp segments do
    [
      {:base, %{function_def: "a\t1\n", instr: noise(1, 3 * Pack.inline_limit())}},
      {Argus.Extractors.ETS, %{}},
      {Argus.Extractors.Monitor, %{param_decided: "b\tc\n", function_def: "d\t2\n"}}
    ]
  end

  describe "from_segments/3" do
    test "holds a small segment in the pack and puts a large one beside it", %{store: store} do
      {pack, held} = Pack.from_segments(store, :m, segments())
      {:ok, index} = Blob.get_term(store, pack.pack)

      assert [
               {:base, large, [:function_def, :instr]},
               {Argus.Extractors.Monitor, %{param_decided: "b\tc\n", function_def: "d\t2\n"},
                [:function_def, :param_decided]}
             ] = index

      assert is_binary(large)
      assert held == [pack.pack, large]
      assert Enum.all?(held, &Blob.member?(store, &1))
      assert {:ok, %{instr: _, function_def: "a\t1\n"}} = Blob.get_term(store, large)
    end

    test "names each relation by its bytes, wherever its segment is held", %{store: store} do
      {pack, _held} = Pack.from_segments(store, :m, segments())
      [{:base, base} | _] = segments()
      joined = sha256(["argus-joined-chunk\n", sha256("a\t1\n"), sha256("d\t2\n")])

      assert pack.relations == %{
               function_def: joined,
               instr: sha256(base.instr),
               param_decided: sha256("b\tc\n")
             }
    end

    test "makes the same pack from the same rows in another store", %{store: store, tmp_dir: dir} do
      other = Blob.open!(Path.join(dir, "other"))

      assert Pack.from_segments(store, :m, segments()) ==
               Pack.from_segments(other, :m, segments())
    end

    test "holds a segment of the limit in the pack, and one a byte past it beside it", %{
      store: store
    } do
      limit = Pack.inline_limit()
      at = rows_of_size(:at, limit)
      past = rows_of_size(:past, limit + 1)

      {pack, held} = Pack.from_segments(store, :m, [{:base, at}, {Argus.Extractors.ETS, past}])
      {:ok, index} = Blob.get_term(store, pack.pack)

      assert [{:base, ^at, [:at]}, {Argus.Extractors.ETS, digest, [:past]}] = index
      assert held == [pack.pack, digest]
      assert Blob.get_term(store, digest) == {:ok, past}
    end
  end

  describe "chunks/4" do
    test "joins a relation's bytes from held and separate segments in producer order", %{
      store: store
    } do
      {pack, _held} = Pack.from_segments(store, :m, segments())

      assert Pack.chunks(store, pack.pack, [:function_def, :param_decided, :absent]) ==
               {:ok, %{function_def: "a\t1\nd\t2\n", param_decided: "b\tc\n"}}

      assert Pack.chunks(store, pack.pack, [:function_def], [Argus.Extractors.Monitor]) ==
               {:ok, %{function_def: "d\t2\n"}}
    end

    test "reads a pack that names every segment by digest as earlier versions wrote", %{
      store: store
    } do
      {pack, _held} = Pack.from_segments(store, :m, segments())

      old =
        for {producer, rows} <- segments(), rows != %{} do
          {:ok, digest} = Blob.put_term(store, rows)
          {producer, digest, rows |> Map.keys() |> Enum.sort()}
        end

      {:ok, old_pack} = Blob.put_term(store, old)
      relations = [:function_def, :instr, :param_decided]

      assert Pack.chunks(store, old_pack, relations) == Pack.chunks(store, pack.pack, relations)

      assert Pack.chunks(store, old_pack, [:function_def], [:base]) ==
               Pack.chunks(store, pack.pack, [:function_def], [:base])
    end

    test "misses a lost separate segment only when it holds a relation asked for", %{
      store: store
    } do
      {pack, [_pack, large]} = Pack.from_segments(store, :m, segments())
      File.rm!(Blob.path(store, large))

      assert Pack.chunks(store, pack.pack, [:param_decided]) ==
               {:ok, %{param_decided: "b\tc\n"}}

      assert Pack.chunks(store, pack.pack, [:instr]) == {:missing, large}
      assert Pack.chunks(store, pack.pack, [:function_def]) == {:missing, large}
    end
  end
end
