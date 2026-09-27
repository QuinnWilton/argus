defmodule Argus.DlTest do
  @moduledoc """
  The rules an escript carries (`Argus.Dl.Embedded`) are the tree in
  `priv/dl`, file for file, and unpack once per tree, atomically.
  """

  use ExUnit.Case, async: true

  alias Argus.Dl.Embedded

  @moduletag :tmp_dir

  @priv_dl Path.expand("../../priv/dl", __DIR__)

  test "in a Mix build the rules are the application's priv/dl" do
    assert File.regular?(Path.join(Argus.Dl.root(), "base.dl"))
    assert Argus.Dl.path("stage0.dl") == Path.join(Argus.Dl.root(), "stage0.dl")
  end

  test "the embedded tree is priv/dl, file for file" do
    on_disk =
      @priv_dl
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, @priv_dl), File.read!(&1)})

    assert Embedded.files() == on_disk
  end

  test "unpacking writes the tree under its digest, once", %{tmp_dir: dir} do
    target = Embedded.unpack!(dir)
    assert target == Path.join(dir, Embedded.digest())

    for {relative, content} <- Embedded.files() do
      assert File.read!(Path.join(target, relative)) == content
    end

    # A second unpack finds it there and writes nothing.
    stat = File.stat!(Path.join(target, "base.dl"))
    assert Embedded.unpack!(dir) == target
    assert File.stat!(Path.join(target, "base.dl")) == stat

    # No staging directory is left behind.
    assert File.ls!(dir) == [Embedded.digest()]
  end

  test "runs racing to unpack agree on one tree", %{tmp_dir: dir} do
    targets =
      1..8
      |> Task.async_stream(fn _ -> Embedded.unpack!(dir) end, timeout: :infinity)
      |> Enum.map(fn {:ok, target} -> target end)
      |> Enum.uniq()

    assert targets == [Path.join(dir, Embedded.digest())]
    assert File.ls!(dir) == [Embedded.digest()]

    assert File.read!(Path.join(hd(targets), "base.dl")) ==
             File.read!(Path.join(@priv_dl, "base.dl"))
  end
end
