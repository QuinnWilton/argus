defmodule Argus.CacheTest do
  @moduledoc """
  The store's retention policy (`Argus.Cache.stale/2`) and its content
  digests.
  """
  use ExUnit.Case, async: true

  alias Argus.Cache

  @moduletag :tmp_dir

  @hour 60 * 60

  defp key(char), do: String.duplicate(char, 64)

  defp entries(dir, names_and_ages) do
    now = System.os_time(:second)

    for {name, age} <- names_and_ages do
      path = Path.join(dir, name)

      if String.starts_with?(name, "programs/"),
        do: File.mkdir_p!(Path.dirname(path)) && File.write!(path, "x\ty\n"),
        else: File.mkdir_p!(path)

      File.touch!(path, now - age)
    end
  end

  test "each group keeps its most recent entries and anything touched within the hour",
       %{tmp_dir: root} do
    entries(root, [
      {"shards/base-0123456789abcdef-#{key("a")}", 5 * @hour},
      {"shards/base-0123456789abcdef-#{key("b")}", 4 * @hour},
      {"shards/base-0123456789abcdef-#{key("c")}", 3 * @hour},
      {"shards/base-0123456789abcdef-#{key("d")}", 60},
      {"shards/base-fedcba9876543210-#{key("a")}", 9 * @hour},
      {"solves/races-0123456789abcdef-#{key("a")}", 2 * @hour},
      {"solves/races-0123456789abcdef-#{key("b")}", 3 * @hour},
      {"programs/races-#{key("a")}", 3 * @hour},
      {"programs/races-#{key("b")}", 4 * @hour}
    ])

    # base over the first beams keeps its live entry and its most
    # recent other; each other group's one most recent is spared.
    assert Cache.stale(root, recent: 1) ==
             Enum.map(
               [
                 "shards/base-0123456789abcdef-#{key("a")}",
                 "shards/base-0123456789abcdef-#{key("b")}",
                 "solves/races-0123456789abcdef-#{key("b")}",
                 "programs/races-#{key("b")}"
               ],
               &Path.join(root, &1)
             )
             |> Enum.sort()
  end

  test "max_age removes what no recent run has touched, however recent in its group",
       %{tmp_dir: root} do
    entries(root, [
      {"solves/p-#{key("a")}", 30 * @hour},
      {"solves/q-#{key("a")}", 2 * @hour},
      {"solves/q-#{key("b")}", 60}
    ])

    assert Cache.stale(root, max_age: 24 * @hour) == [Path.join(root, "solves/p-#{key("a")}")]
  end

  test "keep and the hour are never pruned; staging goes after a day; other names never",
       %{tmp_dir: root} do
    entries(root, [
      {"solves/p-#{key("a")}", 30 * @hour},
      {"solves/p-#{key("b")}", 30 * @hour},
      {"solves/p-#{key("c")}", 10},
      {"solves/p-#{key("d")}.123.4", 2 * @hour},
      {"solves/p-#{key("e")}.123.5", 25 * @hour},
      {"solves/notes", 48 * @hour}
    ])

    assert Cache.prune(root, recent: 0, keep: ["p-#{key("a")}"]) ==
             Enum.map(
               ["solves/p-#{key("b")}", "solves/p-#{key("e")}.123.5"],
               &Path.join(root, &1)
             )

    assert root |> Path.join("solves") |> File.ls!() |> Enum.sort() ==
             ["notes", "p-#{key("a")}", "p-#{key("c")}", "p-#{key("d")}.123.4"]
  end

  test "an installed entry is read-only, and a second install of the key loses",
       %{tmp_dir: root} do
    entry = Path.join(root, "p-#{key("a")}")

    for content <- ["first", "second"] do
      {:ok, staging} = Cache.staging(entry)
      File.write!(Path.join(staging, "out.csv"), content)
      assert :ok = Cache.install(staging, entry)
      refute File.exists?(staging)
    end

    assert File.read!(Path.join(entry, "out.csv")) == "first"
    assert File.stat!(Path.join(entry, "out.csv")).access == :read
    assert {:ok, ^entry} = Cache.fetch(entry)
    assert Cache.fetch(Path.join(root, "p-#{key("b")}")) == :miss
  end

  test "file digests are of the bytes, one file or several joined", %{tmp_dir: tmp} do
    one = Path.join(tmp, "one")
    two = Path.join(tmp, "two")
    File.write!(one, "a\tb\n")
    File.write!(two, "c\n")

    assert {:ok, digest} = Cache.file_digest(one)
    assert digest == Base.encode16(:crypto.hash(:sha256, "a\tb\n"), case: :lower)

    assert Cache.files_digest([one, two]) ==
             {:ok, Base.encode16(:crypto.hash(:sha256, "a\tb\nc\n"), case: :lower)}

    assert {:error, :enoent} = Cache.file_digest(Path.join(tmp, "none"))
  end
end
