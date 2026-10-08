defmodule Argus.EmbeddedTree do
  @moduledoc """
  A directory tree carried in a module's code as one gzipped literal,
  for a build with no source tree on disk (a Hex dependency, an
  escript): `Argus.Dl.Embedded` carries the Datalog rules and
  `Argus.FlowLog.Native` the FlowLog toolchain's sources.

  The carrying module reads the tree when it compiles (`read/2`), names
  each file an external resource, and recompiles when the tree's listing
  moves (`listing/2`). Its digest (`digest/1`) names the directory the
  tree unpacks to (`unpack!/4`).
  """

  @typedoc "Every file of a tree, by its path relative to the root, with its content."
  @type files :: [{Path.t(), binary()}]

  @typedoc """
  Paths a tree leaves out: one ending in `/` leaves out every path that
  contains it (`"target/"`), any other leaves out that path alone.
  """
  @type except :: [String.t()]

  @doc "The files under `root`, but `except`, sorted by path."
  @spec read(Path.t(), except()) :: files()
  def read(root, except) do
    for relative <- listing(root, except), do: {relative, File.read!(Path.join(root, relative))}
  end

  @doc "The paths `read/2` reads, relative to `root`, sorted."
  @spec listing(Path.t(), except()) :: [Path.t()]
  def listing(root, except) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&excluded?(&1, except))
    |> Enum.sort()
  end

  defp excluded?(relative, except) do
    Enum.any?(except, fn
      skip ->
        if String.ends_with?(skip, "/"),
          do: String.contains?(relative, skip),
          else: relative == skip
    end)
  end

  @doc "The digest of a tree: every file by its path and content, as lowercase hex."
  @spec digest(files()) :: String.t()
  def digest(files) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(files, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "The literal a module carries `files` as."
  @spec pack(files()) :: binary()
  def pack(files), do: :zlib.gzip(:erlang.term_to_binary(files, [:deterministic]))

  @doc "The files a `pack/1` literal holds."
  @spec unpack(binary()) :: files()
  def unpack(payload), do: payload |> :zlib.gunzip() |> :erlang.binary_to_term()

  @doc """
  `files` unpacked under `base`, at `<base>/<digest>`: written into a
  directory of its own and renamed into place, unless an earlier run (or
  a concurrent one) put the tree there first. Returns the directory. A
  rename that fails with no tree in place raises `File.RenameError`,
  saying it failed to `action` the target.
  """
  @spec unpack!(Path.t(), String.t(), files(), String.t()) :: Path.t()
  def unpack!(base, digest, files, action) do
    target = Path.join(base, digest)

    if File.dir?(target) do
      target
    else
      staging =
        Path.join(base, ".#{digest}.#{:os.getpid()}.#{System.unique_integer([:positive])}")

      Argus.RawFile.mkdir_p!(staging)

      try do
        # Each directory made once and the files written directly: one
        # by one through the file server, a tree of a hundred files and
        # dozens of directories queued every other file read of the VM.
        files
        |> Enum.map(fn {relative, _} -> Path.dirname(Path.join(staging, relative)) end)
        |> Enum.uniq()
        |> Enum.each(&Argus.RawFile.mkdir_p!/1)

        for {relative, content} <- files do
          File.write!(Path.join(staging, relative), content, [:raw])
        end

        install(staging, target, action)
      after
        File.rm_rf(staging)
      end
    end
  end

  # A rename onto a directory another run installed meanwhile fails
  # (it is not empty); that run's tree is this one's.
  defp install(staging, target, action) do
    case :file.rename(staging, target) do
      :ok ->
        target

      {:error, reason} when reason in [:eexist, :enotempty] ->
        target

      {:error, reason} ->
        if File.dir?(target) do
          target
        else
          raise File.RenameError,
            reason: reason,
            action: action,
            source: staging,
            destination: target
        end
    end
  end
end
