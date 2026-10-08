defmodule Argus.Dl.Embedded do
  @moduledoc """
  argus's Datalog rules (`priv/dl`), carried in this module's code as
  one gzipped literal, for a build with no priv directory on disk (an
  escript). `Argus.Dl.root/0` unpacks them when it needs a directory.

  The tree is read when this module compiles, and each file is an
  external resource: an edit to a rule recompiles it, and moves the
  tree's digest (`digest/0`), which names the directory it unpacks to.
  """

  @dl Path.expand("../../../priv/dl", __DIR__)

  @files @dl
         |> Path.join("**/*")
         |> Path.wildcard()
         |> Enum.filter(&File.regular?/1)
         |> Enum.sort()
         |> Enum.map(&{Path.relative_to(&1, @dl), File.read!(&1)})

  for {relative, _content} <- @files do
    @external_resource Path.join(@dl, relative)
  end

  @digest :crypto.hash(:sha256, :erlang.term_to_binary(@files, [:deterministic]))
          |> Base.encode16(case: :lower)

  @payload :zlib.gzip(:erlang.term_to_binary(@files, [:deterministic]))

  # A rule added to or removed from the tree changes no file this module
  # names as a resource: its listing does.
  @paths Enum.map(@files, &elem(&1, 0))

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    @dl
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @dl))
    |> Enum.sort()
    |> Kernel.!=(@paths)
  end

  @doc "The digest of the tree of rules: every file by its path and content."
  @spec digest() :: String.t()
  def digest, do: @digest

  @doc "Every file of the tree, by its path relative to `dl/`, with its content."
  @spec files() :: [{Path.t(), binary()}]
  def files, do: @payload |> :zlib.gunzip() |> :erlang.binary_to_term()

  @doc """
  The tree unpacked under `base`, at `<base>/<digest>`: written into a
  directory of its own and renamed into place, unless an earlier run
  (or a concurrent one) put it there first. Returns the directory.
  """
  @spec unpack!(Path.t()) :: Path.t()
  def unpack!(base) do
    target = Path.join(base, @digest)

    if File.dir?(target) do
      target
    else
      staging =
        Path.join(base, ".#{@digest}.#{:os.getpid()}.#{System.unique_integer([:positive])}")

      files = files()
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

        install(staging, target)
      after
        File.rm_rf(staging)
      end
    end
  end

  # A rename onto a directory another run installed meanwhile fails
  # (it is not empty); that run's tree is this one's.
  defp install(staging, target) do
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
            action: "install argus's Datalog rules at",
            source: staging,
            destination: target
        end
    end
  end
end
