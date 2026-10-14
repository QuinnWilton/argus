defmodule Argus.Test.Store do
  @moduledoc """
  Where the suite keeps its blob store: under the user's cache
  (`Argus.Dirs.cache_home/0`), in a directory of the checkout's own,
  never in the checkout. The suite writes hundreds of thousands of
  entries a day, and a store inside the working tree had every editor
  and file watcher over the tree (and the file system's event log
  behind them) take each one.

  A checkout's directory is `argus/test/<name>-<hash>` under the cache:
  its working directory's name, for a person looking, and a hash of its
  build path (`Mix.Project.build_path/0`), so two checkouts of one name
  never share a store. It holds the store (`store`) and the build path
  it belongs to (`checkout`): `prune_orphans/0` takes the directories of
  checkouts whose build is gone (a worktree removed, `_build` deleted),
  as deleting the build took the store when it lived there.

  `ARGUS_TEST_STORE` names the store instead (CI keeps it in the build,
  which its cache saves between runs). Where the cache cannot be
  written, the store is in the build as it was.
  """

  @doc "The suite's store's root, its directory made (see the moduledoc)."
  @spec root() :: Path.t()
  def root do
    case System.get_env("ARGUS_TEST_STORE", "") do
      "" -> cached_root()
      root -> Path.expand(root)
    end
  end

  defp cached_root do
    build = Path.expand(Mix.Project.build_path())
    dir = Path.join(base(), "#{Path.basename(File.cwd!())}-#{hash(build)}")
    checkout = Path.join(dir, "checkout")

    with :ok <- File.mkdir_p(dir),
         :ok <- record(checkout, build) do
      Path.join(dir, "store")
    else
      {:error, _} -> Path.join(build, "argus/store")
    end
  end

  # The build path, written when it is not there already: a warm start
  # writes nothing.
  defp record(checkout, build) do
    case File.read(checkout) do
      {:ok, ^build} -> :ok
      _ -> File.write(checkout, build)
    end
  end

  defp base, do: Path.join([Argus.Dirs.cache_home(), "argus", "test"])

  defp hash(build),
    do: :sha256 |> :crypto.hash(build) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @doc """
  Removes the directories of checkouts whose build is gone (a worktree
  removed, a build cleaned), and returns them. A directory that does
  not say whose it is is left alone: it may be one being made.
  """
  @spec prune_orphans() :: [Path.t()]
  def prune_orphans do
    orphans =
      for name <- ls(base()),
          dir = Path.join(base(), name),
          {:ok, build} <- [File.read(Path.join(dir, "checkout"))],
          not File.dir?(build),
          do: dir

    Argus.Test.Files.rm_rf!(orphans)
    orphans
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end
end
