defmodule Argus.FlowLog.Native do
  @moduledoc """
  The Rust sources argus builds its FlowLog toolchain from
  (`native/flowlog`), carried in this module's code as one gzipped
  literal, the way `Argus.Dl.Embedded` carries the rules: a Mix build, a
  Hex dependency and an escript all build from the same bytes.

    * `tool/` — `argus-flowlog-tool`: inspects a program (its inputs and
      outputs, or the diagnostic that rejects it) and generates the
      sources of the engine that hosts it.
    * `engine/` — the engine template: the host every program's engine
      shares, completed per program by the tool's generated module and
      glue.

  Both pin FlowLog to one revision and carry their `Cargo.lock`, so every
  machine builds the same toolchain from the same sources. `digest/0`
  names them, and with them what a solve of any program means: it is part
  of every program's digest (`Argus.Graph.Programs`).
  """

  @native Path.expand("../../../native/flowlog", __DIR__)

  # Only sources travel: a developer's `target/` or a generated module in
  # the template are build products.
  @files @native
         |> Path.join("**/*")
         |> Path.wildcard()
         |> Enum.filter(&File.regular?/1)
         |> Enum.map(&Path.relative_to(&1, @native))
         |> Enum.reject(
           &(String.contains?(&1, "target/") or
               &1 in ["engine/src/program.rs", "engine/src/glue.rs"])
         )
         |> Enum.sort()
         |> Enum.map(&{&1, File.read!(Path.join(@native, &1))})

  for {relative, _content} <- @files do
    @external_resource Path.join(@native, relative)
  end

  @digest :crypto.hash(:sha256, :erlang.term_to_binary(@files, [:deterministic]))
          |> Base.encode16(case: :lower)

  @payload :zlib.gzip(:erlang.term_to_binary(@files, [:deterministic]))

  @paths Enum.map(@files, &elem(&1, 0))

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    @native
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @native))
    |> Enum.reject(
      &(String.contains?(&1, "target/") or &1 in ["engine/src/program.rs", "engine/src/glue.rs"])
    )
    |> Enum.sort()
    |> Kernel.!=(@paths)
  end

  @doc "The digest of the toolchain's sources: every file by its path and content."
  @spec digest() :: String.t()
  def digest, do: @digest

  @doc "Every source file, by its path relative to `native/flowlog`, with its content."
  @spec files() :: [{Path.t(), binary()}]
  def files, do: @payload |> :zlib.gunzip() |> :erlang.binary_to_term()

  @doc """
  The FlowLog revision the toolchain pins, as its `Cargo.toml`s name it.
  """
  @spec flowlog_revision() :: String.t()
  def flowlog_revision do
    {_, manifest} = List.keyfind(files(), "engine/Cargo.toml", 0)
    [_, rev] = Regex.run(~r/flowlog-runtime = \{[^}]*rev = "([^"]+)"/, manifest)
    rev
  end

  @doc """
  The sources unpacked under `base`, at `<base>/<digest>`: written into a
  directory of its own and renamed into place, unless an earlier run (or
  a concurrent one) put them there first. Returns the directory.
  """
  @spec unpack!(Path.t()) :: Path.t()
  def unpack!(base) do
    target = Path.join(base, @digest)

    if File.dir?(target) do
      target
    else
      staging =
        Path.join(base, ".#{@digest}.#{:os.getpid()}.#{System.unique_integer([:positive])}")

      File.mkdir_p!(staging)

      try do
        for {relative, content} <- files() do
          path = Path.join(staging, relative)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
        end

        case :file.rename(staging, target) do
          :ok ->
            target

          {:error, reason} when reason in [:eexist, :enotempty] ->
            target

          {:error, reason} ->
            raise File.RenameError,
              reason: reason,
              action: "install the FlowLog toolchain sources at",
              source: staging,
              destination: target
        end
      after
        File.rm_rf(staging)
      end
    end
  end
end
