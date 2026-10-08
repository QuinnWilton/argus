defmodule Argus.RawFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.RawFile

  @moduletag :tmp_dir

  # A tree of directories and files, some named with a leading dot, some
  # with the extension asked for and some without.
  defp tree(depth) do
    entry =
      if depth == 0,
        do: file(),
        else: one_of([file(), tuple({:dir, name(), tree(depth - 1)})])

    list_of(entry, max_length: 4)
  end

  defp file, do: tuple({:file, name(), member_of([".dl", ".dlx", ".txt", ""])})

  defp name,
    do:
      map(
        tuple({member_of(["", "."]), string(:alphanumeric, min_length: 1, max_length: 4)}),
        fn {dot, n} -> dot <> n end
      )

  defp write!(dir, entries) do
    File.mkdir_p!(dir)

    for entry <- entries do
      case entry do
        {:file, name, ext} -> File.write!(Path.join(dir, name <> ext), name)
        {:dir, name, children} -> write!(Path.join(dir, name <> ".d"), children)
      end
    end
  end

  property "files/2 finds what Path.wildcard/1 finds", %{tmp_dir: tmp} do
    check all(entries <- tree(3), max_runs: 50) do
      root = Path.join(tmp, "t#{System.unique_integer([:positive])}")
      write!(root, entries)

      assert RawFile.files(root, ".dl") == Path.wildcard(Path.join(root, "**/*.dl"))
    end
  end

  property "cp_r! copies a tree as File.cp_r! does", %{tmp_dir: tmp} do
    check all(entries <- tree(3), max_runs: 25) do
      root = Path.join(tmp, "t#{System.unique_integer([:positive])}")
      write!(Path.join(root, "src"), entries)

      RawFile.cp_r!(Path.join(root, "src"), Path.join(root, "raw"))
      File.cp_r!(Path.join(root, "src"), Path.join(root, "file"))

      assert contents(Path.join(root, "raw")) == contents(Path.join(root, "file"))
    end
  end

  defp contents(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true), into: %{} do
      {Path.relative_to(path, dir), if(File.dir?(path), do: :dir, else: File.read!(path))}
    end
  end

  test "stat, read and ls agree with File's, and say why they cannot", %{tmp_dir: tmp} do
    path = Path.join(tmp, "a.dl")
    File.write!(path, "content")

    assert RawFile.stat(path) == File.stat(path, time: :posix)
    assert RawFile.stat(tmp) == File.stat(tmp, time: :posix)
    assert RawFile.read(path) == {:ok, "content"}
    assert RawFile.read!(path) == "content"
    assert RawFile.ls(tmp) == File.ls(tmp)

    missing = Path.join(tmp, "missing")
    assert RawFile.stat(missing) == {:error, :enoent}
    assert RawFile.read(missing) == {:error, :enoent}
    assert RawFile.ls(missing) == {:error, :enoent}
    assert RawFile.files(missing, ".dl") == []

    assert_raise File.Error, ~r/could not read file .*missing": no such file/, fn ->
      RawFile.read!(missing)
    end

    assert_raise File.Error, ~r/could not copy .*missing/, fn ->
      RawFile.cp_r!(missing, Path.join(tmp, "copy"))
    end
  end

  test "mkdir_p makes every missing directory and is satisfied by one there", %{tmp_dir: tmp} do
    deep = Path.join([tmp, "a", "b", "c"])
    assert RawFile.mkdir_p(deep) == :ok
    assert File.dir?(deep)
    assert RawFile.mkdir_p(deep) == :ok

    file = Path.join(tmp, "file")
    File.write!(file, "")
    assert RawFile.mkdir_p(file) == {:error, :eexist}
    assert RawFile.mkdir_p(Path.join(file, "below")) == {:error, :enotdir}
    assert_raise File.Error, fn -> RawFile.mkdir_p!(file) end
  end
end
